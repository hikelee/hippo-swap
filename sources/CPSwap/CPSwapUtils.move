/// Uniswap v2 like token swap program
module hippo_swap::cp_swap_utils {
    use hippo_swap::safe_math;

    const ERROR_INSUFFICIENT_INPUT_AMOUNT: u64 = 0;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 1;
    const ERROR_INSUFFICIENT_AMOUNT: u64 = 2;

    public fun get_amount_out(
        amount_in: u64,
        reserve_in: u64,
        reserve_out: u64
    ): u64 {
        assert!(amount_in > 0, ERROR_INSUFFICIENT_INPUT_AMOUNT);
        assert!(reserve_in > 0 && reserve_out > 0, ERROR_INSUFFICIENT_LIQUIDITY);

        let amount_in_with_fee = safe_math::mul(
            (amount_in as u128),
            997u128
        );
        let numerator = safe_math::mul(amount_in_with_fee, (reserve_out as u128));
        let denominator = safe_math::mul((reserve_in as u128), 1000u128) + amount_in_with_fee;
        (safe_math::div(numerator, denominator) as u64)
    }

    public fun quote(amount_x: u64, reserve_x: u64, reserve_y: u64): u64 {
        assert!(amount_x > 0, ERROR_INSUFFICIENT_AMOUNT);
        assert!(reserve_x > 0 && reserve_y > 0, ERROR_INSUFFICIENT_LIQUIDITY);
        (safe_math::div(
            safe_math::mul(
                (amount_x as u128),
                (reserve_y as u128)
            ),
            (reserve_x as u128)
        ) as u64)
    }

    #[test]
    fun test_get_amount_out() {
        let a = get_amount_out(100, 10, 10);
        std::debug::print(&a);
        assert!(a > 0, 0);
    }
}