from itertools import count
from brownie import Wei, reverts
from useful_methods import genericStateOfVault, genericStateOfStrat
import random
import brownie


def test_good_migration(
    Strategy,
    chain,
    whale,
    gov,
    strategist,
    rando,
    vault,
    strategy,
    currency,
):
    decimals = currency.decimals()
    currency.approve(vault, 2**256 - 1, {"from": whale})
    currency.approve(vault, 2**256 - 1, {"from": strategist})

    deposit_limit = 100_000_000 * (10**decimals)
    debt_ratio = 10_000
    vault.addStrategy(strategy, debt_ratio, 0, 2**256 - 1, 500, {"from": gov})
    vault.setDepositLimit(deposit_limit, {"from": gov})

    amount1 = 500 * 1e6
    vault.deposit(amount1, {"from": whale})

    amount1 = 50 * 1e6
    vault.deposit(amount1, {"from": strategist})

    chain.sleep(1)
    strategy.harvest({"from": strategist})
    chain.sleep(30 * 13)
    chain.mine(30)

    chain.sleep(1)
    strategy.harvest({"from": strategist})

    strategy_debt = vault.strategies(strategy)[6]  # totalDebt
    print(vault.strategies(strategy).dict())
    prior_position = strategy.estimatedTotalAssets()
    assert strategy_debt > 0

    new_strategy = strategist.deploy(Strategy, vault)
    assert vault.strategies(new_strategy)[6] == 0
    assert currency.balanceOf(new_strategy) == 0

    # Only Governance can migrate
    with brownie.reverts():
        vault.migrateStrategy(strategy, new_strategy, {"from": rando})

    tx = vault.migrateStrategy(strategy, new_strategy, {"from": gov})
    print(tx.events)
    assert vault.strategies(strategy)[6] == 0
    assert vault.strategies(new_strategy)[6] == strategy_debt
    assert (
        new_strategy.estimatedTotalAssets() > prior_position * 0.999
        or new_strategy.estimatedTotalAssets() < prior_position * 1.001
    )


def test_normal_activity(
    chain,
    whale,
    gov,
    strategist,
    rando,
    vault,
    strategy,
    currency,
):
    starting_balance = currency.balanceOf(strategist)
    decimals = currency.decimals()

    currency.approve(vault, 2**256 - 1, {"from": whale})
    currency.approve(vault, 2**256 - 1, {"from": strategist})

    deposit_limit = 1_000_000_000 * (10 ** (decimals))
    debt_ratio = 10_000
    vault.addStrategy(strategy, debt_ratio, 0, 2**256 - 1, 500, {"from": gov})
    vault.setDepositLimit(deposit_limit, {"from": gov})

    assert deposit_limit == vault.depositLimit()
    # our humble strategist deposits some test funds
    depositAmount = 501 * (10 ** (decimals))
    vault.deposit(depositAmount, {"from": strategist})

    assert strategy.estimatedTotalAssets() == 0
    chain.mine(1)
    assert strategy.harvestTrigger(1) == True

    chain.sleep(1)
    strategy.harvest({"from": strategist})

    assert (
        strategy.estimatedTotalAssets() >= depositAmount * 0.999999
    )  # losing some dust is ok

    assert strategy.harvestTrigger(1) == False

    # whale deposits as well
    whale_deposit = 100_000 * (10 ** (decimals))
    vault.deposit(whale_deposit, {"from": whale})
    assert strategy.harvestTrigger(1000) == True

    chain.sleep(1)
    strategy.harvest({"from": strategist})

    for i in range(15):
        waitBlock = random.randint(10, 50)
        chain.sleep(15 * 30)
        chain.mine(waitBlock)

        strategy.harvest({"from": strategist})
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
            expectedout = sharesout * shareprice / (10**decimals)

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
    expectedout = shares * shareprice / (10**decimals)
    balanceBefore = currency.balanceOf(strategist)

    # genericStateOfStrat(strategy, currency, vault)
    # genericStateOfVault(vault, currency)
    status = strategy.lendStatuses()
    form = "{:.2%}"
    formS = "{:,.0f}"
    for j in status:
        print(
            f"Lender: {j[0]}, Deposits: {formS.format(j[1]/1e6)}, APR:"
            f" {form.format(j[2]/1e18)}"
        )
    vault.withdraw(vault.balanceOf(strategist), {"from": strategist})
    balanceAfter = currency.balanceOf(strategist)

    # genericStateOfStrat(strategy, currency, vault)
    # genericStateOfVault(vault, currency)
    status = strategy.lendStatuses()

    withdrawn = balanceAfter - balanceBefore
    assert withdrawn > expectedout * 0.99 and withdrawn < expectedout * 1.01

    profit = balanceAfter - starting_balance
    assert profit > 0
    print(profit)


