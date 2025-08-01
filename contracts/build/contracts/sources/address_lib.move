module libraries::address_lib{
    
    use sui::address;
    

    const ETHEREUM_CHAIN_ID : u64 = 1;
    const SUI_CHAIN_ID: u64 = 2;
    const TOKEN_ID: u64 = 3;

    public struct Address has copy , drop , store {
        chain_id: u64,
        address_bytes: vector<u8>
    }

    // Function to get address_bytes

    public fun get_address_bytes(address: &Address): &vector<u8> {
         &address.address_bytes
    }


    
    public fun from_ethereum(eth_address: vector<u8>): Address {
        assert!(vector::length(&eth_address) == 20, 1);
        Address{
            chain_id: ETHEREUM_CHAIN_ID,
            address_bytes: eth_address
        }
    }

    public fun from_sui(sui_address: address): Address {
        let address_bytes = address::to_bytes(sui_address);

        Address{
            chain_id: SUI_CHAIN_ID,
            address_bytes: address_bytes
        }

    }

    public fun from_token(token: vector<u8>) : Address {
        Address {
           chain_id: TOKEN_ID,
           address_bytes: token
        }
    }
}