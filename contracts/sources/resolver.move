module cross_chain_swap::resolver {
    use sui::object::{Self, UID};
    use sui::event;
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::address;
    use sui::hash;
    use sui::sui::SUI;

    use cross_chain_swap::factory::{Self, EscrowFactory, FactoryCap};
    use cross_chain_swap::limit_orders::{Self, LimitOrder, OrderFilled};
    use cross_chain_swap::src_escrow::{Self, EscrowSrc};
    use cross_chain_swap::dst_escrow::{Self, EscrowDst};
    use cross_chain_swap::base_escrow::EscrowCap;
    use libraries::immutables::{Self, Immutables};
    use libraries::time_lock::{Self, Timelocks};

    // Error codes
    const EINVALID_LENGTH: u64 = 1;
    const ELENGTH_MISMATCH: u64 = 2;
    const EINVALID_ORDER: u64 = 3;
    const EINVALID_ESCROW: u64 = 4;
    const EINVALID_SECRET: u64 = 5;
    const EESCROW_NOT_FOUND: u64 = 6;
    const EINVALID_MAKER: u64 = 7;
    const EINSUFFICIENT_BALANCE: u64 = 8;
    const EINVALID_AMOUNT: u64 = 9;

    // Main resolver struct
    public struct CrossChainResolver has key, store {
        id: UID,
        factory: address,
        limit_order_protocol: address,
        default_rescue_delay: u64,
        fee_token: address,
        access_token: address,
        src_escrows: Table<vector<u8>, address>, // orderHash => src escrow
        dst_escrows: Table<vector<u8>, address>, // orderHash => dst escrow
        completed_swaps: Table<vector<u8>, bool>, // orderHash => completed
    }

    // Events
    public struct SrcDeployed has copy, drop {
        escrow: address,
        order_hash: vector<u8>,
        maker: address,
        amount: u64,
    }

    public struct DstDeployed has copy, drop {
        escrow: address,
        order_hash: vector<u8>,
        taker: address,
        amount: u64,
    }

    public struct CrossChainSwapInitiated has copy, drop {
        order_hash: vector<u8>,
        src_escrow: address,
        dst_escrow: address,
        maker: address,
        taker: address,
    }

    public struct EscrowWithdrawal has copy, drop {
        escrow: address,
        withdrawer: address,
        secret: vector<u8>,
    }

    public struct EscrowCancellation has copy, drop {
        escrow: address,
        canceller: address,
    }

    /// Creates a new CrossChainResolver
    public fun new(
        factory: address,
        limit_order_protocol: address,
        default_rescue_delay: u64,
        fee_token: address,
        access_token: address,
        ctx: &mut TxContext
    ): CrossChainResolver {
        CrossChainResolver {
            id: object::new(ctx),
            factory,
            limit_order_protocol,
            default_rescue_delay,
            fee_token,
            access_token,
            src_escrows: table::new(ctx),
            dst_escrows: table::new(ctx),
            completed_swaps: table::new(ctx),
        }
    }

    /// Deploys source escrow and fills order in one transaction
    /// This ensures atomicity and proper safety deposit handling
    public fun deploy_src<T>(
        resolver: &mut CrossChainResolver,
        factory: &mut EscrowFactory,
        immutables: Immutables,
        order: &mut LimitOrder<T>,
        initial_tokens: Coin<T>,
        safety_deposit: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ): (EscrowSrc<T>, Coin<T>) {
        assert!(coin::value(&initial_tokens) > 0, EINVALID_AMOUNT);
        assert!(coin::value(&safety_deposit) >= 0, EINVALID_AMOUNT);

        // Get order hash from immutables
        let order_hash = *immutables::get_order_hash(&immutables);
        let maker = immutables::get_maker_address(&immutables);
        let maker_bytes = libraries::address_lib::get_address_bytes(maker);
        let maker_address = address::from_bytes(*maker_bytes);

        // Validate order maker matches immutables maker
        assert!(limit_orders::get_maker(order) == maker_address, EINVALID_MAKER);

        // Create source escrow using factory
        let initial_amount = coin::value(&initial_tokens);
        let (src_escrow, escrow_cap) = factory::create_src_escrow<T>(
            factory,
            immutables,
            initial_tokens,
            safety_deposit,
            clock,
            ctx
        );

        
        limit_orders::fill_order(
            order,
            initial_amount,  
    
        );

        
        let escrow_id_address = src_escrow::get_src_escrow_id(&src_escrow);
        table::add(&mut resolver.src_escrows, order_hash, escrow_id_address);

        // Emit event
        event::emit(SrcDeployed {
            escrow: escrow_id_address,
            order_hash,
            maker: maker_address,
            amount: initial_amount,
        });

        // Transfer escrow cap to caller (they need it for future operations)
        transfer::public_transfer(escrow_cap, tx_context::sender(ctx));

        // Return the escrow and a zero coin (since tokens are deposited in escrow)
        let zero_coin = coin::zero<T>(ctx);
        (src_escrow, zero_coin)
    }

    /// Deploys destination escrow
    public fun deploy_dst<T>(
        resolver: &mut CrossChainResolver,
        factory: &mut EscrowFactory,
        immutables: Immutables,
        initial_tokens: Coin<T>,
        safety_deposit: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ): (EscrowDst<T>, EscrowCap) {
        assert!(coin::value(&initial_tokens) > 0, EINVALID_AMOUNT);
        assert!(coin::value(&safety_deposit) >= 0, EINVALID_AMOUNT);

        // Create destination escrow using factory
        let initial_amount = coin::value(&initial_tokens);
        let (dst_escrow, escrow_cap) = factory::create_dst_escrow<T>(
            factory,
            immutables,
            initial_tokens,
            safety_deposit,
            clock,
            ctx
        );

        // Record the escrow
        let order_hash = *immutables::get_order_hash(&immutables);
        let escrow_id = dst_escrow::get_dst_escrow_id(&dst_escrow);
        table::add(&mut resolver.dst_escrows, order_hash, escrow_id);

        // Emit event
        let taker_address = immutables::get_taker_address(&immutables);
        let taker_bytes = libraries::address_lib::get_address_bytes(taker_address);
        event::emit(DstDeployed {
            escrow: escrow_id,
            order_hash,
            taker: address::from_bytes(*taker_bytes),
            amount: initial_amount,
        });

        (dst_escrow, escrow_cap)
    }

    /// Withdraws from an escrow with secret
    public fun withdraw<T>(
        resolver: &CrossChainResolver,
        escrow: &mut EscrowSrc<T>,
        secret: vector<u8>,
        immutables: Immutables,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let order_hash = *immutables::get_order_hash(&immutables);
        let escrow_address = src_escrow::get_src_escrow_id(escrow);
        
        // Verify escrow is registered
        assert!(table::contains(&resolver.src_escrows, order_hash), EESCROW_NOT_FOUND);
        assert!(table::borrow(&resolver.src_escrows, order_hash) == &escrow_address, EINVALID_ESCROW);

        // Withdraw from source escrow
        src_escrow::withdraw(escrow, secret, immutables, clock, ctx);

        // Emit event
        event::emit(EscrowWithdrawal {
            escrow: escrow_address,
            withdrawer: tx_context::sender(ctx),
            secret,
        });
    }

    /// Withdraws from an escrow to a specific address
    public fun withdraw_to<T>(
        resolver: &CrossChainResolver,
        escrow: &mut EscrowSrc<T>,
        secret: vector<u8>,
        target: address,
        immutables: Immutables,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let order_hash = *immutables::get_order_hash(&immutables);
        let escrow_address = src_escrow::get_src_escrow_id(escrow);
        
        // Verify escrow is registered
        assert!(table::contains(&resolver.src_escrows, order_hash), EESCROW_NOT_FOUND);
        assert!(table::borrow(&resolver.src_escrows, order_hash) == &escrow_address, EINVALID_ESCROW);

        // Withdraw to target from source escrow
        src_escrow::withdraw_to(escrow, secret, target, immutables, clock, ctx);

        // Emit event
        event::emit(EscrowWithdrawal {
            escrow: escrow_address,
            withdrawer: target,
            secret,
        });
    }

    /// Cancels an escrow
    // public fun cancel<T>(
    //     resolver: &CrossChainResolver,
    //     escrow: &mut EscrowSrc<T>,
    //     immutables: Immutables,
    //     clock: &Clock,
    //     ctx: &mut TxContext
    // ) {
    //     let order_hash = *immutables::get_order_hash(&immutables);
    //     let escrow_address = src_escrow::get_address(escrow);
        
    //     // Verify escrow is registered
    //     assert!(table::contains(&resolver.src_escrows, order_hash), EESCROW_NOT_FOUND);
    //     assert!(table::borrow(&resolver.src_escrows, order_hash) == &escrow_address, EINVALID_ESCROW);

    //     // Cancel source escrow
    //     src_escrow::cancel(escrow, immutables, clock, ctx);

    //     // Emit event
    //     event::emit(EscrowCancellation {
    //         escrow: escrow_address,
    //         canceller: tx_context::sender(ctx),
    //     });
    // }

    /// Gets escrow addresses for an order
    public fun get_escrows(resolver: &CrossChainResolver, order_hash: vector<u8>): (address, address) {
        let src_escrow = if (table::contains(&resolver.src_escrows, order_hash)) {
            *table::borrow(&resolver.src_escrows, order_hash)
        } else {
            @0x0
        };

        let dst_escrow = if (table::contains(&resolver.dst_escrows, order_hash)) {
            *table::borrow(&resolver.dst_escrows, order_hash)
        } else {
            @0x0
        };

        (src_escrow, dst_escrow)
    }

    /// Checks if a swap is completed
    public fun is_swap_completed(resolver: &CrossChainResolver, order_hash: vector<u8>): bool {
        if (table::contains(&resolver.completed_swaps, order_hash)) {
            *table::borrow(&resolver.completed_swaps, order_hash)
        } else {
            false
        }
    }

    /// Marks a swap as completed (internal use)
    public fun mark_swap_completed(resolver: &mut CrossChainResolver, order_hash: vector<u8>) {
        table::add(&mut resolver.completed_swaps, order_hash, true);
    }

    /// Updates configuration
    public fun update_config(
        resolver: &mut CrossChainResolver,
        default_rescue_delay: u64,
        fee_token: address,
        access_token: address
    ) {
        resolver.default_rescue_delay = default_rescue_delay;
        resolver.fee_token = fee_token;
        resolver.access_token = access_token;
    }

    // Helper functions

    /// Gets the factory address
    public fun get_factory(resolver: &CrossChainResolver): address {
        resolver.factory
    }

    /// Gets the limit order protocol address
    public fun get_limit_order_protocol(resolver: &CrossChainResolver): address {
        resolver.limit_order_protocol
    }

    /// Gets the default rescue delay
    public fun get_default_rescue_delay(resolver: &CrossChainResolver): u64 {
        resolver.default_rescue_delay
    }

    /// Gets the fee token address
    public fun get_fee_token(resolver: &CrossChainResolver): address {
        resolver.fee_token
    }

    /// Gets the access token address
    public fun get_access_token(resolver: &CrossChainResolver): address {
        resolver.access_token
    }
}
