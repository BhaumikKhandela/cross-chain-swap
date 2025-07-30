import { TransactionBlock } from "@mysten/sui.js/transactions";
import { getFullnodeUrl, SuiClient } from "@mysten/sui.js/client";
import { Ed25519Keypair } from "@mysten/sui.js/keypairs/ed25519";
import { CONFIG } from "./config";
import { MerkleUtils, OrderSplit, PartialFillParams } from "./merkle-utils";
import { fromB64 } from "@mysten/bcs";

interface SourceEscrowParams {
  initialTokens: string; // Object ID of Coin<T>
  safetyDeposit: string; // Object ID of Coin<SUI>
  immutables: {
    orderHash: number[];
    hashLock: number[];
    makerAddress: string;
    takerAddress: number[];
    tokenAddress: number[];
    amount: string;
    safetyDepositAmount: string;
    timelocks: {
      srcWithdrawal: string;
      srcPublicWithdrawal: string;
      srcCancellation: string;
      srcPublicCancellation: string;
      dstWithdrawal: string;
      dstPublicWithdrawal: string;
      dstCancellation: string;
      dstPublicCancellation: string;
    };
  };
}

export async function executePartialFillAndCreateSrcEscrow(
  client: SuiClient,
  signer: Ed25519Keypair,
  partialOrderId: string,
  partialFillParams: PartialFillParams,
  escrowParams: SourceEscrowParams
) {
  const tx = new TransactionBlock();

  const timelocks = tx.moveCall({
    target: `${CONFIG.PACKAGE_ID}::time_lock::create_timelock`,
    arguments: [
      tx.pure.u64(escrowParams.immutables.timelocks.srcWithdrawal),
      tx.pure.u64(escrowParams.immutables.timelocks.srcPublicWithdrawal),
      tx.pure.u64(escrowParams.immutables.timelocks.srcCancellation),
      tx.pure.u64(escrowParams.immutables.timelocks.srcPublicCancellation),
      tx.pure.u64(escrowParams.immutables.timelocks.dstWithdrawal),
      tx.pure.u64(escrowParams.immutables.timelocks.dstPublicWithdrawal),
      tx.pure.u64(escrowParams.immutables.timelocks.dstCancellation),
      tx.pure.u64(escrowParams.immutables.timelocks.dstPublicCancellation),
    ],
  });

  const makerAddress = tx.moveCall({
    target: `${CONFIG.PACKAGE_ID}::address_lib::from_sui`,
    arguments: [tx.pure(escrowParams.immutables.makerAddress, "address")],
  });

  const takerAddress = tx.moveCall({
    target: `${CONFIG.PACKAGE_ID}::address_lib::from_ethereum`,
    arguments: [
      tx.pure(
        new Uint8Array(escrowParams.immutables.takerAddress),
        "vector<u8>"
      ),
    ],
  });

  const tokenAddress = tx.moveCall({
    target: `${CONFIG.PACKAGE_ID}::address_lib::from_token`,
    arguments: [
      tx.pure(
        new Uint8Array(escrowParams.immutables.tokenAddress),
        "vector<u8>"
      ),
    ],
  });

  const immutables = tx.moveCall({
    target: `${CONFIG.PACKAGE_ID}::immutables::new`,
    arguments: [
      tx.pure(escrowParams.immutables.orderHash, "vector<u8>"),
      tx.pure(escrowParams.immutables.hashLock, "vector<u8>"),
      makerAddress,
      takerAddress,
      tokenAddress,
      tx.pure.u64(escrowParams.immutables.amount),
      tx.pure.u64(escrowParams.immutables.safetyDepositAmount),
      timelocks,
    ],
  });

  const filledTokens = tx.moveCall({
    target: `${CONFIG.PACKAGE_ID}::partial_fill_orders::execute_partial_fill`,
    arguments: [
      tx.object(partialOrderId), // Mutable reference to PartialFillOrder
      tx.pure.u64(partialFillParams.makingAmount),
      tx.pure.u64(partialFillParams.secretIndex),
      tx.pure(
        Array.from(MerkleUtils.hexToBytes(partialFillParams.secretHash)),
        "vector<u8>"
      ),
      tx.pure(
        partialFillParams.merkleProof.map((proof) =>
          tx.pure(Array.from(MerkleUtils.hexToBytes(proof)), "vector<u8>")
        ),
        "vector<vector<u8>>"
      ),
      tx.object(CONFIG.MERKLE_VALIDATOR_ID), // Mutable reference to MerkleValidator
      tx.object(CONFIG.CLOCK_OBJECT_ID), // Reference to Clock
    ],
  });

  const [srcEscrow, srcCap] = tx.moveCall({
    target: `${CONFIG.PACKAGE_ID}::factory::create_src_escrow`,
    arguments: [
      tx.object(CONFIG.FACTORY_OBJECT_ID), // Mutable reference to EscrowFactory
      immutables,
      tx.object(filledTokens), // Coin<SUI> for escrow
      tx.object(escrowParams.safetyDeposit), // Coin<SUI> for safety deposit
      tx.object(CONFIG.CLOCK_OBJECT_ID), // Reference to Clock
    ],
  });

  tx.transferObjects([srcEscrow, srcCap], makerAddress);

  try {
    const result = await client.signAndExecuteTransactionBlock({
      signer,
      transactionBlock: tx,
      options: {
        showEvents: true,
        showEffects: true,
        showObjectChanges: true,
      },
    });

    return {
      success: true,
      digest: result.digest,
      events: result.events,
      objectChanges: result.objectChanges,
      srcEscrowId: extractCreatedObjectId(result.objectChanges!, "EscrowSrc"),
      filledTokensId: extractCreatedObjectId(result.objectChanges!, "Coin"),
    };
  } catch (error) {
    console.error("PTB execution failed:", error);
    return {
      success: false,
      error: error,
    };
  }
}

