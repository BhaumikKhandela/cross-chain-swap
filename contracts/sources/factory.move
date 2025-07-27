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
        
        // Registry of deployed escrows (optional - for tracking)
        src_escrows: Table<vector<u8>, ID>,  // immutables_hash -> escrow_id
        dst_escrows: Table<vector<u8>, ID>,  // immutables_hash -> escrow_id
        
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
            src_escrows: table::new<vector<u8>, ID>(ctx),
            dst_escrows: table::new<vector<u8>, ID>(ctx),
            total_src_escrows: 0,
            total_dst_escrows: 0,
        };

        let cap = FactoryCap {
            id: object::new(ctx),
            factory_id: factory_obj_id,
        };

        (factory, cap)
    }

}