module cross_chain_swap::merkle_secret{
    use sui::object::{Self, UID, ID};
    use sui::hash::keccak256;
    use sui::event;
    use std::vector;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};

    const EINVALID_PROOF: u64 = 1;
    const EINVALID_SECRET_INDEX: u64 = 2;
    const ESECRET_ALREADY_REVEALED: u64 = 3;

    public struct ValidationData has copy, drop, store {
        index: u64,
        secret_hash: vector<u8>,
    }

    public struct MerkleValidator has key {
        id: UID,
        // Maps order_hash + merkle_root_shortened -> ValidationData
        last_validated: Table<vector<u8>, ValidationData>,
    }

    public struct SecretRevealed has copy, drop {
        order_hash: vector<u8>,
        index: u64,
        secret_hash: vector<u8>,
    }

    public fun new_validator(ctx: &mut TxContext): MerkleValidator {
        MerkleValidator {
            id: object::new(ctx),
            last_validated: table::new(ctx),
        }
    }

   
}