// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {INoirVerifier} from "./interfaces/INoirVerifier.sol";

/**
 * @title IPoseidon2
 * @notice Interface for Poseidon2 hash contract (poseidon2-evm)
 */
interface IPoseidon2 {
    function hash_2(uint256 x, uint256 y) external view returns (uint256);
}

/**
 * @title PrivateRaffle
 * @notice Zero-Knowledge private raffle system where winners are completely anonymous
 * @dev Uses Noir ZK proofs for privacy and pseudo-randomness for winner selection
 *      Uses Poseidon2 hash function for cryptographic compatibility with ZK circuit
 */
contract PrivateRaffle {
    // =========================================================================
    // TYPES
    // =========================================================================

    enum RaffleStatus {
        Active, // Accepting tickets
        Closed, // Winner selected, ready for claim
        Claimed // Prize claimed
    }

    enum PrizeType {
        NativeToken // ETH or native token (expandable to NFT/ERC20 later)
    }

    struct Raffle {
        // Configuration
        address creator;
        uint256 ticketPrice; // Price per ticket in wei
        uint256 maxParticipants; // 2^levels
        uint256 duration; // Duration in seconds
        uint256 endTime; // When ticket sales end
        // Merkle tree state
        uint256 levels; // Tree height
        uint256 nextIndex; // Next leaf index
        uint256 root; // Current Merkle root
        // Prize
        PrizeType prizeType;
        uint256 prizePool; // Total prize in wei
        // Status
        RaffleStatus status;
        uint256 winnerIndex; // Winning leaf index (set by VRF)
        // Timing
        uint256 createdAt;
    }

    // =========================================================================
    // STATE VARIABLES
    // =========================================================================

    address public owner;
    INoirVerifier public verifier;
    IPoseidon2 public immutable poseidon2;

    uint256 public raffleCounter;

    // Raffle data
    mapping(uint256 => Raffle) public raffles;
    mapping(uint256 => uint256[]) public filledSubtrees; // raffleId => subtrees
    mapping(uint256 => uint256[]) public emptySubtrees; // raffleId => empty subtrees
    mapping(uint256 => mapping(uint256 => uint256)) public commitments; // raffleId => index => commitment

    // Double-claim protection
    mapping(uint256 => mapping(uint256 => bool)) public nullifierUsed; // raffleId => nullifierHash => used

    // =========================================================================
    // EVENTS
    // =========================================================================

    event RaffleCreated(
        uint256 indexed raffleId,
        address indexed creator,
        uint256 ticketPrice,
        uint256 maxParticipants,
        uint256 duration,
        uint256 prizeAmount
    );

    event TicketPurchased(
        uint256 indexed raffleId,
        uint256 indexed leafIndex,
        uint256 commitment
        // NO address logged - privacy!
    );

    event WinnerSelected(
        uint256 indexed raffleId,
        uint256 winnerIndex
        // NO winner address - only index
    );

    event PrizeClaimed(
        uint256 indexed raffleId,
        uint256 amount,
        uint256 nullifierHash
        // NO recipient logged - privacy via relayer
    );

    event RelayerPaid(
        uint256 indexed raffleId,
        address indexed relayer,
        uint256 fee
    );

    // =========================================================================
    // ERRORS
    // =========================================================================

    error OnlyOwner();
    error RaffleNotActive();
    error RaffleNotClosed();
    error RaffleAlreadyClaimed();
    error InvalidTicketPrice();
    error RaffleFull();
    error RaffleEnded();
    error RaffleNotEnded();
    error NoParticipants();
    error InvalidProof();
    error NullifierAlreadyUsed();
    error TransferFailed();
    error InvalidRecipientBinding();
    error NotWinner();
    error InvalidRootMismatch();
    error InvalidRaffleId();

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /**
     * @param _verifier Address of the Noir proof verifier contract
     * @param _poseidon2 Address of the deployed Poseidon2 hash contract (poseidon2-evm)
     */
    constructor(address _verifier, address _poseidon2) {
        owner = msg.sender;
        verifier = INoirVerifier(_verifier);
        poseidon2 = IPoseidon2(_poseidon2);
    }

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    function setVerifier(address _verifier) external onlyOwner {
        verifier = INoirVerifier(_verifier);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    // =========================================================================
    // RAFFLE CREATION
    // =========================================================================

    /**
     * @notice Create a new raffle with native token prize
     * @param ticketPrice Price per ticket in wei
     * @param levels Merkle tree height (max participants = 2^levels)
     * @param duration Duration in seconds
     */
    function createRaffle(
        uint256 ticketPrice,
        uint256 levels,
        uint256 duration
    ) external payable returns (uint256 raffleId) {
        require(levels > 0 && levels <= 20, "Invalid levels");
        require(duration > 0, "Invalid duration");
        require(msg.value > 0, "Must deposit prize");

        raffleId = ++raffleCounter;

        uint256 maxSize = uint256(1) << levels;

        Raffle storage r = raffles[raffleId];
        r.creator = msg.sender;
        r.ticketPrice = ticketPrice;
        r.maxParticipants = maxSize;
        r.levels = levels;
        r.duration = duration;
        r.endTime = block.timestamp + duration;
        r.prizeType = PrizeType.NativeToken;
        r.prizePool = msg.value;
        r.status = RaffleStatus.Active;
        r.createdAt = block.timestamp;

        // Initialize Merkle tree with empty subtrees
        _initMerkleTree(raffleId, levels);

        emit RaffleCreated(
            raffleId,
            msg.sender,
            ticketPrice,
            maxSize,
            duration,
            msg.value
        );
    }

    /**
     * @notice Initialize empty Merkle tree subtrees using Poseidon2 hash
     * @dev empty[0] = 0, empty[i] = Poseidon2(empty[i-1], empty[i-1])
     */
    function _initMerkleTree(uint256 raffleId, uint256 levels) internal {
        uint256[] storage filled = filledSubtrees[raffleId];
        uint256[] storage empty = emptySubtrees[raffleId];

        // Initialize with zeros first
        for (uint256 i = 0; i < levels; i++) {
            filled.push(0);
            empty.push(0);
        }

        // Compute empty subtrees: empty[i] = Poseidon2(empty[i-1], empty[i-1])
        // empty[0] = 0 (empty leaf)
        for (uint256 i = 1; i < levels; i++) {
            empty[i] = _poseidon2Hash(empty[i - 1], empty[i - 1]);
        }
    }

    // =========================================================================
    // TICKET PURCHASE (via Relayer for max privacy)
    // =========================================================================

    /**
     * @notice Purchase a ticket by submitting a commitment
     * @dev Should be called through a relayer for maximum privacy
     * @param raffleId The raffle to join
     * @param commitment Poseidon2(secret, nullifier) computed off-chain
     */
    function purchaseTicket(
        uint256 raffleId,
        uint256 commitment
    ) external payable {
        Raffle storage r = raffles[raffleId];

        if (r.status != RaffleStatus.Active) revert RaffleNotActive();
        if (block.timestamp >= r.endTime) revert RaffleEnded();
        if (r.nextIndex >= r.maxParticipants) revert RaffleFull();
        if (msg.value != r.ticketPrice) revert InvalidTicketPrice();

        uint256 currentIndex = r.nextIndex;

        _insertLeaf(raffleId, commitment, currentIndex, r.levels);

        commitments[raffleId][currentIndex] = commitment;

        r.prizePool += msg.value;
        r.nextIndex++;

        emit TicketPurchased(raffleId, currentIndex, commitment);
    }

    /**
     * @notice Insert leaf into Merkle tree and update root using Poseidon2
     * @dev Standard incremental Merkle tree insertion
     */
    function _insertLeaf(
        uint256 raffleId,
        uint256 leaf,
        uint256 index,
        uint256 levels
    ) internal {
        uint256[] storage filled = filledSubtrees[raffleId];
        uint256[] storage empty = emptySubtrees[raffleId];

        uint256 currentHash = leaf;
        uint256 currentIndex = index;

        for (uint256 i = 0; i < levels; i++) {
            uint256 left;
            uint256 right;

            if (currentIndex % 2 == 0) {
                // Current is left child (even index)
                left = currentHash;
                right = empty[i];
                filled[i] = currentHash;
            } else {
                // Current is right child (odd index)
                left = filled[i];
                right = currentHash;
            }

            // Poseidon2 hash of left and right
            currentHash = _poseidon2Hash(left, right);
            currentIndex >>= 1;
        }

        // Update root
        raffles[raffleId].root = currentHash;
    }

    /**
     * @notice Compute Poseidon2 hash of two field elements
     * @dev Calls the external Poseidon2 contract (poseidon2-evm)
     */
    function _poseidon2Hash(
        uint256 a,
        uint256 b
    ) internal view returns (uint256) {
        return poseidon2.hash_2(a, b);
    }

    // =========================================================================
    // RAFFLE DRAWING (Gelato VRF)
    // =========================================================================

    /**
     * @notice Select winner using simple pseudo-randomness
     * @dev Can only be called after raffle ends. Replaces VRF for now.
     */
    function drawWinner(uint256 raffleId) external {
        Raffle storage r = raffles[raffleId];

        if (r.status != RaffleStatus.Active) revert RaffleNotActive();
        if (block.timestamp < r.endTime) revert RaffleNotEnded();
        if (r.nextIndex == 0) revert NoParticipants();

        // Pseudo-randomness for testing/devnet
        // Insecure for production!
        uint256 randomness = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao,
                    msg.sender,
                    raffleId
                )
            )
        );

        r.winnerIndex = randomness % r.nextIndex;
        r.status = RaffleStatus.Closed;

        emit WinnerSelected(raffleId, r.winnerIndex);
    }

    // =========================================================================
    // PRIZE CLAIM (Via Relayer for max privacy)
    // =========================================================================

    /**
     * @notice Claim prize with ZK proof
     * @dev Should be called by relayer for maximum privacy
     *
     * The proof verifies:
     * 1. Prover knows (secret, nullifier) such that commitment = Poseidon2(secret, nullifier)
     * 2. commitment exists in Merkle tree at winnerIndex position
     * 3. nullifierHash = Poseidon2(nullifier) - for double-claim prevention
     * 4. recipientBinding = Poseidon2(nullifierHash, recipient) - binds recipient to proof
     *
     * @param raffleId The raffle ID
     * @param proof The ZK proof bytes
     * @param publicInputs Array of public inputs:
     *        [0] root
     *        [1] nullifierHash
     *        [2] recipientBinding
     *        [3] raffleId
     *        [4] winnerIndex
     *        [5] treeDepth
     * @param recipient Address to receive the prize (must match proof)
     * @param relayerFee Fee to pay the relayer (deducted from prize)
     */
    function claimPrize(
        uint256 raffleId,
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        address recipient,
        uint256 relayerFee
    ) external {
        Raffle storage r = raffles[raffleId];

        if (r.status != RaffleStatus.Closed) revert RaffleNotClosed();

        require(publicInputs.length == 6, "Invalid public inputs length");

        uint256 proofRoot = uint256(publicInputs[0]);
        uint256 nullifierHash = uint256(publicInputs[1]);
        uint256 recipientBinding = uint256(publicInputs[2]);
        uint256 proofRaffleId = uint256(publicInputs[3]);
        uint256 proofWinnerIndex = uint256(publicInputs[4]);

        if (proofRaffleId != raffleId) revert InvalidRaffleId();

        if (proofRoot != r.root) revert InvalidRootMismatch();

        if (proofWinnerIndex != r.winnerIndex) revert NotWinner();

        if (nullifierUsed[raffleId][nullifierHash])
            revert NullifierAlreadyUsed();

        uint256 expectedBinding = _poseidon2Hash(
            nullifierHash,
            uint256(uint160(recipient))
        );
        if (recipientBinding != expectedBinding)
            revert InvalidRecipientBinding();

        if (!verifier.verify(proof, publicInputs)) revert InvalidProof();

        nullifierUsed[raffleId][nullifierHash] = true;

        r.status = RaffleStatus.Claimed;

        uint256 prizeAmount = r.prizePool;
        r.prizePool = 0;

        uint256 recipientAmount = prizeAmount - relayerFee;

        if (relayerFee > 0) {
            (bool relayerSuccess, ) = msg.sender.call{value: relayerFee}("");
            if (!relayerSuccess) revert TransferFailed();
            emit RelayerPaid(raffleId, msg.sender, relayerFee);
        }

        (bool success, ) = recipient.call{value: recipientAmount}("");
        if (!success) revert TransferFailed();

        emit PrizeClaimed(raffleId, recipientAmount, nullifierHash);
    }

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    function getRaffle(uint256 raffleId) external view returns (Raffle memory) {
        return raffles[raffleId];
    }

    function getRoot(uint256 raffleId) external view returns (uint256) {
        return raffles[raffleId].root;
    }

    function getParticipantCount(
        uint256 raffleId
    ) external view returns (uint256) {
        return raffles[raffleId].nextIndex;
    }

    function isRaffleActive(uint256 raffleId) external view returns (bool) {
        Raffle storage r = raffles[raffleId];
        return r.status == RaffleStatus.Active && block.timestamp < r.endTime;
    }

    function canDrawWinner(uint256 raffleId) external view returns (bool) {
        Raffle storage r = raffles[raffleId];
        return
            r.status == RaffleStatus.Active &&
            block.timestamp >= r.endTime &&
            r.nextIndex > 0;
    }

    /**
     * @notice Compute Poseidon2 hash externally (for off-chain use)
     * @dev Useful for generating commitments off-chain
     */
    function computeHash(uint256 a, uint256 b) external view returns (uint256) {
        return _poseidon2Hash(a, b);
    }

    // =========================================================================
    // EMERGENCY FUNCTIONS
    // =========================================================================

    /**
     * @notice Emergency withdraw for stuck funds
     * @dev Only callable by owner, use with caution
     */
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    receive() external payable {}
}
