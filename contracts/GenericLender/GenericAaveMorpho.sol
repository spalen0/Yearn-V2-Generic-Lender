// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./GenericLenderBase.sol";
import "../Interfaces/Morpho/IMorpho.sol";
import "../Interfaces/Morpho/IRewardsDistributor.sol";
import "../Interfaces/Morpho/ILens.sol";
import "../Interfaces/Morpho/ILendingPoolAave.sol";
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
        require(market.underlyingToken == address(want), "WRONG CTOKEN");
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
        return currentUserSupplyRatePerYearInRay.div(1e9);
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
        _withdraw(amount);
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
        if (looseBalance >= amount) {
            want.safeTransfer(address(strategy), amount);
            return amount;
        }

        // no fear of underflow
        uint256 toWithdraw = amount - looseBalance;
        if (toWithdraw > balanceUnderlying) {
            // withdraw all
            MORPHO.withdraw(aToken, type(uint256).max);
        } else {
            // withdraw what is needed
            MORPHO.withdraw(aToken, toWithdraw);
        }
        // calculate withdrawan balance to new loose balance
        looseBalance = want.balanceOf(address(this));

        want.safeTransfer(address(strategy), looseBalance);
        return looseBalance;
    }

    /**
     * @notice Supply want balance
     */
    function harvest() external keepers {
        uint256 wantBalance = want.balanceOf(address(this));
        if (wantBalance > 0) {
            MORPHO.supply(
                aToken,
                address(this),
                wantBalance,
                maxGasForMatching
            );
        }
    }

    /**
     * @notice Supplies free want balance to Morpho
     */
    function deposit() external override management {
        MORPHO.supply(
            aToken,
            address(this),
            want.balanceOf(address(this)),
            maxGasForMatching
        );
    }

    /**
     * @notice Withdraws asset form Morpho
     * @return Is more asset returned than invested
     */
    function withdrawAll() external override management returns (bool) {
        uint256 invested = _nav();
        // withdraw all
        MORPHO.withdraw(aToken, type(uint256).max);
        uint256 wantBalance = want.balanceOf(address(this));
        want.safeTransfer(address(strategy), wantBalance);
        return wantBalance >= invested;
    }

    function hasAssets() external view override returns (bool) {
        (, , uint256 balanceUnderlying) = underlyingBalance();
        return
            balanceUnderlying > 0 ||
            want.balanceOf(address(this)) > 0;
    }

    /**
     * @notice Calculate new APR for supplying amount to lender.
     * @dev For P2P APR only biggest borrower from the pool is accounted.
     * @param _amount to supply
     * @return New lender APR after supplying given amount
     */
    function aprAfterDeposit(uint256 _amount) external view override returns (uint256) {
        ILens.Indexes memory indexes = LENS.getIndexes(aToken);
        IMorpho.Market memory market = MORPHO.market(aToken);
        IMorpho.Delta memory delta = MORPHO.deltas(aToken);

        IMorpho.SupplyBalance memory supplyBalance = MORPHO.supplyBalanceInOf(aToken, address(this));
        if (_amount > 0 && delta.p2pBorrowDelta > 0) {
            uint256 matchedDelta = Math.min(
                rayMul(delta.p2pBorrowDelta, indexes.poolBorrowIndex),
                _amount
            );

            supplyBalance.inP2P = supplyBalance.inP2P.add(rayDiv(matchedDelta, indexes.p2pSupplyIndex));
            _amount = _amount.sub(matchedDelta);
        }

        if (_amount > 0 && !market.isP2PDisabled) {
            address firstPoolBorrower = MORPHO.getHead(
                aToken,
                IMorpho.PositionType.BORROWERS_ON_POOL
            );
            uint256 firstPoolBorrowerBalance = MORPHO
            .borrowBalanceInOf(aToken, firstPoolBorrower)
            .onPool;

            if (firstPoolBorrowerBalance > 0) {
                uint256 matchedP2P = Math.min(
                    rayMul(firstPoolBorrowerBalance, indexes.poolBorrowIndex),
                    _amount
                );

                supplyBalance.inP2P = supplyBalance.inP2P.add(rayDiv(matchedP2P, indexes.p2pSupplyIndex));
                _amount = _amount.sub(matchedP2P);
            }
        }

        if (_amount > 0) supplyBalance.onPool = supplyBalance.onPool.add(rayDiv(_amount, indexes.poolSupplyIndex));

        uint256 balanceOnPool = rayMul(supplyBalance.onPool, indexes.poolSupplyIndex);
        uint256 balanceInP2P = rayMul(supplyBalance.inP2P, indexes.p2pSupplyIndex);

        (uint256 nextSupplyRatePerYearInRay, ) = _getUserSupplyRatePerYear(
            balanceInP2P,
            balanceOnPool
        );

        // downscale to WAD(1e18)
        return nextSupplyRatePerYearInRay.div(1e9);
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

    // ********* MORPHO RATES *********
    function _getUserSupplyRatePerYear(
        uint256 _balanceInP2P,
        uint256 _balanceOnPool
    ) internal view returns (uint256, uint256) {
        (uint256 p2pSupplyRatePerYear, uint256 poolSupplyRatePerYear) = getRatesPerYear(
            aToken, _balanceInP2P, _balanceOnPool
        );

        return
            _getWeightedRate(
                p2pSupplyRatePerYear,
                poolSupplyRatePerYear,
                _balanceInP2P,
                _balanceOnPool
            );
    }

    /// @dev Returns the rate experienced based on a given pool & peer-to-peer distribution.
    /// @param _p2pRate The peer-to-peer rate (in a unit common to `_poolRate` & `weightedRate`).
    /// @param _poolRate The pool rate (in a unit common to `_p2pRate` & `weightedRate`).
    /// @param _balanceInP2P The amount of balance matched peer-to-peer (in a unit common to `_balanceOnPool`).
    /// @param _balanceOnPool The amount of balance supplied on pool (in a unit common to `_balanceInP2P`).
    /// @return weightedRate The rate experienced by the given distribution (in a unit common to `_p2pRate` & `_poolRate`).
    /// @return totalBalance The sum of peer-to-peer & pool balances.
    function _getWeightedRate(
        uint256 _p2pRate,
        uint256 _poolRate,
        uint256 _balanceInP2P,
        uint256 _balanceOnPool
    ) internal pure returns (uint256 weightedRate, uint256 totalBalance) {
        totalBalance = _balanceInP2P.add(_balanceOnPool);
        if (totalBalance == 0) return (weightedRate, totalBalance);

        if (_balanceInP2P > 0) weightedRate = rayMul(_p2pRate, rayDiv(_balanceInP2P, totalBalance));
        if (_balanceOnPool > 0)
            weightedRate = weightedRate.add(rayMul(_poolRate, rayDiv(_balanceOnPool, totalBalance)));
    }

    /// @notice Computes and returns peer-to-peer and pool rates for a specific market.
    /// @dev Note: prefer using getAverageSupplyRatePerYear & getAverageBorrowRatePerYear to get the actual experienced supply/borrow rate.
    /// @param _poolToken The market address.
    /// @param _balanceInP2P Amount added to P2P.
    /// @param _balanceOnPool Amount added to pool.
    /// @return p2pSupplyRate The market's peer-to-peer supply rate per year (in ray).
    /// @return poolSupplyRate The market's pool supply rate per year (in ray).
    function getRatesPerYear(address _poolToken, uint256 _balanceInP2P, uint256 _balanceOnPool)
        internal
        view
        returns (
            uint256 p2pSupplyRate,
            uint256 poolSupplyRate
        )
    {
        ILens.Indexes memory indexes = LENS.getIndexes(aToken);
        IMorpho.Market memory market = MORPHO.market(aToken);
        IMorpho.Delta memory delta = MORPHO.deltas(aToken);

        ILendingPoolAave pool = ILendingPoolAave(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
        ILendingPoolAave.ReserveData memory reserve = pool.getReserveData(market.underlyingToken);
        // TODO: add pool amount to caluclation if _balanceOnPool > 0
        // check if _balanceOnPool is whole balance in pool, or new balance in pool
        poolSupplyRate = reserve.currentLiquidityRate;
        uint256 poolBorrowRate = reserve.currentVariableBorrowRate;

        p2pSupplyRate = computeP2PSupplyRatePerYear(
            P2PRateComputeParams({
                poolSupplyRatePerYear: poolSupplyRate,
                poolBorrowRatePerYear: poolBorrowRate,
                poolIndex: indexes.poolSupplyIndex,
                p2pIndex: indexes.p2pSupplyIndex,
                p2pDelta: delta.p2pSupplyDelta,
                p2pAmount: delta.p2pSupplyAmount.add(_balanceInP2P), // TODO: check if this add is correct spot
                p2pIndexCursor: market.p2pIndexCursor,
                reserveFactor: market.reserveFactor
            })
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
            uint256 p2pRate = weightedAvg(
                _params.poolSupplyRatePerYear,
                _params.poolBorrowRatePerYear,
                _params.p2pIndexCursor
            );

            p2pSupplyRate =
                p2pRate.sub(percentMul((p2pRate.sub(_params.poolSupplyRatePerYear)), _params.reserveFactor));
        }

        if (_params.p2pDelta > 0 && _params.p2pAmount > 0) {
            uint256 shareOfTheDelta = Math.min(
                rayDiv(
                    rayMul(_params.p2pDelta, _params.poolIndex),
                    rayMul(_params.p2pAmount, _params.p2pIndex)
                ), // Using ray division of an amount in underlying decimals by an amount in underlying decimals yields a value in ray.
                RAY // To avoid shareOfTheDelta > 1 with rounding errors.
            ); // In ray.

            p2pSupplyRate =
                rayMul(p2pSupplyRate, RAY.sub(shareOfTheDelta))
                .add(rayMul(_params.poolSupplyRatePerYear, shareOfTheDelta));
        }
    }


    // ********** MORPHO MATH **********
    uint256 internal constant MAX_UINT256 = 2**256 - 1; // Not possible to use type(uint256).max in yul.
    uint256 internal constant MAX_UINT256_MINUS_HALF_RAY = 2**256 - 1 - 0.5e27;
    uint256 internal constant MAX_UINT256_MINUS_HALF_PERCENTAGE = 2**256 - 1 - 0.5e4;
    uint256 internal constant PERCENTAGE_FACTOR = 1e4; // 100.00%
    uint256 internal constant HALF_PERCENTAGE_FACTOR = 0.5e4; // 50.00%
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = 0.5e27;

    /// @dev Multiplies two ray, rounding half up to the nearest ray.
    /// @param x Ray.
    /// @param y Ray.
    /// @return z The result of x * y, in ray.
    function rayMul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // Let y > 0
        // Overflow if (x * y + HALF_RAY) > type(uint256).max
        // <=> x * y > type(uint256).max - HALF_RAY
        // <=> x > (type(uint256).max - HALF_RAY) / y
        assembly {
            if mul(y, gt(x, div(MAX_UINT256_MINUS_HALF_RAY, y))) {
                revert(0, 0)
            }

            z := div(add(mul(x, y), HALF_RAY), RAY)
        }
    }

    /// @dev Divides two ray, rounding half up to the nearest ray.
    /// @param x Ray.
    /// @param y Ray.
    /// @return z The result of x / y, in ray.
    function rayDiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // Overflow if y == 0
        // Overflow if (x * RAY + y / 2) > type(uint256).max
        // <=> x * RAY > type(uint256).max - y / 2
        // <=> x > (type(uint256).max - y / 2) / RAY
        assembly {
            z := div(y, 2)
            if iszero(mul(y, iszero(gt(x, div(sub(MAX_UINT256, z), RAY))))) {
                revert(0, 0)
            }

            z := div(add(mul(RAY, x), z), y)
        }
    }

    /// @notice Executes a percentage multiplication (x * p), rounded up.
    /// @param x The value to multiply by the percentage.
    /// @param percentage The percentage of the value to multiply.
    /// @return y The result of the multiplication.
    function percentMul(uint256 x, uint256 percentage) internal pure returns (uint256 y) {
        // Must revert if
        // x * percentage + HALF_PERCENTAGE_FACTOR > type(uint256).max
        // <=> percentage > 0 and x > (type(uint256).max - HALF_PERCENTAGE_FACTOR) / percentage
        assembly {
            if mul(percentage, gt(x, div(MAX_UINT256_MINUS_HALF_PERCENTAGE, percentage))) {
                revert(0, 0)
            }

            y := div(add(mul(x, percentage), HALF_PERCENTAGE_FACTOR), PERCENTAGE_FACTOR)
        }
    }

    /// @notice Executes a weighted average (x * (1 - p) + y * p), rounded up.
    /// @param x The first value, with a weight of 1 - percentage.
    /// @param y The second value, with a weight of percentage.
    /// @param percentage The weight of y, and complement of the weight of x.
    /// @return z The result of the weighted average.
    function weightedAvg(
        uint256 x,
        uint256 y,
        uint256 percentage
    ) internal pure returns (uint256 z) {
        // Must revert if
        //     percentage > PERCENTAGE_FACTOR
        // or if
        //     y * percentage + HALF_PERCENTAGE_FACTOR > type(uint256).max
        //     <=> percentage > 0 and y > (type(uint256).max - HALF_PERCENTAGE_FACTOR) / percentage
        // or if
        //     x * (PERCENTAGE_FACTOR - percentage) + y * percentage + HALF_PERCENTAGE_FACTOR > type(uint256).max
        //     <=> (PERCENTAGE_FACTOR - percentage) > 0 and x > (type(uint256).max - HALF_PERCENTAGE_FACTOR - y * percentage) / (PERCENTAGE_FACTOR - percentage)
        assembly {
            z := sub(PERCENTAGE_FACTOR, percentage) // Temporary assignment to save gas.
            if or(
                gt(percentage, PERCENTAGE_FACTOR),
                or(
                    mul(percentage, gt(y, div(MAX_UINT256_MINUS_HALF_PERCENTAGE, percentage))),
                    mul(z, gt(x, div(sub(MAX_UINT256_MINUS_HALF_PERCENTAGE, mul(y, percentage)), z)))
                )
            ) {
                revert(0, 0)
            }
            z := div(add(add(mul(x, z), mul(y, percentage)), HALF_PERCENTAGE_FACTOR), PERCENTAGE_FACTOR)
        }
    }
}
