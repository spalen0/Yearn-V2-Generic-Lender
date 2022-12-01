from itertools import count
from brownie import Wei, reverts
from useful_methods import genericStateOfVault, genericStateOfStrat
import random
import brownie


def test_apr(
    strategy,
    chain,
    vault,
    currency,
    gov,
    interface,
    whale,
    strategist,
    plugin_type,
):
    decimals = currency.decimals()
    deposit_limit = 100_000_000 * (10**decimals)
    debt_ratio = 10_000
    vault.addStrategy(strategy, debt_ratio, 0, 2**256 - 1, 500, {"from": gov})
    vault.setDepositLimit(deposit_limit, {"from": gov})
    gov = strategist

    currency.approve(vault, 2**256 - 1, {"from": whale})
    currency.approve(vault, 2**256 - 1, {"from": gov})

    amount1 = 10_000 * (10**decimals)
    amount2 = 50_000 * (10**decimals)
    vault.deposit(amount1, {"from": gov})
    vault.deposit(amount2, {"from": whale})

    chain.sleep(1)
    strategy.harvest({"from": gov})

    # set lowest value to collect and sell comp rewards
    plugin = plugin_type.at(strategy.lenders(0))
    plugin.setRewardStuff(1, 1, {"from": gov})

    chain.sleep(1)
    strategy.harvest({"from": gov})

    startingBalance = vault.totalAssets()

    for i in range(10):
        waitBlock = 25
        print(f"\n----wait {waitBlock} blocks----")
        chain.mine(waitBlock)
        chain.sleep(waitBlock * 13)

        print(f"\n----harvest----")
        tx = strategy.harvest({"from": strategist})

        genericStateOfStrat(strategy, currency, vault)
        genericStateOfVault(vault, currency)

        profit = (vault.totalAssets() - startingBalance) / 10 ** currency.decimals()
        strState = vault.strategies(strategy)
        totalGains = strState[7]  # get strategy reported total gains

        blocks_per_year = 2_252_857
        assert startingBalance != 0
        time = (i + 1) * waitBlock
        assert time != 0
        apr = (totalGains / startingBalance) * (blocks_per_year / time)

        # print(f"Implied apr: {apr:.8%}")
        assert apr > 0 and apr < 1

    vault.withdraw(vault.balanceOf(gov), {"from": gov})
    vault.withdraw(vault.balanceOf(whale), {"from": whale})
