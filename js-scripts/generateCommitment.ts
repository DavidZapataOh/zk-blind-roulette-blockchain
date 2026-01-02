import { Barretenberg, Fr } from "@aztec/bb.js";
import { ethers } from "ethers";

export default async function generateCommitment(): Promise<string> {
    const bb = await Barretenberg.new();
    const nullifier = Fr.random();
    const secret = Fr.random();

    const commitment: Fr = await bb.poseidon2Hash([secret, nullifier]);
    const result = ethers.AbiCoder.defaultAbiCoder().encode(["bytes32", "bytes32", "bytes32"], [commitment.toBuffer(), nullifier.toBuffer(), secret.toBuffer()]);
    return result;
}

(async () => {
    generateCommitment()
    .then((result) => {
        process.stdout.write(result);
        process.exit(0);
    })
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
})();