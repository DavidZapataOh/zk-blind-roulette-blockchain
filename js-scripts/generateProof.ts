import { Barretenberg, Fr, UltraHonkBackend } from "@aztec/bb.js";
import { ethers } from "ethers";
import { Noir } from "@noir-lang/noir_js";
import { PoseidonIMT, bytes32HexToBigInt } from "./merkleTree";
import * as fs from "fs";
import * as path from "path";

const circuit = JSON.parse(
    fs.readFileSync(path.resolve(__dirname, "../circuits/target/raffle_circuits.json"), "utf-8")
);

const MAX_DEPTH = 32;

export default async function generateProof() {
    const bb = await Barretenberg.new();
    const inputs = process.argv.slice(2);
    const nullifier = Fr.fromString(inputs[0]);
    const secret = Fr.fromString(inputs[1]); 
    const recipient = Fr.fromString(inputs[2]);
    const raffleId = inputs[3];
    const winnerIndex = Number(BigInt(inputs[4]));
    const treeDepth = Number(BigInt(inputs[5]));

    //const commitment = await bb.poseidon2Hash([secret, nullifier]);
    const leafHexes = inputs.slice(6);
    const leaves = leafHexes.map((hex) => bytes32HexToBigInt(hex));

    const tree = new PoseidonIMT(bb, treeDepth);
    await tree.initEmpty();

    for (const leaf of leaves) {
        await tree.insert(leaf);
    }

    // Compute proof for winnerIndex
    const merkleProof = tree.proof(winnerIndex);

    const nullifierHash = await bb.poseidon2Hash([nullifier]);
    const recipientBinding = await bb.poseidon2Hash([nullifierHash, recipient]);

    const siblingsPadded = new Array<bigint>(MAX_DEPTH).fill(0n);
    const pathIdxPadded = new Array<bigint>(MAX_DEPTH).fill(0n);

    for (let i = 0; i < treeDepth; i++) {
        siblingsPadded[i] = merkleProof.pathElements[i];
        pathIdxPadded[i] = merkleProof.pathIndices[i];
    }
    
    try {
        const noir = new Noir(circuit);
        const honk = new UltraHonkBackend(circuit.bytecode, {threads: 1});
        const input = {
            // Public inputs
            root: merkleProof.root.toString(),
            nullifier_hash: nullifierHash.toString(),
            recipient_binding: recipientBinding.toString(),
            raffle_id: raffleId.toString(),
            winner_index: winnerIndex.toString(),
            tree_depth: treeDepth.toString(),
            // Private inputs
            nullifier: nullifier.toString(),
            secret: secret.toString(),
            siblings: siblingsPadded.map(i => i.toString()),
            path_indices: pathIdxPadded.map(i => i.toString()),
            recipient: recipient.toString(),
        }

        const { witness } = await noir.execute(input);
        const originalLog = console.log;
        console.log = () => {};
        const { proof, publicInputs } = await honk.generateProof(witness, { keccak: true });
        console.log = originalLog;
        const result = ethers.AbiCoder.defaultAbiCoder().encode(["bytes", "bytes32[]"], [proof, publicInputs]);
        
        return result;
    } catch (error) {
        console.log(error);
        throw error;
    }
}

(async () => {
    generateProof()
    .then((result) => {
        process.stdout.write(result);
        process.exit(0);
    })
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
})();