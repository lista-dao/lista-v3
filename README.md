# Lista V3

A Uniswap V3 fork renamed to Lista V3, with the factory and NFT position manager deployed behind upgradeable proxies.

## Contracts

### Core (`src/core/`)

- `ListaV3Factory` — canonical factory. **Upgradeable** via `TransparentUpgradeableProxy`; initializer replaces the constructor and seeds the 500 / 3000 / 10000 fee tiers.
- `ListaV3Pool` — AMM pool, CREATE2-deployed by the factory, **not upgradeable**.
- `ListaV3PoolDeployer` — base of the factory; writes transient parameters so the pool constructor can read them back, keeping `POOL_INIT_CODE_HASH` constant for off-chain address derivation.

### Periphery (`src/periphery/`)

- `NonfungiblePositionManager` — wraps positions as ERC-721 NFTs. **Hybrid upgradeable**: the ERC-721 / permit stack uses `ERC721PermitUpgradeable` (storage-backed, behind the proxy), while `factory` and `WETH9` remain constructor-set `immutable`s in the implementation bytecode. Every impl upgrade must re-pass the original `(factory, WETH9)` to the new impl's constructor.
- `SwapRouter`, `V3Migrator`, `Quoter`, `QuoterV2`, `NonfungibleTokenPositionDescriptor`, `PairFlash` — deployed normally (non-upgradeable).

## Deployment outline

1. Deploy `ListaV3Factory` impl (no constructor args).
2. Deploy a shared `ProxyAdmin`.
3. Deploy `TransparentUpgradeableProxy(factoryImpl, proxyAdmin, abi.encodeWithSelector(ListaV3Factory.initialize.selector, owner))`. Treat the proxy address as *the* factory from here on.
4. Deploy `NonfungiblePositionManager` impl with `(factoryProxy, WETH9)`.
5. Deploy `TransparentUpgradeableProxy(npmImpl, proxyAdmin, abi.encodeWithSelector(NonfungiblePositionManager.initialize.selector, tokenDescriptor))`.
6. Deploy `SwapRouter`, `V3Migrator`, etc. against the factory proxy address.

Operational notes:

- The Factory/NPM implementations should have their initializers consumed post-deploy (e.g. `initialize(0xdead)` / `initialize(0xdead, 0xdead)`) to close the Parity-style impl-takeover window.
- Pool addresses are derived from the factory proxy via `PoolAddress.computeAddress`. If `ListaV3Pool` bytecode is ever changed, `PoolAddress.POOL_INIT_CODE_HASH` must be recomputed — the value in `src/periphery/libraries/PoolAddress.sol` is only valid for the currently-checked-in pool source and build settings.
- Re-verify `POOL_INIT_CODE_HASH` before deploying to a new chain. The value is machine-deterministic given `bytecode_hash = "none"` in `foundry.toml`, but a different toolchain version, optimizer setting, or solc patch can still shift it. Run `testInitCodeHash` in `test/periphery/FullFlowTest.t.sol` against your build environment as a pre-deploy gate; if it fails, update the constant before deploying or off-chain pool address derivation will silently point at the wrong addresses.

## Build & test

Uses Foundry with Solidity 0.7.6.

```sh
forge build
forge test
```

The end-to-end flow (pool creation, mint, swap, increase / decrease liquidity, collect, transfer, burn) runs in `test/periphery/FullFlowTest.t.sol`, which also exercises the proxy wiring and asserts NPM initializer state / ERC-165 registrations.

## Dependencies

Git submodules under `lib/`:

- `forge-std`
- `openzeppelin-contracts` at `v3.4.2-solc-0.7` — non-upgradeable contracts and proxy wrappers (`TransparentUpgradeableProxy`, `ProxyAdmin`).
- `openzeppelin-contracts-upgradeable` at `v3.4.2-solc-0.7` — upgradeable ERC-721, Initializable, Context, ERC-165.
- `solidity-lib` — Uniswap math helpers.
