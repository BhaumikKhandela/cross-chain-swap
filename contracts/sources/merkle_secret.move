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
    const EINVALID_SECRET_SEQUENCE: u64 = 4;
    const EESCROW_ALREADY_VALIDATED: u64 = 5;
    const EINVALID_PROGRESSIVE_SECRETS: u64 = 6;

    public struct ValidationData has copy, drop, store {
        index: u64,
        secret_hash: vector<u8>,
        escrow_id: Option<ID>,
    }

    public struct SecretWithProof has copy, drop, store {
        index: u64,
        secret_hash: vector<u8>,
        merkle_proof: vector<vector<u8>>,
    }

    public struct MerkleValidator has key {
        id: UID,
        // Per-order validation tracking (maintains backward compatibility)
        last_validated: Table<vector<u8>, ValidationData>,
        // Per-escrow validation tracking (new for escrow-per-fill)
        escrow_validations: Table<ID, ValidationData>,
        // Order to escrows mapping
        order_to_escrows: Table<vector<u8>, vector<ID>>,
        // Track revealed secrets to prevent reuse
        revealed_secrets: Table<vector<u8>, bool>, // keccak256(order_hash + secret_index) -> bool
    }

    // Events
    public struct SecretRevealed has copy, drop {
        order_hash: vector<u8>,
        index: u64,
        secret_hash: vector<u8>,
        escrow_id: Option<ID>,
    }

    public struct ProgressiveSecretsValidated has copy, drop {
        order_hash: vector<u8>,
        secret_indices: vector<u64>,
        escrow_id: ID,
    }

    
    public fun new_validator(ctx: &mut TxContext): MerkleValidator {
        MerkleValidator {
            id: object::new(ctx),
            last_validated: table::new(ctx),
            escrow_validations: table::new(ctx),
            order_to_escrows: table::new(ctx),
            revealed_secrets: table::new(ctx),
        }
    }

    

    

   
}