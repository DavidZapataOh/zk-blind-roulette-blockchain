/**
 * Private Raffle Relayer Service
 */

import express, { Request, Response, NextFunction } from 'express';
import { ethers } from 'ethers';
import * as dotenv from 'dotenv';
import { RaffleProver, ProofInputs } from './prover.js';

dotenv.config();

// ============================================================================
// Configuration
// ============================================================================

const PORT = parseInt(process.env.PORT || '3000');
const RPC_URL = process.env.RPC_URL || 'https://sepolia-rpc.scroll.io';
const PRIVATE_RAFFLE_ADDRESS = process.env.PRIVATE_RAFFLE_ADDRESS || '';
const RELAYER_PRIVATE_KEY = process.env.RELAYER_PRIVATE_KEY || '';
const RELAYER_FEE = process.env.RELAYER_FEE || '1000000000000000'; // 0.001 ETH
const CIRCUIT_PATH = process.env.CIRCUIT_PATH || '../circuits/target/raffle_circuits.json';

// ============================================================================
// Contract ABI (minimal for claiming)
// ============================================================================

const RAFFLE_ABI = [
  'function claimPrize(uint256 raffleId, bytes calldata proof, bytes32[] calldata publicInputs, address recipient, uint256 relayerFee) external',
  'function getRaffle(uint256 raffleId) external view returns (tuple(address creator, uint256 ticketPrice, uint256 maxParticipants, uint256 duration, uint256 endTime, uint256 levels, uint256 nextIndex, uint256 root, uint8 prizeType, uint256 prizePool, uint8 status, uint256 winnerIndex, uint256 createdAt))',
  'function getRoot(uint256 raffleId) external view returns (uint256)',
  'function nullifierUsed(uint256 raffleId, uint256 nullifierHash) external view returns (bool)',
];

// ============================================================================
// Express App Setup
// ============================================================================

const app = express();
app.use(express.json());

// Disable any identifying logging
app.set('trust proxy', true);

// Security middleware - no logging of IP or identifying info
app.use((req: Request, res: Response, next: NextFunction) => {
  // Remove identifying headers
  res.removeHeader('X-Powered-By');
  next();
});

// ============================================================================
// Prover and Provider Initialization
// ============================================================================

let prover: RaffleProver;
let provider: ethers.JsonRpcProvider;
let signer: ethers.Wallet;
let raffleContract: ethers.Contract;

async function initializeServices(): Promise<void> {
  console.log('Initializing relayer services...');
  
  // Initialize provider and signer
  provider = new ethers.JsonRpcProvider(RPC_URL);
  
  if (!RELAYER_PRIVATE_KEY) {
    console.warn('WARNING: RELAYER_PRIVATE_KEY not set. Transactions will fail.');
    signer = ethers.Wallet.createRandom().connect(provider);
  } else {
    signer = new ethers.Wallet(RELAYER_PRIVATE_KEY, provider);
  }
  
  console.log('Relayer address:', await signer.getAddress());
  
  // Initialize contract
  if (PRIVATE_RAFFLE_ADDRESS) {
    raffleContract = new ethers.Contract(PRIVATE_RAFFLE_ADDRESS, RAFFLE_ABI, signer);
  }
  
  // Initialize prover
  prover = new RaffleProver(CIRCUIT_PATH);
  
  try {
    await prover.initialize();
  } catch (error) {
    console.warn('Prover initialization failed (circuit may not be compiled yet):', error);
  }
  
  console.log('Services initialized');
}

// ============================================================================
// API Endpoints
// ============================================================================

/**
 * Health check endpoint
 */
app.get('/health', async (req: Request, res: Response) => {
  const balance = await provider.getBalance(await signer.getAddress());
  
  res.json({
    status: 'ok',
    relayerBalance: ethers.formatEther(balance),
    relayerFee: ethers.formatEther(RELAYER_FEE),
    contractConfigured: !!PRIVATE_RAFFLE_ADDRESS,
  });
});

/**
 * Get raffle info (public data only)
 */
