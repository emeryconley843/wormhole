module token_bridge::wrapped {
    use aptos_framework::account::{create_resource_account};
    use aptos_framework::signer::{address_of};
    use aptos_framework::coin::{Self, Coin, MintCapability, BurnCapability, FreezeCapability};

    use wormhole::vaa;

    use token_bridge::state;
    use token_bridge::asset_meta::{Self, AssetMeta};
    use token_bridge::deploy_coin::{deploy_coin};
    use token_bridge::vaa as token_bridge_vaa;
    use token_bridge::string32;

    friend token_bridge::complete_transfer;
    friend token_bridge::complete_transfer_with_payload;
    friend token_bridge::transfer_tokens;

    #[test_only]
    friend token_bridge::transfer_tokens_test;
    #[test_only]
    friend token_bridge::complete_transfer_test;
    #[test_only]
    friend token_bridge::wrapped_test;

    const E_IS_NOT_WRAPPED_ASSET: u64 = 0;
    const E_COIN_CAP_DOES_NOT_EXIST: u64 = 1;

    struct CoinCapabilities<phantom CoinType> has key, store {
        mint_cap: MintCapability<CoinType>,
        freeze_cap: FreezeCapability<CoinType>,
        burn_cap: BurnCapability<CoinType>,
    }

    // this function is called before create_wrapped_coin
    // TODO(csongor): document why these two are in separate transactions
    public entry fun create_wrapped_coin_type(vaa: vector<u8>): address {
        // NOTE: we do not do replay protection here, only verify that the VAA
        // comes from a known emitter. This is because `create_wrapped_coin`
        // itself will need to verify the VAA again in a separate transaction,
        // and it itself will perform the replay protection.
        // This function cannot be called twice with the same VAA because it
        // creates a resource account, which will fail the second time if the
        // account already exists.
        // TODO(csongor): should we implement a more explicit replay protection
        // for this function?
        // TODO(csongor): we could break this function up a little so it's
        // better testable. In particular, resource accounts are little hard to
        // test.
        let vaa = token_bridge_vaa::parse_and_verify(vaa);
        let asset_meta:AssetMeta = asset_meta::parse(vaa::destroy(vaa));
        let seed = asset_meta::create_seed(&asset_meta);

        //create resource account
        let token_bridge_signer = state::token_bridge_signer();
        let (new_signer, new_cap) = create_resource_account(&token_bridge_signer, seed);

        let token_address = asset_meta::get_token_address(&asset_meta);
        let token_chain = asset_meta::get_token_chain(&asset_meta);
        let origin_info = state::create_origin_info(token_chain, token_address);

        deploy_coin(&new_signer);
        state::set_wrapped_asset_signer_capability(origin_info, new_cap);

        // return address of the new signer
        address_of(&new_signer)
    }

    // this function is called in tandem with bridge_implementation::create_wrapped_coin_type
    // initializes a coin for CoinType, updates mappings in State
    public entry fun create_wrapped_coin<CoinType>(vaa: vector<u8>) {
        let vaa = token_bridge_vaa::parse_verify_and_replay_protect(vaa);
        let asset_meta: AssetMeta = asset_meta::parse(vaa::destroy(vaa));

        let native_token_address = asset_meta::get_token_address(&asset_meta);
        let native_token_chain = asset_meta::get_token_chain(&asset_meta);
        let native_info = state::create_origin_info(native_token_chain, native_token_address);

        // TODO: where do we check that CoinType corresponds to the thing in the VAA?
        // I think it's fine because only the correct signer can initialise the
        // coin, so it would fail, but we should have a test for this.
        let coin_signer = state::get_wrapped_asset_signer(native_info);
        init_wrapped_coin<CoinType>(&coin_signer, &asset_meta)
    }

    public(friend) fun init_wrapped_coin<CoinType>(
        coin_signer: &signer,
        asset_meta: &AssetMeta,
    ) {
        // initialize new coin using CoinType
        let name = asset_meta::get_name(asset_meta);
        let symbol = asset_meta::get_symbol(asset_meta);
        let decimals = asset_meta::get_decimals(asset_meta);
        let monitor_supply = true;
        let (burn_cap, freeze_cap, mint_cap)
            = coin::initialize<CoinType>(
                coin_signer,
                string32::to_string(&name),
                string32::to_string(&symbol),
                decimals,
                monitor_supply
            );

        let token_address = asset_meta::get_token_address(asset_meta);
        let token_chain = asset_meta::get_token_chain(asset_meta);
        let origin_info = state::create_origin_info(token_chain, token_address);

        // update the following two mappings in State
        // 1. (native chain, native address) => wrapped address
        // 2. wrapped address => (native chain, native address)
        state::setup_wrapped<CoinType>(coin_signer, origin_info);

        // store coin capabilities
        let token_bridge = state::token_bridge_signer();
        move_to(&token_bridge, CoinCapabilities { mint_cap, freeze_cap, burn_cap });
    }

    public(friend) fun mint<CoinType>(amount: u64): Coin<CoinType> acquires CoinCapabilities {
        assert!(state::is_wrapped_asset<CoinType>(), E_IS_NOT_WRAPPED_ASSET);
        assert!(exists<CoinCapabilities<CoinType>>(@token_bridge), E_COIN_CAP_DOES_NOT_EXIST);
        let caps = borrow_global<CoinCapabilities<CoinType>>(@token_bridge);
        let mint_cap = &caps.mint_cap;
        let coins = coin::mint<CoinType>(amount, mint_cap);
        coins
    }

    public(friend) fun burn<CoinType>(coins: Coin<CoinType>) acquires CoinCapabilities {
        assert!(state::is_wrapped_asset<CoinType>(), E_IS_NOT_WRAPPED_ASSET);
        assert!(exists<CoinCapabilities<CoinType>>(@token_bridge), E_COIN_CAP_DOES_NOT_EXIST);
        let caps = borrow_global<CoinCapabilities<CoinType>>(@token_bridge);
        let burn_cap = &caps.burn_cap;
        coin::burn<CoinType>(coins, burn_cap);
    }

}

