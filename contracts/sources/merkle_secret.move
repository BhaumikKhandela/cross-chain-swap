module cross_chain_swap::merkle_secret{
   use sui::object::{Self, UID, ID};
    use sui::hash::keccak256;
    use sui::event;
    use std::vector;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use std::option::{Self, Option};


    const EINVALID_PROOF: u64 = 1;
    const EINVALID_SECRET_INDEX: u64 = 2;
    const ESECRET_ALREADY_REVEALED: u64 = 3;
    const EINVALID_SECRET_SEQUENCE: u64 = 4;
    const EESCROW_ALREADY_VALIDATED: u64 = 5;
    const EINVALID_PROGRESSIVE_SECRETS: u64 = 6;

    public struct ValidationData has copy, drop, store {
        index: u64,
        secret_hash: vector<u8>,
        escrow_id: Option<ID>,
    }

    public struct SecretWithProof has copy, drop, store {
        index: u64,
        secret_hash: vector<u8>,
        merkle_proof: vector<vector<u8>>,
    }

    public struct MerkleValidator has key {
        id: UID,
        // Per-order validation tracking (maintains backward compatibility)
        last_validated: Table<vector<u8>, ValidationData>,
        // Per-escrow validation tracking (new for escrow-per-fill)
        escrow_validations: Table<ID, ValidationData>,
        // Order to escrows mapping
        order_to_escrows: Table<vector<u8>, vector<ID>>,
        // Track revealed secrets to prevent reuse
        revealed_secrets: Table<vector<u8>, bool>, // keccak256(order_hash + secret_index) -> bool
    }

    // Events
    public struct SecretRevealed has copy, drop {
        order_hash: vector<u8>,
        index: u64,
        secret_hash: vector<u8>,
        escrow_id: Option<ID>,
    }

    public struct ProgressiveSecretsValidated has copy, drop {
        order_hash: vector<u8>,
        secret_indices: vector<u64>,
        escrow_id: ID,
    }

    
    public fun new_validator(ctx: &mut TxContext): MerkleValidator {
        MerkleValidator {
            id: object::new(ctx),
            last_validated: table::new(ctx),
            escrow_validations: table::new(ctx),
            order_to_escrows: table::new(ctx),
            revealed_secrets: table::new(ctx),
        }
    }

    public fun validate_merkle_proof(
        validator: &mut MerkleValidator,
        order_hash: vector<u8>,
        merkle_root_shortened: vector<u8>, // First 30 bytes of merkle root
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

        // Compare first 30 bytes (240 bits) of calculated root
        let calculated_shortened = extract_shortened_root(calculated_root);
        assert!(calculated_shortened == merkle_root_shortened, EINVALID_PROOF);

        // Mark secret as revealed
        table::add(&mut validator.revealed_secrets, secret_key, true);

        // Create validation key for order-level tracking
        let mut validation_key = order_hash;
        vector::append(&mut validation_key, merkle_root_shortened);

        // Update validation data
        let validation_data = ValidationData {
            index: secret_index,
            secret_hash,
            escrow_id: option::none(),
        };

        // Update or add validation data
        if (table::contains(&validator.last_validated, validation_key)) {
            let existing_data = table::borrow_mut(&mut validator.last_validated, validation_key);
            *existing_data = validation_data;
        } else {
            table::add(&mut validator.last_validated, validation_key, validation_data);
        };

        event::emit(SecretRevealed {
            order_hash,
            index: secret_index,
            secret_hash,
            escrow_id: option::none(),
        });

        true
    }


    public fun validate_for_escrow(
        validator: &mut MerkleValidator,
        escrow_id: ID,
        order_hash: vector<u8>,
        merkle_root_shortened: vector<u8>,
        secret_index: u64,
        secret_hash: vector<u8>,
        merkle_proof: vector<vector<u8>>,
    ): bool {
        // First validate the merkle proof
        let valid = validate_merkle_proof(
            validator,
            order_hash,
            merkle_root_shortened,
            secret_index,
            secret_hash,
            merkle_proof,
        );

        if (valid) {
            // Ensure escrow hasn't been validated before
            assert!(!table::contains(&validator.escrow_validations, escrow_id), EESCROW_ALREADY_VALIDATED);

            // Store escrow-specific validation
            let escrow_validation_data = ValidationData {
                index: secret_index,
                secret_hash,
                escrow_id: option::some(escrow_id),
            };
            
            table::add(&mut validator.escrow_validations, escrow_id, escrow_validation_data);
            
            // Update order to escrows mapping
            if (!table::contains(&validator.order_to_escrows, order_hash)) {
                table::add(&mut validator.order_to_escrows, order_hash, vector::empty<ID>());
            };
            
            let escrow_list = table::borrow_mut(&mut validator.order_to_escrows, order_hash);
            vector::push_back(escrow_list, escrow_id);

            event::emit(SecretRevealed {
                order_hash,
                index: secret_index,
                secret_hash,
                escrow_id: option::some(escrow_id),
            });
        };

        valid
    }


    public fun validate_progressive_secrets(
        validator: &mut MerkleValidator,
        order_hash: vector<u8>,
        merkle_root_shortened: vector<u8>,
        secrets_and_proofs: vector<SecretWithProof>,
        escrow_id: ID,
    ): bool {
        let secrets_count = vector::length(&secrets_and_proofs);
        assert!(secrets_count > 0, EINVALID_PROGRESSIVE_SECRETS);

        let mut i = 0;
        let mut secret_indices = vector::empty<u64>();
        
        while (i < secrets_count) {
            let secret_data = vector::borrow(&secrets_and_proofs, i);
            
            // Validate each secret in sequence
            let valid = validate_for_escrow(
                validator,
                escrow_id,
                order_hash,
                merkle_root_shortened,
                secret_data.index,
                secret_data.secret_hash,
                secret_data.merkle_proof,
            );
            
            assert!(valid, EINVALID_PROGRESSIVE_SECRETS);
            vector::push_back(&mut secret_indices, secret_data.index);
            
            i = i + 1;
        };

        event::emit(ProgressiveSecretsValidated {
            order_hash,
            secret_indices,
            escrow_id,
        });

        true
    }


    fun verify_merkle_proof_1inch_style(
        leaf_hash: vector<u8>,
        index: u64,
        proof: vector<vector<u8>>
    ): vector<u8> {
        // Create leaf using 1inch's encoding: keccak256(index || secret_hash)
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
        
        // Encode index as 32 bytes (big-endian) to match 1inch
        let index_bytes = encode_u64_big_endian(index);
        vector::append(&mut encoded, index_bytes);
        
        // Append secret hash
        vector::append(&mut encoded, hash);
        
        encoded
    }

    fun encode_u64_big_endian(value: u64): vector<u8> {
        let mut encoded = vector::empty<u8>();
        
        // Fill with zeros for the first 24 bytes (32 - 8 = 24)
        let mut i = 0;
        while (i < 24) {
            vector::push_back(&mut encoded, 0u8);
            i = i + 1;
        };
        
        // Encode the u64 value in big-endian (most significant byte first)
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


    fun extract_shortened_root(root: vector<u8>): vector<u8> {
        let mut shortened = vector::empty<u8>();
        let mut i = 0;
        let root_length = vector::length(&root);
        let extract_length = if (root_length < 30) root_length else 30;
        
        while (i < extract_length) {
            vector::push_back(&mut shortened, *vector::borrow(&root, i));
            i = i + 1;
        };
        
        shortened
    }

    fun create_secret_key(order_hash: vector<u8>, secret_index: u64): vector<u8> {
        let mut key = order_hash;
        let index_bytes = encode_u64_big_endian(secret_index);
        vector::append(&mut key, index_bytes);
        keccak256(&key)
    }
    

   
}