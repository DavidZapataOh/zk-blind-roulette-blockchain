// js-scripts/merkleTree.ts
import { Barretenberg, Fr } from "@aztec/bb.js";
import { ethers } from "ethers";

// BN254 scalar field modulus (same one you use in Solidity)
const MODULUS =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

function modField(x: bigint): bigint {
  let r = x % MODULUS;
  if (r < 0n) r += MODULUS;
  return r;
}

/**
 * IMPORTANT:
 * Never do Fr.fromString(x.toString()) if x is a bigint interpreted as decimal.
 * Always convert bigint -> 32-byte hex -> Fr.fromString(hex).
 */
function frFromFieldBigInt(x: bigint): Fr {
  const hex32 = ethers.zeroPadValue(ethers.toBeHex(modField(x)), 32); // "0x" + 64 hex chars
  return Fr.fromString(hex32);
}

function bigIntFromFr(fr: Fr): bigint {
  // bb.js Fr.toString() is safe to parse as BigInt (decimal string)
  return BigInt(fr.toString());
}

// bytes32 hex -> bigint
export function bytes32HexToBigInt(x: string): bigint {
  // x comes like "0x..."
  return BigInt(x);
}

export type MerkleProof = {
  root: bigint;
  leaf: bigint;
  pathElements: bigint[]; // siblings as field bigints
  pathIndices: bigint[]; // 0/1 as bigints
};

export class PoseidonIMT {
  public readonly levels: number;
  public readonly zeros: bigint[]; // zeros[0..levels]
  private readonly bb: Barretenberg;
  private storage: Map<string, bigint>; // "level-index" -> node bigint
  private totalLeaves: number;

  constructor(bb: Barretenberg, levels: number, zero0?: bigint) {
    if (levels <= 0) throw new Error("levels must be > 0");
    this.bb = bb;
    this.levels = levels;
    this.storage = new Map();
    this.totalLeaves = 0;

    this.zeros = new Array(levels + 1);
    // if you want to force the same ZERO_VALUE as Solidity, pass it as zero0
    this.zeros[0] = zero0 !== undefined ? modField(zero0) : zeroValueRaffero();
  }

  private key(level: number, index: number): string {
    return `${level}-${index}`;
  }

  private async hash2(a: bigint, b: bigint): Promise<bigint> {
    const frA = frFromFieldBigInt(a);
    const frB = frFromFieldBigInt(b);
    const h = await this.bb.poseidon2Hash([frA, frB]);
    return modField(bigIntFromFr(h));
  }

  public async initEmpty(): Promise<void> {
    // build zeros chain: zeros[i] = H(zeros[i-1], zeros[i-1])
    for (let i = 1; i <= this.levels; i++) {
      this.zeros[i] = await this.hash2(this.zeros[i - 1], this.zeros[i - 1]);
    }
    // root is implicit if storage empty: zeros[levels]
  }

  public root(): bigint {
    return this.storage.get(this.key(this.levels, 0)) ?? this.zeros[this.levels];
  }

  public async insert(leaf: bigint): Promise<number> {
    const index = this.totalLeaves;
    await this.update(index, leaf, true);
    this.totalLeaves++;
    return index;
  }

  private async update(index: number, leaf: bigint, isInsert: boolean): Promise<void> {
    if (isInsert && index !== this.totalLeaves) {
      throw new Error("insert must be at next index (append-only)");
    }

    const leafField = modField(leaf);
    this.storage.set(this.key(0, index), leafField);

    let current = leafField;
    let currentIndex = index;

    for (let level = 0; level < this.levels; level++) {
      const isRight = currentIndex % 2; // 0 left, 1 right
      const siblingIndex = isRight === 0 ? currentIndex + 1 : currentIndex - 1;

      const sibling =
        this.storage.get(this.key(level, siblingIndex)) ?? this.zeros[level];

      const left = isRight === 0 ? current : sibling;
      const right = isRight === 0 ? sibling : current;

      const parent = await this.hash2(left, right);

      const parentIndex = Math.floor(currentIndex / 2);
      this.storage.set(this.key(level + 1, parentIndex), parent);

      current = parent;
      currentIndex = parentIndex;
    }
  }

  public proof(index: number): MerkleProof {
    const leaf = this.storage.get(this.key(0, index));
    if (leaf === undefined) throw new Error("leaf not found at index");

    const pathElements: bigint[] = [];
    const pathIndices: bigint[] = [];

    let currentIndex = index;
    for (let level = 0; level < this.levels; level++) {
      const isRight = currentIndex % 2; // 0/1
      const siblingIndex = isRight === 0 ? currentIndex + 1 : currentIndex - 1;

      const sibling =
        this.storage.get(this.key(level, siblingIndex)) ?? this.zeros[level];

      pathElements.push(sibling);
      pathIndices.push(BigInt(isRight));

      currentIndex = Math.floor(currentIndex / 2);
    }

    return {
      root: this.root(),
      leaf,
      pathElements,
      pathIndices,
    };
  }

  public getTotalLeaves(): number {
    return this.totalLeaves;
  }
}

function zeroValueRaffero(): bigint {
  const h = ethers.keccak256(ethers.toUtf8Bytes("raffero"));
  return modField(BigInt(h));
}
