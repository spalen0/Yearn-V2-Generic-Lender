from itertools import count
from brownie import Wei, reverts
from useful_methods import genericStateOfStrat, genericStateOfVault, deposit, sleep
import random
import brownie


# this test cycles through every plugin and checks we can add/remove lender and withdraw
def test_withdrawals_work(
    interface,
    chain,
    whale,
    gov,
    strategist,
    rando,
    vault,
    strategy,
    currency,
    valueOfCurrencyInDollars,
    amount,
):
    starting_balance = currency.balanceOf(strategist)
    decimals = currency.decimals()

    currency.approve(vault, 2**256 - 1, {"from": whale})
    currency.approve(vault, 2**256 - 1, {"from": strategist})

    deposit_limit = 1_000_000_000 * 10**decimals
    debt_ratio = 10000
    vault.addStrategy(strategy, debt_ratio, 0, 2**256 - 1, 500, {"from": gov})
    vault.setDepositLimit(deposit_limit, {"from": gov})

    status = strategy.lendStatuses()
    depositAmount = amount / 100
    vault.deposit(depositAmount, {"from": strategist})

    # whale deposits as well
    whale_deposit = amount / 2
    vault.deposit(whale_deposit, {"from": whale})

    chain.sleep(1)
    strategy.harvest({"from": strategist})

    sleep(chain, 25)
    strategy.harvest({"from": strategist})

    # TODO: remove all lenders -> to withdraw all amounts
    for j in status:
        plugin = interface.IGeneric(j[3])
        tx = strategy.safeRemoveLender(plugin, {"from": strategist})

    assert currency.balanceOf(plugin) == 0
    assert currency.balanceOf(strategy) > (depositAmount + whale_deposit) * 0.999

    form = "{:.2%}"
    formS = "{:,.0f}"

    for j in status:
        plugin = interface.IGeneric(j[3])
        # print("Testing ", j[0])
        strategy.addLender(j[3], {"from": gov})
        chain.sleep(1)
        strategy.harvest({"from": strategist})

        assert plugin.nav() > (depositAmount + whale_deposit) * 0.999

        shareprice = vault.pricePerShare()

        shares = vault.balanceOf(strategist)
        expectedout = shares * shareprice / 10**decimals
        balanceBefore = currency.balanceOf(strategist)
        # print(f"Lender: {j[0]}, Deposits: {formS.format(plugin.nav()/1e6)}")

        vault.withdraw(vault.balanceOf(strategist), {"from": strategist})
        balanceAfter = currency.balanceOf(strategist)
        # print(f"after Lender: {j[0]}, Deposits: {formS.format(plugin.nav()/1e6)}")

        withdrawn = balanceAfter - balanceBefore
        assert withdrawn > expectedout * 0.99 and withdrawn < expectedout * 1.01

        shareprice = vault.pricePerShare()

        shares = vault.balanceOf(whale)
        expectedout = shares * shareprice / 10**decimals
        balanceBefore = currency.balanceOf(whale)
        vault.withdraw(vault.balanceOf(whale), {"from": whale})
        balanceAfter = currency.balanceOf(whale)

        withdrawn = balanceAfter - balanceBefore
        assert withdrawn > expectedout * 0.99 and withdrawn < expectedout * 1.01

        vault.deposit(whale_deposit, {"from": whale})
        vault.deposit(depositAmount, {"from": strategist})

        chain.sleep(1)
        strategy.harvest({"from": strategist})
        strategy.safeRemoveLender(j[3])

        # verify plugin is empty or just have less than a penny
        assert plugin.nav() < (valueOfCurrencyInDollars / 100) * 10**decimals
        assert currency.balanceOf(strategy) > (depositAmount + whale_deposit) * 0.999

    shareprice = vault.pricePerShare()

    shares = vault.balanceOf(strategist)
    expectedout = shares * shareprice / 10**decimals
    balanceBefore = currency.balanceOf(strategist)

    # genericStateOfStrat(strategy, currency, vault)
    # genericStateOfVault(vault, currency)

    vault.withdraw(vault.balanceOf(strategist), {"from": strategist})
    balanceAfter = currency.balanceOf(strategist)

    # genericStateOfStrat(strategy, currency, vault)
    # genericStateOfVault(vault, currency)

    chain.mine(1)
    withdrawn = balanceAfter - balanceBefore
    assert withdrawn > expectedout * 0.99 and withdrawn < expectedout * 1.01

    shareprice = vault.pricePerShare()
    shares = vault.balanceOf(whale)
    expectedout = shares * shareprice / 10**decimals

    balanceBefore = currency.balanceOf(whale)
    vault.withdraw(vault.balanceOf(whale), {"from": whale})
    balanceAfter = currency.balanceOf(whale)
    withdrawn = balanceAfter - balanceBefore
    assert withdrawn > expectedout * 0.99 and withdrawn < expectedout * 1.01


# this test cycles through every plugin and checks we can add/remove lender and withdraw
def test_withdrawal_above_aave_liquidity(
    interface,
    chain,
    whale,
    gov,
    strategist,
    vault,
    strategy,
    currency,
    valueOfCurrencyInDollars,
    amount,
    accounts,
    pool_token,
):
    starting_balance = currency.balanceOf(strategist)
    decimals = currency.decimals()

    currency.approve(vault, 2**256 - 1, {"from": whale})
    currency.approve(vault, 2**256 - 1, {"from": strategist})

    deposit_limit = 1_000_000_000 * 10**decimals
    debt_ratio = 10000
    vault.addStrategy(strategy, debt_ratio, 0, 2**256 - 1, 500, {"from": gov})
    vault.setDepositLimit(deposit_limit, {"from": gov})

    status = strategy.lendStatuses()
    depositAmount = amount / 100
    vault.deposit(depositAmount, {"from": strategist})

    # whale deposits as well
    whale_deposit = amount / 2
    vault.deposit(whale_deposit, {"from": whale})

    chain.sleep(1)
    strategy.harvest({"from": strategist})

    sleep(chain, 25)
    strategy.harvest({"from": strategist})

    pool_account = accounts.at(pool_token, force=True)
    pool_balance = currency.balanceOf(pool_token)
    currency.transfer(gov, pool_balance, {"from": pool_account})

    balanceBefore = currency.balanceOf(whale)
    asset_before = strategy.estimatedTotalAssets()
    # transaction didn't revert
    vault.withdraw(vault.balanceOf(whale), {"from": whale})
    assert strategy.estimatedTotalAssets() >= asset_before

    # whale didn't withdraw all
    balanceAfter = currency.balanceOf(whale)
    withdrawn = balanceAfter - balanceBefore
    assert withdrawn < whale_deposit

    chain.sleep(1)
    strategy.harvest({"from": strategist})
    # no loss is reported
    state = vault.strategies(strategy)
    total_losses = state[8] / (10 ** decimals)
    assert total_losses == 0
