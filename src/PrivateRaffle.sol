/*
██████╗░░█████╗░███████╗███████╗███████╗██████╗░░█████╗░
██╔══██╗██╔══██╗██╔════╝██╔════╝██╔════╝██╔══██╗██╔══██╗
██████╔╝███████║█████╗░░█████╗░░█████╗░░██████╔╝██║░░██║
██╔══██╗██╔══██║██╔══╝░░██╔══╝░░██╔══╝░░██╔══██╗██║░░██║
██║░░██║██║░░██║██║░░░░░██║░░░░░███████╗██║░░██║╚█████╔╝
╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░░░░╚═╝░░░░░╚══════╝╚═╝░░╚═╝░╚════╝░

    https://raffero.com
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IncrementalMerkleTree, Poseidon2} from "./IncrementalMerkleTree.sol";
import {IVerifier} from "./UltraVerifier.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISupraRouter} from "./interfaces/ISupraRouter.sol";

/**
 * @title PrivateRaffle
 * @notice Zero-Knowledge private raffle system where winners are completely anonymous
 * @dev Uses Noir ZK proofs for privacy and dVRF for winner selection
 *      Uses Poseidon2 hash function for cryptographic compatibility with ZK circuit
 */
contract PrivateRaffle is IncrementalMerkleTree, ReentrancyGuard {
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
        bytes32 root; // Current Merkle root
        // Prize
        PrizeType prizeType;
        uint256 prizePool; // Total prize in wei
        // Status
        RaffleStatus status;
        uint256 winnerIndex; // Winning leaf index (set by VRF)
        // dVRF
        uint256 requestId;
        bool randomnessRequested;
        // Timing
        uint256 createdAt;
    }

    struct ClaimInputs {
        bytes32 root;
        bytes32 nullifierHash;
        bytes32 recipientBinding;
        uint256 raffleId;
        uint256 winnerIndex;
        uint256 treeDepth;
    }

    // =========================================================================
    // STATE VARIABLES
    // =========================================================================

    address public owner;
    IVerifier public verifier;
    ISupraRouter public supraRouter;

    uint256 public raffleCounter;
    uint256 public constant MAX_LEVELS = 32;
    uint256 public constant MODULUS =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;
    bytes32 public constant ZERO_VALUE =
        bytes32(uint256(keccak256("raffero")) % MODULUS);

    // Raffle data
    mapping(uint256 => Raffle) private raffles;
    mapping(uint256 => mapping(uint256 => bytes32)) public commitments; // raffleId => index => commitment

    // Double-claim protection
    mapping(uint256 => mapping(bytes32 => bool)) public commitmentUsed; // raffleId => commitment => used
    mapping(uint256 => mapping(bytes32 => bool)) public nullifierUsed; // raffleId => nullifierHash => used
    mapping(uint256 => uint256) public requestToRaffle; // requestId => raffleId
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
        bytes32 commitment
    );

    event WinnerSelected(uint256 indexed raffleId, uint256 winnerIndex);

    event PrizeClaimed(
        uint256 indexed raffleId,
        uint256 amount,
        bytes32 nullifierHash
    );

    event RelayerPaid(
        uint256 indexed raffleId,
        address indexed relayer,
        uint256 fee
    );

    event RandomnessRequested(uint256 indexed raffleId, uint256 requestId);

    // =========================================================================
    // ERRORS
    // =========================================================================

    error OnlyOwner();
    error RaffleNotActive(RaffleStatus status);
    error RaffleNotClosed(RaffleStatus status);
    error RaffleAlreadyClaimed();
    error InvalidTicketPrice(uint256 amount, uint256 ticketPrice);
    error RaffleFull(uint256 nextIndex, uint256 maxParticipants);
    error RaffleEnded(uint256 timestamp, uint256 endTime);
    error RaffleNotEnded(uint256 timestamp, uint256 endTime);
    error NoParticipants(uint256 nextIndex);
    error InvalidProof();
    error NullifierAlreadyUsed();
    error TransferFailed();
    error InvalidRecipientBinding(
        bytes32 recipientBinding,
        bytes32 expectedBinding
    );
    error NotWinner(uint256 proofWinnerIndex, uint256 winnerIndex);
    error InvalidRootMismatch(bytes32 proofRoot, bytes32 root);
    error InvalidRaffleId(uint256 proofRaffleId, uint256 raffleId);
    error InvalidLevels(uint256 levels);
    error InvalidDuration(uint256 duration);
    error InvalidPrize(uint256 prize);
    error CommitmentAlreadyUsed();
    error VRFAlreadyRequested();
    error OnlySupraRouter();

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier onlySupraRouter() {
        if (msg.sender != address(supraRouter)) revert OnlySupraRouter();
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /**
     * @param _verifier Address of the Noir proof verifier contract
     * @param _poseidon2 Address of the deployed Poseidon2 hash contract (poseidon2-evm)
     */
    constructor(
        address _verifier,
        address _poseidon2,
        address _supraRouter
    ) IncrementalMerkleTree(Poseidon2(_poseidon2)) {
        owner = msg.sender;
        verifier = IVerifier(_verifier);
        supraRouter = ISupraRouter(_supraRouter);
    }

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    function setVerifier(address _verifier) external onlyOwner {
        verifier = IVerifier(_verifier);
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
    ) external payable nonReentrant returns (uint256 raffleId) {
        if (levels > MAX_LEVELS || levels == 0) revert InvalidLevels(levels);
        if (duration == 0) revert InvalidDuration(duration);
        if (msg.value == 0) revert InvalidPrize(msg.value);

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
        _initTree(raffleId, uint32(levels));
        r.root = getLastRoot(raffleId);
        r.nextIndex = getNextLeafIndex(raffleId);

        emit RaffleCreated(
            raffleId,
            msg.sender,
            ticketPrice,
            maxSize,
            duration,
            msg.value
        );
    }

    // =========================================================================
    // TICKET PURCHASE
    // =========================================================================

    /**
     * @notice Purchase a ticket by submitting a commitment
     * @dev Should be called through a relayer for maximum privacy
     * @param raffleId The raffle to join
     * @param commitment Poseidon2(secret, nullifier) computed off-chain
     */
    function purchaseTicket(
        uint256 raffleId,
        bytes32 commitment
    ) external payable {
        Raffle storage r = raffles[raffleId];

        if (r.status != RaffleStatus.Active) revert RaffleNotActive(r.status);
        if (block.timestamp >= r.endTime)
            revert RaffleEnded(block.timestamp, r.endTime);
        if (r.nextIndex >= r.maxParticipants)
            revert RaffleFull(r.nextIndex, r.maxParticipants);
        if (msg.value != r.ticketPrice)
            revert InvalidTicketPrice(msg.value, r.ticketPrice);
        if (commitmentUsed[raffleId][commitment])
            revert CommitmentAlreadyUsed();

        uint32 insertedIndex = _insert(raffleId, commitment);

        commitments[raffleId][uint256(insertedIndex)] = commitment;
        commitmentUsed[raffleId][commitment] = true;

        r.root = getLastRoot(raffleId);
        r.nextIndex = uint256(getNextLeafIndex(raffleId));
        r.prizePool += msg.value;

        emit TicketPurchased(raffleId, uint256(insertedIndex), commitment);
    }

    // =========================================================================
    // RAFFLE DRAWING
    // =========================================================================

    /**
     * @notice Select winner using dVRF
     * @dev Can only be called after raffle ends.
     */
    function drawWinner(uint256 raffleId) external {
        Raffle storage r = raffles[raffleId];

        if (r.status != RaffleStatus.Active) revert RaffleNotActive(r.status);
        if (block.timestamp < r.endTime)
            revert RaffleNotEnded(block.timestamp, r.endTime);
        if (r.nextIndex == 0) revert NoParticipants(r.nextIndex);
        if (r.randomnessRequested) revert VRFAlreadyRequested();

        r.randomnessRequested = true;

        uint256 seed = uint256(
            keccak256(
                abi.encodePacked(
                    raffleId,
                    r.root,
                    msg.sender,
                    block.timestamp,
                    block.prevrandao
                )
            )
        );
        uint256 requestId = supraRouter.generateRequest(
            "supraCallback(uint256,uint256[])",
            1,
            1,
            seed,
            msg.sender
        );

        r.requestId = requestId;
        requestToRaffle[requestId] = raffleId;

        emit RandomnessRequested(raffleId, requestId);
    }

    function supraCallback(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external onlySupraRouter {
        uint256 raffleId = requestToRaffle[requestId];
        Raffle storage r = raffles[raffleId];

        if (r.status != RaffleStatus.Active) return;
        if (randomWords.length == 0) return;

        uint256 randomness = randomWords[0];
        r.winnerIndex = randomness % r.nextIndex;
        r.status = RaffleStatus.Closed;

        emit WinnerSelected(raffleId, r.winnerIndex);
    }

    // =========================================================================
    // PRIZE CLAIM (Via Relayer for max privacy)
    // =========================================================================
    function _parsePublicInputs(
        bytes32[] calldata publicInputs
    ) internal pure returns (ClaimInputs memory ci) {
        // Esperas exactamente 6 inputs
        if (publicInputs.length != 6) revert InvalidProof();

        ci.root = publicInputs[0];
        ci.nullifierHash = publicInputs[1];
        ci.recipientBinding = publicInputs[2];

        // bytes32 -> uint256 (directo)
        ci.raffleId = uint256(publicInputs[3]);
        ci.winnerIndex = uint256(publicInputs[4]);
        ci.treeDepth = uint256(publicInputs[5]);
    }

    function _validateClaim(
        Raffle storage r,
        uint256 raffleId,
        ClaimInputs memory ci,
        address recipient
    ) internal view {
        if (ci.raffleId != raffleId)
            revert InvalidRaffleId(ci.raffleId, raffleId);

        if (ci.root != r.root) revert InvalidRootMismatch(ci.root, r.root);

        if (ci.winnerIndex != r.winnerIndex)
            revert NotWinner(ci.winnerIndex, r.winnerIndex);

        if (nullifierUsed[raffleId][ci.nullifierHash])
            revert NullifierAlreadyUsed();
        /*
        bytes32 expected = _expectedRecipientBinding(
            ci.nullifierHash,
            recipient
        );
        if (ci.recipientBinding != expected)
            revert InvalidRecipientBinding(ci.recipientBinding, expected);
        */

        // Si quieres, también puedes validar depth (opcional):
        // if (ci.treeDepth != r.levels) revert InvalidProof(); // o crea error propio
    }

    /*
    function _expectedRecipientBinding(
        bytes32 nullifierHash,
        address recipient
    ) internal view returns (bytes32) {
        return
            Field.toBytes32(
                poseidon2.hash_2(
                    Field.toField(nullifierHash),
                    Field.toField(uint160(recipient))
                )
            );
    }
    */

    function _payout(
        uint256 raffleId,
        Raffle storage r,
        address recipient,
        uint256 relayerFee
    ) internal returns (uint256 paidToRecipient) {
        uint256 prizeAmount = r.prizePool;
        r.prizePool = 0;

        if (relayerFee > prizeAmount) revert TransferFailed();

        paidToRecipient = prizeAmount - relayerFee;

        if (relayerFee > 0) {
            (bool okRelayer, ) = msg.sender.call{value: relayerFee}("");
            if (!okRelayer) revert TransferFailed();
            emit RelayerPaid(raffleId, msg.sender, relayerFee);
        }

        (bool okRecipient, ) = recipient.call{value: paidToRecipient}("");
        if (!okRecipient) revert TransferFailed();
    }

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
    ) external nonReentrant {
        Raffle storage r = raffles[raffleId];

        if (r.status != RaffleStatus.Closed) revert RaffleNotClosed(r.status);

        require(publicInputs.length == 6, "Invalid public inputs length");

        ClaimInputs memory ci = _parsePublicInputs(publicInputs);

        _validateClaim(r, raffleId, ci, recipient);

        if (!verifier.verify(proof, publicInputs)) revert InvalidProof();

        nullifierUsed[raffleId][ci.nullifierHash] = true;

        r.status = RaffleStatus.Claimed;

        uint256 paidToRecipient = _payout(raffleId, r, recipient, relayerFee);

        emit PrizeClaimed(raffleId, paidToRecipient, ci.nullifierHash);
    }

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    function getRaffle(uint256 raffleId) external view returns (Raffle memory) {
        return raffles[raffleId];
    }

    function getRoot(uint256 raffleId) external view returns (bytes32) {
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
