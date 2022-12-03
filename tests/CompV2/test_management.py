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

    chain.sleep(1)
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
    whale,
    gov,
    strategist,
    GenericCompound,
    pluginType,
    rando,
    vault,
    strategy,
    accounts,
    compCurrency,
    currency,
    weth,
):
    # Check original values
    plugin = pluginType.at(strategy.lenders(0))

    assert plugin.keep3r() == ZERO_ADDRESS
    assert plugin.minCompToSell() == 1 * (10**18)
    assert plugin.minCompToClaim() == 1 * (10**18)

    minCompToSell = 10**20
    minCompToClaim = 10**5
    dustThreshold = 10**10
    compEthFee = 3000
    ethWantFee = 100

    with brownie.reverts():
        plugin.setKeep3r(accounts[1], {"from": rando})
    with brownie.reverts():
        plugin.setRewardStuff(minCompToSell, minCompToClaim, {"from": rando})
    with brownie.reverts():
        plugin.setDustThreshold(dustThreshold, {"from": rando})
    with brownie.reverts():
        plugin.setUniFees(compEthFee, ethWantFee, {"from": rando})

    plugin.setKeep3r(accounts[1], {"from": strategist})
    plugin.setRewardStuff(minCompToSell, minCompToClaim, {"from": strategist})
    plugin.setDustThreshold(dustThreshold, {"from": strategist})
    plugin.setUniFees(compEthFee, ethWantFee, {"from": strategist})

    assert plugin.keep3r() == accounts[1]
    assert plugin.minCompToSell() == minCompToSell
    assert plugin.minCompToClaim() == minCompToClaim
    assert plugin.dustThreshold() == dustThreshold
    assert plugin.ethToWantFee() == ethWantFee
    assert plugin.compToEthFee() == compEthFee

    # only GenericCompound has clone function
    if pluginType != GenericCompound:
        return

    tx = plugin.cloneCompoundLender(
        strategy, "CloneGC", compCurrency, {"from": strategist}
    )
    clone = GenericCompound.at(tx.return_value)

    assert clone.keep3r() == ZERO_ADDRESS
    assert clone.minCompToSell() == 1 * (10**18)
    assert clone.minCompToClaim() == 1 * (10**18)
    assert clone.dustThreshold() == 0
    assert clone.ethToWantFee() == 0
    assert clone.compToEthFee() == 0

    with brownie.reverts():
        clone.setKeep3r(accounts[1], {"from": rando})
    with brownie.reverts():
        clone.setRewardStuff(minCompToSell, minCompToClaim, {"from": rando})
    with brownie.reverts():
        clone.setDustThreshold(dustThreshold, {"from": rando})
    with brownie.reverts():
        clone.setUniFees(compEthFee, ethWantFee, {"from": rando})

    clone.setKeep3r(accounts[1], {"from": strategist})
    clone.setRewardStuff(minCompToSell, minCompToClaim, {"from": strategist})
    clone.setDustThreshold(dustThreshold, {"from": strategist})
    clone.setUniFees(compEthFee, ethWantFee, {"from": strategist})

    assert clone.keep3r() == accounts[1]
    assert clone.minCompToSell() == minCompToSell
    assert clone.minCompToClaim() == minCompToClaim
    assert clone.dustThreshold() == dustThreshold
    assert clone.ethToWantFee() == ethWantFee
    assert clone.compToEthFee() == compEthFee
