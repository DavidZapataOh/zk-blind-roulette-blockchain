// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {PrivateRaffle, Poseidon2} from "../src/PrivateRaffle.sol";
import {HonkVerifier} from "../src/UltraVerifier.sol";
import {ISupraRouter} from "../src/interfaces/ISupraRouter.sol";

contract MockSupraRouter is ISupraRouter {
    uint256 public nextRequestId = 1;

    function generateRequest(
        string memory _functionSig,
        uint8 _rngCount,
        uint256 _numConfirmations,
        uint256 _clientSeed,
        address _clientWalletAddress
    ) external returns (uint256 requestId) {
        requestId = nextRequestId++;
    }

    function fulfill(
        address consumer,
        uint256 requestId,
        uint256 randomness
    ) external {
        uint256[] memory words = new uint256[](1);
        words[0] = randomness;

        // llama el callback del consumer (tu PrivateRaffle)
        (bool ok, bytes memory ret) = consumer.call(
            abi.encodeWithSignature(
                "supraCallback(uint256,uint256[])",
                requestId,
                words
            )
        );

        if (!ok) {
            // bubble revert reason si existe
            if (ret.length > 0) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            revert("MockSupraRouter: callback failed");
        }
    }
}

/**
 * @title PrivateRaffleTest
 */
