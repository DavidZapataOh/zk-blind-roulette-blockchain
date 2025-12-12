// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PrivateRaffle} from "../src/PrivateRaffle.sol";
import {Poseidon2} from "poseidon2-evm/Poseidon2.sol";

/**
 * @title DeployPrivateRaffle
 * @notice Deployment script for PrivateRaffle on Scroll Sepolia
 *
 * Prerequisites:
 * - UltraVerifier already deployed: 0x3Ab7eD4598E2841413Ab9EfAb1710835f0D952E9
 * - Poseidon2 contract deployed (set POSEIDON2_ADDRESS env var)
 *
 * Usage:
 *   POSEIDON2_ADDRESS=0x... forge script script/Deploy.s.sol:DeployPrivateRaffle \
 *     --rpc-url $SCROLL_SEPOLIA_RPC \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 */
contract DeployPrivateRaffle is Script {
    // Already deployed on Scroll Sepolia via Remix
    address constant VERIFIER_ADDRESS =
        0x3Ab7eD4598E2841413Ab9EfAb1710835f0D952E9;

    function run() external {
        address poseidon2Address = vm.envOr("POSEIDON2_ADDRESS", address(0));

        console.log("=== Deploying PrivateRaffle ===");
        console.log("Deployer:", msg.sender);
        console.log("Verifier:", VERIFIER_ADDRESS);
        console.log("Poseidon2:", poseidon2Address);

        vm.startBroadcast();

        if (poseidon2Address == address(0)) {
            console.log("Deploying Poseidon2...");
            Poseidon2 p2 = new Poseidon2();
            poseidon2Address = address(p2);
            console.log("Poseidon2 Deployed at:", poseidon2Address);
        }

        PrivateRaffle raffle = new PrivateRaffle(
            VERIFIER_ADDRESS,
            poseidon2Address
        );

        console.log("\n=== Deployment Complete ===");
        console.log("PrivateRaffle:", address(raffle));

        vm.stopBroadcast();
    }
}
