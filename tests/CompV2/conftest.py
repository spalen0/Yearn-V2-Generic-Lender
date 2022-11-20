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


token_addresses = {
    "USDT": "0xdAC17F958D2ee523a2206206994597C13D831ec7",
    "DAI": "0x6B175474E89094C44Da98b954EedeAC495271d0F",
    "USDC": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    "LINK": "0x514910771AF9Ca656af840dff83E8264EcF986CA",
    "UNI": "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
    "AAVE": "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9",
    "TUSD": "0x0000000000085d4780B73119b644AE5ecd22b376",
    "WETH": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
}


# TODO: uncomment those tokens you want to test as want
@pytest.fixture(
    params=[
        "USDC",
        # "USDT",
        # "DAI",
        # "LINK",
        # "UNI",
        # "AAVE",
        # "TUSD",
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


c_token_addresses = {
    "USDC": "0x39AA39c021dfbaE8faC545936693aC917d5E7563",
    "USDT": "0xf650C3d88D12dB855b8bf7D11Be6C55A4e07dCC9",
    "DAI": "0x5d3a536e4d6dbd6114cc1ead35777bab948e3643",
    "LINK": "0xFAce851a4921ce59e912d19329929CE6da6EB0c7",
    "UNI": "0x35A18000230DA775CAc24873d00Ff85BccdeD550",
    "AAVE": "0xe65cdB6479BaC1e22340E4E755fAE7E509EcD06c",
    "TUSD": "0x12392F67bdf24faE0AF363c24aC620a2f67DAd86",
    "WETH": "0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5",
}


@pytest.fixture
def compCurrency(interface, token):
    yield interface.CErc20I(c_token_addresses[token.symbol()])


whale_addresses = {
    "USDT": "0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503",
    "DAI": "0xbebc44782c7db0a1a60cb6fe97d0b483032ff1c7",
    "USDC": "0x0a59649758aa4d66e25f08dd01271e891fe52199",
    "LINK": "0xf977814e90da44bfa03b6295a0616a897441acec",
    "UNI": "0x4b4e140d1f131fdad6fb59c13af796fd194e4135",
    "AAVE": "0x4da27a545c0c5b758a6ba100e3a049001de870f5",
    "TUSD": "0xf977814e90da44bfa03b6295a0616a897441acec",
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
    "LINK": 8,
    "UNI": 7,
    "AAVE": 94,
    "TUSD": 1,
    "WETH": 1_600,
}


@pytest.fixture
def valueOfCurrencyInDollars(token):
    yield token_prices[token.symbol()]


# minimal values for dustThreshold because to fix comptroller revert: redeemTokens zero
# this happens because of when try to withdraw too small
dust_values = {
    "USDT": 1,
    "USDC": 1,
    "DAI": 1e9,
    "LINK": 1e9,
    "UNI": 1e9,
    "AAVE": 1e9,
    "TUSD": 1e9,
    "WETH": 1e9,
}


@pytest.fixture
def dust(token):
    yield dust_values[token.symbol()]


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
):
    strategy = strategist.deploy(Strategy, vault)
    strategy.setKeeper(keeper, {"from": gov})
    strategy.setWithdrawalThreshold(0, {"from": gov})
    strategy.setRewards(rewards, {"from": strategist})

    if pluginType == EthCompound:
        compoundPlugin = strategist.deploy(
            pluginType, strategy, "Compound_" + currency.symbol()
        )
        assert compoundPlugin.apr() > 0

        strategy.addLender(compoundPlugin, {"from": gov})
        assert strategy.numLenders() == 1

        compoundPlugin.setDustThreshold(dust)
        yield strategy

    else:
        compoundPlugin = strategist.deploy(
            pluginType, strategy, "Compound_" + currency.symbol(), compCurrency
        )
        assert compoundPlugin.apr() > 0

        strategy.addLender(compoundPlugin, {"from": gov})
        assert strategy.numLenders() == 1

        compoundPlugin.setDustThreshold(dust)
        yield strategy
