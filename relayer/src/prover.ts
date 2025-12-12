/**
 * Prover module for generating ZK proofs for raffle claims
 */

import { Noir } from '@noir-lang/noir_js';
import { UltraHonkBackend } from '@aztec/bb.js';
import * as fs from 'fs';
import * as path from 'path';

export interface ProofInputs {
  // Private inputs (known only to the winner)
  secret: string;           // Secret used in commitment
  nullifier: string;        // Nullifier for double-claim prevention
  siblings: string[];       // Merkle proof siblings
  recipient: string;        // Clean address to receive prize
  
  // Public inputs (verified on-chain)
  root: string;             // Merkle root
  raffleId: string;         // Raffle ID
  winnerIndex: string;      // Winning index
  treeDepth: string;        // Merkle tree depth
}

export interface GeneratedProof {
  proof: Uint8Array;
  publicInputs: string[];
}

export class RaffleProver {
  private noir: Noir | null = null;
  private backend: UltraHonkBackend | null = null;
  private circuitPath: string;
  
  constructor(circuitPath: string) {
    this.circuitPath = circuitPath;
  }
  
  /**
   * Initialize the prover by loading the compiled circuit
   */
  async initialize(): Promise<void> {
    console.log('Loading circuit from:', this.circuitPath);
    
    // Load compiled circuit JSON
    const circuitJson = JSON.parse(
      fs.readFileSync(this.circuitPath, 'utf-8')
    );
    
    // Initialize Noir with the circuit
    this.noir = new Noir(circuitJson);
    
    // Initialize the backend (UltraHonk for Noir)
    this.backend = new UltraHonkBackend(circuitJson.bytecode);
    
    console.log('Prover initialized successfully');
  }
  
  /**
   * Generate a ZK proof for claiming a raffle prize
   */
  async generateProof(inputs: ProofInputs): Promise<GeneratedProof> {
    if (!this.noir || !this.backend) {
      throw new Error('Prover not initialized. Call initialize() first.');
    }
    
    // Prepare circuit inputs
    const circuitInputs = {
      // Private inputs
      secret: inputs.secret,
      nullifier: inputs.nullifier,
      siblings: this.padSiblings(inputs.siblings, 20), // MAX_DEPTH = 20
      recipient: inputs.recipient,
      
      // Public inputs
      root: inputs.root,
      nullifier_hash: await this.computeNullifierHash(inputs.nullifier),
      recipient_binding: await this.computeRecipientBinding(
        await this.computeNullifierHash(inputs.nullifier),
        inputs.recipient
      ),
      raffle_id: inputs.raffleId,
      winner_index: inputs.winnerIndex,
      tree_depth: inputs.treeDepth,
    };
    
    console.log('Generating witness...');
    const { witness } = await this.noir.execute(circuitInputs);
    
    console.log('Generating proof...');
    const proof = await this.backend.generateProof(witness);
    
    // Extract public inputs in the order expected by the contract
    const publicInputs = [
      inputs.root,
      circuitInputs.nullifier_hash,
      circuitInputs.recipient_binding,
      inputs.raffleId,
      inputs.winnerIndex,
      inputs.treeDepth,
    ];
    
    console.log('Proof generated successfully');
    
    return {
      proof: proof.proof,
      publicInputs,
    };
  }
  
  /**
   * Verify a proof locally before submitting
   */
  async verifyProof(proof: Uint8Array, publicInputs: string[]): Promise<boolean> {
    if (!this.backend) {
      throw new Error('Prover not initialized');
    }
    
    return await this.backend.verifyProof({ proof, publicInputs });
  }
  
  /**
   * Pad siblings array to MAX_DEPTH
   */
  private padSiblings(siblings: string[], maxDepth: number): string[] {
    const padded = [...siblings];
    while (padded.length < maxDepth) {
      padded.push('0');
    }
    return padded;
  }
  
  /**
   * Compute nullifier hash (Pedersen hash of nullifier)
   * 
   * Note: This should match the hash function used in the circuit
   * For testing, we use a placeholder. In production, use proper Pedersen.
   */
  private async computeNullifierHash(nullifier: string): Promise<string> {
    // In production, this should use the same Pedersen hash as the circuit
    // For now, we compute it during proof generation
    // The circuit will verify this matches
    
    // Placeholder: Return a deterministic value based on nullifier
    // Real implementation would use a Pedersen hash library
    const hash = BigInt(nullifier) * BigInt(7919) % BigInt(2n ** 254n);
    return hash.toString();
  }
  
  /**
   * Compute recipient binding (Pedersen hash of nullifierHash + recipient)
   */
  private async computeRecipientBinding(
    nullifierHash: string,
    recipient: string
  ): Promise<string> {
    // Same as nullifierHash - placeholder for actual Pedersen
    const combined = (BigInt(nullifierHash) + BigInt(recipient)) % BigInt(2n ** 254n);
    return combined.toString();
  }
  
  /**
   * Format proof for Solidity contract
   * Converts Uint8Array to hex string
   */
  formatProofForContract(proof: Uint8Array): string {
    return '0x' + Buffer.from(proof).toString('hex');
  }
  
  /**
   * Format public inputs for Solidity contract
   * Converts strings to bytes32
   */
  formatPublicInputsForContract(publicInputs: string[]): string[] {
    return publicInputs.map(input => {
      const bn = BigInt(input);
      return '0x' + bn.toString(16).padStart(64, '0');
    });
  }
}

export default RaffleProver;
