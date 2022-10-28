from itertools import count
from brownie import Wei, reverts, ZERO_ADDRESS
import brownie


def test_manual_override(
    strategy,
    chain,
    vault,
    currency,
    interface,
    whale,
    strategist,
    gov,
    rando,
):

    decimals = currency.decimals()

    deposit_limit = 100_000_000 * (10**decimals)
    vault.addStrategy(strategy, 9800, 0, 2**256 - 1, 500, {"from": gov})

    amount1 = 50 * (10**decimals)
    currency.approve(vault, 2**256 - 1, {"from": whale})
    currency.approve(vault, 2**256 - 1, {"from": strategist})

    vault.setDepositLimit(deposit_limit, {"from": gov})
    assert vault.depositLimit() > 0

    amount2 = 50_000 * (10**decimals)

    vault.deposit(amount1, {"from": strategist})
    vault.deposit(amount2, {"from": whale})

    strategy.harvest({"from": strategist})

    status = strategy.lendStatuses()

    for j in status:
        plugin = interface.IGeneric(j[3])

        with brownie.reverts("!gov"):
            plugin.emergencyWithdraw(1, {"from": rando})
        with brownie.reverts("!management"):
            plugin.withdrawAll({"from": rando})
        with brownie.reverts("!management"):
            plugin.deposit({"from": rando})
        with brownie.reverts("!management"):
            plugin.withdraw(1, {"from": rando})


def test_setter_functions(
    chain,
    usdc,
    whale,
    gov,
    strategist,
    GenericCompound,
    rando,
    vault,
    strategy,
    accounts,
    cUsdc,
):
    # Check original values
    plugin = GenericCompound.at(strategy.lenders(0))

    assert plugin.keep3r() == ZERO_ADDRESS
    assert plugin.minCompToSell() == 1 * (10**18)
    assert plugin.minCompToClaim() == 1 * (10**18)

    minCompToSell = 10**20
    minCompToClaim = 10**5

    with brownie.reverts():
        plugin.setKeep3r(accounts[1], {"from": rando})
    with brownie.reverts():
        plugin.setRewardStuff(minCompToSell, minCompToClaim, {"from": rando})

    plugin.setKeep3r(accounts[1], {"from": strategist})
    plugin.setRewardStuff(minCompToSell, minCompToClaim, {"from": strategist})

    assert plugin.keep3r() == accounts[1]
    assert plugin.minCompToSell() == minCompToSell
    assert plugin.minCompToClaim() == minCompToClaim

    tx = plugin.cloneCompoundLender(strategy, "CloneGC", cUsdc, {"from": strategist})
    clone = GenericCompound.at(tx.return_value)

    assert clone.keep3r() == ZERO_ADDRESS
    # TODO: check these values
    # assert clone.minCompToSell() == 1 * (10**18)
    # assert clone.minCompToClaim() == 1 * (10**18)

    with brownie.reverts():
        clone.setKeep3r(accounts[1], {"from": rando})
    with brownie.reverts():
        clone.setRewardStuff(minCompToSell, minCompToClaim, {"from": rando})

    clone.setKeep3r(accounts[1], {"from": strategist})
    clone.setRewardStuff(minCompToSell, minCompToClaim, {"from": strategist})

    assert clone.keep3r() == accounts[1]
    assert clone.minCompToSell() == minCompToSell
    assert clone.minCompToClaim() == minCompToClaim
