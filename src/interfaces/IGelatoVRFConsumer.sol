// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IGelatoVRFConsumer
/// @notice Interface for Gelato VRF consumer base functionality
interface IGelatoVRFConsumer {
    /// @notice Event emitted when randomness is requested
    event RequestedRandomness(uint256 round, bytes data);

    /// @notice Called by Gelato to fulfill the randomness request
    /// @param randomness The random value
    /// @param data Arbitrary data passed during request
    function fulfillRandomness(
        uint256 randomness,
        bytes calldata data
    ) external;
}
