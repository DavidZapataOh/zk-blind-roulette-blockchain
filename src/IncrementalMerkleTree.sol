//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Poseidon2, Field} from "@poseidon/src/Poseidon2.sol";

contract IncrementalMerkleTree {
    Poseidon2 public immutable HASHER;

    uint32 public constant ROOT_HISTORY_SIZE = 30;
    uint32 public constant MAX_DEPTH = 32;

    error DepthCannotBeZero();
    error DepthTooLarge(uint32 depth);
    error MerkleTreeIsFull(uint256 nextLeafIndex);
    error LevelOutOfBounds(uint32 level);

    struct TreeState {
        uint32 depth;
        uint32 currentRootIndex;
        uint32 nextLeafIndex;
        mapping(uint32 => bytes32) cachedSubtrees; // level -> subtree
        mapping(uint32 => bytes32) roots; // ring index -> root
        bool initialized;
    }

    mapping(uint256 => TreeState) internal trees; // raffleId -> TreeState

    constructor(Poseidon2 _hasher) {
        HASHER = _hasher;
    }

    function _initTree(uint256 raffleId, uint32 depth) internal {
        if (depth == 0) revert DepthCannotBeZero();
        if (depth > MAX_DEPTH) revert DepthTooLarge(depth);

        TreeState storage t = trees[raffleId];
        t.depth = depth;
        t.currentRootIndex = 0;
        t.nextLeafIndex = 0;
        t.initialized = true;

        for (uint32 i = 0; i < depth; i++) {
            t.cachedSubtrees[i] = zeros(i);
        }

        t.roots[0] = zeros(depth);
    }

    function _isTreeInitialized(uint256 raffleId) internal view returns (bool) {
        return trees[raffleId].initialized;
    }

    function getLastRoot(uint256 raffleId) public view returns (bytes32) {
        TreeState storage t = trees[raffleId];
        return t.roots[t.currentRootIndex];
    }

    function getNextLeafIndex(uint256 raffleId) public view returns (uint32) {
        return trees[raffleId].nextLeafIndex;
    }

    function _insert(
        uint256 raffleId,
        bytes32 leaf
    ) internal returns (uint32 insertedIndex) {
        TreeState storage t = trees[raffleId];
        if (!t.initialized) revert DepthCannotBeZero();
        uint32 depth = t.depth;

        insertedIndex = t.nextLeafIndex;
        if (insertedIndex == uint32(2) ** depth) {
            revert MerkleTreeIsFull(insertedIndex);
        }
        // Si el index de la hoja es impar, se pondrá a la izquierda del hash, y el hash cero a la derecha
        // Almacena el resultado en el cached subtree
        // Si el index de la hoja es par, se pondrá a la derecha del hash, y el hash de cached subtree a la izquierda

        // Index de los lefs de izq a der
        uint32 currentIndex = insertedIndex;
        // Dato hasheado a insertar
        bytes32 currentHash = leaf;
        bytes32 left;
        bytes32 right;
        for (uint32 i = 0; i < depth; i++) {
            if (currentIndex % 2 == 0) {
                // Si el index es par
                left = currentHash; // El hash a insertar
                right = zeros(i); // El hash cero
                t.cachedSubtrees[i] = currentHash; // Almacena el hash en el cached subtree
            } else {
                // Si el index es impar
                left = t.cachedSubtrees[i]; // El hash del cached subtree
                right = currentHash; // El hash a insertar
            }
            currentHash = _hashLeftRight(left, right); // Hashea el hash izquierdo y el hash derecho para obtener el hash del nivel superior
            currentIndex /= 2; // Divide el index por 2 para obtener el index del nivel superior
        }
        uint32 newRootIndex = (t.currentRootIndex + 1) % ROOT_HISTORY_SIZE;
        t.currentRootIndex = newRootIndex; // Incrementa el index del root
        t.roots[newRootIndex] = currentHash; // Almacena el hash del nivel superior en el array de roots
        t.nextLeafIndex = insertedIndex + 1; // Incrementa el index de la hoja
    }

    function isKnownRoot(
        uint256 raffleId,
        bytes32 root
    ) public view returns (bool) {
        if (root == bytes32(0)) {
            return false;
        }
        TreeState storage t = trees[raffleId];
        if (!t.initialized) {
            return false;
        }
        uint32 rootIndex = t.currentRootIndex;
        uint32 i = rootIndex;
        do {
            if (t.roots[i] == root) {
                return true;
            }
            if (i == 0) {
                i = ROOT_HISTORY_SIZE;
            }
            i--;
        } while (i != rootIndex);
        return false;
    }

    function _hashLeftRight(
        bytes32 left,
        bytes32 right
    ) internal view returns (bytes32) {
        return
            Field.toBytes32(
                HASHER.hash_2(Field.toField(left), Field.toField(right))
            );
    }

    function zeros(uint32 i) public pure returns (bytes32) {
        // El hash cero será el hash del string "raffero" mod MaxField
        // bytes32(uint256(keccak256("raffero")) % 21888242871839275222246405745257275088548364400416034343698204186575808495617)
        // Para obtener los siguientes hashes, se debe hashear los hashes anteriores de par en par con Poseidon2
        if (i == 0)
            return
                bytes32(
                    0x1d028cb78671d570e29d04748982b4d86bf5d94d10b081fc71ab63f5f319a144
                );
        else if (i == 1)
            return
                bytes32(
                    0x2702209a4ea80e6bbf9f8fe36da29f1eba9794e7a5afc6d4987502b867b2782c
                );
        else if (i == 2)
            return
                bytes32(
                    0x0eed089401030c227ffe8ee49faa3e98d1090a4c38b1ad94cb8487ae6bdf47d7
                );
        else if (i == 3)
            return
                bytes32(
                    0x098fd15689f7dc1d33fcc9a135e90410b077240261134c7a56e2a3f7a71b98d8
                );
        else if (i == 4)
            return
                bytes32(
                    0x1cde1166a86cf6ef94fe2992f5c67063f595939f87a93dffa2e2f0c505dfc791
                );
        else if (i == 5)
            return
                bytes32(
                    0x205b0bff5586bfca62d3206f9731040cc0935a9b65c6ec7899ec2bc8da67ce12
                );
        else if (i == 6)
            return
                bytes32(
                    0x2693cc868fbed3c2bdbc0af93fb61c1defda77da8ffab201af750b8e748ad4a0
                );
        else if (i == 7)
            return
                bytes32(
                    0x2217e8304afcd5622719d233ab0de5fcae7bedd4b19cd40562beb18400338d9b
                );
        else if (i == 8)
            return
                bytes32(
                    0x28f8e6b1e3f075f3fdc6cb2cb2b2e9bbe5333477147b8ffabbd1d3bd5cd6f0c0
                );
        else if (i == 9)
            return
                bytes32(
                    0x2b571502975f1b52653e2a90e75f835e7133211e903ee30c18eae39e5a54a003
                );
        else if (i == 10)
            return
                bytes32(
                    0x01004fe703167ea084b15031ef1797eff6717655820e97b15c3f5f160adc58b3
                );
        else if (i == 11)
            return
                bytes32(
                    0x2405d6072abfd248a61d72511906e089ea958d7685221b3f891f6442978588c7
                );
        else if (i == 12)
            return
                bytes32(
                    0x159f221789c95106cdba76de370bd8d2acc3c45897b2aad72f6d8f1953b02cbb
                );
        else if (i == 13)
            return
                bytes32(
                    0x1d8b8943e98b3841b5d57a6407ebf93721d1a17de8fe9efa7cdaddea564531bb
                );
        else if (i == 14)
            return
                bytes32(
                    0x213c67f6dcdd9f86c76a7452bafd916440013eedb3f71aa2fc3d4619e9990aeb
                );
        else if (i == 15)
            return
                bytes32(
                    0x2fa3fae6226c32750351b998c397e37c7fb8f14d68cca124672d49b524744847
                );
        else if (i == 16)
            return
                bytes32(
                    0x05ed3f2487e0cfe51e10e558ce98eefbaebf0eabe0ea6cdfaeba432d8c9a0ffc
                );
        else if (i == 17)
            return
                bytes32(
                    0x2d6226cc2cd15cbec071be3b2574e6e5d5570f72ddd4acf7b9399384cb140ee0
                );
        else if (i == 18)
            return
                bytes32(
                    0x18e425282700d965c80c2386a4682da6d33628307641dc7d1d2901daa31fcc0d
                );
        else if (i == 19)
            return
                bytes32(
                    0x28239d63a8ee098ce6d497c7eb15d11ca423185d3b1a5be97392394d3d691ff7
                );
        else if (i == 20)
            return
                bytes32(
                    0x1196568a4bed8c2f8eee0dbf9a62034940f8e567630b14ac917aa5fa0747ac7a
                );
        else if (i == 21)
            return
                bytes32(
                    0x251610436985b62321e7d0be2e7536359665518ba198fec7073c0ca198097852
                );
        else if (i == 22)
            return
                bytes32(
                    0x24f0ad62d50feed3e2c59b59bb6c06863e4e578b0f7cd0eb68b6e085b1fa736d
                );
        else if (i == 23)
            return
                bytes32(
                    0x020cd2dc08d478c3e154d4358f984c1823117a14895b545b0d6a2fb72f638f7f
                );
        else if (i == 24)
            return
                bytes32(
                    0x125ee57756f6b850994a7117d95332c885b600dc1b3a6d8fc6b69221fcd5ebf9
                );
        else if (i == 25)
            return
                bytes32(
                    0x29f9cb3e9f17085d7d43d5645429e4083d3ad7dec3192a970cc8ef9cf1d388aa
                );
        else if (i == 26)
            return
                bytes32(
                    0x21518a1b2046d7ee337397aafcfbd922e01d118b2f48b8da5d8d29da7791ec19
                );
        else if (i == 27)
            return
                bytes32(
                    0x26769f5b643b8c03c05179c60c410d8f13a07a481a4295edafae5fe8e1807ff6
                );
        else if (i == 28)
            return
                bytes32(
                    0x1118b9bbc49f482de8e3e792471f2816e964ac619606aaa556aade0e27986b80
                );
        else if (i == 29)
            return
                bytes32(
                    0x208479db3047fb2d7d1891b07b27e6030671387a59fc1b6326bc62cf9c58941e
                );
        else if (i == 30)
            return
                bytes32(
                    0x1dc9cf833a0e2e3fe2e63a5356060d43497e4830a310413457c8daf9e56dbf75
                );
        else if (i == 31)
            return
                bytes32(
                    0x22516451d073ee15525e5ca2796d69d13e76f627bce77c5244a5737c83c536f9
                );
        else if (i == 32)
            return
                bytes32(
                    0x00a812174e08b158a441f6e823d92ee3a1c3fe2eccc0a15283e7f841a39da33b
                );
        else revert LevelOutOfBounds(i);
    }
}