contract PrivateRaffleTest is Test {
    PrivateRaffle public raffle;
    HonkVerifier public verifier;
    Poseidon2 public poseidon2;
    MockSupraRouter public supraRouter;

    address public creator = makeAddr("creator");
    address public participant1 = makeAddr("participant1");
    address public participant2 = makeAddr("participant2");
    address public relayer = makeAddr("relayer");
    address public winner = makeAddr("winner");

    uint256 constant TICKET_PRICE = 0.01 ether;
    uint256 constant PRIZE_AMOUNT = 1 ether;
    uint256 constant LEVELS = 20;
    uint256 constant DURATION = 1 days;

    function setUp() public {
        verifier = new HonkVerifier();
        poseidon2 = new Poseidon2();
        supraRouter = new MockSupraRouter();
        raffle = new PrivateRaffle(
            address(verifier),
            address(poseidon2),
            address(supraRouter)
        );

        vm.deal(creator, 10 ether);
        vm.deal(participant1, 10 ether);
        vm.deal(participant2, 10 ether);
        vm.deal(relayer, 1 ether);
    }

    function _getCommitment()
        internal
        returns (bytes32 _commitment, bytes32 _nullifier, bytes32 _secret)
    {
        string[] memory inputs = new string[](3);
        inputs[0] = "npx";
        inputs[1] = "tsx";
        inputs[2] = "js-scripts/generateCommitment.ts";
        bytes memory result = vm.ffi(inputs);
        (_commitment, _nullifier, _secret) = abi.decode(
            result,
            (bytes32, bytes32, bytes32)
        );
        return (_commitment, _nullifier, _secret);
    }

    function _getProof(
        bytes32 _nullifier,
        bytes32 _secret,
        address _recipient,
        uint256 raffleId,
        uint256 winnerIndex,
        uint256 treeDepth,
        bytes32[] memory leaves
    ) internal returns (bytes memory _proof, bytes32[] memory _publicInputs) {
        string[] memory inputs = new string[](leaves.length + 9);
        inputs[0] = "npx";
        inputs[1] = "tsx";
        inputs[2] = "js-scripts/generateProof.ts";
        inputs[3] = vm.toString(_nullifier);
        inputs[4] = vm.toString(_secret);
        inputs[5] = vm.toString(bytes32(uint256(uint160(_recipient))));
        inputs[6] = vm.toString(raffleId);
        inputs[7] = vm.toString(winnerIndex);
        inputs[8] = vm.toString(treeDepth);

        for (uint256 i = 0; i < leaves.length; i++) {
            inputs[9 + i] = vm.toString(leaves[i]);
        }
        // use ffi to run scripts in the CLI to create a commitment
        bytes memory result = vm.ffi(inputs);
        (_proof, _publicInputs) = abi.decode(result, (bytes, bytes32[]));
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
        vm.expectRevert();
        raffle.createRaffle{value: 0}(TICKET_PRICE, LEVELS, DURATION);
    }

    function test_RevertWhen_CreateRaffle_InvalidLevels() public {
        vm.prank(creator);
        vm.expectRevert();
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

        (
            bytes32 _commitment,
            bytes32 _nullifier,
            bytes32 _secret
        ) = _getCommitment();

        vm.prank(participant1);
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, _commitment);

        assertEq(raffle.getParticipantCount(raffleId), 1);
    }

    function test_RevertWhen_PurchaseTicket_WrongPrice() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        (
            bytes32 _commitment,
            bytes32 _nullifier,
            bytes32 _secret
        ) = _getCommitment();

        vm.prank(participant1);
        vm.expectRevert();
        raffle.purchaseTicket{value: TICKET_PRICE - 1}(raffleId, _commitment);
    }

    function test_RevertWhen_PurchaseTicket_RaffleEnded() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        vm.warp(block.timestamp + DURATION + 1);

        (
            bytes32 _commitment,
            bytes32 _nullifier,
            bytes32 _secret
        ) = _getCommitment();

        vm.prank(participant1);
        vm.expectRevert();
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, _commitment);
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

        (
            bytes32 _commitment,
            bytes32 _nullifier,
            bytes32 _secret
        ) = _getCommitment();

        vm.prank(participant1);
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, _commitment);

        vm.warp(block.timestamp + DURATION + 1);
        raffle.drawWinner(raffleId);

        PrivateRaffle.Raffle memory r = raffle.getRaffle(raffleId);
        assertEq(uint256(r.status), uint256(PrivateRaffle.RaffleStatus.Active));
        assertTrue(r.randomnessRequested);
        assertGt(r.requestId, 0);

        supraRouter.fulfill(address(raffle), r.requestId, 777);

        r = raffle.getRaffle(raffleId);
        assertEq(uint256(r.status), uint256(PrivateRaffle.RaffleStatus.Closed));
        assertEq(r.winnerIndex, 0);
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
            (
                bytes32 _commitment,
                bytes32 _nullifier,
                bytes32 _secret
            ) = _getCommitment();
            vm.prank(participant);
            raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, _commitment);
        }

        vm.warp(block.timestamp + DURATION + 1);
        raffle.drawWinner(raffleId);
        PrivateRaffle.Raffle memory r = raffle.getRaffle(raffleId);

        uint256 random = 9; // 9 % 5 = 4
        supraRouter.fulfill(address(raffle), r.requestId, random);

        r = raffle.getRaffle(raffleId);
        assertEq(uint256(r.status), uint256(PrivateRaffle.RaffleStatus.Closed));
        assertEq(r.winnerIndex, 4);
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

        (
            bytes32 _commitment,
            bytes32 _nullifier,
            bytes32 _secret
        ) = _getCommitment();

        vm.prank(participant1);
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, _commitment);

        vm.warp(block.timestamp + DURATION + 1);
        raffle.drawWinner(raffleId);

        PrivateRaffle.Raffle memory r = raffle.getRaffle(raffleId);

        supraRouter.fulfill(address(raffle), r.requestId, 0);

        r = raffle.getRaffle(raffleId);
        assertEq(uint256(r.status), uint256(PrivateRaffle.RaffleStatus.Closed));
        assertEq(r.winnerIndex, 0);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _commitment;

        (bytes memory proof, bytes32[] memory publicInputs) = _getProof(
            _nullifier,
            _secret,
            participant1,
            raffleId,
            r.winnerIndex,
            LEVELS,
            leaves
        );
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

        (
            bytes32 _commitment,
            bytes32 _nullifier,
            bytes32 _secret
        ) = _getCommitment();

        vm.prank(participant1);
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, _commitment);

        vm.warp(block.timestamp + DURATION + 1);
        raffle.drawWinner(raffleId);
        PrivateRaffle.Raffle memory r = raffle.getRaffle(raffleId);
        supraRouter.fulfill(address(raffle), r.requestId, 0);

        r = raffle.getRaffle(raffleId);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _commitment;

        (bytes memory proof, bytes32[] memory publicInputs) = _getProof(
            _nullifier,
            _secret,
            participant1,
            raffleId,
            r.winnerIndex,
            LEVELS,
            leaves
        );

        vm.prank(relayer);
        raffle.claimPrize(raffleId, proof, publicInputs, winner, 0);

        // Second claim should fail
        vm.prank(relayer);
        vm.expectRevert();
        raffle.claimPrize(raffleId, proof, publicInputs, winner, 0);
    }

    function test_RevertWhen_ClaimPrize_InvalidProof() public {
        vm.prank(creator);
        uint256 raffleId = raffle.createRaffle{value: PRIZE_AMOUNT}(
            TICKET_PRICE,
            LEVELS,
            DURATION
        );

        (
            bytes32 _commitment,
            bytes32 _nullifier,
            bytes32 _secret
        ) = _getCommitment();

        vm.prank(participant1);
        raffle.purchaseTicket{value: TICKET_PRICE}(raffleId, _commitment);

        vm.warp(block.timestamp + DURATION + 1);
        raffle.drawWinner(raffleId);
        PrivateRaffle.Raffle memory r = raffle.getRaffle(raffleId);
        supraRouter.fulfill(address(raffle), r.requestId, 0);

        r = raffle.getRaffle(raffleId);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _commitment;

        (bytes memory proof, bytes32[] memory publicInputs) = _getProof(
            _nullifier,
            _secret,
            participant1,
            raffleId,
            r.winnerIndex,
            LEVELS,
            leaves
        );

        vm.prank(relayer);
        vm.expectRevert();
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
}
