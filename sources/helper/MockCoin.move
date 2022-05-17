// token holder address, not admin address
address HippoSwap {
module MockCoin {
    use AptosFramework::Coin;
    use AptosFramework::TypeInfo;
    use Std::ASCII;

    struct TokenSharedCapability<phantom TokenType> has key, store {
        mint: Coin::MintCapability<TokenType>,
        burn: Coin::BurnCapability<TokenType>,
    }

    // mock ETH token
    struct WETH has copy, drop, store {}

    // mock USDT token
    struct WUSDT has copy, drop, store {}

    // mock DAI token
    struct WDAI has copy, drop, store {}

    // mock BTC token
    struct WBTC has copy, drop, store {}

    // mock DOT token
    struct WDOT has copy, drop, store {}


    public fun initialize<TokenType: store>(account: &signer, decimals: u64){
        let name = ASCII::string(TypeInfo::struct_name(&TypeInfo::type_of<TokenType>()));
        let (mint_capability, burn_capability) = Coin::initialize<TokenType>(
            account,
            name,
            name,
            decimals,
            true
        );
        Coin::register<TokenType>(account);

        move_to(account, TokenSharedCapability { mint: mint_capability, burn: burn_capability });
    }

    public fun mint<TokenType: store>(amount: u64): Coin::Coin<TokenType> acquires TokenSharedCapability{
        //token holder address
        let addr = TypeInfo::account_address(&TypeInfo::type_of<TokenType>());
        let cap = borrow_global<TokenSharedCapability<TokenType>>(addr);
        Coin::mint<TokenType>( amount, &cap.mint,)
    }

    public fun burn<TokenType: store>(tokens: Coin::Coin<TokenType>) acquires TokenSharedCapability{
        //token holder address
        let addr = TypeInfo::account_address(&TypeInfo::type_of<TokenType>());
        let cap = borrow_global<TokenSharedCapability<TokenType>>(addr);
        Coin::burn<TokenType>(tokens, &cap.burn);
    }
}

}

