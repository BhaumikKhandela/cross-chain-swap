import { keccak256 } from "js-sha3";

// Types for 1inch Fusion+ style merkle implementation
export interface MerkleLeaf {
  index: number;
  secretHash: string; // 32-byte hex string
}

export interface MerkleProof {
  leaf: MerkleLeaf;
  proof: string[]; // Array of 32-byte hex strings
}

export interface OrderSplit {
  orderHash: string;
  totalAmount: string;
  partsAmount: number;
  hashlockInfo: string; // 30-byte hex string (merkle root)
  secrets: MerkleLeaf[];
  merkleProofs: Map<number, MerkleProof>;
}

export interface PartialFillParams {
  makingAmount: string;
  secretIndex: number;
  secretHash: string;
  merkleProof: string[];
}

// Utility functions for 1inch Fusion+ compatibility
export class MerkleUtils {
  /**
   * Creates a 1inch Fusion+ compatible merkle tree from secrets
   * @param secrets Array of secret hashes with indices
   * @returns Merkle tree with root and proofs
   */
  static createMerkleTree(secrets: MerkleLeaf[]): {
    root: string;
    proofs: Map<number, MerkleProof>;
  } {
    if (secrets.length === 0) {
      throw new Error("At least one secret is required");
    }

    // Sort secrets by index
    const sortedSecrets = [...secrets].sort((a, b) => a.index - b.index);

    // Create leaves using 1inch encoding
    const leaves = sortedSecrets.map((secret) =>
      this.encodeLeaf1inchStyle(secret.index, secret.secretHash)
    );

    // Build merkle tree
    const tree = this.buildMerkleTree(leaves);

    // Generate proofs for each leaf
    const proofs = new Map<number, MerkleProof>();
    sortedSecrets.forEach((secret, leafIndex) => {
      const proof = this.generateProof(tree, leafIndex);
      proofs.set(secret.index, {
        leaf: secret,
        proof: proof.map((node) => this.bytesToHex(node)),
      });
    });

    // Extract first 30 bytes of root (1inch compatibility)
    const root = this.bytesToHex(tree[tree.length - 1][0]).slice(0, 60); // 30 bytes = 60 hex chars

    return { root, proofs };
  }

  /**
   * Encodes a leaf using 1inch's encoding style
   * @param index Secret index (uint256)
   * @param secretHash 32-byte secret hash
   * @returns Encoded leaf bytes
   */
  private static encodeLeaf1inchStyle(
    index: number,
    secretHash: string
  ): Uint8Array {
    // Encode index as 32 bytes (big-endian) to match Solidity uint256
    const indexBytes = this.encodeU64AsU256(BigInt(index));

    // Convert secret hash to bytes
    const hashBytes = this.hexToBytes(secretHash);

    // Combine: index (32 bytes) + secret hash (32 bytes)
    const encoded = new Uint8Array(64);
    encoded.set(indexBytes, 0);
    encoded.set(hashBytes, 32);

    return encoded;
  }

  /**
   * Encodes a u64 as u256 (32 bytes, big-endian)
   * @param value BigInt value
   * @returns 32-byte array
   */
  private static encodeU64AsU256(value: bigint): Uint8Array {
    const bytes = new Uint8Array(32);

    // Fill first 24 bytes with zeros
    for (let i = 0; i < 24; i++) {
      bytes[i] = 0;
    }

    // Encode the value in the last 8 bytes (big-endian)
    for (let i = 0; i < 8; i++) {
      bytes[31 - i] = Number(value & BigInt(0xff));
      value = value >> BigInt(8);
    }

    return bytes;
  }

