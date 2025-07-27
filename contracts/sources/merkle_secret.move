module cross_chain_swap::merkle_secret{
   
    use sui::object::{Self, UID, ID};
    use sui::hash::keccak256;
    use sui::event;
    use std::vector;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use std::option::{Self, Option};

    const EINVALID_PROOF: u64 = 1;
    const EINVALID_SECRET_INDEX: u64 = 2;
    const ESECRET_ALREADY_REVEALED: u64 = 3;
    const EINVALID_SECRETS_AMOUNT: u64 = 4;

    public struct ValidationData has copy, drop, store {
        leaf: vector<u8>,      // The secret hash (leaf in merkle tree)
        index: u64,            // Secret index used
    }

    public struct MerkleValidator has key, store {
        id: UID,
        // Maps keccak256(orderHash, uint240(hashlockInfo)) -> ValidationData
        last_validated: Table<vector<u8>, ValidationData>,
        // Track revealed secrets to prevent reuse
        revealed_secrets: Table<vector<u8>, bool>, // keccak256(order_hash + secret_index) -> bool
    }

    public struct SecretRevealed has copy, drop {
        order_hash: vector<u8>,
        secret_index: u64,
        secret_hash: vector<u8>,
    }

    public fun new_validator(ctx: &mut TxContext): MerkleValidator {
        MerkleValidator {
            id: object::new(ctx),
            last_validated: table::new(ctx),
            revealed_secrets: table::new(ctx),
        }
    }

   
}