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
    Strategy,
    strategy,
    interface,
    plugin_type,
    currency,
    comp_whale,
    gas_oracle,
    strategist_ms,
):
    starting_balance = currency.balanceOf(strategist)
    decimals = currency.decimals()
    plugin = plugin_type.at(strategy.lenders(0))
    gas_oracle.setMaxAcceptableBaseFee(10000 * 1e9, {"from": strategist_ms})

    currency.approve(vault, 2**256 - 1, {"from": whale})
    currency.approve(vault, 2**256 - 1, {"from": strategist})

    deposit_limit = 1_000_000_000 * (10 ** (decimals))
    debt_ratio = 10_000
    vault.addStrategy(strategy, debt_ratio, 0, 2**256 - 1, 500, {"from": gov})
    vault.setDepositLimit(deposit_limit, {"from": gov})

    #Set uni fees
    plugin.setUniFees(3000, 500, {"from": strategist})

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
    comp = interface.ERC20(plugin.COMP())
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


def test_no_rewards(
    Strategy,
    chain,
    whale,
    gov,
    strategist,
    vault,
    strategy,
    plugin_type,
    currency,
):
    starting_balance = currency.balanceOf(strategist)
    decimals = currency.decimals()
    plugin = plugin_type.at(strategy.lenders(0))

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
    # harvest should work without rewards
    tx = strategy.harvest({"from": strategist})

    comp = interface.ERC20(plugin.COMP())

    assert plugin.harvestTrigger(10) == False
    assert comp.balanceOf(plugin) == 0

    # should still be able to call harvest
    chain.sleep(1)
    plugin.harvest({"from": strategist})


def test_trade_factory(
    chain,
    whale,
    gov,
    strategist,
    rando,
    vault,
    strategy,
    interface,
    plugin_type,
    trade_factory,
    weth,
    currency,
    comp_whale,
    gas_oracle,
    strategist_ms,
):
    starting_balance = currency.balanceOf(strategist)
    decimals = currency.decimals()
    plugin = plugin_type.at(strategy.lenders(0))
    gas_oracle.setMaxAcceptableBaseFee(10000 * 1e9, {"from": strategist_ms})

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
    comp = interface.ERC20(plugin.COMP())
    toSend = 10 * (10 ** comp.decimals())
    comp.transfer(plugin.address, toSend, {"from": comp_whale})
    assert comp.balanceOf(plugin.address) == toSend
    assert plugin.harvestTrigger(10) == True

    navBefore = plugin.nav()
    currencyBefore = currency.balanceOf(plugin)

    with reverts():
        plugin.setTradeFactory(trade_factory.address, {"from": rando})

    assert plugin.tradeFactory() == ZERO_ADDRESS
    plugin.setTradeFactory(trade_factory.address, {"from": gov})
    assert plugin.tradeFactory() == trade_factory.address

    assert plugin.harvestTrigger("1") == True

    plugin.harvest({"from": gov})

    # nothing should have been sold because ySwap is set and not yet executed
    assert comp.balanceOf(plugin.address) >= toSend
    token_in = comp
    token_out = currency

    print(f"Executing trade...")
    receiver = plugin.address
    amount_in = token_in.balanceOf(plugin.address)
    assert amount_in > 0

    router = WeirollContract.createContract(
        Contract("0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D")
    )
    receiver = plugin

    planner = WeirollPlanner(trade_factory)
    token_in = WeirollContract.createContract(token_in)

    route = []
    if currency.symbol() == "WETH":
        route = [token_in.address, currency.address]
    else:
        route = [token_in.address, weth.address, currency.address]

    planner.add(
        token_in.transferFrom(
            plugin.address,
            trade_factory.address,
            amount_in,
        )
    )

    planner.add(token_in.approve(router.address, amount_in))

    planner.add(
        router.swapExactTokensForTokens(
            amount_in, 0, route, receiver.address, 2**256 - 1
        )
    )

    cmds, state = planner.plan()
    trade_factory.execute(cmds, state, {"from": trade_factory.governance()})
    afterBal = token_out.balanceOf(plugin)
    print(token_out.balanceOf(plugin))

    assert afterBal > 0
    assert comp.balanceOf(plugin.address) == 0

    # must have more want tokens after the ySwap is executed
    assert plugin.nav() > navBefore
    assert currency.balanceOf(plugin) > currencyBefore

    plugin.removeTradeFactoryPermissions({"from": strategist})
    assert plugin.tradeFactory() == ZERO_ADDRESS
    assert comp.allowance(plugin.address, trade_factory.address) == 0

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



def test_rewards_calculation_and_claim(
    chain,
    whale,
    gov,
    strategist,
    rando,
    vault,
    Strategy,
    strategy,
    interface,
    plugin_type,
    currency,
    compCurrency,
    comp_whale,
    gas_oracle,
    strategist_ms,
    EthCompound,
):
    starting_balance = currency.balanceOf(strategist)
    decimals = currency.decimals()
    plugin = plugin_type.at(strategy.lenders(0))
    gas_oracle.setMaxAcceptableBaseFee(10000 * 1e9, {"from": strategist_ms})

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

    # somebody else, not strategy, deposited to cToken to trigger rewards calculations
    if plugin_type == EthCompound:
        compCurrency.mint(10, {"from": whale})
    else:
        currency.approve(compCurrency, 2**256 - 1, {"from": whale})
        compCurrency.mint(10 * (10 ** (decimals)), {"from": whale})

    pendingRewards = plugin.getRewardsPending()
    assert pendingRewards > minCompToClaim
    assert plugin.harvestTrigger(10) == True
    plugin.harvest({"from": strategist})

    # verify reward tokens are claimed
    assert plugin.getRewardsPending() == 0
    comp = interface.ERC20(plugin.COMP())
    # verify calculating pending rewards is ok
    rewardsBalance = comp.balanceOf(plugin.address)
    # ETH has higher difference between claimed(higher) and calculated(lower)
    assert rewardsBalance > pendingRewards and rewardsBalance < pendingRewards * 1.35


def test_rewards_apr(strategy, plugin_type, currency):
    plugin = plugin_type.at(strategy.lenders(0))
    # get apr in percentage (100 / 1e18)
    apr = plugin.getRewardAprForSupplyBase(0) / 1e16
    # for current apr visit compound website: https://v2-app.compound.finance/
    if apr != 0:
        assert apr < 1 # all rewards are less than 1%
        assert apr > 0.1 # all rewards are higher than 0.1%
        # supplying more capital should reward in small rewards
        assert plugin.getRewardAprForSupplyBase(0) > plugin.getRewardAprForSupplyBase(10 ** currency.decimals())
