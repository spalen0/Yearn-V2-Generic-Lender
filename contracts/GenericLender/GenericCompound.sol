// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./GenericLenderBase.sol";
import "../Interfaces/Compound/CErc20I.sol";
import "../Interfaces/Compound/InterestRateModel.sol";
import "../Interfaces/Compound/ComptrollerI.sol";
import "../Interfaces/Compound/UniswapAnchoredViewI.sol";
import "../Interfaces/UniswapInterfaces/IUniswapV2Router02.sol";
import "../Interfaces/ySwaps/ITradeFactory.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

/********************
 *   A lender plugin for LenderYieldOptimiser for any erc20 asset on compound (not eth)
 *   Made by SamPriestley.com
 *   https://github.com/Grandthrax/yearnv2/blob/master/contracts/GenericLender/GenericCompound.sol
 *
 ********************* */

contract GenericCompound is GenericLenderBase {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // eth blocks are mined every 12s -> 3600 * 24 * 365 / 12 = 2_628_000
    uint256 private constant BLOCKS_PER_YEAR = 2_628_000;
    address public constant UNISWAP_ROUTER =
        address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address public constant COMP =
        address(0xc00e94Cb662C3520282E6f5717214004A7f26888);
    address public constant WETH =
        address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ComptrollerI public constant COMPTROLLER =
        ComptrollerI(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    UniswapAnchoredViewI public constant PRICE_FEED =
        UniswapAnchoredViewI(0x65c816077C29b557BEE980ae3cC2dCE80204A0C5);

    address public tradeFactory;
    uint256 public minCompToSell;
    uint256 public minCompToClaim;
    address public keep3r;

    CErc20I public cToken;

    modifier keepers() {
        require(
            msg.sender == address(keep3r) ||
                msg.sender == address(strategy) ||
                msg.sender == vault.governance() ||
                msg.sender == IBaseStrategy(strategy).strategist(),
            "!keepers"
        );
        _;
    }

    constructor(
        address _strategy,
        string memory name,
        address _cToken
    ) public GenericLenderBase(_strategy, name) {
        _initialize(_cToken);
    }

    function initialize(address _cToken) external {
        _initialize(_cToken);
    }

    function _initialize(address _cToken) internal {
        require(
            address(cToken) == address(0),
            "GenericCompound already initialized"
        );
        cToken = CErc20I(_cToken);
        require(cToken.underlying() == address(want), "WRONG CTOKEN");
        want.safeApprove(_cToken, uint256(-1));
        IERC20(COMP).safeApprove(address(UNISWAP_ROUTER), type(uint256).max);
        minCompToClaim = 1 ether;
        minCompToSell = 1 ether;
        // setting dust is importmant! see values for each asset in conifgtest
    }

    function cloneCompoundLender(
        address _strategy,
        string memory _name,
        address _cToken
    ) external returns (address newLender) {
        newLender = _clone(_strategy, _name);
        GenericCompound(newLender).initialize(_cToken);
    }

    function nav() external view override returns (uint256) {
        return _nav();
    }

    function _nav() internal view returns (uint256) {
        return want.balanceOf(address(this)).add(underlyingBalanceStored());
    }

    /**
     * @notice Returns the value deposited in Compound protocol
     * @return balance in want token value
     */
    function underlyingBalanceStored() public view returns (uint256 balance) {
        uint256 currentCr = cToken.balanceOf(address(this));
        if (currentCr == 0) {
            balance = 0;
        } else {
            //The current exchange rate as an unsigned integer, scaled by 1e18.
            balance = currentCr.mul(cToken.exchangeRateStored()).div(1e18);
        }
    }

    function apr() external view override returns (uint256) {
        return _apr();
    }

    // scaled by 1e18
    function _apr() internal view returns (uint256) {
        uint256 baseApr = cToken.supplyRatePerBlock().mul(BLOCKS_PER_YEAR);
        uint256 rewardsApr = getRewardAprForSupplyBase(0);
        return baseApr.add(rewardsApr);
    }

    function weightedApr() external view override returns (uint256) {
        uint256 a = _apr();
        return a.mul(_nav());
    }

    /**
     * @notice Get the current reward for supplying APR in Compound
     * @param newAmount Any amount that will be added to the total supply in a deposit
     * @return The reward APR calculated by converting tokens value to USD with a decimal scaled up by 1e18
     */
    function getRewardAprForSupplyBase(uint256 newAmount)
        public
        view
        returns (uint256)
    {
        // The price of the asset in USD as an unsigned integer scaled up by 10 ^ 6
        uint256 rewardTokenPriceInUsd = PRICE_FEED.price("COMP");

        // The price of the asset in USD as an unsigned integer scaled up by 10 ^ (36 - underlying asset decimals)
        uint256 wantPriceInUsd = PRICE_FEED.getUnderlyingPrice(address(cToken));

        uint256 wantTotalSupply = cToken.totalSupply().add(newAmount);

        // COMP issued per block to suppliers OR borrowers * (1 * 10 ^ 18)
        uint256 compSpeed = COMPTROLLER.compSpeeds(address(cToken));
        // Approximate COMP issued per year to suppliers OR borrowers * (1 * 10 ^ 18)
        uint256 compSpeedPerYear = compSpeed * BLOCKS_PER_YEAR;
        // result 1e18 = 1e6 * 1e12 * 1e18 / 1e18
        uint256 supplyBaseRewardApr = rewardTokenPriceInUsd
            .mul(1e12)
            .mul(compSpeedPerYear)
            .div(wantTotalSupply.mul(wantPriceInUsd));

        if (vault.decimals() < 18) {
            // scale value to 1e18, see wantPriceInUsd scaling above
            supplyBaseRewardApr = supplyBaseRewardApr.div(
                10**(18 - vault.decimals())
            );
        }
        return supplyBaseRewardApr;
    }

    function withdraw(uint256 amount)
        external
        override
        management
        returns (uint256)
    {
        return _withdraw(amount);
    }

    /**
     * @notice Withdraws the specified amount from Compound along with all free want tokens.
     * @param amount to withdraw from Compound, defined in want token value
     */
    function emergencyWithdraw(uint256 amount)
        external
        override
        onlyGovernance
    {
        // dont care about errors here. we want to exit what we can
        cToken.redeemUnderlying(amount);

        want.safeTransfer(vault.governance(), want.balanceOf(address(this)));
    }

    function _withdraw(uint256 amount) internal returns (uint256) {
        // underlying balance is in want token, no need for additional conversion
        uint256 balanceUnderlying = cToken.balanceOfUnderlying(address(this));
        uint256 looseBalance = want.balanceOf(address(this));
        uint256 total = balanceUnderlying.add(looseBalance);

        if (amount > total) {
            // cant withdraw more than we own
            amount = total;
        }

        if (looseBalance >= amount) {
            want.safeTransfer(address(strategy), amount);
            return amount;
        }

        uint256 toWithdraw = amount.sub(looseBalance);
        if (toWithdraw > dust) {
            // withdraw all available liqudity from compound
            uint256 liquidity = want.balanceOf(address(cToken));
            if (toWithdraw <= liquidity) {
                // we can take all
                require(
                    cToken.redeemUnderlying(toWithdraw) == 0,
                    "ctoken: redeemUnderlying fail"
                );
            } else {
                // take all we can
                require(
                    cToken.redeemUnderlying(liquidity) == 0,
                    "ctoken: redeemUnderlying fail"
                );
            }
            // calculate withdrawan balance to new loose balance
            looseBalance = want.balanceOf(address(this));
        }

        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    function _disposeOfComp() internal {
        uint256 compBalance = IERC20(COMP).balanceOf(address(this));

        if (compBalance > minCompToSell) {
            address[] memory path = new address[](3);
            path[0] = COMP;
            path[1] = WETH;
            path[2] = address(want);

            IUniswapV2Router02(UNISWAP_ROUTER).swapExactTokensForTokens(
                compBalance,
                uint256(0),
                path,
                address(this),
                now
            );
        }
    }

    /**
     * @notice Get pending COMP rewards for supplying want token
     * @return Amount of pending COMP tokens
     */
    function getRewardsPending() public view returns (uint256) {
        return COMPTROLLER.compAccrued(address(this));
    }

    /**
     * @notice Collect all pending COMP rewards for supplying want token
     */
    function claimComp() public {
        if (getRewardsPending() > minCompToClaim) {
            CTokenI[] memory cTokens = new CTokenI[](1);
            cTokens[0] = cToken;
            address[] memory holders = new address[](1);
            holders[0] = address(this);

            // Claim only rewards for lending to reduce the gas cost
            COMPTROLLER.claimComp(holders, cTokens, true, false);
        }
    }

    /**
     * @notice Collect rewards, dispose them for want token and supply to protocol
     */
    function harvest() external keepers {
        claimComp();
        if (tradeFactory == address(0)) {
            _disposeOfComp();
        }
        
        uint256 wantBalance = want.balanceOf(address(this));
        if (wantBalance > 0) {
            cToken.mint(wantBalance);
        }
    }

    /**
     * @notice Checks if the harvest should be called
     * @return Should call harvest function
     */
    function harvestTrigger(
        uint256 /*callCost*/
    ) external view returns (bool) {
        if (getRewardsPending() > minCompToClaim) return true;
        if (IERC20(COMP).balanceOf(address(this)) > minCompToSell) return true;
    }

    /**
     * @notice Supplies free want balance to compound
     */
    function deposit() external override management {
        uint256 balance = want.balanceOf(address(this));
        require(cToken.mint(balance) == 0, "ctoken: mint fail");
    }

    /**
     * @notice Withdraws asset form compound
     * @return Is more asset returned than invested
     */
    function withdrawAll() external override management returns (bool) {
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    function hasAssets() external view override returns (bool) {
        return
            cToken.balanceOf(address(this)) > dust ||
            want.balanceOf(address(this)) > dust;
    }

    /**
     * @notice Calculate new APR for supplying amount to lender
     * @param amount to supply
     * @return New lender APR after supplying given amount
     */
    function aprAfterDeposit(uint256 amount)
        external
        view
        override
        returns (uint256)
    {
        uint256 cashPrior = want.balanceOf(address(cToken));
        uint256 borrows = cToken.totalBorrows();
        uint256 reserves = cToken.totalReserves();
        uint256 reserverFactor = cToken.reserveFactorMantissa();
        InterestRateModel model = cToken.interestRateModel();

        //the supply rate is derived from the borrow rate, reserve factor and the amount of total borrows.
        uint256 supplyRate = model.getSupplyRate(
            cashPrior.add(amount),
            borrows,
            reserves,
            reserverFactor
        );
        uint256 newSupply = supplyRate.mul(BLOCKS_PER_YEAR);
        uint256 rewardApr = getRewardAprForSupplyBase(amount);
        return newSupply.add(rewardApr);
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](3);
        protected[0] = address(want);
        protected[1] = address(cToken);
        protected[2] = COMP;
        return protected;
    }

    /**
     * @notice Set values for handling COMP reward token
     * @param _minCompToSell Minimum value that will be sold
     * @param _minCompToClaim Minimum vaule to claim from compound
     */
    function setRewardStuff(uint256 _minCompToSell, uint256 _minCompToClaim)
        external
        management
    {
        minCompToSell = _minCompToSell;
        minCompToClaim = _minCompToClaim;
    }

    function setKeep3r(address _keep3r) external management {
        keep3r = _keep3r;
    }

    // ---------------------- YSWAPS FUNCTIONS ----------------------
    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        ITradeFactory tf = ITradeFactory(_tradeFactory);

        IERC20(COMP).safeApprove(_tradeFactory, type(uint256).max);
        tf.enable(COMP, address(want));
        
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external management {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        IERC20(COMP).safeApprove(tradeFactory, 0);
        
        tradeFactory = address(0);
    }
}
