// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import 'forge-std/Script.sol';
import 'forge-std/console.sol';

import {IListaV3Factory} from '../src/core/interfaces/IListaV3Factory.sol';
import {IPoolInitializer} from '../src/periphery/interfaces/IPoolInitializer.sol';

/// @dev Minimal view into Lista's slisBNB StakeManager for the live slisBNB->BNB rate.
interface IStakeManager {
    function convertSnBnbToBnb(uint256 amount) external view returns (uint256);
}

/// @title Create the slisBNB/BNB 0.01% pool on Lista V3 (BSC mainnet)
/// @notice Initializes the pool at the *current* slisBNB exchange rate read on-chain at run time, so
/// the starting price tracks slisBNB's BNB value. fee = 100 (0.01% / 1bp). The 1bp fee tier is not
/// seeded by the factory, so this script enables it first (owner-only; the deployer owns the factory).
///
/// slisBNB (0xB0b8...A1B) < WBNB (0xbb4C...95c), so token0 = slisBNB, token1 = WBNB, and the pool price
/// (token1/token0) = WBNB per slisBNB = convertSnBnbToBnb(1e18)/1e18. Both tokens are 18 decimals, so
/// no decimal adjustment is needed.
///
/// Usage:
///   forge script script/CreateSlisBnbPool.s.sol:CreateSlisBnbPool \
///     --rpc-url $BSC_RPC --private-key $PRIVATE_KEY --broadcast
contract CreateSlisBnbPool is Script {
    uint256 internal constant BSC_MAINNET_CHAIN_ID = 56;

    // Lista V3 mainnet (canonical hardened deploy)
    IListaV3Factory internal constant FACTORY = IListaV3Factory(0xcb010ed373523942706F730b89792aA1C1597b20);
    IPoolInitializer internal constant NPM = IPoolInitializer(0x31677537685EBDF1B695eDa46eC385845395f5dD);

    // Tokens (BSC mainnet)
    address internal constant SLISBNB = 0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // slisBNB exchange-rate source
    IStakeManager internal constant STAKE_MANAGER = IStakeManager(0x1adB950d8bB3dA4bE104211D5AB038628e477fE6);

    uint24 internal constant FEE = 100; // 0.01% (1bp)
    int24 internal constant TICK_SPACING = 1; // canonical tick spacing for the 1bp tier

    function run() external returns (address pool, uint160 sqrtPriceX96) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        require(chainId == BSC_MAINNET_CHAIN_ID, 'not BSC mainnet (expected chainid 56)');
        require(SLISBNB < WBNB, 'token order'); // token0 must be the lower address

        // Live rate: BNB returned for 1 slisBNB. Price (token1/token0) = WBNB per slisBNB.
        uint256 amountIn = 1e18;
        uint256 amountOut = STAKE_MANAGER.convertSnBnbToBnb(amountIn);
        require(amountOut > 0, 'rate=0');
        require(amountOut < (uint256(1) << 64), 'rate too large for fixed-point'); // keeps the <<192 safe

        // sqrtPriceX96 = sqrt(price) * 2^96 = sqrt(amountOut * 2^192 / amountIn).
        uint256 ratioX192 = (amountOut << 192) / amountIn;
        sqrtPriceX96 = uint160(_sqrt(ratioX192));

        console.log('--- create slisBNB/BNB pool (0.01%) ---');
        console.log('deployer:', msg.sender);
        console.log('token0 (slisBNB):', SLISBNB);
        console.log('token1 (WBNB):', WBNB);
        console.log('rate: BNB per slisBNB (x1e18):', amountOut);
        console.log('sqrtPriceX96:', uint256(sqrtPriceX96));

        vm.startBroadcast();

        // Enable the 1bp fee tier if it isn't already (owner-only). Permanent: V3 tiers can't be removed.
        if (FACTORY.feeAmountTickSpacing(FEE) == 0) {
            FACTORY.enableFeeAmount(FEE, TICK_SPACING);
        }

        pool = NPM.createAndInitializePoolIfNecessary(SLISBNB, WBNB, FEE, sqrtPriceX96);

        vm.stopBroadcast();

        console.log('pool:', pool);
    }

    /// @dev Integer square root (Babylonian). Converges for the full uint256 domain used here.
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