app.get('/raffle/:raffleId', async (req: Request, res: Response) => {
  try {
    const raffleId = req.params.raffleId;
    
    if (!raffleContract) {
      return res.status(503).json({ error: 'Contract not configured' });
    }
    
    const raffle = await raffleContract.getRaffle(raffleId);
    const root = await raffleContract.getRoot(raffleId);
    
    res.json({
      raffleId,
      ticketPrice: raffle.ticketPrice.toString(),
      maxParticipants: raffle.maxParticipants.toString(),
      participants: raffle.nextIndex.toString(),
      status: ['Active', 'Drawing', 'Closed', 'Claimed'][raffle.status],
      winnerIndex: raffle.status >= 2 ? raffle.winnerIndex.toString() : null,
      root: root.toString(),
      prizePool: ethers.formatEther(raffle.prizePool),
    });
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
});

/**
 * Submit claim with pre-generated proof
 * 
 * The winner generates the proof locally and only sends:
 * - proof (bytes)
 * - publicInputs (for verification)
 * - recipient (clean address)
 * 
 * Note: Do NOT log recipient or any identifying info
 */
app.post('/claim', async (req: Request, res: Response) => {
  try {
    const { raffleId, proof, publicInputs, recipient } = req.body;
    
    // Validate inputs
    if (!raffleId || !proof || !publicInputs || !recipient) {
      return res.status(400).json({ error: 'Missing required fields' });
    }
    
    if (!ethers.isAddress(recipient)) {
      return res.status(400).json({ error: 'Invalid recipient address' });
    }
    
    if (!raffleContract) {
      return res.status(503).json({ error: 'Contract not configured' });
    }
    
    // Check if nullifier already used
    const nullifierHash = publicInputs[1];
    const isUsed = await raffleContract.nullifierUsed(raffleId, nullifierHash);
    if (isUsed) {
      return res.status(400).json({ error: 'Nullifier already used' });
    }
    
    // Submit transaction
    console.log(`Processing claim for raffle ${raffleId}`);
    // Note: NOT logging recipient for privacy
    
    const tx = await raffleContract.claimPrize(
      raffleId,
      proof,
      publicInputs,
      recipient,
      RELAYER_FEE
    );
    
    console.log(`Transaction submitted: ${tx.hash}`);
    
    // Wait for confirmation
    const receipt = await tx.wait();
    
    res.json({
      success: true,
      txHash: receipt.hash,
      blockNumber: receipt.blockNumber,
    });
    
  } catch (error: any) {
    console.error('Claim error:', error.message);
    res.status(500).json({ error: 'Claim failed' });
  }
});

/**
 * Generate proof and submit claim
 * 
 * For users who can't generate proofs locally.
 * WARNING: This requires sharing private inputs with the relayer.
 * Use only if you trust the relayer operator.
 */
app.post('/claim-with-proof-generation', async (req: Request, res: Response) => {
  try {
    const {
      raffleId,
      secret,
      nullifier,
      siblings,
      recipient,
      winnerIndex,
      root,
      treeDepth,
    } = req.body;
    
    // Validate inputs
    if (!raffleId || !secret || !nullifier || !siblings || !recipient) {
      return res.status(400).json({ error: 'Missing required fields' });
    }
    
    if (!ethers.isAddress(recipient)) {
      return res.status(400).json({ error: 'Invalid recipient address' });
    }
    
    // Generate proof
    const proofInputs: ProofInputs = {
      secret,
      nullifier,
      siblings,
      recipient: BigInt(recipient).toString(),
      root,
      raffleId: raffleId.toString(),
      winnerIndex: winnerIndex.toString(),
      treeDepth: treeDepth.toString(),
    };
    
    const { proof, publicInputs } = await prover.generateProof(proofInputs);
    
    // Format for contract
    const proofHex = prover.formatProofForContract(proof);
    const publicInputsBytes32 = prover.formatPublicInputsForContract(publicInputs);
    
    // Submit transaction
    const tx = await raffleContract.claimPrize(
      raffleId,
      proofHex,
      publicInputsBytes32,
      recipient,
      RELAYER_FEE
    );
    
    const receipt = await tx.wait();
    
    res.json({
      success: true,
      txHash: receipt.hash,
      blockNumber: receipt.blockNumber,
    });
    
  } catch (error: any) {
    console.error('Claim with proof generation error:', error.message);
    res.status(500).json({ error: 'Claim failed' });
  }
});

/**
 * Get current relayer fee
 */
app.get('/fee', (req: Request, res: Response) => {
  res.json({
    feeWei: RELAYER_FEE,
    feeEth: ethers.formatEther(RELAYER_FEE),
  });
});

// ============================================================================
// Error Handling
// ============================================================================

app.use((err: Error, req: Request, res: Response, next: NextFunction) => {
  console.error('Unhandled error:', err.message);
  res.status(500).json({ error: 'Internal server error' });
});

// ============================================================================
// Start Server
// ============================================================================

async function main(): Promise<void> {
  await initializeServices();
  
  app.listen(PORT, () => {
    console.log(`\n🎰 Private Raffle Relayer running on port ${PORT}`);
    console.log(`\nEndpoints:`);
    console.log(`  GET  /health                      - Health check`);
    console.log(`  GET  /raffle/:raffleId            - Get raffle info`);
    console.log(`  GET  /fee                         - Get relayer fee`);
    console.log(`  POST /claim                       - Submit claim with proof`);
    console.log(`  POST /claim-with-proof-generation - Generate proof and claim\n`);
  });
}

main().catch(console.error);
