module cross_chain_swap::merkle_secret{
   
   use sui::object::{Self, UID, ID};
    use sui::hash::keccak256;
    use sui::event;
    use std::vector;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use std::option::{Self, Option};


   // Error constants
    const EINVALID_PROOF: u64 = 1;
    const EINVALID_SECRET_INDEX: u64 = 2;
    const ESECRET_ALREADY_REVEALED: u64 = 3;
    const EINVALID_SECRETS_AMOUNT: u64 = 4;

    public struct ValidationData has copy, drop, store {
        leaf: vector<u8>,      // The secret hash (leaf in merkle tree)
        index: u64,            // Secret index used
    }

    public struct MerkleValidator has key, store {
        id: UID,
        // Maps keccak256(orderHash, uint240(hashlockInfo)) -> ValidationData
        last_validated: Table<vector<u8>, ValidationData>,
        // Track revealed secrets to prevent reuse
        revealed_secrets: Table<vector<u8>, bool>, // keccak256(order_hash + secret_index) -> bool
    }

    // Events
    public struct SecretRevealed has copy, drop {
        order_hash: vector<u8>,
        secret_index: u64,
        secret_hash: vector<u8>,
    }

    public fun new_validator(ctx: &mut TxContext): MerkleValidator {
        MerkleValidator {
            id: object::new(ctx),
            last_validated: table::new(ctx),
            revealed_secrets: table::new(ctx),
        }
    }


    public fun validate_merkle_proof(
        validator: &mut MerkleValidator,
        order_hash: vector<u8>,
        hashlock_info: vector<u8>, // uint240 from 1inch (30 bytes)
        secret_index: u64,
        secret_hash: vector<u8>,
        merkle_proof: vector<vector<u8>>,
    ): bool {
        // Check if secret was already revealed
        let secret_key = create_secret_key(order_hash, secret_index);
        assert!(!table::contains(&validator.revealed_secrets, secret_key), ESECRET_ALREADY_REVEALED);

        // Reconstruct merkle root from proof using 1inch-compatible encoding
        let calculated_root = verify_merkle_proof_1inch_style(
            secret_hash,
            secret_index,
            merkle_proof
        );

        // Compare with stored merkle root (first 30 bytes)
        let calculated_shortened = extract_first_30_bytes(calculated_root);
        assert!(calculated_shortened == hashlock_info, EINVALID_PROOF);

        // Mark secret as revealed
        table::add(&mut validator.revealed_secrets, secret_key, true);

        // Create validation key: keccak256(orderHash, hashlock_info)
        let mut validation_key = order_hash;
        vector::append(&mut validation_key, hashlock_info);
        let key = keccak256(&validation_key);

        // Store validation data
        let validation_data = ValidationData {
            leaf: secret_hash,
            index: secret_index,
        };

        table::add(&mut validator.last_validated, key, validation_data);

        event::emit(SecretRevealed {
            order_hash,
            secret_index,
            secret_hash,
        });

        true
    }

    fun verify_merkle_proof_1inch_style(
        leaf_hash: vector<u8>,
        index: u64,
        proof: vector<vector<u8>>
    ): vector<u8> {
        // Create leaf using 1inch's encoding
        let leaf = encode_leaf_1inch_style(index, leaf_hash);
        let mut current_hash = keccak256(&leaf);
        let mut current_index = index;
        
        let proof_length = vector::length(&proof);
        let mut i = 0;
        
        while (i < proof_length) {
            let proof_element = *vector::borrow(&proof, i);
            
            if (current_index % 2 == 0) {
                // Current node is left child
                current_hash = keccak256(&combine_hashes(current_hash, proof_element));
            } else {
                // Current node is right child  
                current_hash = keccak256(&combine_hashes(proof_element, current_hash));
            };
            
            current_index = current_index / 2;
            i = i + 1;
        };
        
        current_hash
    }

    fun encode_leaf_1inch_style(index: u64, hash: vector<u8>): vector<u8> {
        let mut encoded = vector::empty<u8>();
        
        // Encode index as 32 bytes (big-endian) to match Solidity uint256
        let index_bytes = encode_u64_as_u256(index);
        vector::append(&mut encoded, index_bytes);
        
        // Append secret hash
        vector::append(&mut encoded, hash);
        
        encoded
    }

    fun encode_u64_as_u256(value: u64): vector<u8> {
        let mut encoded = vector::empty<u8>();
        
        // Fill with zeros for the first 24 bytes (32 - 8 = 24)
        let mut i = 0;
        while (i < 24) {
            vector::push_back(&mut encoded, 0u8);
            i = i + 1;
        };
        
        // Encode the u64 value in big-endian
        let mut temp_value = value;
        let mut value_bytes = vector::empty<u8>();
        i = 0;
        while (i < 8) {
            vector::push_back(&mut value_bytes, ((temp_value % 256) as u8));
            temp_value = temp_value / 256;
            i = i + 1;
        };
        
        // Reverse for big-endian
        vector::reverse(&mut value_bytes);
        vector::append(&mut encoded, value_bytes);
        
        encoded
    }

    fun combine_hashes(left: vector<u8>, right: vector<u8>): vector<u8> {
        let mut combined = left;
        vector::append(&mut combined, right);
        combined
    }

    fun extract_first_30_bytes(hash: vector<u8>): vector<u8> {
        let mut result = vector::empty<u8>();
        let mut i = 0;
        let hash_length = vector::length(&hash);
        let extract_length = if (hash_length < 30) hash_length else 30;
        
        while (i < extract_length) {
            vector::push_back(&mut result, *vector::borrow(&hash, i));
            i = i + 1;
        };
        
        result
    }

    fun create_secret_key(order_hash: vector<u8>, secret_index: u64): vector<u8> {
        let mut key = order_hash;
        let index_bytes = encode_u64_as_u256(secret_index);
        vector::append(&mut key, index_bytes);
        keccak256(&key)
    }

    

    public fun get_validation_data(
        validator: &MerkleValidator,
        order_hash: vector<u8>,
        hashlock_info: vector<u8>
    ): Option<ValidationData> {
        let mut validation_key = order_hash;
        vector::append(&mut validation_key, hashlock_info);
        let key = keccak256(&validation_key);
        
        if (table::contains(&validator.last_validated, key)) {
            option::some(*table::borrow(&validator.last_validated, key))
        } else {
            option::none()
        }
    }

    /// Check if a secret has been revealed
    public fun is_secret_revealed(
        validator: &MerkleValidator,
        order_hash: vector<u8>,
        secret_index: u64
    ): bool {
        let secret_key = create_secret_key(order_hash, secret_index);
        table::contains(&validator.revealed_secrets, secret_key)
    }

   
}