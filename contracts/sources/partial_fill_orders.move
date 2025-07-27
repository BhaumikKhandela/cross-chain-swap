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


    public fun validate_partial_fill(
        order: &PartialFillOrder,
        making_amount: u64,
        secret_index: u64,
        validator: &MerkleValidator,
    ): bool {
        // Basic validations
        if (!order.multiple_fills_allowed) {
            return making_amount == order.total_making_amount
        };

        if (making_amount == 0 || making_amount > order.remaining_making_amount) {
            return false
        };

        // Check if secret index was already used
        if (vector::contains(&order.used_secret_indices, &secret_index)) {
            return false
        };

        // Check if secret was already revealed globally
        if (merkle_secret::is_secret_revealed(validator, order.order_hash, secret_index)) {
            return false
        };

        // Validate against 1inch partial fill logic
        is_valid_partial_fill_1inch_style(
            making_amount,
            order.remaining_making_amount,
            order.total_making_amount,
            order.parts_amount,
            secret_index
        )
    }

    fun is_valid_partial_fill_1inch_style(
        making_amount: u64,
        remaining_making_amount: u64,
        order_making_amount: u64,
        parts_amount: u64,
        secret_index: u64
    ): bool {
        // Calculate fill index based on current progress
        let filled_amount = order_making_amount - remaining_making_amount;
        let new_filled_amount = filled_amount + making_amount;
        
        // Calculate expected secret index for this fill level
        let calculated_index = if (new_filled_amount == order_making_amount) {
            // Complete fill - use parts_amount as final index
            parts_amount
        } else {
            // Partial fill - calculate based on percentage
            ((new_filled_amount * parts_amount) / order_making_amount)
        };

        // Validate against expected secret index
        if (remaining_making_amount == making_amount) {
            // Order filled to completion
            return secret_index == parts_amount || secret_index == calculated_index
        };

        // For partial fills, secret index should match calculated threshold
        secret_index == calculated_index || secret_index + 1 == calculated_index
    }


    public fun execute_partial_fill_with_escrow(
        order: &mut PartialFillOrder,
        making_amount: u64,
        secret_index: u64,
        escrow_id: ID,
        validator: &MerkleValidator,
        timestamp: u64,
    ) {
        assert!(
            validate_partial_fill(order, making_amount, secret_index, validator), 
            EINVALID_PARTIAL_FILL
        );
        assert!(making_amount <= order.remaining_making_amount, EINVALID_FILL_AMOUNT);
        assert!(!vector::contains(&order.used_secret_indices, &secret_index), ESECRET_INDEX_USED);

        // Update order state
        order.remaining_making_amount = order.remaining_making_amount - making_amount;
        let accumulated_fill = order.total_making_amount - order.remaining_making_amount;

        // Record the fill
        let fill_record = FillRecord {
            fill_amount: making_amount,
            secret_index,
            fill_sequence: order.total_fills_count,
            escrow_id: option::some(escrow_id),
            timestamp,
            accumulated_fill,
        };

        table::add(&mut order.completed_fills, secret_index, fill_record);
        vector::push_back(&mut order.used_secret_indices, secret_index);
        order.total_fills_count = order.total_fills_count + 1;

        // Emit appropriate event
        if (order.remaining_making_amount == 0) {
            event::emit(OrderFullyCompleted {
                order_hash: order.order_hash,
                total_amount: order.total_making_amount,
                total_fills: order.total_fills_count,
                final_escrow_id: escrow_id,
            });
        } else {
            event::emit(PartialFillCompleted {
                order_hash: order.order_hash,
                fill_amount: making_amount,
                secret_index,
                fill_sequence: order.total_fills_count - 1,
                escrow_id,
                remaining_amount: order.remaining_making_amount,
                accumulated_fill,
            });
        };
    }
}