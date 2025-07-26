module libraries::time_lock {
    
    public struct Timelocks has copy, drop , store {
        // Source chain timelocks
        src_withdrawal: u64,
        src_public_withdrawal: u64,
        src_cancellation: u64,
        src_public_cancellation: u64,

        // Destination chain timelocks
        dst_withdrawal: u64,
        dst_public_withdrawal: u64,
        dst_cancellation: u64,

        // Deploy timestamp (when escrow was created)
        deployed_at: u64
    }

    const SRC_WITHDRAWAL: u8 = 0;
    const SRC_PUBLIC_WITHDRAWAL: u8 = 1;
    const SRC_CANCELLATION: u8 = 2;
    const SRC_PUBLIC_CANCELLATION: u8 = 3;
    const DST_WITHDRAWAL: u8 = 4;
    const DST_PUBLIC_WITHDRAWAL: u8 = 5;
    const DST_CANCELLATION: u8 = 6;

    // To create timelock
    public fun create_timelock (src_withdrawal: u64,src_public_withdrawal: u64,src_cancellation: u64,src_public_cancellation: u64,
    dst_withdrawal: u64,dst_public_withdrawal: u64,dst_cancellation: u64,): Timelocks {
       Timelocks {
        src_withdrawal,
        src_public_withdrawal,
        src_cancellation,
        src_public_cancellation,
        dst_withdrawal,
        dst_public_withdrawal,
        dst_cancellation,
        deployed_at: 0
       }
    }

    // set deploy timestamp
    public fun set_deploy_timestamp(timelock: &mut Timelocks, timestamp: u64){
        timelock.deployed_at = timestamp;
    }

    // Get start time for rescue period
    public fun rescue_start(timelock: &Timelocks, rescue_delay: u64): u64 {
       timelock.deployed_at + rescue_delay
    }

    public fun get_src_withdrawal(timelock: &Timelocks): u64 {
        timelock.src_withdrawal
    }
    public fun get_src_public_withdrawal(timelock: &Timelocks): u64 {
        timelock.src_public_withdrawal
    }
    public fun get_src_cancellation(timelock: &Timelocks): u64 {
        timelock.src_cancellation
    }

    public fun get_dst_withdrawal(timelock: &Timelocks): u64 {
        timelock.dst_withdrawal
    }

    public fun get_dst_public_withdrawal(timelock: &Timelocks): u64 {
        timelock.dst_public_withdrawal
    }

    public fun get_dst_cancellation(timelock: &Timelocks): u64 {
        timelock.dst_cancellation
    }
    

    // Get time when a stage becomes active
    public fun get(timelock: &Timelocks, stage: u8): u64{
        let offset = if (stage == SRC_WITHDRAWAL){
            timelock.src_withdrawal
        } else if (stage == SRC_PUBLIC_WITHDRAWAL){
            timelock.src_public_withdrawal
        } else if (stage == SRC_CANCELLATION){
            timelock.src_cancellation
        } else if (stage == SRC_PUBLIC_CANCELLATION){
            timelock.src_public_cancellation
        } else if (stage == DST_WITHDRAWAL){
            timelock.dst_withdrawal
        } else if (stage == DST_PUBLIC_WITHDRAWAL){
            timelock.dst_public_withdrawal
        } else if (stage == DST_CANCELLATION){
            timelock.dst_cancellation
        } else {
            abort 1
        };

        timelock.deployed_at + offset
    }

}