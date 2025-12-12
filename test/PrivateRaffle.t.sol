// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {PrivateRaffle} from "../src/PrivateRaffle.sol";
import {INoirVerifier} from "../src/interfaces/INoirVerifier.sol";

/**
 * @title MockVerifier
 * @notice Mock verifier that always returns true for testing
 */
contract MockVerifier is INoirVerifier {
    bool public shouldPass = true;

    function setShouldPass(bool _shouldPass) external {
        shouldPass = _shouldPass;
    }

    function verify(
        bytes calldata,
        bytes32[] calldata
    ) external view returns (bool) {
        return shouldPass;
    }
}

/**
 * @title MockPoseidon2
 * @notice Mock Poseidon2 hash contract for testing
 */
contract MockPoseidon2 {
    uint256 constant BN254_FIELD_PRIME =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    function hash_2(uint256 x, uint256 y) external pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(x, y))) % BN254_FIELD_PRIME;
    }
}

/**
 * @title PrivateRaffleTest
 */
contract PrivateRaffleTest is Test {
    PrivateRaffle public raffle;
    MockVerifier public verifier;
    MockPoseidon2 public poseidon2;

    address public creator = address(0x1);
    address public participant1 = address(0x2);
    address public participant2 = address(0x3);
    address public relayer = address(0x4);
    address public winner = address(0x5);
    address public gelatoVRF = address(0x6);

    uint256 constant TICKET_PRICE = 0.01 ether;
    uint256 constant PRIZE_AMOUNT = 1 ether;
    uint256 constant LEVELS = 10;
    uint256 constant DURATION = 1 days;

    function setUp() public {
        verifier = new MockVerifier();
        poseidon2 = new MockPoseidon2();
        raffle = new PrivateRaffle(address(verifier), address(poseidon2));

        vm.deal(creator, 10 ether);
        vm.deal(participant1, 10 ether);
        vm.deal(participant2, 10 ether);
        vm.deal(relayer, 1 ether);
    }

    // =========================================================================
    // RAFFLE CREATION TESTS
    // =========================================================================

    function test_CreateRaffle() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        assertEq(raffleId, 1);
        PrivateRaffle.Raffle memory r = raffle.getRaffle(raffleId);
        assertEq(r.creator, creator);
        assertEq(r.ticketPrice, TICKET_PRICE);
        assertEq(r.prizePool, PRIZE_AMOUNT);
    }

    function test_RevertWhen_CreateRaffle_NoPrize() public {
        vm.prank(creator);
        vm.expectRevert("Must deposit prize");
        raffle.createRaffle{value: 0}(TICKET_PRICE, LEVELS, DURATION);
    }

    function test_RevertWhen_CreateRaffle_InvalidLevels() public {
        vm.prank(creator);
        vm.expectRevert("Invalid levels");
        raffle.createRaffle{value: PRIZE_AMOUNT}(TICKET_PRICE, 0, DURATION);
    }

    // =========================================================================
    // TICKET PURCHASE TESTS
    // =========================================================================

    function test_PurchaseTicket() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        uint256 commitment = poseidon2.hash_2(uint256(12345), uint256(67890));

        vm.prank(participant1);
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, commitment);

        assertEq(raffle.getParticipantCount(raffleId), 1);
    }

    function test_RevertWhen_PurchaseTicket_WrongPrice() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        uint256 commitment = poseidon2.hash_2(uint256(111), uint256(222));

        vm.prank(participant1);
        vm.expectRevert(PrivateRaffle.InvalidTicketPrice.selector);
        raffle.purchaseTicket{value: TICKET_PRICE - 1}(raffleId, commitment);
    }

    function test_RevertWhen_PurchaseTicket_RaffleEnded() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        vm.warp(block.timestamp + DURATION + 1);

        uint256 commitment = poseidon2.hash_2(uint256(111), uint256(222));

        vm.prank(participant1);
        vm.expectRevert(PrivateRaffle.RaffleEnded.selector);
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, commitment);
    }

    // =========================================================================
    // VRF TESTS
    // =========================================================================

    function test_DrawWinner() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        vm.prank(participant1);
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, 123);

        vm.warp(block.timestamp + DURATION + 1);
        raffle.drawWinner(raffleId);

        PrivateRaffle.Raffle memory r = raffle.getRaffle(raffleId);
        assertEq(uint256(r.status), uint256(PrivateRaffle.RaffleStatus.Closed));
    }

    function test_DrawWinner_MultipleParticipants() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        for (uint256 i = 0; i < 5; i++) {
            address participant = address(uint160(100 + i));
            vm.deal(participant, 1 ether);
            vm.prank(participant);
            raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, i + 1);
        }

        vm.warp(block.timestamp + DURATION + 1);
        raffle.drawWinner(raffleId);

        PrivateRaffle.Raffle memory r = raffle.getRaffle(raffleId);
        assertEq(uint256(r.status), uint256(PrivateRaffle.RaffleStatus.Closed));
        // We can't deterministic check winner index easily without mocking block params,
        // but we assert it is within bounds
        assertLt(r.winnerIndex, 5);
    }

    // =========================================================================
    // PRIZE CLAIM TESTS
    // =========================================================================

    function test_ClaimPrize() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        uint256 commitment = poseidon2.hash([uint256(12345), uint256(67890)]);
        vm.prank(participant1);
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, commitment);

        vm.warp(block.timestamp + DURATION + 1);
        raffle.drawWinner(raffleId);

        PrivateRaffle.Raffle memory r = raffle.getRaffle(raffleId);

        bytes32[] memory publicInputs = new bytes32[](6);
        publicInputs[0] = bytes32(r.root);
        uint256 nullifierHash = poseidon2.hash_2(uint256(67890), uint256(0));
        publicInputs[1] = bytes32(nullifierHash);
        uint256 recipientBinding = poseidon2.hash_2(
            nullifierHash,
            uint256(uint160(winner))
        );
        publicInputs[2] = bytes32(recipientBinding);
        publicInputs[3] = bytes32(uint256(raffleId));
        publicInputs[4] = bytes32(r.winnerIndex);
        publicInputs[5] = bytes32(uint256(LEVELS));

        bytes memory proof = "mock_proof";
        uint256 relayerFee = 0.001 ether;
        uint256 winnerBalanceBefore = winner.balance;

        vm.prank(relayer);
        raffle.claimPrize(raffleId, proof, publicInputs, winner, relayerFee);

        assertGt(winner.balance, winnerBalanceBefore);
        r = raffle.getRaffle(raffleId);
        assertEq(
            uint256(r.status),
            uint256(PrivateRaffle.RaffleStatus.Claimed)
        );
    }

    function test_RevertWhen_ClaimPrize_DoubleClaim() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        vm.prank(participant1);
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, 123);

        vm.warp(block.timestamp + DURATION + 1);
        raffle.drawWinner(raffleId);

        PrivateRaffle.Raffle memory r = raffle.getRaffle(raffleId);

        bytes32[] memory publicInputs = new bytes32[](6);
        publicInputs[0] = bytes32(r.root);
        uint256 nullifierHash = 111222333;
        publicInputs[1] = bytes32(nullifierHash);
        uint256 recipientBinding = poseidon2.hash_2(
            nullifierHash,
            uint256(uint160(winner))
        );
        publicInputs[2] = bytes32(recipientBinding);
        publicInputs[3] = bytes32(uint256(raffleId));
        publicInputs[4] = bytes32(r.winnerIndex);
        publicInputs[5] = bytes32(uint256(LEVELS));

        bytes memory proof = "mock_proof";

        vm.prank(relayer);
        raffle.claimPrize(raffleId, proof, publicInputs, winner, 0);

        // Second claim should fail
        vm.prank(relayer);
        vm.expectRevert(PrivateRaffle.RaffleNotClosed.selector);
        raffle.claimPrize(raffleId, proof, publicInputs, winner, 0);
    }

    function test_RevertWhen_ClaimPrize_InvalidProof() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        vm.prank(participant1);
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, 123);

        vm.warp(block.timestamp + DURATION + 1);
        raffle.drawWinner(raffleId);

        verifier.setShouldPass(false);

        PrivateRaffle.Raffle memory r = raffle.getRaffle(raffleId);

        bytes32[] memory publicInputs = new bytes32[](6);
        publicInputs[0] = bytes32(r.root);
        publicInputs[1] = bytes32(uint256(111));
        uint256 recipientBinding = poseidon2.hash_2(
            uint256(111),
            uint256(uint160(winner))
        );
        publicInputs[2] = bytes32(recipientBinding);
        publicInputs[3] = bytes32(uint256(raffleId));
        publicInputs[4] = bytes32(r.winnerIndex);
        publicInputs[5] = bytes32(uint256(LEVELS));

        vm.prank(relayer);
        vm.expectRevert(PrivateRaffle.InvalidProof.selector);
        raffle.claimPrize(raffleId, "bad_proof", publicInputs, winner, 0);
    }

    // =========================================================================
    // VIEW FUNCTION TESTS
    // =========================================================================

    function test_IsRaffleActive() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        assertTrue(raffle.isRaffleActive(raffleId));

        vm.warp(block.timestamp + DURATION + 1);
        assertFalse(raffle.isRaffleActive(raffleId));
    }

    function test_ComputeHash() public view {
        uint256 a = 12345;
        uint256 b = 67890;
        uint256 expected = poseidon2.hash_2(a, b);
        uint256 result = raffle.computeHash(a, b);
        assertEq(result, expected);
    }
}
