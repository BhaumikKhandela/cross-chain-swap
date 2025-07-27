module cross_chain_swap::base_escrow{
    use sui::object::{Self, UID, ID};
    use sui::transfer;

    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self,Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::address;
    
    
    use std::option::{Self, Option};

    use libraries::time_lock::{Self, Timelocks};
    use libraries::immutables::{Self, Immutables};
    use sui::hash::keccak256;


    // Error constants 
    const EINVALID_CALLER: u64 = 1;
    const EINVALID_SECRET: u64 = 2;
    const EINVALID_TIME: u64 = 3;
    const ENATIVE_TOKEN_SENDING_FAILURE: u64 = 4;
    const EINVALD_IMMUTABLES: u64 = 5;
    const EINSUFFIUCIENT_ACCESS_TOKEN: u64 = 6;

    
    public struct FundRescued has copy, drop {
        escrow_id: ID,
        token: address,
        amount: u64
    }

    public struct TokenDeposited has copy, drop {
        escrow_id: ID,
        amount: u64,
    }

    public struct NativeTokenDeposited has copy, drop {
        escrow_id: ID,
        amount: u64,
    }
    
    public struct BaseEscrow<phantom T> has key, store {
        id: UID,

        token_balance: Balance<T>,
        native_balance: Balance<SUI>,

        rescue_delay: u64,
        access_token_type: address,

        withdrawn: bool,
        cancelled: bool,
    }

    public struct EscrowCap has key, store {
        id: UID,
        escrow_id: ID,
    }

    public struct AccessTokenCap<phantom AccessToken> has key,store {
        id: UID,
        balance: Balance<AccessToken>
    }

    public fun new<T>(rescue_delay: u64, access_token_type: address, ctx: &mut TxContext): (BaseEscrow<T>,EscrowCap) {
        let escrow_id = object::new(ctx);
        let escrow_object_id = object::uid_to_inner(&escrow_id);

        let escrow = BaseEscrow<T> {
            id: escrow_id,
            token_balance: balance::zero<T>(),
            native_balance: balance::zero<SUI>(),
            rescue_delay,
            access_token_type,
            withdrawn: false,
            cancelled: false
        };

        let cap = EscrowCap {
            id: object::new(ctx),
            escrow_id: escrow_object_id
        };

        (escrow,cap)
    }

    public fun split_token_balance<T>(escrow: &mut BaseEscrow<T>, amount: u64): Balance<T> {
        balance::split(&mut escrow.token_balance, amount)
    }

    public fun transfer_native_to_caller<T>(escrow: &mut BaseEscrow<T>, amount: u64, caller: address, ctx: &mut TxContext) {
     let split = balance::split(&mut escrow.native_balance, amount);
    let sui_coin = coin::from_balance(split, ctx);
    transfer::public_transfer(sui_coin, caller);
    }

    public fun create_access_token_cap<AccessToken>(
        tokens: Coin<AccessToken>,
        ctx: &mut TxContext
    ): AccessTokenCap<AccessToken> {
        AccessTokenCap<AccessToken> {
            id: object::new(ctx),
            balance: coin::into_balance(tokens),
        }
    }

    // middlewares

       public fun assert_only_taker(immutables: &Immutables , ctx: &TxContext){
        let sender =tx_context::sender(ctx);
        let sender_bytes = address::to_bytes(sender);
        let taker = immutables::get_taker(immutables);

        assert!(sender_bytes == *taker, EINVALID_CALLER);

    }
    public fun assert_valid_secret(secret: &vector<u8>, immutables: &Immutables){
        let secret_hash = keccak256(secret);
        let hashlock = immutables::get_hashlock(immutables);
        assert!(secret_hash == *hashlock, EINVALID_SECRET);

    }
    public fun assert_only_after(start_time: u64, clock: &Clock){
        let current_time = clock::timestamp_ms(clock)/1000;
        assert!(current_time >= start_time , EINVALID_TIME);
    }

    public fun assert_only_before(stop_time: u64, clock: &Clock){
        let current_time = clock::timestamp_ms(clock)/1000;
        assert!(current_time < stop_time, EINVALID_TIME);
    }

    public fun assert_access_token_holder<AccessToken>(
        access_cap: &AccessTokenCap<AccessToken>,
    ){
        let balance = balance::value(&access_cap.balance);
        assert!(balance > 0, EINSUFFIUCIENT_ACCESS_TOKEN);
    }

    public fun is_withdrawn<T>(escrow: &BaseEscrow<T>): bool {
        escrow.withdrawn
    }

    public fun is_cancelled<T>(escrow: &BaseEscrow<T>): bool {
        escrow.cancelled
    }

    public fun set_withdrawn<T>(escrow: &mut BaseEscrow<T>, withdrawn: bool) {
        escrow.withdrawn = withdrawn
    }

    public fun set_cancelled<T>(escrow: &mut BaseEscrow<T>, cancelled: bool){
        escrow.cancelled = cancelled
    }

    public fun get_token_balance<T>(escrow: &BaseEscrow<T>): u64 {
        balance::value(&escrow.token_balance)
    }

    public fun get_native_balance<T>(escrow: &BaseEscrow<T>): u64 {
       balance::value(&escrow.native_balance)
    }

    public fun rescue_funds<T>(escrow: &mut BaseEscrow<T>, token_address: address, amount: u64, immutables: Immutables, clock: &Clock, ctx: &mut TxContext) {
        assert_only_taker(&immutables, ctx);
        let rescue_start_time = time_lock::rescue_start(immutables::get_timelocks(&immutables), escrow.rescue_delay);
        assert_only_after(rescue_start_time, clock);

        let rescued_balance = balance::split(&mut escrow.token_balance, amount);
        let rescued_coin = coin::from_balance(rescued_balance,ctx);

        let caller_address = tx_context::sender(ctx);
        transfer::public_transfer(rescued_coin, caller_address);

        event::emit(FundRescued{
            escrow_id: object::uid_to_inner(&escrow.id),
            token: token_address,
            amount
        });    
    }


    public fun deposit_tokens<T>(
        escrow: &mut BaseEscrow<T>,
        tokens: Coin<T>
    ){
     let token_balance = coin::into_balance(tokens);
     let amount: u64 = balance::value(&token_balance);
     balance::join(&mut escrow.token_balance, token_balance);
     event::emit(TokenDeposited{
        escrow_id: object::uid_to_inner(&escrow.id),
        amount: amount
     })
    }

    public fun deposit_native<T>(
        escrow: &mut BaseEscrow<T>,
        coin: Coin<SUI>
    ) {
        let amount = coin::value(&coin);
    let native_balance = coin::into_balance(coin);
    balance::join(&mut escrow.native_balance, native_balance);

    event::emit(NativeTokenDeposited{
        escrow_id: object::uid_to_inner(&escrow.id),
        amount: amount
    })
    }

  public fun get_escrow_id<T>(escrow: &BaseEscrow<T>): ID {
    object::uid_to_inner(&escrow.id)  // Use reference to id
}
    
}