function extractCreatedObjectId(
  objectChanges: any[],
  objectType: string
): string | null {
  const createdObject = objectChanges?.find(
    (change) =>
      change.type === "created" && change.objectType.includes(objectType)
  );
  return createdObject?.objectId || null;
}

// Helper to create PartialFillOrder on-chain and return its object ID
export async function createPartialFillOrder(
  client: SuiClient,
  signer: Ed25519Keypair,
  orderSplit: OrderSplit,
  coinObjectId: string // Coin<T> object ID for initial balance
) {
  const tx = new TransactionBlock();

  // Convert Coin<T> to Balance<T>
  const balance = tx.moveCall({
    target: "0x2::coin::into_balance",
    typeArguments: ["0x2::sui::SUI"], // or your token type
    arguments: [tx.object(coinObjectId)],
  });

  // Create the PartialFillOrder and capture the return value
  const partialOrder = tx.moveCall({
    target: `${CONFIG.PACKAGE_ID}::partial_fill_orders::new_partial_fill_order`,
    typeArguments: ["0x2::sui::SUI"], // or your token type
    arguments: [
      tx.pure(
        Array.from(MerkleUtils.hexToBytes(orderSplit.orderHash)),
        "vector<u8>"
      ),
      tx.pure.u64(orderSplit.totalAmount),
      tx.pure.u64(orderSplit.partsAmount),
      tx.pure(
        Array.from(MerkleUtils.hexToBytes(orderSplit.hashlockInfo)),
        "vector<u8>"
      ),
      balance, // Use the Balance<T> object here
      tx.object(CONFIG.CLOCK_OBJECT_ID),
    ],
  });

  // Transfer the created PartialFillOrder to the sender
  tx.transferObjects(
    [partialOrder],
    tx.pure(signer.getPublicKey().toSuiAddress(), "address")
  );

  const result = await client.signAndExecuteTransactionBlock({
    signer,
    transactionBlock: tx,
    options: { showObjectChanges: true },
  });

  const partialOrderId = (
    result.objectChanges?.find(
      (change) =>
        change.type === "created" &&
        "objectType" in change &&
        change.objectType.includes("PartialFillOrder")
    ) as any
  )?.objectId;

  if (!partialOrderId) throw new Error("PartialFillOrder was not created");
  return partialOrderId;
}

// New function to create order split and execute partial fill
export async function createOrderSplitAndExecute(
  client: SuiClient,
  signer: Ed25519Keypair,
  orderHash: string,
  totalAmount: string,
  partsAmount: number,
  escrowParams: SourceEscrowParams,
  coinObjectId: string // Pass the Coin<T> object ID for initial balance
) {
  console.log("🔧 Creating order split with merkle tree...");

  // Step 1: Create order split with merkle tree
  const orderSplit = MerkleUtils.splitOrder(
    orderHash,
    totalAmount,
    partsAmount
  );

  console.log("✅ Order split created:");
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

  // Step 2: Create partial fill order on-chain
  const partialOrderId = await createPartialFillOrder(
    client,
    signer,
    orderSplit,
    coinObjectId
  );

  // Step 3: Execute partial fill for first part
  const partIndex = 0; // First part
  const makingAmount = (BigInt(totalAmount) / BigInt(partsAmount)).toString();

  const partialFillParams = MerkleUtils.createPartialFillParams(
    orderSplit,
    partIndex,
    makingAmount
  );

  console.log("🎯 Partial fill parameters created:");
  console.log("Making Amount:", partialFillParams.makingAmount);
  console.log("Secret Index:", partialFillParams.secretIndex);
  console.log(
    "Secret Hash:",
    partialFillParams.secretHash.slice(0, 16) + "..."
  );
  console.log("Merkle Proof Length:", partialFillParams.merkleProof.length);

  // Step 4: Execute the partial fill and create source escrow
  const result = await executePartialFillAndCreateSrcEscrow(
    client,
    signer,
    partialOrderId,
    partialFillParams,
    escrowParams
  );

  return {
    orderSplit,
    partialFillParams,
    result,
  };
}

