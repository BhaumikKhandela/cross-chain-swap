module cross_chain_swap::partial_fill_orders{
   use sui::object::{Self, UID, ID};
    use sui::event;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use std::option::{Self, Option};
    use std::vector;
    use cross_chain_swap::merkle_secret::{Self, MerkleValidator};
    use sui::clock::Clock;
    use sui::clock;

    // Error constants
    const EINVALID_PARTS_AMOUNT: u64 = 1;
    const EINVALID_PARTIAL_FILL: u64 = 2;
    const EORDER_COMPLETED: u64 = 3;
    const EINVALID_FILL_AMOUNT: u64 = 4;
    const EINSUFFICIENT_BALANCE: u64 = 5;
    const ESECRET_ALREADY_USED: u64 = 6;
    const EINVALID_SECRET_INDEX: u64 = 7;
    const EORDER_NOT_FOUND: u64 = 8;


   public struct FillRecord has copy, drop, store {
        secret_index: u64,
        fill_amount: u64,
        timestamp: u64,
        resolver: address,
        cumulative_filled: u64, // Total filled up to this point
    }
    
    public struct PartialFillOrder<phantom T> has key, store {
        id: UID,
        order_hash: vector<u8>,
        total_making_amount: u64,
        filled_amount: u64,               // Cumulative filled amount
        remaining_balance: Balance<T>,    // Decreases with each fill
        parts_amount: u64,                // N parts the order is split into
        hashlock_info: vector<u8>,        // 30-byte merkle root (compatible with merkle_secret)
        // Fill tracking
        fill_records: Table<u64, FillRecord>, // secret_index -> FillRecord
        used_secret_indices: vector<u64>, // Track which secrets have been used
        total_fills: u64,
        created_at: u64,
        multiple_fills_allowed: bool,
    }


     // Events
    public struct PartialFillExecuted has copy, drop {
        order_hash: vector<u8>,
        secret_index: u64,
        fill_amount: u64,
        remaining_amount: u64,
        cumulative_filled: u64,
        resolver: address,
        timestamp: u64,
    }

     public struct OrderFullyCompleted has copy, drop {
        order_hash: vector<u8>,
        total_amount: u64,
        total_fills: u64,
        final_resolver: address,
    }


     public struct InvalidPartialFillAttempt has copy, drop {
        order_hash: vector<u8>,
        attempted_amount: u64,
        secret_index: u64,
        reason: vector<u8>,
    }


   public fun new_partial_fill_order<T>(
        order_hash: vector<u8>,
        total_making_amount: u64,
        parts_amount: u64,
        hashlock_info: vector<u8>,
        initial_balance: Balance<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ): PartialFillOrder<T> {
        assert!(parts_amount >= 2, EINVALID_PARTS_AMOUNT);
        assert!(total_making_amount > 0, EINVALID_FILL_AMOUNT);
        assert!(balance::value(&initial_balance) == total_making_amount, EINVALID_FILL_AMOUNT);
        assert!(vector::length(&hashlock_info) == 30, EINVALID_FILL_AMOUNT); // Must be 30 bytes
        
        PartialFillOrder {
            id: object::new(ctx),
            order_hash,
            total_making_amount,
            filled_amount: 0,
            remaining_balance: initial_balance,
            parts_amount,
            hashlock_info,
            fill_records: table::new(ctx),
            used_secret_indices: vector::empty<u64>(),
            total_fills: 0,
            created_at: clock::timestamp_ms(clock),
            multiple_fills_allowed: true,
        }
    }


    
}