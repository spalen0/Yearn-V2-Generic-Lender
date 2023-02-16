import pytest
from brownie import Wei, config, Contract


@pytest.fixture
def live_strat_usdc_1(OptStrategy):
    yield OptStrategy.at("0xe82DEb62412DB78D00Cae77BE3d1334e26034Cf6")


@pytest.fixture
def live_vault_usdc(pm):
    Vault = pm(config["dependencies"][0]).Vault
    yield Vault.at("0xaD17A225074191d5c8a37B50FdA1AE278a2EE6A2")


token_addresses = {
    "USDT": "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58",
    "DAI": "0xda10009cbd5d07dd0cecc66161fc93d7c9000da1",
    "USDC": "0x7f5c764cbc14f9669b88837ca1490cca17c31607",
    "OP": "0x4200000000000000000000000000000000000042",
    "WBTC": "0x68f180fcce6836688e9084f035309e29bf0a2095",
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
}


# TODO: uncomment those tokens you want to test as want
@pytest.fixture(
    params=[
        "USDC",
        # "USDT",
        # "DAI",
        # "OP",
        # "WBTC",
        # "WETH",
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
    "USDC": "0xEC8FEa79026FfEd168cCf5C627c7f486D77b765F",
    "USDT": "0x5Ff29E4470799b982408130EFAaBdeeAE7f66a10",
    "DAI": "0x5569b83de187375d43FBd747598bfe64fC8f6436",
    "OP": "0x8cD6b19A07d754bF36AdEEE79EDF4F2134a8F571",
    "WBTC": "0x33865e09a572d4f1cc4d75afc9abcc5d3d4d867d",
    "WETH": "0xf7B5965f5C117Eb1B5450187c9DcFccc3C317e8E",
}


@pytest.fixture
def compCurrency(interface, token):
    yield interface.CErc20I(c_token_addresses[token.symbol()])


whale_addresses = {
    "USDC": "0xebe80f029b1c02862b9e8a70a7e5317c06f62cae",
    "USDT": "0x85faa6c1f2450b9caea300838981c2e6e120c35c",
    "DAI": "0x5569b83de187375d43FBd747598bfe64fC8f6436",
    "OP": "0x2501c477d0a35545a387aa4a3eee4292a9a8b3f0",
    "WBTC": "0x33865e09a572d4f1cc4d75afc9abcc5d3d4d867d",
    "WETH": "0xf7B5965f5C117Eb1B5450187c9DcFccc3C317e8E",
}


@pytest.fixture
def whale(accounts, token):
    acc = accounts.at(whale_addresses[token.symbol()], force=True)
    yield acc


@pytest.fixture
def comp_whale(accounts):
    yield accounts.at("0xdc05d85069dc4aba65954008ff99f2d73ff12618", force=True)


@pytest.fixture
def comp():
    yield Contract("0x1db2466d9f5e10d7090e7152b68d62703a2245f0")


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


# @pytest.fixture
# def trade_factory():
#     yield Contract("0xd6a8ae62f4d593DAf72E2D7c9f7bDB89AB069F06")


# @pytest.fixture
# def gas_oracle():
#     yield Contract("0xb5e1CAcB567d98faaDB60a1fD4820720141f064F")


@pytest.fixture
def strategist_ms(accounts):
        # like governance, but better
    yield accounts.at("0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7", force=True)


# specific token addresses
@pytest.fixture
def weth(interface):
    yield interface.IWETH("0x4200000000000000000000000000000000000006")


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


token_prices = {
    "USDT": 1,
    "USDC": 1,
    "DAI": 1,
    "OP": 8,
    "WBTC": 7,
    "WETH": 1_600,
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
    "OP": 1e9,
    "WBTC": 1e9,
    "WETH": 1e9,
}


@pytest.fixture
def dust(token):
    yield dust_values[token.symbol()]


rewards_values = {
    "USDT": True,
    "USDC": True,
    "DAI": True,
    "OP": True,
    "WBTC": True,
    "WETH": True,
}


@pytest.fixture
def has_rewards(token):
    yield rewards_values[token.symbol()]


@pytest.fixture
def strategy(
    strategist,
    gov,
    rewards,
    keeper,
    vault,
    OptStrategy,
    SonneFinance,
    currency,
    compCurrency,
    dust,
):
    strategy = strategist.deploy(OptStrategy, vault)
    strategy.setKeeper(keeper, {"from": gov})
    strategy.setWithdrawalThreshold(0, {"from": gov})
    strategy.setRewards(rewards, {"from": strategist})

    plugin = strategist.deploy(
        SonneFinance, strategy, "Sonne_" + currency.symbol(), compCurrency
    )
    assert plugin.apr() > 0

    strategy.addLender(plugin, {"from": gov})
    assert strategy.numLenders() == 1

    plugin.setDust(dust)
    yield strategy
