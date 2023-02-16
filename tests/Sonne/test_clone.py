from itertools import count
from brownie import Wei, reverts
from useful_methods import genericStateOfVault, genericStateOfStrat
import random
import brownie


def test_clone(
    chain,
    whale,
    gov,
    strategist,
    rando,
    vault,
    OptStrategy,
    strategy,
    SonneFinance,
    currency,
    compCurrency,
    dust,
):
    # Clone magic
    tx = strategy.clone(vault)
    cloned_strategy = OptStrategy.at(tx.return_value)
    cloned_strategy.setWithdrawalThreshold(
        strategy.withdrawalThreshold(), {"from": gov}
    )
    cloned_strategy.setDebtThreshold(strategy.debtThreshold(), {"from": gov})
    cloned_strategy.setProfitFactor(strategy.profitFactor(), {"from": gov})
    cloned_strategy.setMaxReportDelay(strategy.maxReportDelay(), {"from": gov})

    assert cloned_strategy.numLenders() == 0

    # Clone the Comp lender
    original_comp = SonneFinance.at(strategy.lenders(strategy.numLenders() - 1))
    cloned_name = "Cloned_Comp_" + currency.symbol()
    tx = original_comp.cloneSonneFinance(
        cloned_strategy, cloned_name, compCurrency, {"from": gov}
    )
    cloned_lender = SonneFinance.at(tx.return_value)
    assert cloned_lender.lenderName() == cloned_name

    cloned_strategy.addLender(cloned_lender, {"from": gov})

    with brownie.reverts():
        cloned_lender.initialize(compCurrency, {"from": gov})

    cloned_lender.setDust(dust, {"from": gov})
    assert cloned_lender.dust() == dust

    starting_balance = currency.balanceOf(strategist)
    decimals = currency.decimals()

    currency.approve(vault, 2**256 - 1, {"from": whale})
    currency.approve(vault, 2**256 - 1, {"from": strategist})

    deposit_limit = 1_000_000_000 * (10 ** (decimals))
    debt_ratio = 10_000
    vault.addStrategy(cloned_strategy, debt_ratio, 0, 2**256 - 1, 500, {"from": gov})
    vault.setDepositLimit(deposit_limit, {"from": gov})

    assert deposit_limit == vault.depositLimit()
    # our humble strategist deposits some test funds
    depositAmount = 10_000 * (10 ** (decimals))
    vault.deposit(depositAmount, {"from": strategist})

    assert cloned_strategy.estimatedTotalAssets() == 0
    chain.mine(1)
    assert cloned_strategy.harvestTrigger(1) == True

    tx = cloned_strategy.harvest({"from": strategist})

    assert (
        cloned_strategy.estimatedTotalAssets() >= depositAmount * 0.999999
    )  # losing some dust is ok

    assert cloned_strategy.harvestTrigger(1) == False

    # whale deposits as well
    whale_deposit = 500_000 * (10 ** (decimals))
    vault.deposit(whale_deposit, {"from": whale})
    chain.mine(1)
    assert cloned_strategy.harvestTrigger(1000) == True

    tx2 = cloned_strategy.harvest({"from": strategist})

    for i in range(15):
        waitBlock = random.randint(10, 50)
        chain.sleep(15 * 30)
        chain.mine(waitBlock)

        cloned_strategy.harvest({"from": strategist})
        chain.sleep(6 * 3600 + 1)  # to avoid sandwich protection
        chain.mine(1)

        action = random.randint(0, 9)
        if action < 3:
            percent = random.randint(50, 100)

            shares = vault.balanceOf(whale)
            print("whale has:", shares)
            if shares == 0:
                break
            shareprice = vault.pricePerShare()
            sharesout = int(shares * percent / 100)
            expectedout = sharesout * shareprice / 10**decimals

            balanceBefore = currency.balanceOf(whale)
            vault.withdraw(sharesout, {"from": whale})
            chain.mine(waitBlock)
            balanceAfter = currency.balanceOf(whale)

            withdrawn = balanceAfter - balanceBefore
            assert withdrawn > expectedout * 0.99 and withdrawn < expectedout * 1.01

        elif action < 5:
            depositAm = random.randint(10, 100) * (10**decimals)
            vault.deposit(depositAm, {"from": whale})

    # strategist withdraws
    shareprice = vault.pricePerShare()

    shares = vault.balanceOf(strategist)
    expectedout = shares * shareprice / 10**decimals
    balanceBefore = currency.balanceOf(strategist)

    status = cloned_strategy.lendStatuses()
    form = "{:.2%}"
    formS = "{:,.0f}"
    for j in status:
        print(
            f"Lender: {j[0]}, Deposits: {formS.format(j[1]/1e6)}, APR:"
            f" {form.format(j[2]/1e18)}"
        )
    vault.withdraw(vault.balanceOf(strategist), {"from": strategist})
    balanceAfter = currency.balanceOf(strategist)
    status = cloned_strategy.lendStatuses()

    chain.mine(waitBlock)
    withdrawn = balanceAfter - balanceBefore
    assert withdrawn > expectedout * 0.99 and withdrawn < expectedout * 1.01

    profit = balanceAfter - starting_balance
    assert profit > 0
    print(profit)
