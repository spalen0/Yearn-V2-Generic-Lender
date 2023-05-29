import pytest
from brownie import Wei, config, Contract


@pytest.fixture
def live_strat_usdc_1(Strategy):
    yield Strategy.at("0x0Fd45d4fb70D1EC95264dA30934095443DC6af6A")


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
    yield GenericCompound.at("0xA00dBC349E184e7E175832cD66dDb76dA9ddc2bf")


token_addresses = {
    "USDT": "0xdAC17F958D2ee523a2206206994597C13D831ec7",
    "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",
    "USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
}


# TODO: uncomment those tokens you want to test as want
@pytest.fixture(
    params=[
        "USDC",
        # "USDT",
        # "DAI",
    ],
    scope="session",
    autouse=True,
)
def token(request):
    yield Contract(token_addresses[request.param])


@pytest.fixture
def currency(token):
    yield token


c_token_addresses = {
    "USDC": "0x465a5a630482f3abD6d3b84B39B29b07214d19e5",
    "USDT": "0x81994b9607e06ab3d5cF3AffF9a67374f05F27d7",
    "DAI": "0xe2bA8693cE7474900A045757fe0efCa900F6530b",
}


@pytest.fixture
def compCurrency(interface, token):
    yield interface.CErc20I(c_token_addresses[token.symbol()])


whale_addresses = {
    "USDT": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",
    "DAI": "0xbebc44782c7db0a1a60cb6fe97d0b483032ff1c7",
    "USDC": "0x0a59649758aa4d66e25f08dd01271e891fe52199",
}


@pytest.fixture
def whale(accounts, token):
    acc = accounts.at(whale_addresses[token.symbol()], force=True)
    yield acc


@pytest.fixture
def comp_whale(accounts):
    yield accounts.at("0xC5d9221EB9c28A69859264c0A2Fe0d3272228296", force=True)


@pytest.fixture
def comp():
    yield Contract("0xfAbA6f8e4a5E8Ab82F62fe7C39859FA577269BE3")


@pytest.fixture()
def strategist(accounts, whale, currency, gov):
    # decimals = currency.decimals()
    # currency.transfer(gov, 100_000 * (10**decimals), {"from": whale})
    yield gov


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force = True)


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
    yield Contract("0x736D7e3c5a6CB2CE3B764300140ABF476F6CFCCF")


@pytest.fixture
def rando(accounts):
    yield accounts[9]


@pytest.fixture
def trade_factory():
    yield Contract("0xd6a8ae62f4d593DAf72E2D7c9f7bDB89AB069F06")


@pytest.fixture
def gas_oracle():
    yield Contract("0xb5e1CAcB567d98faaDB60a1fD4820720141f064F")


@pytest.fixture
def strategist_ms(accounts):
        # like governance, but better
    yield accounts.at("0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7", force=True)


# specific token addresses
@pytest.fixture
def weth(interface):
    yield interface.IWETH("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")


@pytest.fixture(scope="module", autouse=True)
def shared_setup(module_isolation):
    pass


@pytest.fixture
def vault(gov, rewards, guardian, currency, pm, live_vault_usdc, Strategy):
    old = Strategy.at("0x97D868b5C2937355Bf89C5E5463d52016240fE86")
    live_vault_usdc.updateStrategyDebtRatio("0x97D868b5C2937355Bf89C5E5463d52016240fE86", 0, {"from": gov})
    old.harvest({"from": gov})
    yield live_vault_usdc


token_prices = {
    "USDT": 1,
    "USDC": 1,
    "DAI": 1,
}


@pytest.fixture
def valueOfCurrencyInDollars(token):
    yield token_prices[token.symbol()]


# minimal values for dust because to fix comptroller revert: redeemTokens zero
# this happens because of when try to withdraw too small
dust_values = {
    "USDT": 1,
    "USDC": 1,
    "DAI": 1e9,
}


@pytest.fixture
def dust(token):
    yield dust_values[token.symbol()]


rewards_values = {
    "USDT": False,
    "USDC": False,
    "DAI": False,
}


@pytest.fixture
def has_rewards(token):
    yield rewards_values[token.symbol()]


@pytest.fixture
def pluginType(currency, weth, GenericCompound, EthCompound):
    plugin = GenericCompound
    if currency.address == weth.address:
        plugin = EthCompound
    yield plugin


@pytest.fixture
def strategy(
    strategist,
    gov,
    rewards,
    keeper,
    vault,
    Strategy,
    EthCompound,
    currency,
    compCurrency,
    dust,
    pluginType,
    live_GenericCompound_usdc_1,
    live_strat_usdc_1,
):

    # live_strat_usdc_1.setHealthCheck("0xDDCea799fF1699e98EDF118e0629A974Df7DF012", {"from": gov})
    live_strat_usdc_1.addLender(live_GenericCompound_usdc_1, {"from": gov})
    yield live_strat_usdc_1
