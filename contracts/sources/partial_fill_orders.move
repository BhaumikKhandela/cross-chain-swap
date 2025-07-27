module cross_chain_swap::partial_fill_orders{
    use sui::object::{Self, UID, ID};
    use sui::event;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use std::option::{Self, Option};
    use std::vector;
    use cross_chain_swap::merkle_secret::{Self, MerkleValidator};

    const EINVALID_PARTS_AMOUNT: u64 = 1;
    const EINVALID_PARTIAL_FILL: u64 = 2;
    const EORDER_COMPLETED: u64 = 3;
    const EINVALID_FILL_AMOUNT: u64 = 4;
    const ESECRET_INDEX_USED: u64 = 5;

    public struct PartialFillOrder has key, store {
        id: UID,
        order_hash: vector<u8>,
        total_making_amount: u64,
        remaining_making_amount: u64,
        parts_amount: u64,
        merkle_root_shortened: vector<u8>,
        multiple_fills_allowed: bool,
        // Track individual fills with enhanced data
        completed_fills: Table<u64, FillRecord>, // secret_index -> FillRecord
        total_fills_count: u64,
        // Track which secret indices have been used
        used_secret_indices: vector<u64>,
    }

    public struct FillRecord has copy, drop, store {
        fill_amount: u64,
        secret_index: u64,
        fill_sequence: u64,
        escrow_id: Option<ID>,
        timestamp: u64,
        accumulated_fill: u64, // Total filled up to this point
    }

    public struct OrderFillProgress has copy, drop, store {
        filled_amount: u64,
        remaining_amount: u64,
        current_fill_index: u64,
        next_expected_secret_index: u64,
    }

    // Events
    public struct PartialFillCompleted has copy, drop {
        order_hash: vector<u8>,
        fill_amount: u64,
        secret_index: u64,
        fill_sequence: u64,
        escrow_id: ID,
        remaining_amount: u64,
        accumulated_fill: u64,
    }

    public struct OrderFullyCompleted has copy, drop {
        order_hash: vector<u8>,
        total_amount: u64,
        total_fills: u64,
        final_escrow_id: ID,
    }

    public fun new_partial_fill_order(
        order_hash: vector<u8>,
        total_making_amount: u64,
        parts_amount: u64,
        merkle_root_shortened: vector<u8>,
        ctx: &mut TxContext
    ): PartialFillOrder {
        assert!(parts_amount >= 2, EINVALID_PARTS_AMOUNT);
        assert!(total_making_amount > 0, EINVALID_FILL_AMOUNT);
        
        PartialFillOrder {
            id: object::new(ctx),
            order_hash,
            total_making_amount,
            remaining_making_amount: total_making_amount,
            parts_amount,
            merkle_root_shortened,
            multiple_fills_allowed: true,
            completed_fills: table::new(ctx),
            total_fills_count: 0,
            used_secret_indices: vector::empty<u64>(),
        }
    }

}