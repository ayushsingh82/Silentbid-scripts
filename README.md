# SilentBid CCA - Sepolia Testnet

Privacy-focused fork of Uniswap's Continuous Clearing Auction (CCA) that uses **Chainlink Confidential Compute** and **CRE Confidential HTTP** to orchestrate private, compliant auction flows offchain. (App and product name: **SilentBid**.)

## TODO

**Chainlink Hackathon - Privacy Track ($6,000)**

Participating in the Chainlink hackathon. This project integrates **Chainlink Confidential Compute** (early access) for private transactions and/or **CRE's Confidential HTTP** capability to build privacy-preserving workflows, where API credentials, selected request and response data, and value flows are protected, and sensitive application logic executes offchain.

This track focuses on applications that require secure API connectivity and/or compliant non-public token movement, enabling decentralized workflows without exposing secrets, sensitive inputs or outputs, or internal transaction flows onchain.

*Note: Confidential HTTP and Chainlink Confidential Compute (early access) will be available from Feb 16th.*

### Example use cases and design patterns

- **Sealed-bid auctions & private payments:** Bidders submit payments via compliant private transactions; auction logic runs offchain to determine winners; settlement and refunds occur privately.
- **Private treasury and fund operations:** Move funds internally without exposing detailed transaction flows, while retaining the ability to withdraw to public token contracts.
- **Private governance payouts & incentives:** Governance or scoring logic runs offchain; rewards, grants, or incentives are distributed via compliant private transactions; individual recipients and amounts are not publicly visible.
- **Private rewards & revenue distribution:** Offchain computation determines allocations; payments executed via private transactions; supports rebates, revenue shares, bounties, and incentives.
- **OTC and brokered settlements:** Settle negotiated trades privately between counterparties, with execution coordinated offchain.
- **Secure Web2 API integration for decentralized workflows:** Use external APIs in CRE without exposing API keys or sensitive request & response parameters onchain.
- **Protected request–driven automation:** Trigger offchain or onchain workflows based on API data while keeping credentials and selected request inputs confidential.
- **Safe access to regulated or high-risk APIs:** Interact with APIs where leaked credentials or request parameters could cause financial, security, or compliance risk.
- **Credential-secure data ingestion and processing:** Fetch and process external data offchain using CRE while preventing secrets from being exposed to the blockchain or logs.
- **Controlled offchain data handling with auditability:** Execute API requests offchain with reliable execution guarantees and traceable usage, without writing sensitive inputs onchain.

### Requirements

Build, simulate, or deploy a **CRE Workflow** that's used as an orchestration layer within your project. Your workflow should:

- Integrate at least one blockchain with an external API, system, data source, LLM, or AI agent
- Demonstrate a successful simulation (via the CRE CLI) or a live deployment on the CRE network

## Overview

The Continuous Clearing Auction (CCA) is a novel auction mechanism that generalizes the uniform-price auction into continuous time. It provides fair price discovery for bootstrapping initial liquidity while eliminating timing games and encouraging early participation.

**SilentBid** extends CCA with **sealed-bid privacy**: bid details are kept offchain inside Chainlink Confidential Compute workflows so no one (validators, MEV bots, other bidders) can read bid prices or amounts until the auction closes.

### Key Benefits

- **Fair Price Discovery** - Continuous clearing auctions eliminate timing games and establish credible market prices
- **Immediate Deep Liquidity** - Seamless transition from price discovery to active Uniswap V4 trading
- **Permissionless** - Anyone can bootstrap liquidity or participate in price discovery
- **Sealed Bids via CRE** - Bid prices and amounts are handled inside CRE workflows and never exposed publicly during the auction; only aggregated results are revealed after auction close
- **MEV Resistant** - No front-running or bid sniping since bid data is encrypted

### What's Private vs Public

| Data | During Auction | After Reveal |
|------|---------------|--------------|
| Bid maxPrice | Encrypted | Decrypted for CCA |
| Bid amount | Encrypted | Decrypted for CCA |
| Bidder address | Visible | Visible |
| ETH deposit | Visible | Visible |
| Number of bids | Visible | Visible |
| Clearing price | N/A | Public (CCA computes) |

## Sepolia Contract Addresses

### Uniswap CCA (pre-deployed)

| Contract | Address |
|----------|---------|
| CCA Factory v1.1.0 | `0xcca1101C61cF5cb44C968947985300DF945C3565` |
| Liquidity Launcher | `0x00000008412db3394C91A5CbD01635c6d140637C` |
| FullRangeLBPStrategyFactory | `0x89Dd5691e53Ea95d19ED2AbdEdCf4cBbE50da1ff` |
| AdvancedLBPStrategyFactory | `0xdC3553B7Cea1ad3DAB35cBE9d40728C4198BCBb6` |
| UERC20Factory | `0x0cde87c11b959e5eb0924c1abf5250ee3f9bd1b5` |

## Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- Sepolia ETH for gas (get from a faucet)
- RPC URL for Sepolia (e.g., from Alchemy, Infura)

## Setup

1. Clone this repository and install dependencies:

```bash
cd cca
forge install
```

2. Copy the environment file and configure:

```bash
cp .env.example .env
```

3. Edit `.env` with your values:
   - `SEPOLIA_RPC_URL` - Your Sepolia RPC endpoint
   - `PRIVATE_KEY` - Your wallet private key (without 0x prefix)
   - `DEPLOYER` - Your wallet address
   - `ETHERSCAN_API_KEY` - For contract verification (optional)

4. Build the contracts:

```bash
forge build
```

Then run the deploy script. **You must provide your wallet** or Foundry will refuse to broadcast (`Be sure to set your own --sender`):

