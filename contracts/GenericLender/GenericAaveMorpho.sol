// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./GenericLenderBase.sol";
import "../Interfaces/Aave/ILendingPool.sol";
import "../Interfaces/Aave/IProtocolDataProvider.sol";
import "../Interfaces/Aave/IReserveInterestRateStrategy.sol";
import "../Libraries/Aave/DataTypes.sol";
import "../Libraries/Morpho/WadRayMath.sol";
import "../Libraries/Morpho/PercentageMath.sol";
import "../Interfaces/Morpho/IMorpho.sol";
import "../Interfaces/Morpho/IRewardsDistributor.sol";
import "../Interfaces/Morpho/ILens.sol";
import "../Interfaces/ySwaps/ITradeFactory.sol";

/********************
 *   A lender plugin for LenderYieldOptimiser for any borrowable erc20 asset on Morpho-Aave
 *   Made by @spalen0
 *   https://github.com/spalen0/Yearn-V2-Generic-Lender/blob/main/contracts/GenericLender/GenericAaveMorpho.sol
 *
 ********************* */

contract GenericAaveMorpho is GenericLenderBase {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    ILendingPool internal constant POOL = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IProtocolDataProvider internal constant AAVE_DATA_PROIVDER =
        IProtocolDataProvider(0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d);

    // Morpho is a contract to handle interaction with the protocol
    IMorpho internal constant MORPHO = IMorpho(0x777777c9898D384F785Ee44Acfe945efDFf5f3E0);
    // Lens is a contract to fetch data about Morpho protocol
    ILens internal constant LENS = ILens(0x507fA343d0A90786d86C7cd885f5C49263A91FF4);
    // reward token, not currently listed
    address internal constant MORPHO_TOKEN = 0x9994E35Db50125E0DF82e4c2dde62496CE330999;
    // used for claiming reward Morpho token
    address public rewardsDistributor;
    // aToken = Morpho Aave Market for want token
    address public aToken;
    // Max gas used for matching with p2p deals
    uint256 public maxGasForMatching;

    address public tradeFactory;
    address public keep3r;

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
        address _aToken
    ) public GenericLenderBase(_strategy, name) {
        _initialize(_aToken);
    }

    function initialize(address _aToken) external {
        _initialize(_aToken);
    }

    function _initialize(address _aToken) internal {
        require(
            address(aToken) == address(0),
            "GenericAaveMorpho already initialized"
        );
        aToken = _aToken;
        IMorpho.Market memory market = MORPHO.market(aToken);
        require(market.underlyingToken == address(want), "WRONG A_TOKEN");
        want.safeApprove(address(MORPHO), type(uint256).max);
        // 100000 is the default value set by Morpho
        maxGasForMatching = 100000;
        rewardsDistributor = 0x3B14E5C73e0A56D607A8688098326fD4b4292135;
    }

    function cloneMorphoAaveLender(
        address _strategy,
        string memory _name,
        address _aToken
    ) external returns (address newLender) {
        newLender = _clone(_strategy, _name);
        GenericAaveMorpho(newLender).initialize(_aToken);
    }

    function nav() external view override returns (uint256) {
        return _nav();
    }

    function _nav() internal view returns (uint256) {
        (, , uint256 balanceUnderlying) = underlyingBalance();
        return want.balanceOf(address(this)).add(balanceUnderlying);
    }

    /**
     * @notice Returns the value deposited in Morpho protocol
     * @return balanceInP2P Amount supplied through Morpho that is matched peer-to-peer
     * @return balanceOnPool Amount supplied through Morpho on the underlying protocol's pool
     * @return totalBalance Equals `balanceOnPool` + `balanceInP2P`
     */
    function underlyingBalance()
        public
        view
        returns (
            uint256 balanceInP2P,
            uint256 balanceOnPool,
            uint256 totalBalance
        )
    {
        (balanceInP2P, balanceOnPool, totalBalance) = LENS
            .getCurrentSupplyBalanceInOf(aToken, address(this));
    }

    function apr() external view override returns (uint256) {
        return _apr();
    }

    // scaled by 1e18
    function _apr() internal view returns (uint256) {
        // RAY(1e27)
        uint256 currentUserSupplyRatePerYearInRay = LENS
            .getCurrentUserSupplyRatePerYear(aToken, address(this));
        // downscale to WAD(1e18)
        return currentUserSupplyRatePerYearInRay.div(WadRayMath.WAD_RAY_RATIO);
    }

    function weightedApr() external view override returns (uint256) {
        uint256 a = _apr();
        return a.mul(_nav());
    }

    function withdraw(uint256 amount) external override management returns (uint256) {
        return _withdraw(amount);
    }

    /**
     * @notice Withdraws the specified amount from Morpho along with all free want tokens.
     * @param amount to withdraw from Morpho, defined in want token value
     */
    function emergencyWithdraw(uint256 amount) external override onlyGovernance {
        // use uint256.type(max) to withdraw everything
        MORPHO.withdraw(aToken, amount);
        want.safeTransfer(vault.governance(), want.balanceOf(address(this)));
    }

    function _withdraw(uint256 amount) internal returns (uint256) {
        (, , uint256 balanceUnderlying) = underlyingBalance();
        uint256 looseBalance = want.balanceOf(address(this));
        uint256 total = balanceUnderlying.add(looseBalance);

        if (amount > total) {
            // cant withdraw more than we own
            amount = total;
        }

        if (amount > looseBalance) {
            // if the market is paused we cannot withdraw
            IMorpho.MarketPauseStatus memory market = MORPHO.marketPauseStatus(aToken);
            if (!market.isWithdrawPaused) {
                // check if there is enough liquidity in aave
                uint256 aaveLiquidity = want.balanceOf(address(aToken));
                if (aaveLiquidity > 1) {
                    // withdraw all we need or all liquidity from aave
                    MORPHO.withdraw(aToken, Math.min(amount.sub(looseBalance), aaveLiquidity));
                }
            }
            // calculate withdrawan balance to new loose balance
            looseBalance = want.balanceOf(address(this));
        }

        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    /**
     * @notice Supply want balance
     */
    function harvest() external keepers {
        _deposit();
    }

    /**
     * @notice Supplies free want balance to Morpho
     */
    function deposit() external override management {
        _deposit();
    }

    function _deposit() internal {
        IMorpho.MarketPauseStatus memory market = MORPHO.marketPauseStatus(aToken);
        if (!market.isSupplyPaused || !market.isWithdrawPaused) {
            uint256 wantBalance = want.balanceOf(address(this));
            if (wantBalance > 0) {
                MORPHO.supply(
                    aToken,
                    address(this),
                    want.balanceOf(address(this)),
                    maxGasForMatching
                );
            }
        }
    }

    /**
     * @notice Withdraws asset form Morpho
     * @return Is more asset returned than invested
     */
    function withdrawAll() external override management returns (bool) {
        uint256 invested = _nav();
        uint256 returned = _withdraw(invested);
        return returned >= invested;
    }

    function hasAssets() external view override returns (bool) {
        (, , uint256 balanceUnderlying) = underlyingBalance();
        return
            balanceUnderlying > 0 ||
            want.balanceOf(address(this)) > 0;
    }

    /**
     * @notice Calculate new lowest possible APR for supplying amount to lender.
     * @dev For P2P APR only biggest borrower from the pool is accounted that why we get lowest possible APR.
     * @param _amount to supply.
     * @return New lender lowest possible APR after supplying given amount.
     */
    function aprAfterDeposit(uint256 _amount) external view override returns (uint256) {
        ILens.Indexes memory indexes = LENS.getIndexes(aToken);
        IMorpho.Market memory market = MORPHO.market(aToken);
        IMorpho.Delta memory delta = MORPHO.deltas(aToken);
        IMorpho.SupplyBalance memory supplyBalance = MORPHO.supplyBalanceInOf(aToken, address(this));

        uint256 repaidToPool;
        if (!market.isP2PDisabled) {
            if (delta.p2pBorrowDelta > 0) {
                uint256 matchedDelta = Math.min(
                    WadRayMath.rayMul(delta.p2pBorrowDelta, indexes.poolBorrowIndex),
                    _amount
                );

                supplyBalance.inP2P = supplyBalance.inP2P.add(WadRayMath.rayDiv(matchedDelta, indexes.p2pSupplyIndex));
                repaidToPool = repaidToPool.add(matchedDelta);
                _amount = _amount.sub(matchedDelta);
            }

            if (_amount > 0) {
                address firstPoolBorrower = MORPHO.getHead(
                    aToken,
                    IMorpho.PositionType.BORROWERS_ON_POOL
                );
                uint256 firstPoolBorrowerBalance = MORPHO
                .borrowBalanceInOf(aToken, firstPoolBorrower)
                .onPool;

                if (firstPoolBorrowerBalance > 0) {
                    uint256 matchedP2P = Math.min(
                        WadRayMath.rayMul(firstPoolBorrowerBalance, indexes.poolBorrowIndex),
                        _amount
                    );

                    supplyBalance.inP2P = supplyBalance.inP2P.add(WadRayMath.rayDiv(matchedP2P, indexes.p2pSupplyIndex));
                    repaidToPool = repaidToPool.add(matchedP2P);
                    _amount = _amount.sub(matchedP2P);
                }
                // we could add more p2p matching here, not just first head
            }
        }

        uint256 suppliedToPool;
        if (_amount > 0) {
            supplyBalance.onPool = supplyBalance.onPool.add(WadRayMath.rayDiv(_amount, indexes.poolSupplyIndex));
            suppliedToPool = _amount;
        }

        (uint256 poolSupplyRate, uint256 variableBorrowRate) = getAaveRates(suppliedToPool, repaidToPool);

        uint256 p2pSupplyRate = computeP2PSupplyRatePerYear(
            P2PRateComputeParams({
                poolSupplyRatePerYear: poolSupplyRate,
                poolBorrowRatePerYear: variableBorrowRate,
                poolIndex: indexes.poolSupplyIndex,
                p2pIndex: indexes.p2pSupplyIndex,
                p2pDelta: delta.p2pSupplyDelta,
                p2pAmount: delta.p2pSupplyAmount,
                p2pIndexCursor: market.p2pIndexCursor,
                reserveFactor: market.reserveFactor
            })
        );

        (uint256 weightedRate, ) = getWeightedRate(
            p2pSupplyRate,
            poolSupplyRate,
            WadRayMath.rayMul(supplyBalance.inP2P, indexes.p2pSupplyIndex),
            WadRayMath.rayMul(supplyBalance.onPool, indexes.poolSupplyIndex)
        );
        return weightedRate.div(WadRayMath.WAD_RAY_RATIO);
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](1);
        protected[0] = address(want);
        return protected;
    }

    /**
     * @notice Set the maximum amount of gas to consume to get matched in peer-to-peer.
     * @dev
     *  This value is needed in Morpho supply liquidity calls.
     *  Supplyed liquidity goes to loop with current loans on Morpho
     *  and creates a match for p2p deals. The loop starts from bigger liquidity deals.
     *  The default value set by Morpho is 100000.
     * @param _maxGasForMatching new maximum gas value for P2P matching
     */
    function setMaxGasForMatching(uint256 _maxGasForMatching)
        external
        management
    {
        maxGasForMatching = _maxGasForMatching;
    }

    /**
     * @notice Set new rewards distributor contract
     * @param _rewardsDistributor address of new contract
     */
    function setRewardsDistributor(address _rewardsDistributor)
        external
        management
    {
        rewardsDistributor = _rewardsDistributor;
    }

    /**
     * @notice Claims MORPHO rewards. Use Morpho API to get the data: https://api.morpho.xyz/rewards/{address}
     * @dev See stages of Morpho rewards distibution: https://docs.morpho.xyz/usdmorpho/ages-and-epochs/age-2
     * @param _account The address of the claimer.
     * @param _claimable The overall claimable amount of token rewards.
     * @param _proof The merkle proof that validates this claim.
     */
    function claimMorphoRewards(
        address _account,
        uint256 _claimable,
        bytes32[] calldata _proof
    ) external management {
        require(rewardsDistributor != address(0), "Rewards distributor not set");
        IRewardsDistributor(rewardsDistributor).claim(
            _account,
            _claimable,
            _proof
        );
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

        IERC20(MORPHO_TOKEN).safeApprove(_tradeFactory, type(uint256).max);
        tf.enable(MORPHO_TOKEN, address(want));
        
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external management {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        IERC20(MORPHO_TOKEN).safeApprove(tradeFactory, 0);
        ITradeFactory(tradeFactory).disable(MORPHO_TOKEN, address(want));
        tradeFactory = address(0);
    }

    // ---------------------- RATES CALCULATIONS ----------------------

    /// @dev Returns the rate experienced based on a given pool & peer-to-peer distribution.
    /// @param _p2pRate The peer-to-peer rate (in a unit common to `_poolRate` & `weightedRate`).
    /// @param _poolRate The pool rate (in a unit common to `_p2pRate` & `weightedRate`).
    /// @param _balanceInP2P The amount of balance matched peer-to-peer (in a unit common to `_balanceOnPool`).
    /// @param _balanceOnPool The amount of balance supplied on pool (in a unit common to `_balanceInP2P`).
    /// @return weightedRate The rate experienced by the given distribution (in a unit common to `_p2pRate` & `_poolRate`).
    /// @return totalBalance The sum of peer-to-peer & pool balances.
    function getWeightedRate(
        uint256 _p2pRate,
        uint256 _poolRate,
        uint256 _balanceInP2P,
        uint256 _balanceOnPool
    ) internal pure returns (uint256 weightedRate, uint256 totalBalance) {
        totalBalance = _balanceInP2P.add(_balanceOnPool);
        if (totalBalance == 0) return (weightedRate, totalBalance);

        if (_balanceInP2P > 0) weightedRate = WadRayMath.rayMul(_p2pRate, WadRayMath.rayDiv(_balanceInP2P, totalBalance));
        if (_balanceOnPool > 0)
            weightedRate = weightedRate.add(WadRayMath.rayMul(_poolRate, WadRayMath.rayDiv(_balanceOnPool, totalBalance)));
    }

    struct PoolRatesVars {
        uint256 availableLiquidity;
        uint256 totalStableDebt;
        uint256 totalVariableDebt;
        uint256 avgStableBorrowRate;
        uint256 reserveFactor;
    }

    /// @notice Computes and returns the underlying pool rates on AAVE.
    /// @param suppliedToPool The amount hypothetically supplied.
    /// @param repaidToPool The amount hypothetically repaid.
    /// @return supplyRate The market's pool supply rate per year (in ray).
    /// @return variableBorrowRate The market's pool borrow rate per year (in ray).
    function getAaveRates(uint256 suppliedToPool, uint256 repaidToPool) private view returns (uint256 supplyRate, uint256 variableBorrowRate) {
        DataTypes.ReserveData memory reserve = POOL.getReserveData(address(want));
        PoolRatesVars memory vars;
        (
            vars.availableLiquidity,
            vars.totalStableDebt,
            vars.totalVariableDebt,
            ,
            ,
            ,
            vars.avgStableBorrowRate,
            ,
            ,

        ) = AAVE_DATA_PROIVDER.getReserveData(address(want));
        (, , , , vars.reserveFactor, , , , , ) = AAVE_DATA_PROIVDER.getReserveConfigurationData(address(want));

        (supplyRate, , variableBorrowRate) =
            IReserveInterestRateStrategy(reserve.interestRateStrategyAddress).calculateInterestRates(
                address(want),
                vars.availableLiquidity.add(suppliedToPool).add(repaidToPool), // repaidToPool is added to avaiable liquidity by aave impl, see: https://github.com/aave/protocol-v2/blob/0829f97c5463f22087cecbcb26e8ebe558592c16/contracts/protocol/lendingpool/LendingPool.sol#L277
                vars.totalStableDebt,
                vars.totalVariableDebt.sub(repaidToPool),
                vars.avgStableBorrowRate,
                vars.reserveFactor
            );
    }

    struct P2PRateComputeParams {
        uint256 poolSupplyRatePerYear; // The pool supply rate per year (in ray).
        uint256 poolBorrowRatePerYear; // The pool borrow rate per year (in ray).
        uint256 poolIndex; // The last stored pool index (in ray).
        uint256 p2pIndex; // The last stored peer-to-peer index (in ray).
        uint256 p2pDelta; // The peer-to-peer delta for the given market (in pool unit).
        uint256 p2pAmount; // The peer-to-peer amount for the given market (in peer-to-peer unit).
        uint256 p2pIndexCursor; // The index cursor of the given market (in bps).
        uint256 reserveFactor; // The reserve factor of the given market (in bps).
    }

    /// @notice Computes and returns the peer-to-peer supply rate per year of a market given its parameters.
    /// @param _params The computation parameters.
    /// @return p2pSupplyRate The peer-to-peer supply rate per year (in ray).
    function computeP2PSupplyRatePerYear(P2PRateComputeParams memory _params)
        internal
        pure
        returns (uint256 p2pSupplyRate)
    {
        if (_params.poolSupplyRatePerYear > _params.poolBorrowRatePerYear) {
            p2pSupplyRate = _params.poolBorrowRatePerYear; // The p2pSupplyRate is set to the poolBorrowRatePerYear because there is no rate spread.
        } else {
            p2pSupplyRate = PercentageMath.weightedAvg(
                _params.poolSupplyRatePerYear,
                _params.poolBorrowRatePerYear,
                _params.p2pIndexCursor
            );

            p2pSupplyRate =
                p2pSupplyRate.sub(PercentageMath.percentMul((p2pSupplyRate.sub(_params.poolSupplyRatePerYear)), _params.reserveFactor));
        }

        if (_params.p2pDelta > 0 && _params.p2pAmount > 0) {
            uint256 shareOfTheDelta = Math.min(
                WadRayMath.rayDiv(
                    WadRayMath.rayMul(_params.p2pDelta, _params.poolIndex),
                    WadRayMath.rayMul(_params.p2pAmount, _params.p2pIndex)
                ), // Using ray division of an amount in underlying decimals by an amount in underlying decimals yields a value in ray.
                WadRayMath.RAY // To avoid shareOfTheDelta > 1 with rounding errors.
            ); // In ray.

            p2pSupplyRate =
                WadRayMath.rayMul(p2pSupplyRate, WadRayMath.RAY.sub(shareOfTheDelta))
                .add(WadRayMath.rayMul(_params.poolSupplyRatePerYear, shareOfTheDelta));
        }
    }
}
