module cross_chain_swap::limit_orders {
    use sui::object::{Self, UID};
    use sui::event;
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use std::option;
    use std::vector;

    /// Error codes
    const EINVALID_SIGNATURE: u64 = 1;
    const EORDER_OVERFILLED: u64 = 2;
    const EINSUFFICIENT_ESCROW_BALANCE: u64 = 3;
    const EINVALID_AMOUNT: u64 = 4;

    /// Regular order structure
    public struct LimitOrder<phantom T> has key, store {
        id: UID,
        order_hash: vector<u8>,
        maker: address,
        total_making_amount: u64,
        filled_amount: u64,
        escrow_balance: Balance<T>,
        created_at: u64,
    }

    /// Event emitted when a regular order is filled
    public struct OrderFilled has copy, drop {
        order_hash: vector<u8>,
        maker: address,
        making_amount: u64,
        taking_amount: u64,
    }

    /// Creates a new regular limit order
    public fun create_limit_order<T>(
        order_hash: vector<u8>,
        maker: address,
        total_making_amount: u64,
        escrow_balance: Balance<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ): LimitOrder<T> {
        assert!(total_making_amount > 0, EINVALID_AMOUNT);
        assert!(balance::value(&escrow_balance) == total_making_amount, EINVALID_AMOUNT);

        LimitOrder {
            id: object::new(ctx),
            order_hash,
            maker,
            total_making_amount,
            filled_amount: 0,
            escrow_balance,
            created_at: clock::timestamp_ms(clock),
        }
    }

    /// Fills an existing regular limit order
    public fun fill_order<T>(
        order: &mut LimitOrder<T>,
        making_amount: u64,
        taking_amount: u64,
        ctx: &mut TxContext
    ): Coin<T> {
        assert!(making_amount > 0, EINVALID_AMOUNT);
        assert!(order.filled_amount + making_amount <= order.total_making_amount, EORDER_OVERFILLED);

        let escrow_value = balance::value(&order.escrow_balance);
        assert!(escrow_value >= making_amount, EINSUFFICIENT_ESCROW_BALANCE);

        // Update filled amount
        order.filled_amount = order.filled_amount + making_amount;

        // Transfer tokens from escrow to receiver
        let send_balance = balance::split(&mut order.escrow_balance, making_amount);
        let coin_out = coin::from_balance(send_balance, ctx);

        // Emit OrderFilled event
        event::emit(OrderFilled {
            order_hash: order.order_hash,
            maker: order.maker,
            making_amount,
            taking_amount,
        });

        coin_out
    }

    /// Get current order status
    public fun get_order_status<T>(order: &LimitOrder<T>): (u64, bool) {
        let is_completed = order.filled_amount == order.total_making_amount;
        (order.filled_amount, is_completed)
    }

    /// Get available amount left in escrow
    public fun get_remaining_amount<T>(order: &LimitOrder<T>): u64 {
        balance::value(&order.escrow_balance)
    }

    /// Get total making amount
    public fun get_total_making_amount<T>(order: &LimitOrder<T>): u64 {
        order.total_making_amount
    }

    /// Get filled amount
    public fun get_filled_amount<T>(order: &LimitOrder<T>): u64 {
        order.filled_amount
    }

    /// Get order hash
    public fun get_order_hash<T>(order: &LimitOrder<T>): &vector<u8> {
        &order.order_hash
    }

    /// Get maker address
    public fun get_maker<T>(order: &LimitOrder<T>): address {
        order.maker
    }

    /// Get creation timestamp
    public fun get_created_at<T>(order: &LimitOrder<T>): u64 {
        order.created_at
    }
}
