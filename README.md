# UNIt Protocol - Uniswap v4 Hook Implementation

A permissionless stablecoin protocol built on Uniswap v4 hooks, implementing Liquity-like mechanisms for maintaining peg stability.

## Features

- Permissionless minting and redemption
- Automatic liquidations
- Stability pool for liquidations
- Revenue distribution to UNI stakers
- Peg stability mechanisms
- Uniswap v4 integration

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js and npm
- Access to an Ethereum node (Infura, Alchemy, etc.)

## Installation

1. Clone the repository:
```bash
git clone https://github.com/your-org/unit-protocol.git
cd unit-protocol
```

2. Install dependencies:
```bash
forge install
```

3. Copy the environment file and fill in your values:
```bash
cp .env.example .env
```

## Configuration

Edit the `.env` file with your configuration:

- Network RPC URLs
- Private keys for deployment and testing
- Contract addresses (will be filled after deployment)
- Gas settings
- Protocol parameters

## Deployment

### 1. Deploy Contracts

Deploy the UNIt token and hook contracts:

```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
```

This will deploy:
- UNIt token contract
- UNItHook contract

### 2. Set Up Uniswap v4 Pool

After deployment, set up the Uniswap v4 pool:

```bash
forge script script/SetupPool.s.sol:SetupPoolScript --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
```

This will:
- Initialize the UNIt/collateral pool
- Configure the hook
- Set up the fee tier and tick spacing

### 3. Verify Contracts (Optional)

If you want to verify the contracts on Etherscan:

```bash
forge verify-contract --chain-id 11155111 --constructor-args $(cast abi-encode "constructor(address)" $POOL_MANAGER_ADDRESS) $UNIT_TOKEN_ADDRESS src/UNIt.sol:UNIt
forge verify-contract --chain-id 11155111 --constructor-args $(cast abi-encode "constructor(address,address,address)" $POOL_MANAGER_ADDRESS $UNIT_TOKEN_ADDRESS $COLLATERAL_TOKEN_ADDRESS) $UNIT_HOOK_ADDRESS src/UNItHook.sol:UNItHook
```

## Usage

### Minting UNIt

1. Provide collateral to the Uniswap v4 pool
2. The hook will automatically mint UNIt tokens based on the collateral value
3. Maintain the minimum collateral ratio (110%)

### Redemption

1. When the price is below peg, redemption is automatically triggered
2. Users can redeem UNIt for collateral at a 0.5% fee
3. Redemption helps maintain the peg by reducing supply

### Stability Pool

1. Users can deposit UNIt into the stability pool
2. The pool receives collateral from liquidated troves
3. Depositors earn rewards from liquidations

### Liquidations

1. Undercollateralized troves are automatically liquidated
2. The stability pool receives the collateral
3. Liquidators receive a 10% reward

## Testing

Run the test suite:

```bash
forge test -vv
```

## Security Considerations

- The protocol is permissionless, but users should be aware of risks
- Always maintain sufficient collateral to avoid liquidation
- Monitor the stability pool for potential rewards
- Be cautious of price volatility and its impact on collateral ratios

## License

MIT
