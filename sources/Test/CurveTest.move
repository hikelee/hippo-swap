#[test_only]
module HippoSwap::CurveTest {

    use HippoSwap::MockCoin::{WUSDT, WUSDC, WDAI};
    use HippoSwap::StableCurveScripts::{create_new_pool};

    // 10 to the power of n.
    const P3: u64 = 1000;
    const P4: u64 = 10000;
    const P5: u64 = 100000;
    const P6: u64 = 1000000;
    const P7: u64 = 10000000;
    const P8: u64 = 100000000;
    const P9: u64 = 1000000000;
    const P10: u64 = 10000000000;
    const P11: u64 = 100000000000;
    const P12: u64 = 1000000000000;
    const P13: u64 = 10000000000000;
    const P14: u64 = 100000000000000;
    const P15: u64 = 1000000000000000;
    const P16: u64 = 10000000000000000;
    const P17: u64 = 100000000000000000;
    const P18: u64 = 1000000000000000000;
    const P19: u64 = 10000000000000000000;

    const FEE_RATE: u64 = 3000;    // which is actually 0.3% after divided by the FEE DENOMINATOR;
    const ADMIN_FEE_RATE: u64 = 200000; // which is 20%, the admin fee is the percent to take from the fee (total fee included)

    #[test_only]
    public fun create_pools(signer: &signer) {
        let (logo_url, project_url) = (b"", b"");
        let lp1 =  b"USDC-USDT-CURVE-LP";       // will be compete with Piece Pool
        let lp2 = b"USDC-DAI-CURVE-LP";         // The only route of pair in the sys.
        create_new_pool<WUSDC, WUSDT>(signer, lp1, lp1, lp1, logo_url, project_url, FEE_RATE, ADMIN_FEE_RATE);
        create_new_pool<WUSDC, WDAI>(signer, lp2, lp2, lp2, logo_url, project_url, FEE_RATE, ADMIN_FEE_RATE);
    }

}