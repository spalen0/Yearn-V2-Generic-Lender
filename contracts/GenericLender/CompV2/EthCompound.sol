// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../GenericLenderBase.sol";
import "../../Interfaces/Compound/CEtherI.sol";
import "../../Interfaces/Compound/InterestRateModel.sol";
import "../../Interfaces/Compound/ComptrollerI.sol";
import "../../Interfaces/Compound/UniswapAnchoredViewI.sol";
import "../../Interfaces/UniswapInterfaces/V3/ISwapRouter.sol";
import "../../Interfaces/UniswapInterfaces/IWETH.sol";
import "../../Interfaces/ySwaps/ITradeFactory.sol";
import "../../Interfaces/utils/IBaseFee.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";


/********************
 *   A lender plugin for LenderYieldOptimiser for ETH on Compound
 ********************* */

contract EthCompound is GenericLenderBase {
    using Address for address;
    using SafeMath for uint256;

    //Uniswap v3 router
    ISwapRouter internal constant UNISWAP_ROUTER =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    //Fees for the V3 pools if the supply is incentivized
    uint24 public compToEthFee;

    // eth blocks are mined every 12s -> 3600 * 24 * 365 / 12 = 2_628_000
    uint256 private constant BLOCKS_PER_YEAR = 2_628_000;
    address public constant COMP = 0xc00e94Cb662C3520282E6f5717214004A7f26888;
    ComptrollerI public constant COMPTROLLER =
        ComptrollerI(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    UniswapAnchoredViewI public constant PRICE_FEED =
        UniswapAnchoredViewI(0x65c816077C29b557BEE980ae3cC2dCE80204A0C5);
    IWETH public constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    CEtherI public constant C_ETH = CEtherI(0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5);

    address public tradeFactory;
    uint256 public minCompToSell;
    uint256 public minCompToClaim;
    address public keep3r;

    constructor(address _strategy, string memory name) public GenericLenderBase(_strategy, name) {
        require(address(want) == address(WETH), "NOT WETH");
        IERC20(COMP).safeApprove(address(UNISWAP_ROUTER), type(uint256).max);
        minCompToClaim = 1 ether;
        minCompToSell = 10 ether;
        compToEthFee = 3000;
        dust = 1e9;
    }

    //to receive eth from weth
    receive() external payable {}

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

    function nav() external view override returns (uint256) {
        return _nav();
    }

    function _nav() internal view returns (uint256) {
        return want.balanceOf(address(this)).add(underlyingBalanceStored());
    }

    function underlyingBalanceStored() public view returns (uint256 balance) {
        (, uint256 currentCr, , uint256 exchangeRate) = C_ETH.getAccountSnapshot(address(this));
        balance = currentCr.mul(exchangeRate).div(1e18);
    }

    function apr() external view override returns (uint256) {
        return _apr();
    }

    function _apr() internal view returns (uint256) {
        uint256 baseApr = C_ETH.supplyRatePerBlock().mul(BLOCKS_PER_YEAR);
        uint256 rewardsApr = getRewardAprForSupplyBase(0);
        return baseApr.add(rewardsApr);
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
        // COMP issued per block to suppliers * (1 * 10 ^ 18)
        uint256 compSpeedPerBlock = COMPTROLLER.compSupplySpeeds(address(C_ETH));
        if (compSpeedPerBlock == 0) {
            return 0;
        }
        // Approximate COMP issued per year to suppliers * (1 * 10 ^ 18)
        uint256 compSpeedPerYear = compSpeedPerBlock * BLOCKS_PER_YEAR;

        // The price of the asset in USD as an unsigned integer scaled up by 10 ^ 6
        uint256 rewardTokenPriceInUsd = PRICE_FEED.price("COMP");

        // The price of the asset in USD as an unsigned integer scaled up by 10 ^ (36 - 18(underlying asset decimals))
        // upscale to price COMP percision 10 ^ 6
        uint256 wantPriceInUsd = PRICE_FEED.getUnderlyingPrice(address(C_ETH)).div(1e12);

        uint256 cTokenTotalSupplyInWant = C_ETH.totalSupply().mul(C_ETH.exchangeRateStored()).div(1e18);

        return rewardTokenPriceInUsd
            .mul(compSpeedPerYear)
            .mul(1e18)
            .div(cTokenTotalSupplyInWant.add(newAmount).mul(wantPriceInUsd));
    }

    function weightedApr() external view override returns (uint256) {
        uint256 a = _apr();
        return a.mul(_nav());
    }

    function withdraw(uint256 amount) external override management returns (uint256) {
        return _withdraw(amount);
    }

    //emergency withdraw. sends balance plus amount to governance
    function emergencyWithdraw(uint256 amount) external override onlyGovernance {
        C_ETH.redeemUnderlying(amount);

        //now turn to weth
        WETH.deposit{value: address(this).balance}();

        want.safeTransfer(vault.governance(), want.balanceOf(address(this)));
    }

    //withdraw an amount including any want balance
    function _withdraw(uint256 amount) internal returns (uint256) {
        // underlying balance is in want token, no need for additional conversion
        // balanceOfUnderlying accrues interest in a transaction
        uint256 balanceUnderlying = C_ETH.balanceOfUnderlying(address(this));
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
            uint256 liquidity = C_ETH.getCash();
            if (toWithdraw <= liquidity) {
                // we can take all
                C_ETH.redeemUnderlying(toWithdraw);
            } else {
                // take all we can
                C_ETH.redeemUnderlying(liquidity);
            }
        }
        WETH.deposit{value: address(this).balance}();
        looseBalance = want.balanceOf(address(this));
        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    function _disposeOfComp() internal {
        uint256 compBalance = IERC20(COMP).balanceOf(address(this));

        if (compBalance > minCompToSell) {
            ISwapRouter.ExactInputSingleParams memory params =
                ISwapRouter.ExactInputSingleParams(
                    COMP, // tokenIn
                    address(want), // tokenOut
                    compToEthFee, // comp-eth fee
                    address(this), // recipient
                    now, // deadline
                    compBalance, // amountIn
                    0, // amountOut
                    0 // sqrtPriceLimitX96
                );
            UNISWAP_ROUTER.exactInputSingle(params);
        }
    }

    /**
     * @notice Get pending COMP rewards for supplying want token
     * @return Amount of pending COMP tokens
     */
    function getRewardsPending() public view returns (uint256) {
        // https://github.com/compound-finance/compound-protocol/blob/master/contracts/Comptroller.sol#L1230
        ComptrollerI.CompMarketState memory supplyState = COMPTROLLER.compSupplyState(address(C_ETH));
        uint256 supplyIndex = supplyState.index;
        uint256 supplierIndex = COMPTROLLER.compSupplierIndex(address(C_ETH), address(this));

        // Calculate change in the cumulative sum of the COMP per cToken accrued
        uint256 deltaIndex = supplyIndex.sub(supplierIndex);

        // Calculate COMP accrued: cTokenAmount * accruedPerCToken / doubleScale
        return C_ETH.balanceOf(address(this)).mul(deltaIndex).div(1e36);
    }

    /**
     * @notice Collect all pending COMP rewards for supplying want token
     */
    function claimComp() external keepers {
        _claimComp();
    }

    /**
     * @notice Collect all pending COMP rewards for supplying want token
     */
    function _claimComp() public {
        CTokenI[] memory cTokens = new CTokenI[](1);
        cTokens[0] = C_ETH;
        address[] memory holders = new address[](1);
        holders[0] = address(this);

        // Claim only rewards for lending to reduce the gas cost
        COMPTROLLER.claimComp(holders, cTokens, false, true);
    }

    /**
     * @notice Collect rewards, dispose them for want token and supply to protocol
     */
    function harvest() external keepers {
        _claimComp();
        if (tradeFactory == address(0) && compToEthFee != 0) {
            _disposeOfComp();
        }

        uint256 wantBalance = want.balanceOf(address(this));
        if (wantBalance > 0) {
            WETH.withdraw(wantBalance);
            C_ETH.mint{value: wantBalance}();
        }
    }

    /**
     * @notice Checks if the harvest should be called
     * @return Should call harvest function
     */
    function harvestTrigger(
        uint256 /*callCost*/
    ) external view returns (bool) {
        if (!isBaseFeeAcceptable()) return false;
        return IERC20(COMP).balanceOf(address(this)).add(getRewardsPending()) > minCompToClaim;
    }

    function deposit() external override management {
        uint256 balance = want.balanceOf(address(this));

        WETH.withdraw(balance);
        C_ETH.mint{value: balance}();
    }

    /**
     * @notice Withdraws asset form compound
     * @return Is more asset returned than invested
     */
    function withdrawAll() external override management returns (bool) {
        C_ETH.accrueInterest();
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    function hasAssets() external view override returns (bool) {
        return
            C_ETH.balanceOf(address(this)) > dust ||
            want.balanceOf(address(this)) > 0;
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
        uint256 cashPrior = C_ETH.getCash();
        uint256 borrows = C_ETH.totalBorrows();
        uint256 reserves = C_ETH.totalReserves();
        uint256 reserverFactor = C_ETH.reserveFactorMantissa();
        InterestRateModel model = C_ETH.interestRateModel();

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
        address[] memory protected = new address[](1);
        protected[0] = address(want);
        return protected;
    }

    // check if the current baseFee is below our external target
    function isBaseFeeAcceptable() internal view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }

    //These will default to 0.
    //Will need to be manually set if want is incentized before any harvests
    function setUniFees(uint24 _compToEth) external management {
        compToEthFee = _compToEth;
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
        ITradeFactory(tradeFactory).disable(COMP, address(want));
        tradeFactory = address(0);
    }
}
