import pytest
from brownie import Wei, config, Contract


token_addresses = {
    "USDT": "0xdAC17F958D2ee523a2206206994597C13D831ec7",
    "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",
    "USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
}


# TODO: uncomment those tokens you want to test as want
@pytest.fixture(
    params=[
        "USDC",
        "USDT",
        "DAI",
        "WETH",
    ],
    scope="session",
    autouse=True,
)
def token(request):
    yield Contract(token_addresses[request.param])


@pytest.fixture
def currency(token):
    yield token


aave_pool_token_addresses = {
    "WBTC": "0x9ff58f4fFB29fA2266Ab25e75e2A8b3503311656",  # aWBTC
    "WETH": "0x030bA81f1c18d280636F32af80b9AAd02Cf0854e",  # aWETH
    "USDT": "0x3Ed3B47Dd13EC9a98b44e6204A523E766B225811",  # aUSDT
    "DAI": "0x028171bCA77440897B824Ca71D1c56caC55b68A3",  # aDAI
    "USDC": "0xBcca60bB61934080951369a648Fb03DF4F96263C",  # aUSDC
}


@pytest.fixture
def pool_token(token):
    yield aave_pool_token_addresses[token.symbol()]


whale_addresses = {
    "USDT": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",
    "DAI": "0xbebc44782c7db0a1a60cb6fe97d0b483032ff1c7",
    "USDC": "0x0a59649758aa4d66e25f08dd01271e891fe52199",
    "WETH": "0x2f0b23f53734252bda2277357e97e1517d6b042a",
}


@pytest.fixture
def whale(accounts, token):
    acc = accounts.at(whale_addresses[token.symbol()], force=True)
    yield acc


@pytest.fixture
def comp_whale(accounts):
    yield accounts.at("0x5608169973d639649196a84ee4085a708bcbf397", force=True)


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
    "WETH": 1_600,
}


@pytest.fixture
def valueOfCurrencyInDollars(token):
    yield token_prices[token.symbol()]


@pytest.fixture
def strategy(
    strategist,
    gov,
    rewards,
    keeper,
    vault,
    Strategy,
    pool_token,
    GenericAaveMorpho
):
    strategy = strategist.deploy(Strategy, vault)
    strategy.setKeeper(keeper, {"from": gov})
    strategy.setWithdrawalThreshold(0, {"from": gov})
    strategy.setRewards(rewards, {"from": strategist})

    morpho_plugin = strategist.deploy(GenericAaveMorpho, strategy, "GenericAaveMorpho", pool_token)
    # assert morpho_plugin.apr() > 0

    strategy.addLender(morpho_plugin, {"from": gov})
    assert strategy.numLenders() == 1

    yield strategy