def test_debt_increase(
    chain,
    whale,
    gov,
    strategist,
    rando,
    vault,
    strategy,
    currency,
):
    decimals = currency.decimals()
    currency.approve(vault, 2**256 - 1, {"from": whale})

    deposit_limit = 100_000_000 * (10**decimals)
    debt_ratio = 10_000
    vault.addStrategy(strategy, debt_ratio, 0, 2**256 - 1, 500, {"from": gov})
    vault.setDepositLimit(deposit_limit, {"from": gov})
    form = "{:.2%}"
    formS = "{:,.0f}"
    firstDeposit = 2000_000 * 1e6
    predictedApr = strategy.estimatedFutureAPR(firstDeposit)
    print(
        f"Predicted APR from {formS.format(firstDeposit/1e6)} deposit:"
        f" {form.format(predictedApr/1e18)}"
    )
    vault.deposit(firstDeposit, {"from": whale})
    print("Deposit: ", formS.format(firstDeposit / 1e6))
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    realApr = strategy.estimatedAPR()
    print("Current APR: ", form.format(realApr / 1e18))
    status = strategy.lendStatuses()

    for j in status:
        print(
            f"Lender: {j[0]}, Deposits: {formS.format(j[1]/1e6)}, APR:"
            f" {form.format(j[2]/1e18)}"
        )

    assert realApr > predictedApr * 0.999 and realApr < predictedApr * 1.001

    predictedApr = strategy.estimatedFutureAPR(firstDeposit * 2)
    print(
        f"\nPredicted APR from {formS.format(firstDeposit/1e6)} deposit:"
        f" {form.format(predictedApr/1e18)}"
    )
    print("Deposit: ", formS.format(firstDeposit / 1e6))
    vault.deposit(firstDeposit, {"from": whale})

    chain.sleep(1)
    strategy.harvest({"from": strategist})
    realApr = strategy.estimatedAPR()

    print(f"Real APR after deposit: {form.format(realApr/1e18)}")
    status = strategy.lendStatuses()

    for j in status:
        print(
            f"Lender: {j[0]}, Deposits: {formS.format(j[1]/1e6)}, APR:"
            f" {form.format(j[2]/1e18)}"
        )
    assert realApr > predictedApr * 0.999 and realApr < predictedApr * 1.001


def test_vault_shares(
    strategy,
    chain,
    vault,
    currency,
    rewards,
    gov,
    interface,
    whale,
    strategist,
):
    decimals = currency.decimals()
    deposit_limit = 100_000_000 * (10**decimals)
    debt_ratio = 10_000
    vault.addStrategy(strategy, debt_ratio, 0, 2**256 - 1, 500, {"from": gov})
    vault.setDepositLimit(deposit_limit, {"from": gov})
    decimals = currency.decimals()
    amount1 = 100_000 * 10**decimals

    currency.approve(vault, 2**256 - 1, {"from": whale})
    currency.approve(vault, 2**256 - 1, {"from": strategist})

    vault.deposit(amount1, {"from": whale})
    vault.deposit(amount1, {"from": strategist})

    whale_share = vault.balanceOf(whale)
    gov_share = vault.balanceOf(strategist)

    assert gov_share == whale_share
    assert vault.pricePerShare() == 10**decimals
    assert vault.pricePerShare() * whale_share / 10**decimals - amount1 == 0

    assert (
        vault.pricePerShare() * whale_share / 10**decimals == vault.totalAssets() / 2
    )

    chain.sleep(1)
    strategy.harvest({"from": strategist})

    # no profit yet
    whale_share = vault.balanceOf(whale)
    gov_share = vault.balanceOf(strategist)
    # rewards accumulated in Strategy until claimed by "rewards"
    rew_share = vault.balanceOf(strategy)

    # no profit yet, same shares distribution than initially
    assert gov_share == whale_share and rew_share == 0 and whale_share == amount1
    vaultValue = (
        vault.pricePerShare() * (whale_share + rew_share + gov_share) / 10**decimals
    )
    assert (
        vaultValue > vault.totalAssets() * 0.999
        and vaultValue < vault.totalAssets() * 1.001
    )

    chain.sleep(13 * 1000)
    chain.mine(1000)

    whale_share = vault.balanceOf(whale)
    gov_share = vault.balanceOf(strategist)
    rew_share = vault.balanceOf(rewards)
    # no profit just aum fee. meaning total balance should be the same
    assert (gov_share + whale_share + rew_share) * vault.pricePerShare() / (
        10**decimals
    ) > amount1 * 2 * 0.999 and (
        gov_share + whale_share + rew_share
    ) * vault.pricePerShare() / (
        10**decimals
    ) < amount1 * 2 * 1.001
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    chain.sleep(6 * 3600 + 1)  # pass protection period
    chain.mine(1)

    whale_share = vault.balanceOf(whale)
    gov_share = vault.balanceOf(strategist)
    rew_share = vault.balanceOf(rewards)
    # rewards pending to be claimed by rewards
    pending_rewards = vault.balanceOf(strategy)

    # add strategy return
    assert vault.totalSupply() == whale_share + gov_share + rew_share + pending_rewards
    value = vault.totalSupply() * vault.pricePerShare() / 10**decimals
    assert (
        value * 0.99999 < vault.totalAssets() and value * 1.00001 > vault.totalAssets()
    )

    assert (
        value * 0.9999
        < (amount1 * 2)
        + vault.strategies(strategy)[7]  # changed from 6 to 7 (totalGains)
        and value * 1.0001 > (amount1 * 2) + vault.strategies(strategy)[7]  # see
    )
    # check we are within 0.1% of expected returns
    assert (
        value < strategy.estimatedTotalAssets() * 1.001
        and value > strategy.estimatedTotalAssets() * 0.999
    )
    assert gov_share == whale_share  # they deposited the same at the same moment


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
