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
    GenericAaveMorpho,
    rando,
    vault,
    strategy,
    accounts,
    pool_token,
    currency,
):
    # Check original values
    plugin = GenericAaveMorpho.at(strategy.lenders(0))

    assert plugin.keep3r() == ZERO_ADDRESS
    assert plugin.maxGasForMatching() == 100000
    assert plugin.rewardsDistributor() == "0x3B14E5C73e0A56D607A8688098326fD4b4292135"

    max_gas = 5**10
    rewards_distributor = ZERO_ADDRESS

    with brownie.reverts():
        plugin.setKeep3r(accounts[1], {"from": rando})
    with brownie.reverts():
        plugin.setMaxGasForMatching(max_gas, {"from": rando})
    with brownie.reverts():
        plugin.setRewardsDistributor(rewards_distributor, {"from": rando})

    plugin.setKeep3r(accounts[1], {"from": strategist})
    plugin.setMaxGasForMatching(max_gas, {"from": strategist})
    plugin.setRewardsDistributor(rewards_distributor, {"from": strategist})

    assert plugin.keep3r() == accounts[1]
    assert plugin.maxGasForMatching() == max_gas
    assert plugin.rewardsDistributor() == rewards_distributor

    tx = plugin.cloneMorphoAaveLender(
        strategy, "CloneGC", pool_token, {"from": strategist}
    )
    clone = GenericAaveMorpho.at(tx.return_value)

    assert clone.keep3r() == ZERO_ADDRESS
    assert clone.maxGasForMatching() == 100000
    assert clone.rewardsDistributor() == "0x3B14E5C73e0A56D607A8688098326fD4b4292135"

    with brownie.reverts():
        clone.setKeep3r(accounts[1], {"from": rando})
    with brownie.reverts():
        clone.setMaxGasForMatching(max_gas, {"from": rando})
    with brownie.reverts():
        clone.setRewardsDistributor(rewards_distributor, {"from": rando})

    clone.setKeep3r(accounts[1], {"from": strategist})
    clone.setMaxGasForMatching(max_gas, {"from": strategist})
    clone.setRewardsDistributor(rewards_distributor, {"from": strategist})

    assert clone.keep3r() == accounts[1]
    assert clone.maxGasForMatching() == max_gas
    assert clone.rewardsDistributor() == rewards_distributor
