from brownie import Strategy

def main():
    with open('Strategy.sol', 'w') as f:
        Strategy.get_verification_info()
        f.write(Strategy._flattener.flattened_source)
