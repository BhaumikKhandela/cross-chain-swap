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

}