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

     public fun execute_partial_fill<T>(
        order: &mut PartialFillOrder<T>,
        making_amount: u64,
        secret_index: u64,
        secret_hash: vector<u8>,
        merkle_proof: vector<vector<u8>>,
        validator: &mut MerkleValidator,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<T> {
        let timestamp = clock::timestamp_ms(clock);
        let resolver = tx_context::sender(ctx);
        
        // Basic validations
        assert!(order.multiple_fills_allowed, EORDER_COMPLETED);
        assert!(making_amount > 0, EINVALID_FILL_AMOUNT);
        assert!(!vector::contains(&order.used_secret_indices, &secret_index), ESECRET_ALREADY_USED);
        
        let remaining_making_amount = balance::value(&order.remaining_balance);
        assert!(making_amount <= remaining_making_amount, EINSUFFICIENT_BALANCE);

        // Validate merkle proof using our updated merkle_secret module
        let proof_valid = merkle_secret::validate_merkle_proof(
            validator,
            order.order_hash,
            order.hashlock_info,
            secret_index,
            secret_hash,
            merkle_proof,
        );
        assert!(proof_valid, EINVALID_PARTIAL_FILL);

        // Get validation data for 1inch partial fill logic
        let mut validation_data_opt = merkle_secret::get_validation_data(
            validator,
            order.order_hash,
            order.hashlock_info
        );
        
        assert!(option::is_some(&validation_data_opt), EINVALID_PARTIAL_FILL);
        let validation_data = option::extract(&mut validation_data_opt);

        let validated_index = merkle_secret::get_validation_data_index(&validation_data);
        // Apply exact 1inch partial fill validation logic
        let is_valid = is_valid_partial_fill_1inch(
            making_amount,
            remaining_making_amount,
            order.total_making_amount,
            order.parts_amount,
            validated_index
        );

        if (!is_valid) {
            event::emit(InvalidPartialFillAttempt {
                order_hash: order.order_hash,
                attempted_amount: making_amount,
                secret_index,
                reason: b"Invalid partial fill calculation",
            });
            abort EINVALID_PARTIAL_FILL
        };

        // Execute the fill
        let fill_balance = balance::split(&mut order.remaining_balance, making_amount);
        order.filled_amount = order.filled_amount + making_amount;

        // Record the fill
        let fill_record = FillRecord {
            secret_index,
            fill_amount: making_amount,
            timestamp,
            resolver,
            cumulative_filled: order.filled_amount,
        };
        
        table::add(&mut order.fill_records, secret_index, fill_record);
        vector::push_back(&mut order.used_secret_indices, secret_index);
        order.total_fills = order.total_fills + 1;

        // Check if order is completed
        let new_remaining = balance::value(&order.remaining_balance);
        if (new_remaining == 0) {
            order.multiple_fills_allowed = false;
            event::emit(OrderFullyCompleted {
                order_hash: order.order_hash,
                total_amount: order.total_making_amount,
                total_fills: order.total_fills,
                final_resolver: resolver,
            });
        } else {
            event::emit(PartialFillExecuted {
                order_hash: order.order_hash,
                secret_index,
                fill_amount: making_amount,
                remaining_amount: new_remaining,
                cumulative_filled: order.filled_amount,
                resolver,
                timestamp,
            });
        };

        coin::from_balance(fill_balance, ctx)
    }

    fun is_valid_partial_fill_1inch(
        making_amount: u64,
        remaining_making_amount: u64,
        order_making_amount: u64,
        parts_amount: u64,
        validated_index: u64
    ): bool {
        // Calculate the index based on the new cumulative fill amount
        let calculated_index = ((order_making_amount - remaining_making_amount + making_amount - 1) * parts_amount) / order_making_amount;

        if (remaining_making_amount == making_amount) {
            // If the order is filled to completion, a secret with index i + 1 must be used
            // where i is the index of the secret for the last part.
            return (calculated_index + 2 == validated_index)
        } else if (order_making_amount != remaining_making_amount) {
            // Calculate the previous fill index only if this is not the first fill.
            let prev_calculated_index = ((order_making_amount - remaining_making_amount - 1) * parts_amount) / order_making_amount;
            if (calculated_index == prev_calculated_index) {
                return false
            };
        };

        calculated_index + 1 == validated_index
    }

    public fun validate_partial_fill<T>(
        order: &PartialFillOrder<T>,
        making_amount: u64,
        secret_index: u64,
        validator: &MerkleValidator,
    ): bool {
        // Basic checks
        if (!order.multiple_fills_allowed) return false;
        if (making_amount == 0) return false;
        if (vector::contains(&order.used_secret_indices, &secret_index)) return false;
        if (merkle_secret::is_secret_revealed(validator, order.order_hash, secret_index)) return false;
        
        let remaining_making_amount = balance::value(&order.remaining_balance);
        if (making_amount > remaining_making_amount) return false;

        // Check if we would have validation data (secret must be revealed first)
        let mut validation_data_opt = merkle_secret::get_validation_data(
            validator,
            order.order_hash,
            order.hashlock_info
        );
        
        if (option::is_none(&validation_data_opt)) return false;
        let validation_data = option::extract(&mut validation_data_opt);
         let validated_index = merkle_secret::get_validation_data_index(&validation_data);

        // Apply 1inch validation logic
        is_valid_partial_fill_1inch(
            making_amount,
            remaining_making_amount,
            order.total_making_amount,
            order.parts_amount,
            validated_index
        )
    }
 

    public fun calculate_expected_secret_index<T>(
        order: &PartialFillOrder<T>,
        making_amount: u64,
    ): u64 {
        let remaining_making_amount = balance::value(&order.remaining_balance);
        let calculated_index = ((order.total_making_amount - remaining_making_amount + making_amount - 1) * order.parts_amount) / order.total_making_amount;
        
        if (remaining_making_amount == making_amount) {
            // Completion case
            calculated_index + 2
        } else {
            calculated_index + 1
        }
    }
    
    public fun get_fill_progress<T>(order: &PartialFillOrder<T>): (u64, u64, u64, u64) {
        (
            order.filled_amount,                           // Amount filled so far
            balance::value(&order.remaining_balance),      // Amount remaining
            (order.filled_amount * 100) / order.total_making_amount, // Percentage filled
            order.total_fills                              // Number of fills
        )
    }

    public fun get_order_hash<T>(order: &PartialFillOrder<T>): &vector<u8> {
        &order.order_hash
    }

    public fun get_total_making_amount<T>(order: &PartialFillOrder<T>): u64 {
        order.total_making_amount
    }

    public fun get_filled_amount<T>(order: &PartialFillOrder<T>): u64 {
        order.filled_amount
    }

    public fun get_remaining_amount<T>(order: &PartialFillOrder<T>): u64 {
        balance::value(&order.remaining_balance)
    }

    public fun get_parts_amount<T>(order: &PartialFillOrder<T>): u64 {
        order.parts_amount
    }

    public fun get_hashlock_info<T>(order: &PartialFillOrder<T>): &vector<u8> {
        &order.hashlock_info
    }

    public fun is_completed<T>(order: &PartialFillOrder<T>): bool {
        !order.multiple_fills_allowed || balance::value(&order.remaining_balance) == 0
    }

    public fun allows_multiple_fills<T>(order: &PartialFillOrder<T>): bool {
        order.multiple_fills_allowed
    }

    public fun get_fill_record<T>(order: &PartialFillOrder<T>, secret_index: u64): Option<FillRecord> {
        if (table::contains(&order.fill_records, secret_index)) {
            option::some(*table::borrow(&order.fill_records, secret_index))
        } else {
            option::none()
        }
    }

    public fun get_total_fills<T>(order: &PartialFillOrder<T>): u64 {
        order.total_fills
    }

    public fun get_used_secret_indices<T>(order: &PartialFillOrder<T>): &vector<u64> {
        &order.used_secret_indices
    }

    public fun is_secret_used<T>(order: &PartialFillOrder<T>, secret_index: u64): bool {
        vector::contains(&order.used_secret_indices, &secret_index)
    }

    public fun get_fill_percentage<T>(order: &PartialFillOrder<T>): u64 {
        if (order.total_making_amount == 0) {
            return 0
        };
        (order.filled_amount * 100) / order.total_making_amount
    }

    public fun get_created_at<T>(order: &PartialFillOrder<T>): u64 {
        order.created_at
    }

    public fun get_all_fills<T>(order: &PartialFillOrder<T>): vector<FillRecord> {
        let mut fills = vector::empty<FillRecord>();
        let mut i = 0;
        let indices_len = vector::length(&order.used_secret_indices);
        
        while (i < indices_len) {
            let secret_index = *vector::borrow(&order.used_secret_indices, i);
            if (table::contains(&order.fill_records, secret_index)) {
                let record = *table::borrow(&order.fill_records, secret_index);
                vector::push_back(&mut fills, record);
            };
            i = i + 1;
        };
        
        fills
    }

    public fun calculate_fill_percentage<T>(order: &PartialFillOrder<T>, amount: u64): u64 {
        if (order.total_making_amount == 0) {
            return 0
        };
        (amount * 100) / order.total_making_amount
    }

     public fun get_order_stats<T>(order: &PartialFillOrder<T>): (u64, u64, u64, u64, u64, bool) {
        (
            order.total_making_amount,
            order.filled_amount,
            balance::value(&order.remaining_balance),
            order.parts_amount,
            order.total_fills,
            order.multiple_fills_allowed
        )
    }

}