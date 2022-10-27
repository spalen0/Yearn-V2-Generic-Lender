// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";

import "./GenericLender/IGenericLender.sol";

/********************
 *
 *   A lender optimisation strategy for any erc20 asset
 *   https://github.com/Grandthrax/yearnV2-generic-lender-strat
 *   v0.3.1
 *
 *   This strategy works by taking plugins designed for standard lending platforms
 *   It automatically chooses the best yield generating platform and adjusts accordingly
 *   The adjustment is sub optimal so there is an additional option to manually set position
 *
 ********************* */

contract OptStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    uint256 public withdrawalThreshold = 1e12;
    uint256 public constant SECONDSPERYEAR = 31556952;

    uint8 public constant DEFAULT_LENDER_INDEX = uint8(-1);
    uint8 public activeLenderIndex = DEFAULT_LENDER_INDEX;
    IGenericLender[] public lenders;

    event Cloned(address indexed clone);

    constructor(address _vault) public BaseStrategy(_vault) {
        debtThreshold = 100 * 1e18;
    }

    function clone(address _vault) external returns (address newStrategy) {
        newStrategy = this.clone(_vault, msg.sender, msg.sender, msg.sender);
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        OptStrategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper);

        emit Cloned(newStrategy);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) external virtual {
        _initialize(_vault, _strategist, _rewards, _keeper);
    }

    function setWithdrawalThreshold(uint256 _threshold) external onlyAuthorized {
        withdrawalThreshold = _threshold;
    }

    function name() external view override returns (string memory) {
        return "StrategySingleActiveLenderYieldOptimiser";
    }

    //management functions
    //add lenders for the strategy to choose between
    // only governance to stop strategist adding dodgy lender
    function addLender(address a) public onlyGovernance {
        IGenericLender lender = IGenericLender(a);
        require(lender.strategy() == address(this), "Undocked Lender");

        for (uint256 i = 0; i < lenders.length; i++) {
            require(a != address(lenders[i]), "Already added");
        }
        lenders.push(lender);
    }

    //but strategist can remove for safety
    function safeRemoveLender(address a) public onlyAuthorized {
        _removeLender(a, false);
    }

    function forceRemoveLender(address a) public onlyAuthorized {
        _removeLender(a, true);
    }

    //force removes the lender even if it still has a balance
    function _removeLender(address a, bool force) internal {
        for (uint256 i = 0; i < lenders.length; i++) {
            if (a == address(lenders[i])) {
                if (i == activeLenderIndex) {
                    bool allWithdrawn = lenders[i].withdrawAll();
                    if (!force) {
                        require(allWithdrawn, "Withdraw failed");
                    }
                    activeLenderIndex = DEFAULT_LENDER_INDEX;
                }

                //put the last index here
                //remove last index
                if (i != lenders.length - 1) {
                    lenders[i] = lenders[lenders.length - 1];
                }

                //pop shortens array by 1 thereby deleting the last index
                lenders.pop();

                //if balance to spend we might as well put it into the best lender
                if (want.balanceOf(address(this)) > 0) {
                    adjustPosition(0);
                }
                return;
            }
        }
        require(false, "Not lender");
    }

    //we could make this more gas efficient but it is only used by a view function
    struct LendStatus {
        string name;
        uint256 assets;
        uint256 rate;
        address add;
    }

    //Returns the status of all lenders attached the strategy
    function lendStatuses() public view returns (LendStatus[] memory) {
        LendStatus[] memory statuses = new LendStatus[](lenders.length);
        for (uint256 i = 0; i < lenders.length; i++) {
            LendStatus memory s;
            s.name = lenders[i].lenderName();
            s.add = address(lenders[i]);
            s.assets = lenders[i].nav();
            s.rate = lenders[i].apr();
            statuses[i] = s;
        }

        return statuses;
    }

    // lent assets plus loose assets
    function estimatedTotalAssets() public view override returns (uint256) {
        if (activeLenderIndex == DEFAULT_LENDER_INDEX) {
            return 0;
        }
        return lenders[activeLenderIndex].nav().add(want.balanceOf(address(this)));
    }

    function numLenders() public view returns (uint256) {
        return lenders.length;
    }

    //the weighted apr = (nav * apr)/totalNav
    function estimatedAPR() public view returns (uint256) {
        uint256 bal = estimatedTotalAssets();
        if (bal == 0 || activeLenderIndex == DEFAULT_LENDER_INDEX) {
            return 0;
        }
        return lenders[activeLenderIndex].weightedApr().div(bal);
    }

    //estimates highest apr lenders. Public for debugging purposes but not much use to general public
    function estimateAdjustPosition()
        public
        view
        returns (
            uint8 _highestIndex,
            uint256 _potentialApr
        )
    {
        //all assets are to be invested
        uint256 totalAsset = estimatedTotalAssets();
        for (uint8 i = 0; i < lenders.length; i++) {
            uint256 apr;
            apr = lenders[i].aprAfterDeposit(totalAsset);

            if (apr > _potentialApr) {
                _potentialApr = apr;
                _highestIndex = i;
            }
        }
    }

    //gives estiomate of future APR with a change of debt limit. Useful for governance to decide debt limits
    function estimatedFutureAPR(uint256 newDebtLimit) public view returns (uint256) {
        if (activeLenderIndex == DEFAULT_LENDER_INDEX) {
            (uint8 highestIndex, uint256 potentialApr) = estimateAdjustPosition();
            return lenders[highestIndex].aprAfterDeposit(newDebtLimit);
        } else {
            return lenders[activeLenderIndex].aprAfterDeposit(newDebtLimit);
        }
    }

    //cycle all lenders and collect balances
    function lentTotalAssets() public view returns (uint256) {
        uint256 nav = 0;
        for (uint256 i = 0; i < lenders.length; i++) {
            nav = nav.add(lenders[i].nav());
        }
        return nav;
    }

    // we need to free up profit plus _debtOutstanding.
    // If _debtOutstanding is more than we can free we get as much as possible
    // should be no way for there to be a loss. we hope...
    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _profit = 0;
        _loss = 0; //for clarity
        _debtPayment = _debtOutstanding;

        uint256 lentAssets = lentTotalAssets();
        uint256 looseAssets = want.balanceOf(address(this));
        uint256 total = looseAssets.add(lentAssets);

        if (lentAssets == 0) {
            //no position to harvest or profit to report
            if (_debtPayment > looseAssets) {
                //we can only return looseAssets
                _debtPayment = looseAssets;
            }

            return (_profit, _loss, _debtPayment);
        }

        uint256 debt = vault.strategies(address(this)).totalDebt;

        if (total > debt) {
            _profit = total - debt;

            uint256 amountToFree = _profit.add(_debtPayment);
            //we need to add outstanding to our profit
            //dont need to do logic if there is nothiing to free
            if (amountToFree > 0 && looseAssets < amountToFree) {
                //withdraw what we can withdraw
                _withdrawSome(amountToFree.sub(looseAssets));
                uint256 newLoose = want.balanceOf(address(this));

                //if we dont have enough money adjust _debtOutstanding and only change profit if needed
                if (newLoose < amountToFree) {
                    if (_profit > newLoose) {
                        _profit = newLoose;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(newLoose - _profit, _debtPayment);
                    }
                }
            }
        } else {
            //serious loss should never happen but if it does lets record it accurately
            _loss = debt - total;
            uint256 amountToFree = _loss.add(_debtPayment);

            if (amountToFree > 0 && looseAssets < amountToFree) {
                //withdraw what we can withdraw

                _withdrawSome(amountToFree.sub(looseAssets));
                uint256 newLoose = want.balanceOf(address(this));

                //if we dont have enough money adjust _debtOutstanding and only change profit if needed
                if (newLoose < amountToFree) {
                    if (_loss > newLoose) {
                        _loss = newLoose;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(newLoose - _loss, _debtPayment);
                    }
                }
            }
        }
    }

    /*
     * Key logic.
     *   The algorithm checks if there is a lender with a higher APR and moves the funds to it.
     */
    function adjustPosition(uint256 _debtOutstanding) internal override {
        //emergency exit is dealt with at beginning of harvest
        if (emergencyExit || lenders.length == 0) {
            return;
        }
        
        // defualt value is 0
        uint8 newActiveLenderIndex;
        if (lenders.length > 1) {
            // find highest apr if there are more than 1 lender
            (uint8 highestIndex, uint256 potentialApr) = estimateAdjustPosition();
            newActiveLenderIndex = highestIndex;
        }
        // set functions is optimised for setting the same index again
        _setActiveLender(newActiveLenderIndex);
        
        uint256 balance = want.balanceOf(address(this));
        if (balance > _debtOutstanding) {
            IGenericLender activeLender = lenders[activeLenderIndex];
            want.safeTransfer(address(activeLender), balance);
            activeLender.deposit();
        }
    }

    // function getActiveLender() public view returns (IGenericLender) {
    //     require(activeLenderIndex != DEFAULT_LENDER_INDEX, "Active lender not set");
    //     return lenders[activeLenderIndex];
    // }

    function _setActiveLender(uint8 lenderIndex) internal {
        require(lenderIndex < lenders.length, "Invalid index");

        if (lenderIndex == activeLenderIndex) {
            // skip setting the same lender as active, and lender is set
            return;
        }
        if (activeLenderIndex != DEFAULT_LENDER_INDEX) {
            // withdraw liquidity only if the active lender is set
            bool allWithdrawn = lenders[activeLenderIndex].withdrawAll();
            require(allWithdrawn, "Withdraw failed");
        }
        activeLenderIndex = lenderIndex;
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256 amountWithdrawn) {
        // dont withdraw dust
        if (_amount < withdrawalThreshold || activeLenderIndex == DEFAULT_LENDER_INDEX) {
            return 0;
        }
        return lenders[activeLenderIndex].withdraw(_amount);
    }

    /*
     * Liquidate as many assets as possible to `want`, irregardless of slippage,
     * up to `_amountNeeded`. Any excess should be re-invested here as well.
     */
    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _amountFreed, uint256 _loss) {
        uint256 _balance = want.balanceOf(address(this));

        if (_balance >= _amountNeeded) {
            //if we don't set reserve here withdrawer will be sent our full balance
            return (_amountNeeded, 0);
        } else {
            uint256 received = _withdrawSome(_amountNeeded - _balance).add(_balance);
            if (received >= _amountNeeded) {
                return (_amountNeeded, 0);
            } else {
                return (received, 0);
            }
        }
    }

    // Uniswap pools on Optimism are not suitable for providing oracle prices, as this high-latency 
    // https://docs.uniswap.org/protocol/concepts/V3-overview/oracle#optimism
    function ethToWant(uint256 _amount) public override view returns (uint256) {
        return _amount;
    }

    function liquidateAllPositions() internal override returns (uint256 _amountFreed) {
        // for safety, withdraw from all lenders, not just active one
        for (uint256 i = 0; i < lenders.length; i++) {
            lenders[i].withdrawAll();
        }
        return want.balanceOf(address(this));
    }

    /*
     * revert if we can't withdraw full balance
     */
    function prepareMigration(address _newStrategy) internal override {
        uint256 outstanding = vault.strategies(address(this)).totalDebt;
        (, uint256 loss, uint256 wantBalance) = prepareReturn(outstanding);
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](1);
        protected[0] = address(want);
        return protected;
    }
}