  /**
   * Builds a merkle tree from leaves
   * @param leaves Array of leaf hashes
   * @returns Complete merkle tree
   */
  private static buildMerkleTree(leaves: Uint8Array[]): Uint8Array[][] {
    if (leaves.length === 0) {
      throw new Error("No leaves provided");
    }

    // Ensure we have an even number of leaves
    let currentLevel = [...leaves];
    if (currentLevel.length % 2 === 1) {
      currentLevel.push(currentLevel[currentLevel.length - 1]); // Duplicate last leaf
    }

    const tree: Uint8Array[][] = [currentLevel];

    // Build tree levels
    while (currentLevel.length > 1) {
      const nextLevel: Uint8Array[] = [];

      for (let i = 0; i < currentLevel.length; i += 2) {
        const left = currentLevel[i];
        const right = currentLevel[i + 1];

        // Combine hashes: keccak256(left + right)
        const combined = new Uint8Array(left.length + right.length);
        combined.set(left, 0);
        combined.set(right, left.length);

        const hash = this.keccak256(combined);
        nextLevel.push(hash);
      }

      // Ensure even number of nodes
      if (nextLevel.length % 2 === 1 && nextLevel.length > 1) {
        nextLevel.push(nextLevel[nextLevel.length - 1]);
      }

      tree.push(nextLevel);
      currentLevel = nextLevel;
    }

    return tree;
  }

  /**
   * Generates a merkle proof for a specific leaf
   * @param tree Complete merkle tree
   * @param leafIndex Index of the leaf
   * @returns Array of proof hashes
   */
  private static generateProof(
    tree: Uint8Array[][],
    leafIndex: number
  ): Uint8Array[] {
    const proof: Uint8Array[] = [];
    let currentIndex = leafIndex;

    // Traverse up the tree
    for (let level = 0; level < tree.length - 1; level++) {
      const currentLevel = tree[level];

      if (currentIndex % 2 === 0) {
        // Current node is left child, include right sibling
        if (currentIndex + 1 < currentLevel.length) {
          proof.push(currentLevel[currentIndex + 1]);
        }
      } else {
        // Current node is right child, include left sibling
        proof.push(currentLevel[currentIndex - 1]);
      }

      currentIndex = Math.floor(currentIndex / 2);
    }

    return proof;
  }

  /**
   * Splits an order into multiple parts with merkle secrets
   * @param orderHash Order hash
   * @param totalAmount Total order amount
   * @param partsAmount Number of parts to split into
   * @returns Order split with merkle tree
   */
  static splitOrder(
    orderHash: string,
    totalAmount: string,
    partsAmount: number
  ): OrderSplit {
    if (partsAmount < 2) {
      throw new Error("Order must be split into at least 2 parts");
    }

    // Generate random secrets for each part
    const secrets: MerkleLeaf[] = [];
    for (let i = 0; i < partsAmount; i++) {
      const secret = this.generateRandomSecret();
      secrets.push({
        index: i + 1, // 1-indexed to match 1inch
        secretHash: secret,
      });
    }

    // Create merkle tree
    const { root, proofs } = this.createMerkleTree(secrets);

    return {
      orderHash,
      totalAmount,
      partsAmount,
      hashlockInfo: root,
      secrets,
      merkleProofs: proofs,
    };
  }

  /**
   * Generates a random 32-byte secret hash
   * @returns 32-byte hex string
   */
  private static generateRandomSecret(): string {
    const bytes = new Uint8Array(32);
    for (let i = 0; i < 32; i++) {
      bytes[i] = Math.floor(Math.random() * 256);
    }
    return this.bytesToHex(bytes);
  }

  /**
   * Creates partial fill parameters for a specific part
   * @param orderSplit Order split data
   * @param partIndex Part index (0-based)
   * @param makingAmount Amount to fill
   * @returns Partial fill parameters
   */
  static createPartialFillParams(
    orderSplit: OrderSplit,
    partIndex: number,
    makingAmount: string
  ): PartialFillParams {
    if (partIndex >= orderSplit.partsAmount) {
      throw new Error("Part index out of range");
    }

    const secretIndex = partIndex + 1; // Convert to 1-indexed
    const proof = orderSplit.merkleProofs.get(secretIndex);

    if (!proof) {
      throw new Error(`No proof found for secret index ${secretIndex}`);
    }

    return {
      makingAmount,
      secretIndex,
      secretHash: proof.leaf.secretHash,
      merkleProof: proof.proof,
    };
  }

