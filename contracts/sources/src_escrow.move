module cross_chain_swap::src_escrow{
    use sui::object::{Self, UID, ID};
    use sui::transfer;

    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self,Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::address;

    use cross_chain_swap::base_escrow::{Self, BaseEscrow, EscrowCap, AccessTokenCap};
    
    use libraries::time_lock::{Self, Timelocks};
    use libraries::immutables::{Self, Immutables};
    use libraries::time_lock::SRC_WITHDRAWAL;


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


    public struct EscrowSrc<phantom T> has key, store {
        id: UID,
        base_escrow: BaseEscrow<T>
    }



    public fun new<T>(
        rescue_delay: u64,
        access_token_type: address,
        initial_token: Coin<T>,
        safety_deposit: Coin<SUI>,
        ctx: &mut TxContext
    ): (EscrowSrc<T>, EscrowCap) {
        let ( mut base_escrow, escrow_cap ) = base_escrow::new<T>(rescue_delay, access_token_type, ctx);

        
        base_escrow::deposit_tokens(&mut base_escrow, initial_token);

        base_escrow::deposit_native(&mut base_escrow, safety_deposit);


        let escrow_src = EscrowSrc<T>{
            id: object::new(ctx),
            base_escrow: base_escrow
        };

        (escrow_src, escrow_cap)


    }

public fun withdraw<T>(
    escrow: &mut EscrowSrc<T>,
    secret: vector<u8>,
    immutables: Immutables,
    clock: &Clock,
    ctx: &mut TxContext
){
    base_escrow::assert_only_taker(&immutables, ctx);

    let timelocks = immutables::get_timelocks(&immutables);
    let withdrawal_start = time_lock::get(timelocks, time_lock::get_src_withdrawal(timelocks));
    let cancellation_start = time_lock::get(timelocks, time_lock::get_src_cancellation(timelocks));

    base_escrow::assert_only_after(withdrawal_start, clock);
    base_escrow::assert_only_before(cancellation_start, clock);

    let caller = tx_context::sender(ctx);
    withdrawal_to_internal(escrow, secret, caller, immutables, ctx);


}

public fun withdraw_to<T>(
        escrow: &mut EscrowSrc<T>,
        secret: vector<u8>,
        target: address,
        immutables: Immutables,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        
        base_escrow::assert_only_taker(&immutables, ctx);
        let timelocks = immutables::get_timelocks(&immutables);
        let withdrawal_start = time_lock::get(timelocks, time_lock::get_src_withdrawal(timelocks));
        let cancellation_start = time_lock::get(timelocks, time_lock::get_src_cancellation(timelocks));
        
         base_escrow::assert_only_after(withdrawal_start, clock);
         base_escrow::assert_only_before(cancellation_start, clock);

       
        withdrawal_to_internal(escrow, secret, target, immutables, ctx);
    }
public fun public_withdraw<T, AccessToken>(
        escrow: &mut EscrowSrc<T>,
        secret: vector<u8>,
        immutables: Immutables,
        access_cap: &AccessTokenCap<AccessToken>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validation
        base_escrow::assert_access_token_holder(access_cap);
        let timelocks = immutables::get_timelocks(&immutables);
        let public_withdrawal_start = time_lock::get(timelocks, time_lock::get_src_public_withdrawal(timelocks));
        let cancellation_start = time_lock::get(timelocks, time_lock::get_src_cancellation(timelocks));
        
        base_escrow::assert_only_after(public_withdrawal_start, clock);
        base_escrow::assert_only_before(cancellation_start, clock);

        // Withdraw to taker (not caller)
        let taker_bytes = immutables::get_taker(&immutables);
        let taker_address = address::from_bytes(*taker_bytes);
        withdrawal_to_internal(escrow, secret, taker_address, immutables, ctx);
    }

public fun cancel<T>(
        escrow: &mut EscrowSrc<T>,
        immutables: Immutables,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validation
        base_escrow::assert_only_taker(&immutables, ctx);
        let timelocks = immutables::get_timelocks(&immutables);
        let cancellation_start = time_lock::get(timelocks, time_lock::get_src_cancellation(timelocks));
        
        base_escrow::assert_only_after(cancellation_start, clock);

        cancel_internal(escrow, immutables, ctx);
    }

public fun public_cancel<T, AccessToken>(
        escrow: &mut EscrowSrc<T>,
        immutables: Immutables,
        access_cap: &AccessTokenCap<AccessToken>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validation
        base_escrow::assert_access_token_holder(access_cap);
        let timelocks = immutables::get_timelocks(&immutables);
        let public_cancellation_start = time_lock::get(timelocks, time_lock::get_src_public_cancellation(timelocks));
        
        base_escrow::assert_only_after(public_cancellation_start, clock);

        cancel_internal(escrow, immutables, ctx);
    }


fun withdrawal_to_internal<T>(escrow: &mut EscrowSrc<T>, secret: vector<u8>, target: address, immutables: Immutables, ctx: &mut TxContext){
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
    base_escrow::transfer_native_to_caller<T>(&mut escrow.base_escrow, safety_deposit, caller, ctx);

  };
  event::emit(EscrowWithdrawal {
            escrow_id: object::uid_to_inner(&escrow.id),
            secret,
        });


}
fun cancel_internal<T>(
        escrow: &mut EscrowSrc<T>,
        immutables: Immutables,
        ctx: &mut TxContext
    ) {
        // Validation
        assert!(!base_escrow::is_withdrawn(&escrow.base_escrow), EALREADY_WITHDRAWN);
        assert!(!!base_escrow::is_cancelled(&escrow.base_escrow), EALREADY_CANCELLED);
       

        // Mark as cancelled
       base_escrow::set_cancelled(&mut escrow.base_escrow, true);


        // Transfer ERC20-like tokens back to maker
        let maker_bytes = immutables::get_maker(&immutables);
        let maker_address = address::from_bytes(*maker_bytes);
        let amount = immutables::get_amount(&immutables);
        let token_balance =  base_escrow::split_token_balance(&mut escrow.base_escrow, amount);
        let token_coin = coin::from_balance(token_balance, ctx);
        transfer::public_transfer(token_coin, maker_address);

        // Transfer safety deposit (native tokens) to caller
        let caller = tx_context::sender(ctx);
        let safety_deposit = immutables::get_safety_deposit(&immutables);
        if (safety_deposit > 0) {
           
             base_escrow::transfer_native_to_caller<T>(&mut escrow.base_escrow, safety_deposit, caller, ctx);
            
        };

        // Emit event
        event::emit(EscrowCancelled {
            escrow_id: object::uid_to_inner(&escrow.id),
        });
    }

    public fun get_base_escrow<T>(escrow: &EscrowSrc<T>): &BaseEscrow<T> {
        &escrow.base_escrow
    }





}