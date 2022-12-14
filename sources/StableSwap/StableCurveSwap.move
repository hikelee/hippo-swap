module hippo_swap::stable_curve_swap {
    use std::string;
    use std::option;
    use aptos_framework::coin;
    use aptos_framework::timestamp;

    use hippo_swap::hippo_config;
    use hippo_swap::stable_curve_numeral;
    use hippo_swap::math;
    use std::signer;

    // Token

    struct LPToken<phantom X, phantom Y> {}

    struct LPCapability<phantom X, phantom Y> has key, store {
        mint_cap: coin::MintCapability<LPToken<X, Y>>,
        burn_cap: coin::BurnCapability<LPToken<X, Y>>,
    }

    // Swap

    struct StableCurvePoolInfo<phantom X, phantom Y> has key {
        disabled: bool,
        reserve_x: coin::Coin<X>,
        reserve_y: coin::Coin<Y>,
        fee_x: coin::Coin<X>,
        fee_y: coin::Coin<Y>,
        lp_precision: u64,
        // example: 1000000
        multiplier_x: u64,
        // example: 100
        multiplier_y: u64,
        // example: 1
        //lp_precision is the max value of decimal x and y
        fee: u64,           // Fee percentage that should be divided by the constant FEE_DENOMINATOR (10**6)
        admin_fee: u64,     // Fee percentage that should be divided by the constant FEE_DENOMINATOR (10**6)
        // fee = admin_fee + fee_for_liquidity_provider
        initial_A: u64,
        future_A: u64,
        initial_A_time: u64,
        future_A_time: u64,
    }

    const MIN_RAMP_TIME: u64 = 86400;
    const FEE_DENOMINATOR: u128 = 1000000;     // 10 ** 6


    const MAX_ADMIN_FEE: u64 = 1000000;
    const MAX_FEE: u64 = 500000;
    const MAX_A: u64 = 1000000;
    const MAX_A_CHANGE: u64 = 10;

    const ERROR_ALREADY_INITIALIZED: u64 = 1;
    const ERROR_ITERATE_END: u64 = 1000;
    const ERROR_EXCEEDED: u64 = 1001;
    // 10 ** 10
    const ERROR_SWAP_INVALID_TOKEN_PAIR: u64 = 2000;
    const ERROR_SWAP_PRECONDITION: u64 = 2001;
    const ERROR_SWAP_PRIVILEGE_INSUFFICIENT: u64 = 2003;
    const ERROR_SWAP_BURN_CALC_INVALID: u64 = 2004;
    const ERROR_SWAP_ADDLIQUIDITY_INVALID: u64 = 2007;
    const ERROR_SWAP_TOKEN_NOT_EXISTS: u64 = 2008;
    const ERROR_SWAP_RAMP_TIME: u64 = 2009;
    const ERROR_SWAP_A_VALUE: u64 = 2010;
    const ERROR_SWAP_INVALID_DERIVIATION: u64 = 2020;


    // Token utilities

    fun assert_admin(signer: &signer) {
        assert!(signer::address_of(signer) == hippo_config::admin_address(), ERROR_SWAP_PRIVILEGE_INSUFFICIENT);
    }

    fun initialize_coin<X, Y>(signer: &signer, name: string::String, symbol: string::String, decimals: u64) {
        let addr = signer::address_of(signer);
        assert!(!exists<StableCurvePoolInfo<X, Y>>(addr), ERROR_ALREADY_INITIALIZED);
        assert!(!exists<StableCurvePoolInfo<Y, X>>(addr), ERROR_ALREADY_INITIALIZED);
        assert!(coin::is_coin_initialized<X>(), ERROR_SWAP_INVALID_TOKEN_PAIR);
        assert!(coin::is_coin_initialized<Y>(), ERROR_SWAP_INVALID_TOKEN_PAIR);
        let (mint_capability, burn_capability) = coin::initialize<LPToken<X, Y>>(
            signer, name, symbol, decimals, true
        );
        coin::register_internal<LPToken<X, Y>>(signer);
        move_to(signer, LPCapability<X, Y>{ mint_cap: mint_capability, burn_cap: burn_capability });
    }

    fun mint<X, Y>(amount: u64): coin::Coin<LPToken<X, Y>> acquires LPCapability {
        let liquidity_cap = borrow_global<LPCapability<X, Y>>(hippo_config::admin_address());
        let mint_token = coin::mint<LPToken<X, Y>>(amount, &liquidity_cap.mint_cap);
        mint_token
    }

    fun burn<X, Y>(to_burn: coin::Coin<LPToken<X, Y>>,
    ) acquires LPCapability {
        let liquidity_cap = borrow_global<LPCapability<X, Y>>(hippo_config::admin_address());
        coin::burn<LPToken<X, Y>>(to_burn, &liquidity_cap.burn_cap);
    }

    public fun balance<X, Y>(addr: address): u64 {
        coin::balance<LPToken<X, Y>>(addr)
    }

    fun check_and_deposit<TokenType>(to: &signer, coin: coin::Coin<TokenType>) {
        if(!coin::is_account_registered<TokenType>(signer::address_of(to))) {
            coin::register_internal<TokenType>(to);
        };
        coin::deposit(signer::address_of(to), coin);
    }

    #[test_only]
    fun init_mock_coin<Money: store>(creator: &signer): coin::Coin<Money> {
        use hippo_swap::mock_coin;
        mock_coin::initialize<Money>(creator, 9);
        mock_coin::mint<Money>(20)
    }

    #[test(admin = @hippo_swap)]
    fun mint_mock_coin(admin: &signer) acquires LPCapability {
        use hippo_swap::mock_coin;
        let decimals = 6;
        mock_coin::initialize<hippo_swap::mock_coin::WETH>(admin, decimals);
        mock_coin::initialize<hippo_swap::mock_coin::WDAI>(admin, decimals);
        initialize_coin<hippo_swap::mock_coin::WETH, hippo_swap::mock_coin::WDAI>(
            admin,
            string::utf8(b"Curve:WETH-WDAI"),
            string::utf8(b"WEWD"),
            decimals
        );
        let coin = mint<hippo_swap::mock_coin::WETH, hippo_swap::mock_coin::WDAI>(1000000);
        burn(coin)
    }

    fun create_pool_info<X, Y>(
        lp_precision: u64,
        multiplier_x: u64,
        multiplier_y: u64,
        initial_A: u64,
        future_A: u64,
        initial_A_time: u64,
        future_A_time: u64,
        fee: u64,
        admin_fee: u64,
    ): StableCurvePoolInfo<X, Y> {
        StableCurvePoolInfo<X, Y>{
            disabled: false,
            reserve_x: coin::zero<X>(),
            reserve_y: coin::zero<Y>(),
            fee_x: coin::zero<X>(),
            fee_y: coin::zero<Y>(),
            lp_precision,
            multiplier_x,
            multiplier_y,
            fee,
            admin_fee,
            initial_A,
            future_A,
            initial_A_time,
            future_A_time,
        }
    }

    public fun initialize<X, Y>(
        signer: &signer, lp_name: string::String, lp_symbol: string::String, lp_decimal: u64,
        initial_A: u64, future_A: u64, initial_A_time: u64, future_A_time: u64,
        fee: u64, admin_fee: u64
    ) {
        assert_admin(signer);
        let (x_decimal, y_decimal) = (coin::decimals<X>(), coin::decimals<Y>());
        let lp_precision = (math::pow(10, (lp_decimal as u8)) as u64);
        let x_rate = (math::pow(10, ((lp_decimal - x_decimal) as u8)) as u64);
        let y_rate = (math::pow(10, ((lp_decimal - y_decimal) as u8)) as u64);
        initialize_coin<X, Y>(signer, lp_name, lp_symbol, (lp_precision as u64));
        let token_pair = create_pool_info<X, Y>(
            lp_precision, x_rate, y_rate, initial_A, future_A, initial_A_time, future_A_time, fee, admin_fee
        );
        move_to(signer, token_pair);
    }

    fun get_current_A(initial_A: u64, future_A: u64, initial_A_time: u64, future_A_time: u64): u64 {
        let block_timestamp = timestamp::now_microseconds();
        stable_curve_numeral::get_A(initial_A,  future_A, initial_A_time,  future_A_time, block_timestamp)
    }

    fun get_xp_mem(reserve_x: u64, reserve_y: u64, multiplier_x: u64, multiplier_y: u64): (u64, u64) {
        (multiplier_x * reserve_x, multiplier_y * reserve_y)
    }

    fun get_D_flat(amount_x: u64, amount_y: u64, amp: u64, multiplier_x: u64, multiplier_y: u64): u128 {
        stable_curve_numeral::get_D(((multiplier_x * amount_x) as u128), ((multiplier_y * amount_y) as u128), amp)
    }

    public fun add_liquidity_direct<X, Y>(x: coin::Coin<X>, y: coin::Coin<Y>,
    ): (coin::Coin<X>, coin::Coin<Y>, coin::Coin<LPToken<X, Y>>)
    acquires StableCurvePoolInfo, LPCapability {

        let p = borrow_global<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
        let ( reserve_amt_x, reserve_amt_y ) = (coin::value(&p.reserve_x), coin::value(&p.reserve_y));
        let x_value_prev = coin::value<X>(&x);
        let y_value_prev = coin::value<Y>(&y);

        let amp = get_current_A(p.initial_A, p.future_A, p.initial_A_time, p.future_A_time);
        let d0 = get_D_flat(reserve_amt_x, reserve_amt_y, amp, p.multiplier_x, p.multiplier_y);

        let token_supply = (*option::borrow(&mut coin::supply<LPToken<X, Y>>()) as u128);

        if (token_supply == 0) {
            assert!(x_value_prev > 0, ERROR_SWAP_ADDLIQUIDITY_INVALID);
            assert!(y_value_prev > 0, ERROR_SWAP_ADDLIQUIDITY_INVALID);
        };
        let (new_reserve_x, new_reserve_y) = (reserve_amt_x + x_value_prev, reserve_amt_y + y_value_prev);

        let d1 = get_D_flat(new_reserve_x, new_reserve_y, amp, p.multiplier_x, p.multiplier_y);
        assert!(d1 > d0, ERROR_SWAP_INVALID_DERIVIATION);

        let mint_amount;
        if (token_supply > 0) {
            let fee = p.fee * 2 / 4;

            let (n_b_x, _r_b_x, fee_x) = calc_reserve_and_fees((new_reserve_x as u128), (reserve_amt_x as u128), d0, d1, (fee as u128), (p.admin_fee as u128));
            let (n_b_y, _r_b_y, fee_y) = calc_reserve_and_fees((new_reserve_y as u128), (reserve_amt_y as u128), d0, d1, (fee as u128), (p.admin_fee as u128));
            let d2 = get_D_flat((n_b_x as u64), (n_b_y as u64), amp, p.multiplier_x, p.multiplier_y);
            // x --> fee (fee), reserve (admin)
            let fee_coin_x = coin::extract(&mut x, (fee_x as u64));
            let fee_coin_y = coin::extract(&mut y, (fee_y as u64));
            let token_pair = borrow_global_mut<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
            coin::merge(&mut token_pair.reserve_x, x);
            coin::merge(&mut token_pair.reserve_y, y);
            coin::merge(&mut token_pair.fee_x, fee_coin_x);
            coin::merge(&mut token_pair.fee_y, fee_coin_y);
            mint_amount = token_supply * (d2 - d0) / d0;
        } else {
            mint_amount = d1;
            let token_pair = borrow_global_mut<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
            coin::merge(&mut token_pair.reserve_x, x);
            coin::merge(&mut token_pair.reserve_y, y);
        };
        let mint_token = mint<X, Y>((mint_amount as u64));
        (coin::zero<X>(), coin::zero<Y>(), mint_token)
    }

    fun calc_reserve_and_fees(
        new_reserve: u128, old_reserve: u128, d0: u128, d1: u128, average_fee: u128, admin_fee: u128
    ): (u128, u128, u128) {
        let ideal_reserve = d1 * old_reserve / d0;
        let difference;
        if (ideal_reserve > new_reserve) {
            difference = ideal_reserve - new_reserve;
        } else {
            difference = new_reserve - ideal_reserve;
        };
        let fee_amount = average_fee * difference / FEE_DENOMINATOR ;

        let admin_fee_amount = fee_amount * admin_fee / FEE_DENOMINATOR;
        let real_balance = new_reserve - admin_fee_amount; // (fee * admin_fee / FEE_DENOMINATOR);
        let name_balance = new_reserve - fee_amount;
        (name_balance, real_balance, admin_fee_amount)
    }

    public fun add_liquidity<X, Y>(sender: &signer, amount_x: u64, amount_y: u64): (u64, u64, u64) acquires StableCurvePoolInfo, LPCapability {
        let x_coin = coin::withdraw<X>(sender, amount_x);
        let y_coin = coin::withdraw<Y>(sender, amount_y);
        let (x, y, minted_lp_token) = add_liquidity_direct(x_coin, y_coin);
        let addr = signer::address_of(sender);
        let lp_amt = coin::value<LPToken<X, Y>>(&minted_lp_token);
        coin::deposit(addr, x);
        coin::deposit(addr, y);
        check_and_deposit(sender, minted_lp_token);
        (amount_x, amount_y, lp_amt)
    }

    fun get_y(i: u64, dx: u64, xp: u64, yp: u64, initial_A: u64, initial_A_time: u64, future_A: u64, future_A_time: u64): u64 {
        let amp = get_current_A(initial_A, future_A, initial_A_time, future_A_time);
        let d = stable_curve_numeral::get_D((xp as u128), (yp as u128), amp);
        let x = if (i == 0) dx + xp else dx + yp;
        (stable_curve_numeral::get_y(x, amp, d) as u64)
    }

    public fun swap_x_to_exact_y_direct<X, Y>(coins_in: coin::Coin<X>): (coin::Coin<X>, coin::Coin<X>, coin::Coin<Y>) acquires StableCurvePoolInfo {

        let p = borrow_global<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
        let ( reserve_amt_x, reserve_amt_y ) = (coin::value(&p.reserve_x), coin::value(&p.reserve_y));

        let (xp, yp) = get_xp_mem(reserve_amt_x, reserve_amt_y, p.multiplier_x, p.multiplier_y);
        let i = 0;
        let dx = coin::value(&coins_in);
        let dx_rated = dx * p.multiplier_x;
        let y = get_y(i, dx_rated, xp, yp, p.initial_A, p.initial_A_time, p.future_A, p.future_A_time);

        let amount_dy = ( yp - y - 1) / p.multiplier_y;
        let amount_dy_fee = amount_dy * p.fee / (FEE_DENOMINATOR as u64);
        let charged_amt_dy = (amount_dy - amount_dy_fee);

        let dy_admin_fee = amount_dy_fee * p.admin_fee / (FEE_DENOMINATOR as u64);

        let swap_pair = borrow_global_mut<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());

        coin::merge(&mut swap_pair.reserve_x, coins_in);
        let coin_dy = coin::extract<Y>(&mut swap_pair.reserve_y, charged_amt_dy);
        let coin_fee = coin::extract<Y>(&mut swap_pair.reserve_y, dy_admin_fee);
        coin::merge(&mut swap_pair.fee_y, coin_fee);
        (coin::zero<X>(), coin::zero<X>(), coin_dy)
    }


    public fun swap_y_to_exact_x_direct<X, Y>(coins_in: coin::Coin<Y>): (coin::Coin<Y>, coin::Coin<X>, coin::Coin<Y>) acquires StableCurvePoolInfo {

        let p = borrow_global<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
        let ( reserve_amt_x, reserve_amt_y ) = (coin::value(&p.reserve_x), coin::value(&p.reserve_y));

        let (xp, yp) = get_xp_mem(reserve_amt_x, reserve_amt_y, p.multiplier_x, p.multiplier_y);

        let i = 1;
        let dy = coin::value(&coins_in);
        let dy_rated = dy * p.multiplier_y;
        let x = get_y(i, dy_rated, xp, yp, p.initial_A, p.initial_A_time, p.future_A, p.future_A_time);

        let amount_dx = (xp - x - 1 )  / p.multiplier_x;
        let amount_dx_fee = amount_dx * p.fee / (FEE_DENOMINATOR as u64);
        let charged_amt_dx = (amount_dx - amount_dx_fee);

        let dx_admin_fee = amount_dx_fee * p.admin_fee / (FEE_DENOMINATOR as u64);

        let swap_pair = borrow_global_mut<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());

        coin::merge(&mut swap_pair.reserve_y, coins_in);
        let coin_dx = coin::extract<X>(&mut swap_pair.reserve_x, charged_amt_dx);
        let coin_fee = coin::extract<X>(&mut swap_pair.reserve_x, dx_admin_fee);
        coin::merge(&mut swap_pair.fee_x, coin_fee);
        (coin::zero<Y>(), coin_dx, coin::zero<Y>(),)
    }


    public fun swap_x_to_exact_y<X, Y>(sender: &signer, amount_in: u64, to: address): (u64, u64, u64) // x-in, x-out, y-out
    acquires StableCurvePoolInfo {
        let coin_x = coin::withdraw<X>(sender, amount_in);
        let (x_remain, x_out, coin_y) = swap_x_to_exact_y_direct<X, Y>(coin_x);
        let out_amount = coin::value(&coin_y);
        coin::merge(&mut x_out, x_remain);
        coin::deposit(to, x_out);
        coin::deposit(to, coin_y);
        (amount_in, 0, out_amount)
    }

    public fun swap_y_to_exact_x<X, Y>(sender: &signer, amount_in: u64, to: address): (u64, u64, u64) // x-in, x-out, y-out
    acquires StableCurvePoolInfo {
        let coin_y = coin::withdraw<Y>(sender, amount_in);
        let (y_remain, x_out, y_out) = swap_y_to_exact_x_direct<X, Y>(coin_y);
        let out_amount = coin::value(&x_out);
        coin::merge(&mut y_out, y_remain);
        coin::deposit(to, x_out);
        coin::deposit(to, y_out);
        (amount_in, out_amount, 0)
    }

    public fun withdraw_liquidity<X, Y>(to_burn: coin::Coin<LPToken<X, Y>>): (coin::Coin<X>, coin::Coin<Y>) acquires StableCurvePoolInfo, LPCapability {
        let to_burn_value = (coin::value(&to_burn) as u128);
        let swap_pair = borrow_global_mut<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
        let reserve_x = (coin::value(&swap_pair.reserve_x) as u128);
        let reserve_y =  (coin::value(&swap_pair.reserve_y) as u128);
        let total_supply = (*option::borrow(&mut coin::supply<LPToken<X, Y>>()) as u128);
        let x = ((to_burn_value * reserve_x / total_supply) as u64);
        let y = ((to_burn_value * reserve_y / total_supply) as u64);
        burn<X, Y>(to_burn);
        let coin_x = coin::extract(&mut swap_pair.reserve_x, x);
        let coin_y = coin::extract(&mut swap_pair.reserve_y, y);
        (coin_x, coin_y)
    }

    public fun remove_liquidity<X, Y>(
        sender: &signer,
        liquidity: u64,
        min_amount_x: u64,
        min_amount_y: u64,
    ): (u64, u64) acquires StableCurvePoolInfo, LPCapability {
        let coin = coin::withdraw<LPToken<X, Y>>(sender, liquidity);
        let (coin_x, coin_y) = withdraw_liquidity<X, Y>(coin);
        let (amount_x, amount_y ) = (coin::value<X>(&coin_x), coin::value<Y>(&coin_y));
        assert!(amount_x > min_amount_x, ERROR_SWAP_PRECONDITION);
        assert!(amount_y > min_amount_y, ERROR_SWAP_PRECONDITION);
        coin::deposit(signer::address_of(sender), coin_x);
        coin::deposit(signer::address_of(sender), coin_y);
        (amount_x, amount_y)
    }

    public fun ramp_A<X, Y>(account: &signer, new_future_A: u64, future_time: u64)acquires StableCurvePoolInfo {
        assert_admin(account);
        let p = borrow_global<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
        let block_timestamp = timestamp::now_microseconds();
        assert!(block_timestamp >= p.initial_A_time + MIN_RAMP_TIME, ERROR_SWAP_RAMP_TIME);
        assert!(future_time >= block_timestamp + MIN_RAMP_TIME, ERROR_SWAP_RAMP_TIME);

        let initial_A = get_current_A(p.initial_A, p.future_A, p.initial_A_time, p.future_A_time);
        let future_A_p = new_future_A;
        let cond_a = new_future_A > 0;
        let cond_b = new_future_A < MAX_A;
        assert!( cond_a && cond_b , ERROR_SWAP_A_VALUE);

        if (future_A_p < initial_A) {
            assert!(future_A_p * MAX_A_CHANGE >= initial_A, ERROR_SWAP_A_VALUE);
        } else {
            assert!(future_A_p <= initial_A * MAX_A_CHANGE, ERROR_SWAP_A_VALUE);
        };

        let pair = borrow_global_mut<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
        pair.initial_A = initial_A;
        pair.future_A = future_A_p;
        pair.initial_A_time = block_timestamp;
        pair.future_A_time = future_time;
    }

    public fun stop_ramp_A<X, Y>(account: &signer) acquires StableCurvePoolInfo {
        assert_admin(account);
        let p = borrow_global<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());

        let current_A = get_current_A( p.initial_A, p.future_A, p.initial_A_time, p.future_A_time);
        let block_timestamp = timestamp::now_microseconds();
        let pair = borrow_global_mut<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
        pair.initial_A = current_A;
        pair.future_A = current_A;
        pair.initial_A_time = block_timestamp;
        pair.future_A_time = block_timestamp;
    }

    // Tests

    // Swap utilities
    #[test_only]
    public fun get_pool_info<X, Y>():(bool, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64) acquires StableCurvePoolInfo {
        let i = borrow_global<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
        return (
            i.disabled,
            coin::value(&i.reserve_x),
            coin::value(&i.reserve_y),
            coin::value(&i.fee_x),
            coin::value(&i.fee_y),
            i.lp_precision,
            i.multiplier_x,
            i.multiplier_y,
            i.fee,
            i.admin_fee,
            i.initial_A,
            i.future_A,
            i.initial_A_time,
            i.future_A_time
        )
        // example:
        // let (disabled, reserve_amt_x, reserve_amt_y, fee_amt_x, fee_amt_y, lp_precision, multiplier_x, multiplier_y, fee_param, admin_fee_param,
        //      initial_A, future_A, initial_A_time, future_A_time) = get_pool_info<X, Y>();
    }

    #[test_only]
    public fun get_reserve_amounts<X, Y>(): (u64, u64) acquires StableCurvePoolInfo {
        let i = borrow_global<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
        return (coin::value(&i.reserve_x), coin::value(&i.reserve_y))
    }

    #[test_only]
    public fun get_fee_amounts<X, Y>(): (u64, u64) acquires StableCurvePoolInfo {
        let i = borrow_global<StableCurvePoolInfo<X, Y>>(hippo_config::admin_address());
        return (coin::value(&i.fee_x), coin::value(&i.fee_y))
    }

    #[test_only]
    fun genesis(core: &signer, vm: &signer) {
        use aptos_framework::genesis;
        genesis::setup(core);
        update_time(vm, time(0));
    }

    #[test_only]
    fun update_time(account: &signer, time: u64) {
        use aptos_framework::timestamp;
        timestamp::update_global_time(account, @0x1000010, time);
    }

    #[test_only]
    fun time(offset_seconds: u64): u64 {
        let epoch = 1653289287000000;  // 2022-05-23 15:01:27
        epoch + offset_seconds * 1000000
    }

    #[test_only]
    fun mock_curve_params(): (u64, u64, u64, u64) {
        let initial_A = 100;        // 3 * (10**6)
        let future_A = 200;        // 3.5 * (10**6)
        let initial_A_time = time(0);
        let future_A_time = time(3600);
        (initial_A, future_A, initial_A_time, future_A_time)
    }

    #[test_only]
    fun init_lp_token(admin: &signer, core: &signer, vm: &signer) {
        use hippo_swap::mock_coin;
        genesis(core, vm);

        mock_coin::initialize<mock_coin::WETH>(admin, 6);
        mock_coin::initialize<mock_coin::WDAI>(admin, 6);
        let (ia, fa, iat, fat) = mock_curve_params();
        let (fee, admin_fee) = (3000, 200000);
        initialize<hippo_swap::mock_coin::WETH, hippo_swap::mock_coin::WDAI>(
            admin,
            string::utf8(b"Curve:WETH-WDAI"),
            string::utf8(b"WEWD"),
            6,
            ia, fa, iat, fat, fee, admin_fee
        );
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    fun mint_lptoken_coin(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo, LPCapability {
        use std::signer;
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));
        let x = mock_coin::mint<mock_coin::WETH>(10000000);
        let y = mock_coin::mint<mock_coin::WDAI>(10000000);
        let (x_remain, y_remain, liquidity) = add_liquidity_direct(x, y);
        let (x, y) = withdraw_liquidity(liquidity);
        let addr = signer::address_of(admin);
        coin::deposit(addr, x);
        coin::deposit(addr, y);
        coin::deposit(addr, x_remain);
        coin::deposit(addr, y_remain);
    }


    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    #[expected_failure(abort_code = 2003)]
    public fun fail_assert_admin(core: &signer) {
        assert_admin(core);
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    #[expected_failure(abort_code = 2007)]
    public fun fail_add_liquidity(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo, LPCapability {
        use std::signer;
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));

        let x = mock_coin::mint<mock_coin::WETH>(0);
        let y = mock_coin::mint<mock_coin::WDAI>(0);
        let (x_remain, y_remain, liquidity) = add_liquidity_direct(x, y);
        coin::deposit(signer::address_of(admin), liquidity);
        coin::deposit(signer::address_of(admin), x_remain);
        coin::deposit(signer::address_of(admin), y_remain)
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    #[expected_failure(abort_code = 2007)]
    public fun fail_add_liquidity_y(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo, LPCapability {
        use std::signer;
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));

        let x = mock_coin::mint<mock_coin::WETH>(20);
        let y = mock_coin::mint<mock_coin::WDAI>(0);
        let (x_remain, y_remain, liquidity) = add_liquidity_direct(x, y);
        coin::deposit(signer::address_of(admin), liquidity);
        coin::deposit(signer::address_of(admin), x_remain);
        coin::deposit(signer::address_of(admin), y_remain)
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    #[expected_failure(abort_code = 2020)]
    public fun fail_add_liquidity_d1(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo, LPCapability {
        use std::signer;
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));
        let trader_addr = signer::address_of(admin);
        let x = mock_coin::mint<mock_coin::WETH>(100000000);
        let y = mock_coin::mint<mock_coin::WDAI>(100000000);
        coin::deposit(trader_addr, x);
        coin::deposit(trader_addr, y);
        add_liquidity<mock_coin::WETH, mock_coin::WDAI>(admin, 7000000, 2000000);
        let x = mock_coin::mint<mock_coin::WETH>(0);
        let y = mock_coin::mint<mock_coin::WDAI>(0);
        let (x_remain, y_remain, liquidity) = add_liquidity_direct(x, y);
        coin::deposit(signer::address_of(admin), liquidity);
        coin::deposit(signer::address_of(admin), x_remain);
        coin::deposit(signer::address_of(admin), y_remain)
    }

    #[test(admin = @hippo_swap)]
    #[expected_failure(abort_code = 2000)]
    public fun fail_x(admin: &signer) {
        initialize_coin<hippo_swap::mock_coin::WETH, hippo_swap::mock_coin::WDAI>(
            admin, string::utf8(b"Curve:WETH-WDAI"), string::utf8(b"WEWD"), 1000000);
    }

    #[test(admin = @hippo_swap)]
    #[expected_failure(abort_code = 2000)]
    public fun fail_y(admin: &signer) {
        use hippo_swap::mock_coin;
        mock_coin::initialize<hippo_swap::mock_coin::WETH>(admin, 6);
        initialize_coin<hippo_swap::mock_coin::WETH, hippo_swap::mock_coin::WDAI>(
            admin, string::utf8(b"Curve:WETH-WDAI"), string::utf8(b"WEWD"), 1000000);
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    fun test_swap_pair_case_A(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo {
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        let swap_pair = borrow_global_mut<StableCurvePoolInfo<mock_coin::WETH, mock_coin::WDAI>>(hippo_config::admin_address());
        update_time(vm, time(3500));
        let block_timestamp = timestamp::now_seconds();
        swap_pair.future_A_time = block_timestamp + 2;
        swap_pair.future_A = 20;
        swap_pair.initial_A = 4;

        let p = borrow_global<StableCurvePoolInfo<mock_coin::WETH, mock_coin::WDAI>>(hippo_config::admin_address());
        let k = get_current_A( p.initial_A, p.future_A, p.initial_A_time, p.future_A_time);

        std::debug::print(&k)
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    fun test_swap_pair_case_B(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo {
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        let swap_pair = borrow_global_mut<StableCurvePoolInfo<mock_coin::WETH, mock_coin::WDAI>>(hippo_config::admin_address());
        update_time(vm, time(10000));
        let block_timestamp = timestamp::now_seconds();
        swap_pair.future_A_time = block_timestamp + 200;
        swap_pair.future_A = 4;
        swap_pair.initial_A = 20;

        let p = borrow_global<StableCurvePoolInfo<mock_coin::WETH, mock_coin::WDAI>>(hippo_config::admin_address());
        let k = get_current_A( p.initial_A, p.future_A, p.initial_A_time, p.future_A_time);

        std::debug::print(&k);
    }


    #[test(admin = @hippo_swap, core = @core_resources, vm = @0, trader = @0xFFFFFF01, )]
    fun mock_add_liquidity(admin: &signer, core: &signer, vm: &signer, trader: &signer) acquires StableCurvePoolInfo, LPCapability {
        use std::signer;
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));
        let trader_addr = signer::address_of(trader);
        coin::register_internal<mock_coin::WETH>(trader);
        coin::register_internal<mock_coin::WDAI>(trader);
        coin::register_internal<LPToken<mock_coin::WETH, mock_coin::WDAI>>(trader);
        let x = mock_coin::mint<mock_coin::WETH>(100000000);
        let y = mock_coin::mint<mock_coin::WDAI>(100000000);
        coin::deposit(trader_addr, x);
        coin::deposit(trader_addr, y);

        add_liquidity<mock_coin::WETH, mock_coin::WDAI>(trader, 7000000, 2000000);
        std::debug::print(&coin::balance<LPToken<mock_coin::WETH, mock_coin::WDAI>>(trader_addr));
        add_liquidity<mock_coin::WETH, mock_coin::WDAI>(trader, 21000000, 38200000);
        std::debug::print(&coin::balance<LPToken<mock_coin::WETH, mock_coin::WDAI>>(trader_addr));
        let (x, y) = remove_liquidity<mock_coin::WETH, mock_coin::WDAI>(trader, 1000000, 2000, 2000);
        std::debug::print(&x);
        std::debug::print(&y);
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    fun test_exchange_coin(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo, LPCapability {
        use std::signer;
        use hippo_swap::mock_coin;
        let addr = signer::address_of(admin);
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));
        let x = mock_coin::mint<mock_coin::WETH>(2000000);
        let y = mock_coin::mint<mock_coin::WDAI>(10000000);
        let (left_x, left_y, liquidity) = add_liquidity_direct(x, y);
        let a = mock_coin::mint<mock_coin::WETH>(2000000);
        let (x_remain, x_out, b) = swap_x_to_exact_y_direct<mock_coin::WETH, mock_coin::WDAI>(a);
        coin::deposit(addr, liquidity);
        coin::deposit(addr, x_remain);
        coin::deposit(addr, x_out);
        coin::deposit(addr, b);
        coin::deposit(addr, left_x);
        coin::deposit(addr, left_y);
    }


    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    fun test_ramp_A_stop_ramp_A(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo {
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));
        ramp_A<mock_coin::WETH, mock_coin::WDAI>(admin, 300, time( 10000));
        update_time(vm, time(300));
        stop_ramp_A<mock_coin::WETH, mock_coin::WDAI>(admin);
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    #[expected_failure(abort_code = 2009)]
    fun test_fail_ramp_A_timestamp(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo {
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));
        ramp_A<mock_coin::WETH, mock_coin::WDAI>(admin, 300, time(10000));
        ramp_A<mock_coin::WETH, mock_coin::WDAI>(admin, 400, time(10000));
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    #[expected_failure(abort_code = 2009)]
    fun test_fail_ramp_A_future_time(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo {
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));
        ramp_A<mock_coin::WETH, mock_coin::WDAI>(admin, 300, 10000);
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    #[expected_failure(abort_code = 2010)]
    fun test_fail_ramp_A_future_A_value(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo {
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));
        ramp_A<mock_coin::WETH, mock_coin::WDAI>(admin, 3000000000, time(10000));
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    #[expected_failure(abort_code = 2010)]
    fun test_fail_ramp_A_future_A_value_b(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo {
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));
        ramp_A<mock_coin::WETH, mock_coin::WDAI>(admin, 2, time(10000));
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0)]
    #[expected_failure(abort_code = 2010)]
    fun test_fail_ramp_A_future_A_value_c(admin: &signer, core: &signer, vm: &signer) acquires StableCurvePoolInfo {
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));
        ramp_A<mock_coin::WETH, mock_coin::WDAI>(admin, 20000, time(10000));
    }


    #[test_only]
    fun init_with_liquidity(admin: &signer, core: &signer, vm: &signer, trader: &signer) acquires StableCurvePoolInfo, LPCapability {
        use std::signer;
        use hippo_swap::mock_coin;
        init_lp_token(admin, core, vm);
        update_time(vm, time(200));
        let trader_addr = signer::address_of(trader);
        coin::register_internal<mock_coin::WETH>(trader);
        coin::register_internal<mock_coin::WDAI>(trader);
        coin::register_internal<LPToken<mock_coin::WETH, mock_coin::WDAI>>(trader);
        let x = mock_coin::mint<mock_coin::WETH>(100000000);
        let y = mock_coin::mint<mock_coin::WDAI>(100000000);
        coin::deposit(trader_addr, x);
        coin::deposit(trader_addr, y);

        add_liquidity<mock_coin::WETH, mock_coin::WDAI>(trader, 7000000, 2000000);
        add_liquidity<mock_coin::WETH, mock_coin::WDAI>(trader, 21000000, 38200000);
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0, trader = @0xFFFFFF01, )]
    #[expected_failure(abort_code = 2001)]
    fun test_fail_remove_liquidity_amount_x(admin: &signer, core: &signer, vm: &signer, trader: &signer) acquires StableCurvePoolInfo, LPCapability {
        use hippo_swap::mock_coin;
        init_with_liquidity(admin, core, vm, trader);
        remove_liquidity<mock_coin::WETH, mock_coin::WDAI>(trader, 1000000, 20000000, 2000);
    }

    #[test(admin = @hippo_swap, core = @core_resources, vm = @0, trader = @0xFFFFFF01, )]
    #[expected_failure(abort_code = 2001)]
    fun test_fail_remove_liquidity_amount_y(admin: &signer, core: &signer, vm: &signer, trader: &signer) acquires StableCurvePoolInfo, LPCapability {
        use hippo_swap::mock_coin;
        init_with_liquidity(admin, core, vm, trader);
        remove_liquidity<mock_coin::WETH, mock_coin::WDAI>(trader, 1000000, 2000, 200000000);
    }

}
