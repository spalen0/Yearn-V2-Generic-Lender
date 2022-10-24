from itertools import count
from brownie import Wei, reverts, Contract, interface, ZERO_ADDRESS
from useful_methods import genericStateOfVault, genericStateOfStrat
import random
import brownie
import pytest
from weiroll import WeirollPlanner, WeirollContract


def test_rewards(
    chain,
    usdc,
    whale,
    gov,
    strategist,
    rando,
    vault,
    Strategy,
    strategy,
    interface,
    GenericCompound,
    gasOracle,
    strategist_ms,
    cUsdc,
):

    starting_balance = usdc.balanceOf(strategist)
    currency = usdc
    decimals = currency.decimals()
    plugin = GenericCompound.at(strategy.lenders(0))
    gasOracle.setMaxAcceptableBaseFee(10000 * 1e9, {"from": strategist_ms})

    usdc.approve(vault, 2**256 - 1, {"from": whale})
    usdc.approve(vault, 2**256 - 1, {"from": strategist})

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
    comp = interface.ERC20(plugin.comp())
    toSend = 20 * (10**18)
    comp.transfer(plugin.address, toSend, {"from": whale})
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


def test_no_rewards(
    usdc,
    Strategy,
    chain,
    whale,
    gov,
    strategist,
    vault,
    strategy,
    GenericCompound,
):
    starting_balance = usdc.balanceOf(strategist)
    currency = usdc
    decimals = currency.decimals()
    plugin = GenericCompound.at(strategy.lenders(0))

    usdc.approve(vault, 2**256 - 1, {"from": whale})
    usdc.approve(vault, 2**256 - 1, {"from": strategist})

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
    tx = strategy.harvest({"from": strategist})
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
    tx = strategy.harvest({"from": strategist})

    comp = interface.ERC20(plugin.comp())

    assert plugin.harvestTrigger(10) == False
    assert comp.balanceOf(plugin) == 0
    assert plugin.getRewardAprForSupplyBase(0) == 0

    # should still be able to call harvest
    chain.sleep(1)
    plugin.harvest({"from": strategist})
