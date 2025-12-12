
import { RaffleProver, ProofInputs } from '../prover.js';
import * as dotenv from 'dotenv';
import * as path from 'path';
import * as fs from 'fs';
import { ethers } from 'ethers';

dotenv.config();

// Ensure arguments are provided
// Usage: npm run generate-proof <raffleId> <secret> <nullifier> <recipient> <path_indices_comma_separated> <siblings_comma_separated>
// Or interactive mode if no args

async function main() {
  const circuitPath = process.env.CIRCUIT_PATH || path.join(__dirname, '../../../circuits/target/raffle_circuits.json');
  
  if (!fs.existsSync(circuitPath)) {
    console.error(`Circuit file not found at ${circuitPath}`);
    console.error('Make sure to compile the circuits first: cd circuits && nargo compile');
    process.exit(1);
  }

  const prover = new RaffleProver(circuitPath);
  await prover.initialize();

  // For simplicity in this demo, we'll hardcode or read from env/args
  // In a real CLI we'd use a prompt library
  
  const args = process.argv.slice(2);
  
  if (args.length < 4) {
    console.log(`
Usage: 
  npm run generate-proof <raffleId> <secret> <nullifier> <recipient> [path_indices] [siblings]

Example:
  npm run generate-proof 1 12345 67890 0x123... "0,0,0..." "0x...,0x..."

If path/siblings are omitted, it assumes a simple testing tree (all zeros or derived).
    `);
    process.exit(1);
  }

  const [raffleId, secret, nullifier, recipient] = args;
  
  // Parse arrays
  // For testing, we might accept empty or defaults
  // Real implementation needs actual Merkle proof from the contract events/storage
  const pathIndicesStr = args[4] || "0,0,0,0,0,0,0,0,0,0"; 
  const siblingsStr = args[5] || "0,0,0,0,0,0,0,0,0,0";

  // Convert to arrays
  const path_indices = pathIndicesStr.split(',').map(s => s.trim());
  
  // Siblings might be hex or decimal strings
  const siblings = siblingsStr.split(',').map(s => s.trim());

  // Convert path_indices to integer (0 or 1) for the prover input logic to calculate winnerIndex
  let winnerIndex = 0;
  let powerOfTwo = 1;
  for (let i = 0; i < path_indices.length; i++) {
    const bit = parseInt(path_indices[i]);
    if (bit === 1) {
      winnerIndex += powerOfTwo;
    }
    powerOfTwo *= 2;
  }

  const inputs: ProofInputs = {
    secret,
    nullifier,
    siblings,
    recipient,
    // We don't really have the root here unless passed, but the prover will compute expected root from tree?
    // Wait, the circuit COMPUTES root from inputs. 
    // The Input struct in prover.ts asks for 'root'. 
    // In main.nr, root is a public input.
    // The prover.ts generates witness that includes calculating the root.
    // The verifier (contract) will match this root against its storage.
    // So we need to calculate the root from the provided siblings/secret/nullifier locally to pass it as public input.
    // OR we let the prover/circuit calculate it and extract it.
    // But ProverInputs interface requires it.
    // Let's pass '0' or a dummy if we expect the circuit to output it, 
    // BUT prover.ts passes it to circuitInputs 'root: inputs.root'. 
    // If the circuit expects 'root: pub Field', then we must provide the value we claim is the root.
    
    // For now let's assume the user passes the root or we compute it.
    // Simplification: We'll calculate it using a helper if possible, or accept it as arg.
    root: args[6] || "0", // 6th argument if provided
    raffleId,
    winnerIndex: winnerIndex.toString(),
    treeDepth: path_indices.length.toString()
  };

  console.log("Generating proof with inputs:", JSON.stringify(inputs, null, 2));

  try {
    const { proof, publicInputs } = await prover.generateProof(inputs);
    
    console.log("\n✅ Proof Generated Successfully!");
    
    // Output for easy copying
    console.log("\n--- Proof (Hex) ---");
    console.log(prover.formatProofForContract(proof));
    
    console.log("\n--- Public Inputs (Bytes32 Array) ---");
    console.log(JSON.stringify(prover.formatPublicInputsForContract(publicInputs)));
    
    console.log("\n--- JSON Payload for /claim ---");
    const payload = {
      raffleId,
      proof: prover.formatProofForContract(proof),
      publicInputs: prover.formatPublicInputsForContract(publicInputs),
      recipient
    };
    console.log(JSON.stringify(payload, null, 2));
    
  } catch (err) {
    console.error("Error generating proof:", err);
  }
}

main().catch(console.error);
