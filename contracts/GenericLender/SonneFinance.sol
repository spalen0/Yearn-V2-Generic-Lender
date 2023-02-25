// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./GenericLenderBase.sol";
import "../Interfaces/Compound/CErc20I.sol";
import "../Interfaces/Compound/InterestRateModel.sol";
import "../Interfaces/Compound/ComptrollerI.sol";
import "../Interfaces/Sonne/IVelodromeRouter.sol";
import "../Interfaces/Sonne/IPriceOracle.sol";
import "../Interfaces/utils/IBaseFee.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/********************
 *   A lender plugin for LenderYieldOptimiser for any erc20 asset on compound (not eth)
 *   Made by SamPriestley.com
 *   https://github.com/Grandthrax/yearnv2/blob/master/contracts/GenericLender/GenericCompound.sol
 *
 ********************* */

contract SonneFinance is GenericLenderBase {
    using Address for address;
    using SafeMath for uint256;

    // Velodrome router
    IVelodromeRouter internal constant VELODROME_ROUTER =
        IVelodromeRouter(0x9c12939390052919aF3155f41Bf4160Fd3666A6f);

    // Sonne Finance uses distribution per seconds instead of blocks
    uint256 internal constant BLOCKS_PER_YEAR = 31_536_000;
    address internal constant USDC = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
    address internal constant SONNE = 0x1DB2466d9F5e10D7090E7152B68d62703a2245F0;
    ComptrollerI public constant COMPTROLLER =
        ComptrollerI(0x60CF091cD3f50420d50fD7f707414d0DF4751C58);

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
            "SonneFinance already initialized"
        );
        cToken = CErc20I(_cToken);
        require(cToken.underlying() == address(want), "WRONG CTOKEN");
        want.safeApprove(_cToken, type(uint256).max);
        IERC20(SONNE).safeApprove(address(VELODROME_ROUTER), type(uint256).max);
        minCompToClaim = 1 ether;
        minCompToSell = 10 ether;
        // setting dust is importmant! see values for each asset in conifgtest
    }

    function cloneSonneFinance(
        address _strategy,
        string memory _name,
        address _cToken
    ) external returns (address newLender) {
        newLender = _clone(_strategy, _name);
        SonneFinance(newLender).initialize(_cToken);
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
        (, uint256 currentCr, , uint256 exchangeRate) = cToken.getAccountSnapshot(address(this));
        balance = currentCr.mul(exchangeRate).div(1e18);
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
        // SONNE issued per block to suppliers * (1 * 10 ^ 18)
        uint256 compSpeedPerBlock = COMPTROLLER.compSupplySpeeds(address(cToken));
        if (compSpeedPerBlock == 0) {
            return 0;
        }
        // Approximate SONNE issued per year to suppliers * (1 * 10 ^ 18)
        uint256 compSpeedPerYear = compSpeedPerBlock * BLOCKS_PER_YEAR;

        // The price of the asset in USD as an unsigned integer scaled up by 10 ^ 6
        (uint256 rewardTokenPriceInUsd, ) = VELODROME_ROUTER.getAmountOut(1 ether, SONNE, USDC);

        // https://docs.compound.finance/v2/prices/#underlying-price
        // The price of the asset in USD as an unsigned integer scaled up by 10 ^ (36 - underlying asset decimals)
        uint256 wantPriceInUsd = IPriceOracle(COMPTROLLER.oracle())
            .getUnderlyingPrice(address(cToken))
            .div(10 ** (30 - vault.decimals())); // 36 - 6 (for rewardTokenPriceInUsd) - underlying decimals

        uint256 cTokenTotalSupplyInWant = cToken.totalSupply().mul(cToken.exchangeRateStored()).div(1e18);

        return rewardTokenPriceInUsd
            .mul(compSpeedPerYear)
            .mul(10 ** vault.decimals())
            .div(cTokenTotalSupplyInWant.add(newAmount).mul(wantPriceInUsd));
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
        // balanceOfUnderlying accrues interest in a transaction
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
        uint256 compBalance = IERC20(SONNE).balanceOf(address(this));

        if (compBalance > minCompToSell) {
            IVelodromeRouter.route[] memory path; // TODO: see what is the best option to define the path on velodrome
            if (address(want) == USDC) {
                path = new IVelodromeRouter.route[](1);
                path[0] = IVelodromeRouter.route({
                    from: SONNE,
                    to: USDC,
                    stable: false
                });
            } else {
                path = new IVelodromeRouter.route[](2);
                path[0] = IVelodromeRouter.route({
                    from: SONNE,
                    to: USDC,
                    stable: false
                });
                path[1] = IVelodromeRouter.route({
                    from: USDC,
                    to: address(want),
                    stable: false
                });
            }

            IVelodromeRouter(VELODROME_ROUTER).swapExactTokensForTokens(
                compBalance,
                0,
                path,
                address(this),
                now
            );
        }
    }

    /**
     * @notice Get pending SONNE rewards for supplying want token
     * @dev Pending rewards are update in comptroller afer every ctoken mint or redeem
     * @return Amount of pending SONNE tokens
     */
    function getRewardsPending() public view returns (uint256) {
        // https://github.com/compound-finance/compound-protocol/blob/master/contracts/Comptroller.sol#L1230
        ComptrollerI.CompMarketState memory supplyState = COMPTROLLER.compSupplyState(address(cToken));
        uint256 supplyIndex = supplyState.index;
        uint256 supplierIndex = COMPTROLLER.compSupplierIndex(address(cToken), address(this));

        // Calculate change in the cumulative sum of the SONNE per cToken accrued
        uint256 deltaIndex = supplyIndex.sub(supplierIndex);

        // Calculate SONNE accrued: cTokenAmount * accruedPerCToken / doubleScale
        return cToken.balanceOf(address(this)).mul(deltaIndex).div(1e36);
    }

    /**
     * @notice Collect all pending SONNE rewards for supplying want token
     */
    function claimComp() external keepers {
        _claimComp();
    }

    function _claimComp() internal {
        CTokenI[] memory cTokens = new CTokenI[](1);
        cTokens[0] = cToken;
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
        _disposeOfComp();
        
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
        // if (!isBaseFeeAcceptable()) return false;
        return IERC20(SONNE).balanceOf(address(this)).add(getRewardsPending()) > minCompToClaim;
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
        cToken.accrueInterest();
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    function hasAssets() external view override returns (bool) {
        return
            cToken.balanceOf(address(this)) > dust ||
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
        address[] memory protected = new address[](1);
        protected[0] = address(want);
        return protected;
    }

    // check if the current baseFee is below our external target
    // function isBaseFeeAcceptable() internal view returns (bool) {
    //     return
    //         IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F) // TODO: change to optimism address
    //             .isCurrentBaseFeeAcceptable();
    // }

    /**
     * @notice Set values for handling SONNE reward token
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
}