#[test_only]
module token_bridge::wrapped_test {
    use aptos_framework::coin;
    use aptos_framework::string::{utf8};
    use aptos_framework::type_info::{type_of};
    use aptos_framework::option;

    use token_bridge::token_bridge::{Self as bridge};
    use token_bridge::state;
    use token_bridge::wrapped;
    use token_bridge::utils::{pad_left_32};
    use token_bridge::token_hash;

    use token_bridge::register_chain;

    use wormhole::u16::{Self};

    use wrapped_coin::coin::T;

    /// Registration VAA for the etheruem token bridge 0xdeadbeef
    const ETHEREUM_TOKEN_REG: vector<u8> = x"0100000000010015d405c74be6d93c3c33ed6b48d8db70dfb31e0981f8098b2a6c7583083e0c3343d4a1abeb3fc1559674fa067b0c0e2e9de2fafeaecdfeae132de2c33c9d27cc0100000001000000010001000000000000000000000000000000000000000000000000000000000000000400000000016911ae00000000000000000000000000000000000000000000546f6b656e427269646765010000000200000000000000000000000000000000000000000000000000000000deadbeef";

    /// Attestation VAA sent from the ethereum token bridge 0xdeadbeef
    const ATTESTATION_VAA: vector<u8> = x"01000000000100102d399190fa61daccb11c2ea4f7a3db3a9365e5936bcda4cded87c1b9eeb095173514f226256d5579af71d4089eb89496befb998075ba94cd1d4460c5c57b84000000000100000001000200000000000000000000000000000000000000000000000000000000deadbeef0000000002634973000200000000000000000000000000000000000000000000000000000000beefface00020c0000000000000000000000000000000000000000000000000000000042454546000000000000000000000000000000000042656566206661636520546f6b656e";

    fun setup(
        deployer: &signer,
    ) {
        wormhole::wormhole_test::setup(0);
        bridge::init_test(deployer);
    }

    #[test(deployer=@deployer)]
    #[expected_failure(abort_code = 0)]
    fun test_create_wrapped_coin_unregistered(deployer: &signer) {
        setup(deployer);

        let _addr = wrapped::create_wrapped_coin_type(ATTESTATION_VAA);
    }

    // test create_wrapped_coin_type and create_wrapped_coin
    #[test(deployer=@deployer)]
    fun test_create_wrapped_coin(deployer: &signer) {
        setup(deployer);
        register_chain::submit_vaa(ETHEREUM_TOKEN_REG);

        let _addr = wrapped::create_wrapped_coin_type(ATTESTATION_VAA);

        // assert coin is NOT initialized
        assert!(!coin::is_coin_initialized<T>(), 0);

        // initialize coin using type T, move caps to token_bridge, sets bridge state variables
        wrapped::create_wrapped_coin<T>(ATTESTATION_VAA);

        // assert that coin IS initialized
        assert!(coin::is_coin_initialized<T>(), 0);

        // assert coin info is correct
        assert!(coin::name<T>() == utf8(pad_left_32(&b"Beef face Token")), 0);
        assert!(coin::symbol<T>() == utf8(pad_left_32(&b"BEEF")), 0);
        assert!(coin::decimals<T>() == 12, 0);

        // assert origin address, chain, type_info, is_wrapped are correct
        let token_address = token_hash::derive<T>();
        let origin_info = state::origin_info<T>();
        let origin_token_address = state::get_origin_info_token_address(&origin_info);
        let origin_token_chain = state::get_origin_info_token_chain(&origin_info);
        let wrapped_asset_type_info = state::asset_type_info(token_address);
        let is_wrapped_asset = state::is_wrapped_asset<T>();
        assert!(type_of<T>() == wrapped_asset_type_info, 0); //utf8(b"0xb54071ea68bc35759a17e9ddff91a8394a36a4790055e5bd225fae087a4a875b::coin::T"), 0);
        assert!(origin_token_chain == u16::from_u64(2), 0);
        assert!(origin_token_address == x"00000000000000000000000000000000000000000000000000000000beefface", 0);
        assert!(is_wrapped_asset, 0);

        // load beef face token cap and mint some beef face coins, then burn
        let beef_coins = wrapped::mint<T>(10000);
        assert!(coin::value(&beef_coins)==10000, 0);
        assert!(coin::supply<T>() == option::some(10000), 0);
        wrapped::burn<T>(beef_coins);
        assert!(coin::supply<T>() == option::some(0), 0);
    }
}
