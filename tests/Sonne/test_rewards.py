from itertools import count
from brownie import Wei, reverts, Contract, interface, ZERO_ADDRESS
from useful_methods import genericStateOfVault, genericStateOfStrat
import random
import brownie
import pytest
from weiroll import WeirollPlanner, WeirollContract


def test_rewards(
    chain,
    whale,
    gov,
    strategist,
    rando,
    vault,
    strategy,
    interface,
    currency,
    comp_whale,
    # gas_oracle,
    strategist_ms,
    SonneFinance,
    comp,
    has_rewards,
):
    if not has_rewards:
        return

    starting_balance = currency.balanceOf(strategist)
    decimals = currency.decimals()
    plugin = SonneFinance.at(strategy.lenders(0))
    # gas_oracle.setMaxAcceptableBaseFee(10000 * 1e9, {"from": strategist_ms})

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
    assert plugin.harvestTrigger(10) == False

    assert (
        strategy.estimatedTotalAssets() >= depositAmount * 0.999999
    )  # losing some dust is ok

    assert strategy.harvestTrigger(1) == False
    assert plugin.harvestTrigger(10) == False

    # whale deposits as well
    whale_deposit = 100_000 * (10 ** (decimals))
    vault.deposit(whale_deposit, {"from": whale})
    assert strategy.harvestTrigger(1000) == True
    assert plugin.harvestTrigger(10) == False
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    # send some comp to the strategy
    toSend = 20 * (10 ** comp.decimals())
    comp.transfer(plugin.address, toSend, {"from": comp_whale})
    assert comp.balanceOf(plugin.address) == toSend
    assert plugin.harvestTrigger(10) == True
    chain.sleep(10)

    before_bal = plugin.underlyingBalanceStored()

    with brownie.reverts():
        plugin.harvest({"from": rando})

    plugin.harvest({"from": strategist})

    assert plugin.underlyingBalanceStored() > before_bal
    assert comp.balanceOf(plugin.address) == 0

    chain.sleep(1)
    strategy.harvest({"from": strategist})
    status = strategy.lendStatuses()
    form = "{:.2%}"
    formS = "{:,.0f}"
    for j in status:
        print(
            f"Lender: {j[0]}, Deposits: {formS.format(j[1]/1e6)}, APR:"
            f" {form.format(j[2]/1e18)}"
        )
    chain.sleep(6 * 3600)
    chain.mine(1)
    vault.withdraw({"from": strategist})


# def test_no_rewards(
#     Strategy,
#     chain,
#     whale,
#     gov,
#     strategist,
#     vault,
#     strategy,
#     pluginType,
#     currency,
#     comp,
# ):
#     starting_balance = currency.balanceOf(strategist)
#     decimals = currency.decimals()
#     plugin = pluginType.at(strategy.lenders(0))

#     currency.approve(vault, 2**256 - 1, {"from": whale})
#     currency.approve(vault, 2**256 - 1, {"from": strategist})

#     deposit_limit = 1_000_000_000 * (10 ** (decimals))
#     debt_ratio = 10_000
#     vault.addStrategy(strategy, debt_ratio, 0, 2**256 - 1, 500, {"from": gov})
#     vault.setDepositLimit(deposit_limit, {"from": gov})

#     assert deposit_limit == vault.depositLimit()
#     # our humble strategist deposits some test funds
#     depositAmount = 501 * (10 ** (decimals))
#     vault.deposit(depositAmount, {"from": strategist})

#     assert strategy.estimatedTotalAssets() == 0
#     chain.mine(1)
#     assert strategy.harvestTrigger(1) == True

#     chain.sleep(1)
#     tx = strategy.harvest({"from": strategist})
#     assert plugin.harvestTrigger(10) == False

#     assert (
#         strategy.estimatedTotalAssets() >= depositAmount * 0.999999
#     )  # losing some dust is ok

#     assert strategy.harvestTrigger(1) == False
#     assert plugin.harvestTrigger(10) == False

#     # whale deposits as well
#     whale_deposit = 100_000 * (10 ** (decimals))
#     vault.deposit(whale_deposit, {"from": whale})
#     assert strategy.harvestTrigger(1000) == True
#     assert plugin.harvestTrigger(10) == False
#     chain.sleep(1)
#     # harvest should work without rewards
#     tx = strategy.harvest({"from": strategist})

#     assert plugin.harvestTrigger(10) == False
#     assert comp.balanceOf(plugin) == 0

#     # should still be able to call harvest
#     chain.sleep(1)
#     plugin.harvest({"from": strategist})


def test_rewards_calculation_and_claim(
    chain,
    whale,
    gov,
    strategist,
    rando,
    vault,
    strategy,
    interface,
    currency,
    compCurrency,
    comp_whale,
    # gas_oracle,
    strategist_ms,
    SonneFinance,
    comp,
    has_rewards,
):
    if not has_rewards:
        return
    starting_balance = currency.balanceOf(strategist)
    decimals = currency.decimals()
    plugin = SonneFinance.at(strategy.lenders(0))
    # gas_oracle.setMaxAcceptableBaseFee(10000 * 1e9, {"from": strategist_ms})

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
    assert plugin.harvestTrigger(10) == False

    assert (
        strategy.estimatedTotalAssets() >= depositAmount * 0.999999
    )  # losing some dust is ok

    minCompToSell = 2**256 - 1
    minCompToClaim = 1
    plugin.setRewardStuff(minCompToSell, minCompToClaim, {"from": strategist})

    # whale deposits as well
    whale_deposit = 100_000 * (10 ** (decimals))
    vault.deposit(whale_deposit, {"from": whale})
    chain.sleep(1)

    # wait for rewards to accumulate
    chain.sleep(3600 * 24 * 100)

    pendingRewards = plugin.getRewardsPending()
    assert pendingRewards > minCompToClaim
    assert plugin.harvestTrigger(10) == True
    plugin.harvest({"from": strategist})

    # verify reward tokens are claimed
    assert plugin.getRewardsPending() == 0
    # verify calculating pending rewards is ok
    rewardsBalance = comp.balanceOf(plugin.address)
    # ETH has higher difference between claimed(higher) and calculated(lower)
    assert rewardsBalance > pendingRewards and rewardsBalance < pendingRewards * 1.35


def test_rewards_apr(strategy, SonneFinance, currency, has_rewards):
    if not has_rewards:
        return
    plugin = SonneFinance.at(strategy.lenders(0))
    # get apr in percentage (100 / 1e18)
    apr = plugin.getRewardAprForSupplyBase(0) / 1e16
    # for current apr visit compound website: https://v2-app.compound.finance/
    assert apr < 1 # all rewards are less than 1%
    assert apr > 0.1 # all rewards are higher than 0.1%
    # supplying more capital should reward in small rewards
    assert plugin.getRewardAprForSupplyBase(0) > plugin.getRewardAprForSupplyBase(100* 10 ** currency.decimals())
