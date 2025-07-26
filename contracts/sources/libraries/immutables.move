module libraries::immutables{
    
    use sui::hash;
    use sui::bcs;
    use std::vector;

    use libraries::address_lib::{Self, Address};
    use libraries::time_lock::{Self, Timelocks};

    // Immutable Structure 

    public struct Immutables has copy, drop, store {
        order_hash: vector<u8>,
        hash_lock: vector<u8>,
        maker: Address,
        taker: Address,
        token: Address,
        amount: u64,
        safety_deposit: u64,
        timelocks: Timelocks,
    }

    const EINVALID_HASH_LENGTH: u64 = 1;
    const EINVALID_AMOUNT: u64 = 2;


    public fun new (order_hash: vector<u8>,
        hash_lock: vector<u8>,
        maker: Address,
        taker: Address,
        token: Address,
        amount: u64,
        safety_deposit: u64,
        timelocks: Timelocks,) : Immutables {

            assert!(vector::length(&order_hash) == 32, EINVALID_HASH_LENGTH);
            assert!(vector::length(&hash_lock) == 32, EINVALID_HASH_LENGTH);
            assert!(amount > 0, EINVALID_AMOUNT);

            Immutables{
                order_hash,
                hash_lock,
                maker,
                taker,
                token,
                amount,
                safety_deposit,
                timelocks,
            }
        }


        public fun hash(immutables: &Immutables): vector<u8>{

            let serialized = bcs::to_bytes(immutables);
            
            hash::keccak256(&serialized)
        }


}