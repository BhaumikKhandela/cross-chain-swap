module cross_chain_swap::dst_escrow{
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::address;

    use cross_chain_swap::base_escrow::{Self, BaseEscrow, EscrowCap, AccessTokenCap};
    use libraries::time_lock::{Self, Timelocks};
    use libraries::immutables::{Self, Immutables};
    use sui::sui::SUI;

    const EINVALID_CALLER: u64 = 1;
    const EINVALID_SECRET: u64 = 2;
    const EINVALID_TIME: u64 = 3;
    const EALREADY_WITHDRAWN: u64 = 7;
    const EALREADY_CANCELLED: u64 = 8;
    const EINSUFFICIENT_ACCESS_TOKEN: u64 = 9;

    public struct EscrowWithdrawal has copy, drop {
        escrow_id: ID,
        secret: vector<u8>,
    }

     public struct EscrowCancelled has copy, drop {
        escrow_id: ID,
    }

    public struct EscrowDst<phantom T> has key, store {
        id: UID,
        base_escrow: BaseEscrow<T>,
    }

    public fun new<T>(
        rescue_delay: u64,
        access_token_type: address,
        initial_tokens: Coin<T>,
        safety_deposit: Coin<SUI>,
        ctx: &mut TxContext
    ): (EscrowDst<T>, EscrowCap) {
        let (mut base_escrow, escrow_cap) = base_escrow::new<T>(rescue_delay, access_token_type, ctx);
        
       
       
        base_escrow::deposit_tokens(&mut base_escrow, initial_tokens);
        
        
        base_escrow::deposit_native(&mut base_escrow, safety_deposit);

        let escrow_dst = EscrowDst<T> {
            id: object::new(ctx),
            base_escrow,
        };

        (escrow_dst, escrow_cap)
    }

    public fun withdraw<T>(
        escrow: &mut EscrowDst<T>,
        secret: vector<u8>,
        immutables: Immutables,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
     
        assert_only_maker(&immutables, ctx);
        
        
        let timelocks = immutables::get_timelocks(&immutables);
        let withdrawal_start = time_lock::get(timelocks, time_lock::get_dst_withdrawal(timelocks));
        let cancellation_start = time_lock::get(timelocks, time_lock::get_dst_cancellation(timelocks));
        
        base_escrow::assert_only_after(withdrawal_start, clock);
        base_escrow::assert_only_before(cancellation_start, clock);

        
        let caller = tx_context::sender(ctx);
        withdraw_to_internal(escrow, secret, caller, immutables, ctx);
    }


    public fun withdraw_to<T>(
        escrow: &mut EscrowDst<T>,
        secret: vector<u8>,
        target: address,
        immutables: Immutables,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validate caller is maker
        assert_only_maker(&immutables, ctx);
        
        // Check time constraints - must be in private withdrawal period
        let timelocks = immutables::get_timelocks(&immutables);
        let withdrawal_start = time_lock::get(timelocks, time_lock::get_dst_withdrawal(timelocks));
        let cancellation_start = time_lock::get(timelocks, time_lock::get_dst_cancellation(timelocks));
        
        base_escrow::assert_only_after(withdrawal_start, clock);
        base_escrow::assert_only_before(cancellation_start, clock);

        // Withdraw to specified target
        withdraw_to_internal(escrow, secret, target, immutables, ctx);
    }


    fun assert_only_maker(immutables: &Immutables, ctx: &TxContext) {
        let sender = tx_context::sender(ctx);
        let sender_bytes = address::to_bytes(sender);
        let maker = immutables::get_maker(immutables);
        
        assert!(sender_bytes == *maker, EINVALID_CALLER);
    }

    fun withdraw_to_internal<T>(
        escrow: &mut EscrowDst<T>,
        secret: vector<u8>,
        target: address,
        immutables: Immutables,
        ctx: &mut TxContext
    ) {
        
        assert!(!base_escrow::is_withdrawn(&escrow.base_escrow), EALREADY_WITHDRAWN);
        assert!(!base_escrow::is_cancelled(&escrow.base_escrow), EALREADY_CANCELLED);
        
        
        base_escrow::assert_valid_secret(&secret, &immutables);

        
        base_escrow::set_withdrawn(&mut escrow.base_escrow, true);

       
        let amount = immutables::get_amount(&immutables);
        let token_balance = base_escrow::split_token_balance(&mut escrow.base_escrow, amount);
        let token_coin = coin::from_balance(token_balance, ctx);
        transfer::public_transfer(token_coin, target);

       
        let caller = tx_context::sender(ctx);
        let safety_deposit = immutables::get_safety_deposit(&immutables);
        if (safety_deposit > 0) {
            base_escrow::transfer_native_to_caller(&mut escrow.base_escrow, safety_deposit, caller, ctx);
        };

        
        event::emit(EscrowWithdrawal {
            escrow_id: object::uid_to_inner(&escrow.id),
            secret,
        });
    }


    public fun public_withdraw<T, AccessToken>(
        escrow: &mut EscrowDst<T>,
        secret: vector<u8>,
        immutables: Immutables,
        access_cap: &AccessTokenCap<AccessToken>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        
        base_escrow::assert_access_token_holder(access_cap);
        
        
        let timelocks = immutables::get_timelocks(&immutables);
        let public_withdrawal_start = time_lock::get(timelocks, time_lock::get_dst_public_withdrawal(timelocks));
        let cancellation_start = time_lock::get(timelocks, time_lock::get_dst_cancellation(timelocks));
        
        base_escrow::assert_only_after(public_withdrawal_start, clock);
        base_escrow::assert_only_before(cancellation_start, clock);

        // Withdraw to maker (not caller) - funds always go to the intended maker
        let maker_bytes = immutables::get_maker(&immutables);
        let maker_address = address::from_bytes(*maker_bytes);
        withdraw_to_internal(escrow, secret, maker_address, immutables, ctx);
    }


    public fun cancel<T>(
        escrow: &mut EscrowDst<T>,
        immutables: Immutables,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validate caller is taker (they can cancel to get their deposited funds back)
        base_escrow::assert_only_taker(&immutables, ctx);
        
        
        let timelocks = immutables::get_timelocks(&immutables);
        let cancellation_start = time_lock::get(timelocks, time_lock::get_dst_cancellation(timelocks));
        
        base_escrow::assert_only_after(cancellation_start, clock);

        cancel_internal(escrow, immutables, ctx);
    }

    public fun public_cancel<T, AccessToken>(
        escrow: &mut EscrowDst<T>,
        immutables: Immutables,
        access_cap: &AccessTokenCap<AccessToken>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validate caller has access tokens
        base_escrow::assert_access_token_holder(access_cap);
        
        // Check time constraints - must be in public cancellation period
        let timelocks = immutables::get_timelocks(&immutables);
        let public_cancellation_start = time_lock::get(timelocks, time_lock::get_dst_public_cancellation(timelocks));
        
        base_escrow::assert_only_after(public_cancellation_start, clock);

        cancel_internal(escrow, immutables, ctx);
    }

    fun cancel_internal<T>(
        escrow: &mut EscrowDst<T>,
        immutables: Immutables,
        ctx: &mut TxContext
    ) {
        
        assert!(!base_escrow::is_withdrawn(&escrow.base_escrow), EALREADY_WITHDRAWN);
        assert!(!base_escrow::is_cancelled(&escrow.base_escrow), EALREADY_CANCELLED);

        
        base_escrow::set_cancelled(&mut escrow.base_escrow, true);

        // Transfer tokens back to taker (who originally deposited via resolver)
        let taker_bytes = immutables::get_taker(&immutables);
        let taker_address = address::from_bytes(*taker_bytes);
        let amount = immutables::get_amount(&immutables);
        let token_balance = base_escrow::split_token_balance(&mut escrow.base_escrow, amount);
        let token_coin = coin::from_balance(token_balance, ctx);
        transfer::public_transfer(token_coin, taker_address);

        // Transfer safety deposit (native tokens) to caller 
        let caller = tx_context::sender(ctx);
        let safety_deposit = immutables::get_safety_deposit(&immutables);
        if (safety_deposit > 0) {
            base_escrow::transfer_native_to_caller(&mut escrow.base_escrow, safety_deposit, caller, ctx);
        };

        // Emit cancellation event (using own event)
        event::emit(EscrowCancelled {
            escrow_id: object::uid_to_inner(&escrow.id),
        });
    }


}