  /**
   * Validates a partial fill using 1inch logic
   * @param makingAmount Amount being filled
   * @param remainingAmount Remaining amount in order
   * @param totalAmount Total order amount
   * @param partsAmount Number of parts
   * @param secretIndex Secret index being used
   * @returns Whether the fill is valid
   */
  static validatePartialFill1inch(
    makingAmount: string,
    remainingAmount: string,
    totalAmount: string,
    partsAmount: number,
    secretIndex: number
  ): boolean {
    const making = BigInt(makingAmount);
    const remaining = BigInt(remainingAmount);
    const total = BigInt(totalAmount);
    const parts = BigInt(partsAmount);
    const index = BigInt(secretIndex);

    // Calculate the expected index based on 1inch logic
    const calculatedIndex =
      ((total - remaining + making - BigInt(1)) * parts) / total;

    if (remaining === making) {
      // If the order is filled to completion, a secret with index i + 1 must be used
      return calculatedIndex + BigInt(2) === index;
    } else if (total !== remaining) {
      // Calculate the previous fill index only if this is not the first fill
      const prevCalculatedIndex =
        ((total - remaining - BigInt(1)) * parts) / total;
      if (calculatedIndex === prevCalculatedIndex) {
        return false;
      }
    }

    return calculatedIndex + BigInt(1) === index;
  }

  /**
   * Converts hex string to bytes
   * @param hex Hex string
   * @returns Byte array
   */
  static hexToBytes(hex: string): Uint8Array {
    if (hex.startsWith("0x")) {
      hex = hex.slice(2);
    }

    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < hex.length; i += 2) {
      bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
    }
    return bytes;
  }

  /**
   * Converts bytes to hex string
   * @param bytes Byte array
   * @returns Hex string
   */
  private static bytesToHex(bytes: Uint8Array): string {
    return Array.from(bytes)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
  }

  /**
   * Computes keccak256 hash
   * @param data Input data
   * @returns Hash as byte array
   */
  private static keccak256(data: Uint8Array): Uint8Array {
    const hash = keccak256(data);
    return this.hexToBytes(hash);
  }

  /**
   * Creates a test order split for demonstration
   * @returns Sample order split
   */
  static createTestOrderSplit(): OrderSplit {
    const orderHash = "0x" + "1".repeat(64); // 32-byte order hash
    const totalAmount = "100"; // Very small amount for repeated testing
    const partsAmount = 3;

    return this.splitOrder(orderHash, totalAmount, partsAmount);
  }

  /**
   * Example usage and testing
   */
  static demonstrateMerkleUsage() {
    console.log("🔧 Creating test order split...");

    // Create a test order split
    const orderSplit = this.createTestOrderSplit();

    console.log("📋 Order Split Details:");
    console.log("Order Hash:", orderSplit.orderHash);
    console.log("Total Amount:", orderSplit.totalAmount);
    console.log("Parts Amount:", orderSplit.partsAmount);
    console.log("Hashlock Info (Merkle Root):", orderSplit.hashlockInfo);
    console.log(
      "Secrets:",
      orderSplit.secrets.map((s) => ({
        index: s.index,
        hash: s.secretHash.slice(0, 16) + "...",
      }))
    );

    // Create partial fill params for first part
    const partialFillParams = this.createPartialFillParams(
      orderSplit,
      0, // First part
      "333333333333333333" // 1/3 of total amount
    );

    console.log("\n🎯 Partial Fill Parameters:");
    console.log("Making Amount:", partialFillParams.makingAmount);
    console.log("Secret Index:", partialFillParams.secretIndex);
    console.log(
      "Secret Hash:",
      partialFillParams.secretHash.slice(0, 16) + "..."
    );
    console.log("Merkle Proof Length:", partialFillParams.merkleProof.length);

    // Validate the partial fill
    const isValid = this.validatePartialFill1inch(
      partialFillParams.makingAmount,
      orderSplit.totalAmount, // Initially, remaining = total
      orderSplit.totalAmount,
      orderSplit.partsAmount,
      partialFillParams.secretIndex
    );

    console.log("\n✅ Validation Result:", isValid);

    return { orderSplit, partialFillParams };
  }
}

// Export for use in other modules
export default MerkleUtils;