// Test function
export async function testCompleteFlow() {
  const PRIVATE_KEY_B64 = process.env.SUI_PRIVATE_KEY!;
  const raw = fromB64(PRIVATE_KEY_B64);
  const keypair = Ed25519Keypair.fromSecretKey(raw.slice(1)); // skip the first byte
  const client = new SuiClient({ url: getFullnodeUrl("testnet") });

  console.log("🚀 Testing complete cross-chain swap flow...");

  // Create test order split
  const orderSplit = MerkleUtils.createTestOrderSplit();

  // Create escrow parameters
  const escrowParams: SourceEscrowParams = {
    initialTokens: "YOUR_COIN_OBJECT_ID",
    safetyDeposit: "YOUR_SAFETY_DEPOSIT_COIN_ID",
    immutables: {
      orderHash: Array.from(MerkleUtils.hexToBytes(orderSplit.orderHash)),
      hashLock: Array.from(MerkleUtils.hexToBytes(orderSplit.hashlockInfo)),
      makerAddress: keypair.getPublicKey().toSuiAddress(),
      takerAddress: Array.from({ length: 20 }, (_, i) => i + 1),
      tokenAddress: Array.from({ length: 20 }, (_, i) => i + 5),
      amount: orderSplit.totalAmount,
      safetyDepositAmount: "100000000000000000", // 0.1 ETH
      timelocks: {
        srcWithdrawal: "3600",
        srcPublicWithdrawal: "7200",
        srcCancellation: "1800",
        srcPublicCancellation: "3600",
        dstWithdrawal: "3600",
        dstPublicWithdrawal: "7200",
        dstCancellation: "1800",
        dstPublicCancellation: "3600",
      },
    },
  };

  // Execute the complete flow
  const result = await createOrderSplitAndExecute(
    client,
    keypair,
    orderSplit.orderHash,
    orderSplit.totalAmount,
    orderSplit.partsAmount,
    escrowParams,
    escrowParams.initialTokens // Pass the initialTokens as coinObjectId
  );

  console.log("✅ Complete flow executed successfully!");
  return result;
}

async function testMerkleImplementation() {
  console.log("🚀 Testing 1inch Fusion+ Style Merkle Implementation...\n");

  try {
    // Test the merkle utilities
    const result = MerkleUtils.demonstrateMerkleUsage();

    console.log("\n✅ All tests passed!");
    console.log(
      "�� Your off-chain merkle implementation is working correctly."
    );
    console.log("📋 You can now use this with your on-chain contracts.");

    return result;
  } catch (error) {
    console.error("❌ Test failed:", error);
    throw error;
  }
}

// Main function to run the full on-chain test
async function main() {
  const PRIVATE_KEY_B64 = process.env.SUI_PRIVATE_KEY!;
  const raw = fromB64(PRIVATE_KEY_B64);
  const keypair = Ed25519Keypair.fromSecretKey(raw.slice(1)); // skip the first byte
  const client = new SuiClient({ url: getFullnodeUrl("testnet") });

  // Use the selected Coin object for initialTokens
  const coinObjectId =
    "0x795ab49ec73445e8eeb484ff402d5e82e6e9861f415599f6ae7a42ff93bf38be";

  // Create test order split
  const orderSplit = MerkleUtils.createTestOrderSplit();

  // Create escrow parameters
  const escrowParams: SourceEscrowParams = {
    initialTokens: coinObjectId,
    safetyDeposit: coinObjectId, // For test, use same coin for safety deposit
    immutables: {
      orderHash: Array.from(MerkleUtils.hexToBytes(orderSplit.orderHash)),
      hashLock: Array.from(MerkleUtils.hexToBytes(orderSplit.hashlockInfo)),
      makerAddress: keypair.getPublicKey().toSuiAddress(),
      takerAddress: Array.from({ length: 20 }, (_, i) => i + 1),
      tokenAddress: Array.from({ length: 20 }, (_, i) => i + 5),
      amount: orderSplit.totalAmount,
      safetyDepositAmount: "100000000000000000", // 0.1 ETH
      timelocks: {
        srcWithdrawal: "3600",
        srcPublicWithdrawal: "7200",
        srcCancellation: "1800",
        srcPublicCancellation: "3600",
        dstWithdrawal: "3600",
        dstPublicWithdrawal: "7200",
        dstCancellation: "1800",
        dstPublicCancellation: "3600",
      },
    },
  };

  try {
    const result = await createOrderSplitAndExecute(
      client,
      keypair,
      orderSplit.orderHash,
      orderSplit.totalAmount,
      orderSplit.partsAmount,
      escrowParams,
      coinObjectId
    );
    console.log("\n✅ Full on-chain test completed! Result:", result);
  } catch (error) {
    console.error("\n❌ Full on-chain test failed:", error);
  }
}

// Run the main function if this script is executed directly
if (require.main === module) {
  main();
}
