module libraries::immutables{
    
    use sui::hash;
    use sui::bcs;
   

    use libraries::address_lib:: {Address, get_address_bytes};
    use libraries::time_lock:: Timelocks;

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

        // Function to hash immutables
        public fun hash(immutables: &Immutables): vector<u8>{

            let serialized = bcs::to_bytes(immutables);
            
            hash::keccak256(&serialized)
        }

    
        // Function to get taker address

        public fun get_taker(immutables: &Immutables): &vector<u8> {
            get_address_bytes(&immutables.taker)
        }

        // Function to get hashlock

        public fun get_hashlock(immutables: &Immutables): &vector<u8> {
            &immutables.hash_lock
        }





}