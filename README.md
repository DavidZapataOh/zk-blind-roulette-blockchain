# Raffero - Private ZK Raffle System

A fully private raffle system using Zero-Knowledge proofs (Noir) where winners remain completely anonymous.

## 🎯 Features

- **100% Private**: Winners cannot be linked through blockchain analysis
- **ZK Proofs**: Uses Noir circuits for privacy-preserving winner claims
- **Gelato VRF**: Verifiable randomness for fair winner selection
- **Relayer System**: Winners never interact directly with the blockchain
- **Native Token Prizes**: Currently supports ETH/native token prizes

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Privacy Flow                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. User buys ticket with commitment = Pedersen(secret, nullifier)
│     └─> Commitment stored in Merkle tree (no address link)      │
│                                                                 │
│  2. Raffle ends, Gelato VRF selects random winnerIndex         │
│                                                                 │
│  3. Winner generates ZK proof locally proving:                  │
│     - They know (secret, nullifier) for commitment at winnerIndex
│     - Binds proof to their clean receiving address              │
│                                                                 │
│  4. Relayer submits proof on behalf of winner (pays gas)        │
│     └─> Prize sent to clean address, no on-chain link           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 📁 Project Structure

```
raffero-backend/
├── circuits/                    # Noir ZK circuits
│   ├── Nargo.toml
│   └── src/
│       └── main.nr             # Main circuit (Merkle proof + winner claim)
├── src/                        # Solidity contracts
│   ├── PrivateRaffle.sol       # Main raffle contract
│   └── interfaces/
│       ├── INoirVerifier.sol   # Verifier interface
│       └── IGelatoVRFConsumer.sol
├── test/
│   └── PrivateRaffle.t.sol     # Foundry tests
├── script/
│   └── Deploy.s.sol            # Deployment script
└── relayer/                    # TypeScript relayer service
    ├── package.json
    ├── tsconfig.json
    └── src/
        ├── index.ts            # Express server
        └── prover.ts           # Proof generation
```

## 🚀 Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Noir](https://noir-lang.org/docs/getting_started/installation)
- [Node.js](https://nodejs.org/) v18+

### 1. Compile Noir Circuit

```bash
cd circuits
nargo compile
nargo test  # Run circuit tests
```

### 2. Generate Solidity Verifier

```bash
# Generate verification key
bb write_vk -b ./target/raffle_circuits.json -o ./target/vk

# Generate Solidity verifier
bb write_solidity_verifier -k ./target/vk -o ../src/UltraVerifier.sol
```

### 3. Build & Test Contracts

```bash
forge build
forge test -vvv
```

### 4. Deploy to Scroll Sepolia

```bash
# Set environment variables
export PRIVATE_KEY=your_private_key
export SCROLL_SEPOLIA_RPC=https://sepolia-rpc.scroll.io

# Deploy
forge script script/Deploy.s.sol:DeployPrivateRaffle \
  --rpc-url $SCROLL_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### 5. Run Relayer

```bash
cd relayer
npm install
cp .env.example .env
# Edit .env with your configuration
npm run dev
```

## 📡 Relayer API

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check & relayer balance |
| `/raffle/:id` | GET | Get raffle info |
| `/fee` | GET | Get current relayer fee |
| `/claim` | POST | Submit claim with proof |

### Claiming a Prize

```bash
curl -X POST http://localhost:3000/claim \
  -H "Content-Type: application/json" \
  -d '{
    "raffleId": 1,
    "proof": "0x...",
    "publicInputs": ["0x...", ...],
    "recipient": "0xCleanAddress..."
  }'
```

## 🔒 Privacy Guarantees

1. **Deposit Privacy**: Tickets purchased via relayer if desired
2. **Claim Privacy**: Winner proves ownership without revealing identity
3. **No On-Chain Links**: Nullifier prevents analysis of deposit-claim pairs
4. **Clean Addresses**: Prize sent to fresh address specified in proof

## 🛡️ Security Considerations

- Store secrets securely - losing them means losing ability to claim
- Use a fresh address for receiving prizes
- Trust the relayer minimally - they can't steal funds but could delay claims
- Verify circuit compilation matches deployed verifier

## 📄 License

MIT
