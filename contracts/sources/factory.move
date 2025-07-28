module cross_chain_swap::factory{
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::event;
    use sui::address;
    use sui::hash;
    use sui::table::{Self, Table};
    use std::vector;
    use std::option::{Self, Option};

    use cross_chain_swap::base_escrow::{Self, BaseEscrow, EscrowCap, AccessTokenCap};
    use cross_chain_swap::src_escrow::{Self, EscrowSrc};
    use cross_chain_swap::dst_escrow::{Self, EscrowDst};
    use libraries::time_lock::{Self, Timelocks};
    use libraries::immutables::{Self, Immutables};
    use sui::sui::SUI;

    const EINVALID_CALLER: u64 = 1;
    const EESCROW_ALREADY_EXISTS: u64 = 2;
    const EESCROW_NOT_FOUND: u64 = 3;
    const EINVALID_IMMUTABLES: u64 = 4;
    const EINSUFFICIENT_FUNDS: u64 = 5;

    public struct SrcEscrowCreated has copy, drop {
        escrow_id: ID,
        factory_id: ID,
        immutables: Immutables,
        deployer: address,
    }

     public struct DstEscrowCreated has copy, drop {
        escrow_id: ID,
        factory_id: ID,
        immutables: Immutables,
        deployer: address,
    }

    public struct EscrowFactory has key, store {
        id: UID,
        
        // Configuration
        rescue_delay: u64,
        access_token_type: address,
        
       
        
        // Statistics
        total_src_escrows: u64,
        total_dst_escrows: u64,
    }
    
    public struct FactoryCap has key, store {
        id: UID,
        factory_id: ID,
    }

    
    public fun new(
        rescue_delay: u64,
        access_token_type: address,
        ctx: &mut TxContext
    ): (EscrowFactory, FactoryCap) {
        let factory_id = object::new(ctx);
        let factory_obj_id = object::uid_to_inner(&factory_id);
        
        let factory = EscrowFactory {
            id: factory_id,
            rescue_delay,
            access_token_type,
            total_src_escrows: 0,
            total_dst_escrows: 0,
        };

        let cap = FactoryCap {
            id: object::new(ctx),
            factory_id: factory_obj_id,
        };

        (factory, cap)
    }


    public fun create_src_escrow<T>(
        factory: &mut EscrowFactory,
        immutables: Immutables,
        initial_tokens: Coin<T>,
        safety_deposit: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ): (EscrowSrc<T>, EscrowCap) {
        // Set deployment timestamp in timelocks
        let current_time = clock::timestamp_ms(clock) / 1000;
        let mut timelocks = *immutables::get_timelocks(&immutables);
        time_lock::set_deploy_timestamp(&mut timelocks, current_time);
        
        // Update immutables with deployment time
        let updated_immutables = immutables::new(
    *immutables::get_order_hash(&immutables),
    *immutables::get_hashlock(&immutables),
    *immutables::get_maker_address(&immutables),
    *immutables::get_taker_address(&immutables),
    *immutables::get_token_address(&immutables),
    immutables::get_amount(&immutables),
    immutables::get_safety_deposit(&immutables),
    timelocks,

);

        // Create the source escrow
        let (escrow, escrow_cap) = src_escrow::new<T>(
            factory.rescue_delay,
            factory.access_token_type,
            initial_tokens,
            safety_deposit,
            timelocks,
            clock,
            ctx
        );

       
       
        let base_escrow_reference = src_escrow::get_base_escrow(&escrow);
        
        let escrow_id = base_escrow::get_escrow_id(base_escrow_reference);

        
        // Update statistics
        factory.total_src_escrows = factory.total_src_escrows + 1;

        // Emit creation event
        event::emit(SrcEscrowCreated {
            escrow_id,
            factory_id: object::uid_to_inner(&factory.id),
            immutables: updated_immutables,
            deployer: tx_context::sender(ctx),
        });

        (escrow, escrow_cap)
    }

    public fun create_dst_escrow<T>(
        factory: &mut EscrowFactory,
        immutables: Immutables,
        initial_tokens: Coin<T>,
        safety_deposit: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ): (EscrowDst<T>, EscrowCap) {
       
        let current_time = clock::timestamp_ms(clock) / 1000;
        let mut timelocks = *immutables::get_timelocks(&immutables);
        time_lock::set_deploy_timestamp(&mut timelocks, current_time);
        
       
        let updated_immutables = immutables::new(
            *immutables::get_order_hash(&immutables),
            *immutables::get_hashlock(&immutables),
            *immutables::get_maker_address(&immutables), 
            *immutables::get_taker_address(&immutables), 
            *immutables::get_token_address(&immutables), 
            immutables::get_amount(&immutables),
            immutables::get_safety_deposit(&immutables),
            timelocks,
        );

     
        let (escrow, escrow_cap) = dst_escrow::new<T>(
            factory.rescue_delay,
            factory.access_token_type,
            initial_tokens,
            safety_deposit,
            timelocks,
            clock,
            ctx
        );

      
        
       let base_escrow_reference = dst_escrow::get_base_escrow(&escrow);
       let escrow_id = base_escrow::get_escrow_id(base_escrow_reference);

        
        
        // Update statistics
        factory.total_dst_escrows = factory.total_dst_escrows + 1;

        // Emit creation event
        event::emit(DstEscrowCreated {
            escrow_id,
            factory_id: object::uid_to_inner(&factory.id),
            immutables: updated_immutables,
            deployer: tx_context::sender(ctx),
        });

        (escrow, escrow_cap)
    }



}