```bash
export AUCTION_ADDRESS=0xYourCCAAuctionAddress

# Option A: private key in env (e.g. from .env: PRIVATE_KEY=0x...)
forge script script/DeployBlindPool.s.sol --rpc-url https://1rpc.io/sepolia --broadcast --private-key $PRIVATE_KEY

# Option B: pass key on the command line (replace with your Sepolia wallet key)
# forge script script/DeployBlindPool.s.sol --rpc-url https://1rpc.io/sepolia --broadcast --private-key 0xYourPrivateKey
```

Ensure the wallet has Sepolia ETH for gas (~0.005 ETH).

## Scripts

### SilentBid: Deploy Privacy Wrapper

Deploy BlindPoolCCA (SilentBid contract) on top of an existing CCA auction. Set `PRIVATE_KEY` in `.env` (see Setup) or pass `--private-key`:

```bash
# Using Make (reads PRIVATE_KEY from .env)
make deploy-blindpool AUCTION_ADDRESS=0x25B5C66f17152F36eE858709852C4BDbB8d71DF5

# Or: forge script with env
export AUCTION_ADDRESS=0x25B5C66f17152F36eE858709852C4BDbB8d71DF5
forge script script/DeployBlindPool.s.sol --rpc-url https://1rpc.io/sepolia --broadcast --private-key $PRIVATE_KEY
```

### BlindPoolFactory: One-time deploy (for UI “Deploy SilentBid” button)

Deploy the factory once so the **app** can deploy SilentBid wrappers from the UI (user connects wallet and clicks; no private key in terminal):

```bash
forge script script/DeployBlindPoolFactory.s.sol --rpc-url https://1rpc.io/sepolia --broadcast --private-key $PRIVATE_KEY
```

Then set in the app’s `.env.local`: `NEXT_PUBLIC_BLIND_POOL_FACTORY_ADDRESS=0x<FactoryAddress>`. After that, on any auction page users see “Deploy SilentBid for this auction” and can deploy with one click (MetaMask signs, they pay gas).

### SilentBid: Check Status

```bash
make check-blindpool BLIND_POOL_ADDRESS=0x...
```

### SilentBid: Reveal / Finalize Bids

After the blind bid deadline, a Chainlink CRE workflow will be responsible for aggregating offchain sealed bids, computing the clearing price, and finalizing the auction onchain. The exact CLI / workflow commands will be documented once the CRE workflow is wired up to the SilentBid (BlindPool) contracts.

---

### Deploy a New CCA Auction

Deploy a mock token and create a new CCA auction:

```bash
source .env
forge script script/DeployCCA.s.sol:DeployCCA \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

### Submit a Bid

Submit a bid on an existing auction:

```bash
source .env
AUCTION_ADDRESS=0x... forge script script/SubmitBid.s.sol:SubmitBid \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

### Check Auction Status

View the current status of an auction:

```bash
source .env
AUCTION_ADDRESS=0x... forge script script/CheckAuction.s.sol:CheckAuction \
  --rpc-url $SEPOLIA_RPC_URL \
  -vvvv
```

### Exit Bid and Claim Tokens

Exit a bid and claim purchased tokens after the auction ends:

```bash
source .env
AUCTION_ADDRESS=0x... BID_ID=0 forge script script/ExitAndClaim.s.sol:ExitAndClaim \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

### Sweep Unsold Tokens and Raised Funds

Sweep remaining tokens and raised ETH after the auction ends:

```bash
source .env
AUCTION_ADDRESS=0x... forge script script/SweepAuction.s.sol:SweepAuction \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

## Auction Parameters Explained

| Parameter | Description |
|-----------|-------------|
| `currency` | Token to raise funds in. Use `address(0)` for ETH |
| `tokensRecipient` | Address to receive leftover tokens |
| `fundsRecipient` | Address to receive all raised funds |
| `startBlock` | Block when the auction starts |
| `endBlock` | Block when the auction ends |
| `claimBlock` | Block when tokens can be claimed |
| `tickSpacing` | Minimum price increment for bids |
| `validationHook` | Optional contract for bid validation |
| `floorPrice` | Starting floor price (Q96 format) |
| `requiredCurrencyRaised` | Minimum amount to raise for graduation |
| `auctionStepsData` | Token issuance schedule |

## Price Format

Prices in CCA are represented as Q96 fixed-point numbers (the ratio of currency to token, shifted left by 96 bits).

Example: A floor price of `79228162514264334008320` represents a 1:1,000,000 ratio (1 ETH = 1,000,000 tokens).

```solidity
// To convert a ratio to Q96 format:
uint256 priceQ96 = (1 << 96) / 1_000_000; // 1 ETH per 1 million tokens
```

## Frontend / CRE Integration (planned)

The app and CRE workflows use:

- EIP‑712 signed bid messages from the SilentBid front‑end.
- Confidential HTTP calls into a Chainlink CRE workflow that:
  - Verifies signatures and compliance rules.
  - Stores sealed bids offchain.
  - Triggers any required onchain deposits or finalization transactions.

Concrete code examples and endpoints will be added once the CRE workflow and HTTP bridge are finalized.

## Resources

- [CCA Whitepaper](https://docs.uniswap.org/concepts/liquidity-launchpad/whitepaper)
- [Uniswap CCA Repository](https://github.com/Uniswap/continuous-clearing-auction)
- [Liquidity Launcher Docs](https://docs.uniswap.org/contracts/liquidity-launchpad)
- [Chainlink Confidential Compute / CRE Docs](https://docs.chain.link/)
- [Compliant Private Transfer Demo](https://github.com/smartcontractkit/compliant-private-transfer-demo) <!-- reference to the cloned repo pattern -->

## License

MIT
