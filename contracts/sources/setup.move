module cross_chain_swap::setup {
    use sui::tx_context::{Self, TxContext};
    use cross_chain_swap::factory::{Self, EscrowFactory, FactoryCap};
    use cross_chain_swap::merkle_secret::{Self, MerkleValidator};

    public fun setup_contracts(ctx: &mut TxContext) {
        // Create factory and factory cap
        let (factory, factory_cap) = factory::new(
            3600, // rescue_delay
            @0x0000000000000000000000000000000000000000000000000000000000000000, // access_token_type
            ctx
        );

        // Create merkle validator
        let merkle_validator = merkle_secret::new_validator(ctx);

        // Transfer all objects to the sender
        sui::transfer::public_transfer(factory, tx_context::sender(ctx));
        sui::transfer::public_transfer(factory_cap, tx_context::sender(ctx));
        sui::transfer::public_transfer(merkle_validator, tx_context::sender(ctx));
    }
} 