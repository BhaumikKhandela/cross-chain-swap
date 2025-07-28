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
    use cross_chain_swap::merkle_secret::{Self, MerkleValidator};
    use std::vector;
    use sui::hash::keccak256;


    // Error constants 
    const EINVALID_CALLER: u64 = 1;
    const EINVALID_SECRET: u64 = 2;
    const EINVALID_TIME: u64 = 3;
    const ENATIVE_TOKEN_SENDING_FAILURE: u64 = 4;
    const EINVALD_IMMUTABLES: u64 = 5;
    const EINSUFFIUCIENT_ACCESS_TOKEN: u64 = 6;
    const EINVALID_PARTIAL_FILL: u64 = 7;
    const EINSUFFICIENT_BALANCE: u64 = 8;
    const EORDER_COMPLETED: u64 = 9;

    
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

        created_at: u64,                           // Timestamp when created
        timelocks: Timelocks,                      // Time lock information
        partial_fill_data: Option<PartialFillData>, // Partial fill support
    }

    public struct EscrowCap has key, store {
        id: UID,
        escrow_id: ID,
    }

    public struct AccessTokenCap<phantom AccessToken> has key,store {
        id: UID,
        balance: Balance<AccessToken>
    }

    public struct PartialFillData has copy, drop, store {
    supports_partial_fills: bool,
    parts_amount: u64,
    hashlock_info: vector<u8>,        // 30-byte merkle root
    order_hash: vector<u8>,
    total_making_amount: u64,
    filled_amount: u64,               // Track cumulative fills
    used_secret_indices: vector<u64>, // Track which secrets used
    total_fills: u64,
    multiple_fills_allowed: bool,
    }

    public fun new<T>(rescue_delay: u64, access_token_type: address, timelocks: Timelocks, clock: &Clock, ctx: &mut TxContext): (BaseEscrow<T>,EscrowCap) {
        let escrow_id = object::new(ctx);
        let escrow_object_id = object::uid_to_inner(&escrow_id);
        let created_at = clock::timestamp_ms(clock);

        let escrow = BaseEscrow<T> {
            id: escrow_id,
            token_balance: balance::zero<T>(),
            native_balance: balance::zero<SUI>(),
            rescue_delay,
            access_token_type,
            withdrawn: false,
            cancelled: false,
            created_at,
            timelocks,
            partial_fill_data: option::none()
        };

        let cap = EscrowCap {
            id: object::new(ctx),
            escrow_id: escrow_object_id
        };

        (escrow,cap)
    }

    public fun new_with_partial_fills<T>(
    rescue_delay: u64,
    access_token_type: address,
    timelocks: Timelocks,
    order_hash: vector<u8>,
    total_making_amount: u64,
    parts_amount: u64,
    hashlock_info: vector<u8>,
    initial_balance: Balance<T>,
    clock: &Clock,
    ctx: &mut TxContext
): (BaseEscrow<T>, EscrowCap) {
    let escrow_id = object::new(ctx);
    let escrow_object_id = object::uid_to_inner(&escrow_id);
    let created_at = clock::timestamp_ms(clock);

    assert!(parts_amount >= 2, EINVALID_PARTIAL_FILL);
    assert!(vector::length(&hashlock_info) == 30, EINVALID_PARTIAL_FILL);
    assert!(balance::value(&initial_balance) == total_making_amount, EINSUFFICIENT_BALANCE);

    let partial_fill_data = PartialFillData {
        supports_partial_fills: true,
        parts_amount,
        hashlock_info,
        order_hash,
        total_making_amount,
        filled_amount: 0,
        used_secret_indices: vector::empty<u64>(),
        total_fills: 0,
        multiple_fills_allowed: true,
    };

    let escrow = BaseEscrow<T> {
        id: escrow_id,
        token_balance: initial_balance,
        native_balance: balance::zero<SUI>(),
        rescue_delay,
        access_token_type,
        withdrawn: false,
        cancelled: false,
        created_at,
        timelocks,
        partial_fill_data: option::some(partial_fill_data),
    };

    let cap = EscrowCap {
        id: object::new(ctx),
        escrow_id: escrow_object_id
    };

    (escrow, cap)
}

    

    public fun execute_partial_fill<T>(
    escrow: &mut BaseEscrow<T>,
    making_amount: u64,
    secret_index: u64,
    secret_hash: vector<u8>,
    merkle_proof: vector<vector<u8>>,
    validator: &mut MerkleValidator,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<T> {
    assert!(!escrow.withdrawn, EINVALID_CALLER);
    assert!(!escrow.cancelled, EINVALID_CALLER);
    assert!(option::is_some(&escrow.partial_fill_data), EINVALID_PARTIAL_FILL);

    let partial_data = option::borrow_mut(&mut escrow.partial_fill_data);
    assert!(partial_data.multiple_fills_allowed, EORDER_COMPLETED);
    assert!(!vector::contains(&partial_data.used_secret_indices, &secret_index), EINVALID_SECRET);

    // Validate merkle proof
    let proof_valid = merkle_secret::validate_merkle_proof(
        validator,
        partial_data.order_hash,
        partial_data.hashlock_info,
        secret_index,
        secret_hash,
        merkle_proof,
    );
    assert!(proof_valid, EINVALID_SECRET);

    // Get validation data for 1inch partial fill logic
    let mut validation_data_opt = merkle_secret::get_validation_data(
        validator,
        partial_data.order_hash,
        partial_data.hashlock_info
    );
    
    assert!(option::is_some(&validation_data_opt), EINVALID_PARTIAL_FILL);
    let validation_data = option::extract(&mut validation_data_opt);
    let validated_index = merkle_secret::get_validation_data_index(&validation_data);

    // Apply 1inch validation logic
    let remaining_making_amount = balance::value(&escrow.token_balance);
    let is_valid = is_valid_partial_fill_1inch(
        making_amount,
        remaining_making_amount,
        partial_data.total_making_amount,
        partial_data.parts_amount,
        validated_index
    );
    assert!(is_valid, EINVALID_PARTIAL_FILL);
    assert!(making_amount <= remaining_making_amount, EINSUFFICIENT_BALANCE);

    // Execute the fill
    let fill_balance = balance::split(&mut escrow.token_balance, making_amount);
    partial_data.filled_amount = partial_data.filled_amount + making_amount;
    vector::push_back(&mut partial_data.used_secret_indices, secret_index);
    partial_data.total_fills = partial_data.total_fills + 1;

    // Check if order is completed
    let new_remaining = balance::value(&escrow.token_balance);
    if (new_remaining == 0) {
        partial_data.multiple_fills_allowed = false;
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
    let calculated_index = ((order_making_amount - remaining_making_amount + making_amount - 1) * parts_amount) / order_making_amount;

    if (remaining_making_amount == making_amount) {
        return (calculated_index + 2 == validated_index)
    } else if (order_making_amount != remaining_making_amount) {
        let prev_calculated_index = ((order_making_amount - remaining_making_amount - 1) * parts_amount) / order_making_amount;
        if (calculated_index == prev_calculated_index) {
            return false
        };
    };

    calculated_index + 1 == validated_index
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

public fun supports_partial_fills<T>(escrow: &BaseEscrow<T>): bool {
    option::is_some(&escrow.partial_fill_data)
}

public fun get_partial_fill_data<T>(escrow: &BaseEscrow<T>): Option<PartialFillData> {
    escrow.partial_fill_data
}

public fun get_created_at<T>(escrow: &BaseEscrow<T>): u64 {
    escrow.created_at
}

public fun get_timelocks<T>(escrow: &BaseEscrow<T>): &Timelocks {
    &escrow.timelocks
}
    
}