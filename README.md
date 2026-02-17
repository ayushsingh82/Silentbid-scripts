# BlindPool CCA - Sepolia Testnet

Privacy-focused fork of Uniswap's Continuous Clearing Auction (CCA) using **Zama fhEVM** (Fully Homomorphic Encryption) on Sepolia testnet.

## Overview

The Continuous Clearing Auction (CCA) is a novel auction mechanism that generalizes the uniform-price auction into continuous time. It provides fair price discovery for bootstrapping initial liquidity while eliminating timing games and encouraging early participation.

**BlindPool** extends CCA with **sealed-bid privacy**: bids are encrypted on-chain using Zama's fhEVM so no one (validators, MEV bots, other bidders) can read bid prices or amounts until the auction closes.

### Key Benefits

- **Fair Price Discovery** - Continuous clearing auctions eliminate timing games and establish credible market prices
- **Immediate Deep Liquidity** - Seamless transition from price discovery to active Uniswap V4 trading
- **Permissionless** - Anyone can bootstrap liquidity or participate in price discovery
- **Sealed Bids (FHE)** - Bid prices and amounts are encrypted on-chain via Zama fhEVM; only revealed after auction close
- **MEV Resistant** - No front-running or bid sniping since bid data is encrypted

### How BlindPool Works

```
Phase 1: BLIND BIDDING (during auction)
  Browser encrypts bid with @zama-fhe/relayer-sdk
  -> BlindPoolCCA stores euint64 ciphertexts on-chain
  -> Nobody can read bid prices or amounts

Phase 2: REVEAL (after blind bid deadline)
  requestReveal() marks ciphertexts as publicly decryptable
  -> Zama KMS allows decryption via relayer SDK

Phase 3: FORWARD (before CCA ends)
  publicDecrypt() returns cleartext + KMS proof
  -> forwardBidToCCA() submits real bids to Uniswap CCA
  -> Normal CCA settlement follows (exitBid, claimTokens)
```

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

### Zama fhEVM (Sepolia coprocessor)

| Contract | Address |
|----------|---------|
| ACL | `0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D` |
| FHEVMExecutor (Coprocessor) | `0x92C920834Ec8941d2C77D188936E1f7A6f49c127` |
| KMS Verifier | `0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A` |
| Input Verifier | `0xBBC1fFCdc7C316aAAd72E807D9b0272BE8F84DA0` |

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

4. **fhevm / encrypted-types (required for BlindPool):**
   - Initialize the fhevm submodule and install Solidity deps:
     ```bash
     git submodule update --init lib/fhevm
     cd lib/fhevm/library-solidity && npm install --ignore-scripts && cd ../../..
     ```
   - If you see `encrypted-types/EncryptedTypes.sol: No such file or directory`, the step above fixes it. If you see `FHEVMHostAddresses.sol` missing, that comes from the **anviltest** folder; you can build only src + script by skipping tests:

5. Build the contracts:

```bash
# Full build (includes anviltest; requires FHEVMHostAddresses from Zama deploy tasks)
forge build

# Build only src + script (no anviltest) — use this if full build fails
forge build --skip "anviltest/**"
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

### BlindPool: Deploy Privacy Wrapper

Deploy BlindPoolCCA on top of an existing CCA auction. Set `PRIVATE_KEY` in `.env` (see Setup) or pass `--private-key`:

```bash
# Using Make (reads PRIVATE_KEY from .env)
make deploy-blindpool AUCTION_ADDRESS=0x25B5C66f17152F36eE858709852C4BDbB8d71DF5

# Or: forge script with env
export AUCTION_ADDRESS=0x25B5C66f17152F36eE858709852C4BDbB8d71DF5
forge script script/DeployBlindPool.s.sol --rpc-url https://1rpc.io/sepolia --broadcast --private-key $PRIVATE_KEY
```

### BlindPoolFactory: One-time deploy (for UI “Deploy BlindPool” button)

Deploy the factory once so the **app** can deploy BlindPools from the UI (user connects wallet and clicks; no private key in terminal):

```bash
forge script script/DeployBlindPoolFactory.s.sol --rpc-url https://1rpc.io/sepolia --broadcast --private-key $PRIVATE_KEY
```

Then set in the app’s `.env.local`: `NEXT_PUBLIC_BLIND_POOL_FACTORY_ADDRESS=0x<FactoryAddress>`. After that, on any auction page users see “Deploy BlindPool for this auction” and can deploy with one click (MetaMask signs, they pay gas).

### BlindPool: Check Status

```bash
make check-blindpool BLIND_POOL_ADDRESS=0x...
```

### BlindPool: Reveal Bids

After the blind bid deadline, mark all encrypted bids as publicly decryptable:

```bash
make reveal-blindpool BLIND_POOL_ADDRESS=0x...
```

Then use the relayer SDK off-chain to decrypt and forward each bid (see Frontend Integration below).

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

## Frontend Integration (Relayer SDK)

The BlindPool frontend uses `@zama-fhe/relayer-sdk` to encrypt bids client-side:

```typescript
import { createInstance } from '@zama-fhe/relayer-sdk';

// Initialize (Sepolia testnet)
const instance = await createInstance({
  aclContractAddress: '0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D',
  kmsContractAddress: '0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A',
  inputVerifierContractAddress: '0xBBC1fFCdc7C316aAAd72E807D9b0272BE8F84DA0',
  verifyingContractAddressDecryption: '0x5D8BD78e2ea6bbE41f26dFe9fdaEAa349e077478',
  verifyingContractAddressInputVerification: '0x483b9dE06E4E4C7D35CCf5837A1668487406D955',
  chainId: 11155111,
  gatewayChainId: 10901,
  network: 'https://1rpc.io/sepolia',
  relayerUrl: 'https://relayer.testnet.zama.org',
});

// Encrypt a bid
const input = instance.createEncryptedInput(blindPoolAddress, userAddress);
input.add64(BigInt(maxPriceQ96));  // encrypted max price
input.add64(BigInt(amountWei));    // encrypted bid amount
const encrypted = await input.encrypt();

// Submit to BlindPoolCCA via wagmi/viem
await writeContract({
  address: blindPoolAddress,
  abi: BlindPoolABI,
  functionName: 'submitBlindBid',
  args: [encrypted.handles[0], encrypted.handles[1], encrypted.inputProof],
  value: BigInt(amountWei),  // ETH escrow
});

// After reveal: decrypt + forward
const results = await instance.publicDecrypt([priceHandle, amountHandle]);
await writeContract({
  address: blindPoolAddress,
  abi: BlindPoolABI,
  functionName: 'forwardBidToCCA',
  args: [
    bidId,
    results.clearValues[priceHandle],
    results.clearValues[amountHandle],
    results.decryptionProof,
  ],
});
```

## Resources

- [CCA Whitepaper](https://docs.uniswap.org/concepts/liquidity-launchpad/whitepaper)
- [Uniswap CCA Repository](https://github.com/Uniswap/continuous-clearing-auction)
- [Liquidity Launcher Docs](https://docs.uniswap.org/contracts/liquidity-launchpad)
- [Zama fhEVM Documentation](https://docs.zama.org/protocol/solidity-guides)
- [Zama Relayer SDK](https://docs.zama.org/protocol/relayer-sdk-guides)

## License

MIT
