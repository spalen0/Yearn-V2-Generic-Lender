import pytest
from brownie import Wei, config, Contract


@pytest.fixture
def live_strat_usdc_1(Strategy):
    yield Strategy.at("0x2216E44fA633ABd2540dB72Ad34b42C7F1557cd4")


@pytest.fixture
def live_vault_usdc(pm):
    Vault = pm(config["dependencies"][0]).Vault
    yield Vault.at("0xa354F35829Ae975e850e23e9615b11Da1B3dC4DE")


@pytest.fixture
def live_vault_usdt(pm):
    Vault = pm(config["dependencies"][0]).Vault
    vault = Vault.at("0xAf322a2eDf31490250fdEb0D712621484b09aBB6")
    yield vault


@pytest.fixture
def live_GenericCompound_usdc_1(GenericCompound):
    yield GenericCompound.at("0x33D4c129586562adfd993ebb54E830481F31ef37")


# change these fixtures for generic tests
@pytest.fixture
def compCurrency(cUsdc, cUsdt):
    yield cUsdc


@pytest.fixture
def currency(interface, compCurrency, weth):
    yield interface.ERC20(compCurrency.underlying())


@pytest.fixture
def whale(accounts, web3, weth):
    # big binance7 wallet
    # acc = accounts.at('0xBE0eB53F46cd790Cd13851d5EFf43D12404d33E8', force=True)
    # Maker
    # acc = accounts.at("0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", force=True)
    # balancer vault
    acc = accounts.at("0xBA12222222228d8Ba445958a75a0704d566BF2C8", force=True)

    # lots of weth account
    wethAcc = accounts.at("0xeBec795c9c8bBD61FFc14A6662944748F299cAcf", force=True)
    weth.approve(acc, 2**256 - 1, {"from": wethAcc})
    weth.transfer(acc, weth.balanceOf(wethAcc), {"from": wethAcc})

    assert weth.balanceOf(acc) > 0
    yield acc


@pytest.fixture()
def strategist(accounts, whale, currency):
    decimals = currency.decimals()
    currency.transfer(accounts[1], 100_000 * (10**decimals), {"from": whale})
    yield accounts[1]


@pytest.fixture
def gov(accounts):
    yield accounts[3]


@pytest.fixture
def rewards(gov):
    yield gov  # TODO: Add rewards contract


@pytest.fixture
def guardian(accounts):
    # YFI Whale, probably
    yield accounts[2]


@pytest.fixture
def keeper(accounts):
    # This is our trusty bot!
    yield accounts[4]


@pytest.fixture
def rando(accounts):
    yield accounts[9]


@pytest.fixture
def trade_factory():
    yield Contract("0xd6a8ae62f4d593DAf72E2D7c9f7bDB89AB069F06")


# specific token addresses
@pytest.fixture
def weth(interface):
    yield interface.IWETH("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")


@pytest.fixture
def cUsdc(interface):
    yield interface.CErc20I("0x39AA39c021dfbaE8faC545936693aC917d5E7563")


@pytest.fixture
def cUsdt(interface):
    yield interface.CErc20I("0xf650C3d88D12dB855b8bf7D11Be6C55A4e07dCC9")


# not working, fails on: Comptroller.redeemVerify
@pytest.fixture
def cDai(interface):
    yield interface.CErc20I("0x5d3a536e4d6dbd6114cc1ead35777bab948e3643")


# tests won't work for CEtherI, because it's not a cERC20 token
# see require in GenericCompound _initialize
@pytest.fixture
def cEth(interface):
    yield interface.CEtherI("0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5")


# Problem with interest rate model, fails in contract apr function, model.getSupplyRate
@pytest.fixture
def cWbtc(interface):
    yield interface.CErc20I("0xC11b1268C1A384e55C48c2391d8d480264A3A7F4")


@pytest.fixture(scope="module", autouse=True)
def shared_setup(module_isolation):
    pass


@pytest.fixture
def vault(gov, rewards, guardian, currency, pm):
    Vault = pm(config["dependencies"][0]).Vault
    vault = Vault.deploy({"from": guardian})
    vault.initialize(currency, gov, rewards, "", "")
    vault.setManagementFee(0, {"from": gov})
    yield vault


@pytest.fixture
def strategy(
    strategist,
    gov,
    rewards,
    keeper,
    vault,
    Strategy,
    GenericCompound,
    currency,
    compCurrency,
):
    strategy = strategist.deploy(Strategy, vault)
    strategy.setKeeper(keeper, {"from": gov})
    strategy.setWithdrawalThreshold(0, {"from": gov})
    strategy.setRewards(rewards, {"from": strategist})

    compoundPlugin = strategist.deploy(
        GenericCompound, strategy, "Compound_" + currency.symbol(), compCurrency
    )
    assert compoundPlugin.apr() > 0

    strategy.addLender(compoundPlugin, {"from": gov})
    assert strategy.numLenders() == 1

    yield strategy
