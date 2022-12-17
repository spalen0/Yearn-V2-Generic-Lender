// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./GenericLenderBase.sol";
import "../Interfaces/Morpho/IMorpho.sol";
import "../Interfaces/Morpho/IRewardsDistributor.sol";
import "../Interfaces/Morpho/ILens.sol";
import "../Interfaces/ySwaps/ITradeFactory.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";


contract GenericAaveMorpho is GenericLenderBase {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // Morpho is a contract to handle interaction with the protocol
    IMorpho internal constant MORPHO = IMorpho(0x777777c9898D384F785Ee44Acfe945efDFf5f3E0);
    // Lens is a contract to fetch data about Morpho protocol
    ILens internal constant LENS = ILens(0x507fA343d0A90786d86C7cd885f5C49263A91FF4);
    address internal constant MORPHO_TOKEN = 0x9994E35Db50125E0DF82e4c2dde62496CE330999;
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
            "GenericCompound already initialized"
        );
        aToken = _aToken;
        IMorpho.Market memory market = MORPHO.market(aToken);
        require(market.underlyingToken == address(want), "WRONG CTOKEN");
        want.safeApprove(address(MORPHO), type(uint256).max);
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
        return want.balanceOf(address(this)).add(underlyingBalance());
    }

    /**
     * @notice Returns the value deposited in Compound protocol
     * @return balance in want token value
     */
    function underlyingBalance() public view returns (uint256 balance) {
        (, , balance) = LENS.getCurrentSupplyBalanceInOf(aToken,address(this));
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
        _withdraw(amount);
        want.safeTransfer(vault.governance(), want.balanceOf(address(this)));
    }

    function _withdraw(uint256 amount) internal returns (uint256) {
        uint256 balanceUnderlying = underlyingBalance();
        uint256 looseBalance = want.balanceOf(address(this));
        uint256 total = balanceUnderlying.add(looseBalance);

        if (amount > total) {
            // cant withdraw more than we own
            amount = total;
        } else if (looseBalance >= amount) {
            want.safeTransfer(address(strategy), amount);
            return amount;
        }

        uint256 toWithdraw = amount.sub(looseBalance);
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
     * @notice Supplies free want balance to compound
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
     * @notice Withdraws asset form compound
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
        return
            underlyingBalance() > 0 ||
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
        // RAY(1e27)
        uint256 nextSupplyRatePerYearInRay;
        // simulated supply rate is a lower bound 
        (nextSupplyRatePerYearInRay, , , ) = LENS
            .getNextUserSupplyRatePerYear(aToken, address(this), amount);
        // downscale to WAD(1e18)
        return nextSupplyRatePerYearInRay.div(1e9);
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

    /**
     * @notice
     *  Set the maximum amount of gas to consume to get matched in peer-to-peer.
     * @dev
     *  This value is needed in morpho supply liquidity calls.
     *  Supplyed liquidity goes to loop with current loans on Compound
     *  and creates a match for p2p deals. The loop starts from bigger liquidity deals.
     * @param _maxGasForMatching new maximum gas value for
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
        
        tradeFactory = address(0);
    }
}
