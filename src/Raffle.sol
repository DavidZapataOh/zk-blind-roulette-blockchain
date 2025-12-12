// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Poseidon hash (arity-2) interface. Must return H(a, b) as a single uint256.
interface IPoseidon2 {
    function poseidon(uint[2] calldata inputs) external view returns (uint256);
}

/// @notice Circom/snarkjs verifier interface generated for the circuit used here.
/// @dev The verifier must expect pubSignals in the exact order produced by the circuit.
interface ICircomVerifier {
    function verifyProof(
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC,
        uint[24] calldata _pubSignals
    ) external view returns (bool);
}

/**
 * @title PrivateRaffle
 * @notice Merkle-based private raffle where the winner proves membership and winner index in ZK.
 * @dev Circuit pubSignals order (MUST match the deployed verifier):
 *      [0] nullifierHash
 *      [1] recipientBinding
 *      [2] root
 *      [3] raffleId
 *      [4..4+levels-1] winnerIndexBits[i]  // bit i (LSB-first)
 */
contract PrivateRaffle {
    struct Raffle {
        uint256 levels; // Merkle height
        uint256 ticketPrice; // wei
        uint256 maxSize; // 2^levels
        uint256 nextIndex; // next leaf index
        uint256 root; // current Merkle root
        uint256[] filledSubtrees;
        uint256[] emptySubtrees;
        bool open; // selling tickets
        bool winnerSet; // winnerIndex finalized
        uint256 winnerIndex; // 0..nextIndex-1
        uint256 prizePool; // wei
    }

    address public owner;
    IPoseidon2 public poseidon2;
    ICircomVerifier public verifier;

    // raffleId => Raffle
    mapping(uint256 => Raffle) public raffles;

    // Optional audit trail: (raffleId, index) -> commitment (leaf)
    mapping(uint256 => mapping(uint256 => uint256)) public commitments;

    // Double-claim protection: (raffleId, nullifierHash) -> used
    mapping(uint256 => mapping(uint256 => bool)) public nullifiers;

    event RaffleCreated(
        uint256 indexed raffleId,
        uint256 ticketPrice,
        uint256 levels,
        uint256 maxSize
    );
    event TicketDeposited(
        uint256 indexed raffleId,
        uint256 index,
        uint256 commitment
    );
    event RaffleClosed(uint256 indexed raffleId, uint256 winnerIndex);
    event PrizeClaimed(
        uint256 indexed raffleId,
        address indexed to,
        uint256 amount,
        uint256 nullifierHash
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "ONLY_OWNER");
        _;
    }

    constructor(address poseidon2Addr, address verifierAddr) {
        owner = msg.sender;
        poseidon2 = IPoseidon2(poseidon2Addr);
        verifier = ICircomVerifier(verifierAddr);
    }

    /* ───────────────────────────── Admin ───────────────────────────── */

    /**
     * @notice Create a raffle with fixed capacity (2^levels) and ticket price.
     * @param raffleId Unique identifier.
     * @param ticketPrice Price per ticket (wei).
     * @param levels Merkle height (capacity = 2^levels).
     */
    function createRaffle(
        uint256 raffleId,
        uint256 ticketPrice,
        uint256 levels
    ) external onlyOwner {
        require(raffles[raffleId].ticketPrice == 0, "RAFFLE_EXISTS");
        require(levels > 0 && levels <= 64, "LEVELS_RANGE");

        uint256 maxSize = uint256(1) << levels;

        Raffle storage r = raffles[raffleId];
        r.levels = levels;
        r.ticketPrice = ticketPrice;
        r.maxSize = maxSize;
        r.open = true;

        r.filledSubtrees = new uint256[](levels);
        r.emptySubtrees = new uint256[](levels);

        // Zero-hash template: empty[0] = 0; empty[i] = H(empty[i-1], 0)
        r.emptySubtrees[0] = 0;
        for (uint256 i = 1; i < levels; i++) {
            r.emptySubtrees[i] = poseidon2.poseidon(
                [r.emptySubtrees[i - 1], uint256(0)]
            );
        }

        emit RaffleCreated(raffleId, ticketPrice, levels, maxSize);
    }

    /**
     * @notice Close ticket sales and set winner index.
     * @dev Replace randomness with Chainlink VRF (or similar) in production.
     */
    function closeAndSetWinner(
        uint256 raffleId,
        uint256 randomness
    ) external onlyOwner {
        Raffle storage r = raffles[raffleId];
        require(r.ticketPrice != 0, "RAFFLE_UNKNOWN");
        require(r.open, "ALREADY_CLOSED");
        require(r.nextIndex > 0, "NO_TICKETS");

        r.open = false;
        r.winnerIndex = randomness % r.nextIndex;
        r.winnerSet = true;

        emit RaffleClosed(raffleId, r.winnerIndex);
    }

    /* ─────────────────────────── User actions ───────────────────────── */

    /**
     * @notice Buy a ticket by submitting a commitment (leaf).
     * @dev Use a relayer if caller privacy is required.
     */
    function depositTicket(
        uint256 raffleId,
        uint256 commitment
    ) external payable {
        Raffle storage r = raffles[raffleId];
        require(r.ticketPrice != 0, "RAFFLE_UNKNOWN");
        require(r.open, "CLOSED");
        require(msg.value == r.ticketPrice, "BAD_PRICE");
        require(r.nextIndex < r.maxSize, "TREE_FULL");

        uint256 currentIndex = r.nextIndex;
        uint256 currentHash = commitment;

        for (uint256 i = 0; i < r.levels; i++) {
            uint256 left;
            uint256 right;

            if (currentIndex % 2 == 0) {
                left = currentHash;
                right = r.emptySubtrees[i];
                r.filledSubtrees[i] = currentHash;
            } else {
                left = r.filledSubtrees[i];
                right = currentHash;
            }

            currentHash = poseidon2.poseidon([left, right]);
            currentIndex >>= 1;
        }

        r.root = currentHash;
        commitments[raffleId][r.nextIndex] = commitment;
        r.nextIndex += 1;
        r.prizePool += msg.value;

        emit TicketDeposited(raffleId, r.nextIndex - 1, commitment);
    }

    /**
     * @notice Claim the prize if your leaf corresponds to the published winner index.
     * @dev Verifies zkSNARK proof, winner bits, recipient binding, and nullifier uniqueness.
     * @param recipient Address to receive the prize. Must be bound in the proof as Poseidon(nullifierHash, recipient).
     * @param _pubSignals Circuit pubSignals in the exact order described in the contract header.
     */
    function claimPrize(
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC,
        uint[24] calldata _pubSignals,
        address recipient
    ) external {
        require(verifier.verifyProof(_pA, _pB, _pC, _pubSignals), "BAD_PROOF");

        // Parse pubSignals according to the circuit:
        // 0: nullifierHash
        // 1: recipientBinding
        // 2: root
        // 3: raffleId
        // 4..4+levels-1: winnerIndexBits
        uint256 nullifierHash = _pubSignals[0];
        uint256 recipientBinding = _pubSignals[1];
        uint256 root = _pubSignals[2];
        uint256 raffleId = _pubSignals[3];

        Raffle storage r = raffles[raffleId];
        require(r.ticketPrice != 0, "RAFFLE_UNKNOWN");

        uint256 L = r.levels;
        require(_pubSignals.length == (4 + L), "BAD_PUBSIG_LEN");

        // Rebuild winner index from bits (LSB-first).
        uint256 idx;
        unchecked {
            for (uint256 i = 0; i < L; i++) {
                uint256 bit = _pubSignals[4 + i];
                require(bit == 0 || bit == 1, "BIT");
                if (bit == 1) idx |= (uint256(1) << i);
            }
        }

        require(!r.open && r.winnerSet, "NOT_CLOSED");
        require(root == r.root, "ROOT_MISMATCH");
        require(idx == r.winnerIndex, "NOT_WINNER");

        // Bind recipient to the proof: Poseidon(nullifierHash, recipient)
        uint256 rb = poseidon2.poseidon(
            [nullifierHash, uint256(uint160(recipient))]
        );
        require(recipientBinding == rb, "RECIPIENT_NOT_BOUND");

        // Prevent double-claim
        require(!nullifiers[raffleId][nullifierHash], "ALREADY_CLAIMED");
        nullifiers[raffleId][nullifierHash] = true;

        // Effects-before-interactions
        uint256 amount = r.prizePool;
        r.prizePool = 0;

        (bool sent, ) = recipient.call{value: amount}("");
        require(sent, "SEND_FAILED");

        emit PrizeClaimed(raffleId, recipient, amount, nullifierHash);
    }

    /* ───────────────────────────── Utilities ─────────────────────────── */

    function getRoot(uint256 raffleId) external view returns (uint256) {
        return raffles[raffleId].root;
    }

    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /// @dev Emergency drain. Avoid using in production unless strictly necessary.
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "WITHDRAW_FAIL");
    }

    receive() external payable {}
}
