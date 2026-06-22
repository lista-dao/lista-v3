// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import 'forge-std/Script.sol';
import 'forge-std/console.sol';

import {ListaV3Factory} from '../src/core/ListaV3Factory.sol';
import {NonfungiblePositionManager} from '../src/periphery/NonfungiblePositionManager.sol';
import {NonfungibleTokenPositionDescriptor} from '../src/periphery/NonfungibleTokenPositionDescriptor.sol';
import {SwapRouter} from '../src/periphery/SwapRouter.sol';

import {ProxyAdmin} from 'lib/openzeppelin-contracts/contracts/proxy/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from 'lib/openzeppelin-contracts/contracts/proxy/TransparentUpgradeableProxy.sol';

/// @title Deploy the full Lista V3 stack on BNB Chain mainnet (chainId 56)
/// @notice Self-contained, chain-pinned counterpart to Deploy.s.sol. Everything BSC-mainnet-specific
/// is hardcoded here (WBNB, native-currency label) and the run() hard-requires chainid == 56 so a
/// mis-set RPC can never broadcast mainnet bytecode to the wrong chain. The deploy sequence matches
/// the audited Deploy.s.sol exactly; only the chain config is fixed.
///
/// The NFT collection name/symbol ("Lista V3 Positions NFT" / "LISTA-V3") are baked into the NPM
/// implementation's initialize() — see NonfungiblePositionManager.sol — not set here.
///
/// All privileged roles (factory owner / fee-tier admin, and ProxyAdmin owner) default to the
/// broadcasting deployer EOA. The deployer address is printed before any broadcast so it can be
/// confirmed against the funded signer.
///
/// Optional env (with defaults):
///   OWNER                 = factory owner / fee-tier admin (defaults to the deployer EOA).
///   PROXY_ADMIN_OWNER     = owner of the ProxyAdmin that controls the NPM proxy (defaults to OWNER).
///   TOKEN_DESCRIPTOR      = existing NFT position descriptor to reuse. If unset (0x0), a fresh
///                           NonfungibleTokenPositionDescriptor is deployed against THIS build's
///                           PoolAddress/init-code-hash and wired into the NPM. Only pass an address
///                           that was built from THIS repo — never a foreign fork.
///
/// Usage:
///   forge script script/DeployBscMainnet.s.sol:DeployBscMainnet \
///     --rpc-url $BSC_RPC --broadcast --verify --etherscan-api-key $BSCSCAN_API_KEY --slow
contract DeployBscMainnet is Script {
    uint256 internal constant BSC_MAINNET_CHAIN_ID = 56;
    /// @dev Canonical WBNB on BNB Chain mainnet.
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// @dev Native-currency label shown for WBNB positions in the freshly-deployed descriptor.
    bytes32 internal constant NATIVE_CURRENCY_LABEL = bytes32('BNB');

    struct Deployment {
        address proxyAdmin;
        address factory;
        address tokenDescriptor;
        address npmImpl;
        address npmProxy;
        address swapRouter;
    }

    function run() external returns (Deployment memory out) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        require(chainId == BSC_MAINNET_CHAIN_ID, 'not BSC mainnet (expected chainid 56)');

        // The deployer is the broadcasting signer; all privileged roles default to it.
        address deployer = msg.sender;
        address owner = vm.envOr('OWNER', deployer);
        address proxyAdminOwner = vm.envOr('PROXY_ADMIN_OWNER', owner);
        address tokenDescriptor = vm.envOr('TOKEN_DESCRIPTOR', address(0));

        require(owner != address(0), 'OWNER=0');
        require(proxyAdminOwner != address(0), 'PROXY_ADMIN_OWNER=0');

        bool deployDescriptor = tokenDescriptor == address(0);

        console.log('--- Lista V3 deploy (BSC mainnet) ---');
        console.log('chainId:', chainId);
        console.log('deployer:', deployer);
        console.log('owner:', owner);
        console.log('proxyAdminOwner:', proxyAdminOwner);
        console.log('WBNB:', WBNB);
        console.log('deploy descriptor?:', deployDescriptor);
        if (!deployDescriptor) {
            console.log('tokenDescriptor (reused):', tokenDescriptor);
        }

        vm.startBroadcast();

        // ProxyAdmin: owner() is the broadcaster from its constructor; transfer only if a different
        // owner was requested.
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        if (proxyAdminOwner != proxyAdmin.owner()) {
            proxyAdmin.transferOwnership(proxyAdminOwner);
        }

        // Factory: plain deploy. owner = broadcaster; hand off to the requested owner if different.
        ListaV3Factory factory = new ListaV3Factory();
        if (owner != msg.sender) {
            factory.setOwner(owner);
        }

        // Descriptor: fresh deploy only when TOKEN_DESCRIPTOR was not provided. Built from THIS repo's
        // PoolAddress/POOL_INIT_CODE_HASH so it derives pool addresses correctly for this deployment.
        // forge auto-deploys and links the NFTDescriptor library it depends on.
        if (deployDescriptor) {
            NonfungibleTokenPositionDescriptor descriptor =
                new NonfungibleTokenPositionDescriptor(WBNB, NATIVE_CURRENCY_LABEL);
            tokenDescriptor = address(descriptor);
        }

        // NPM: impl + proxy. factory/WETH9 are constructor immutables on the impl; every future
        // upgrade MUST re-pass the exact same (factory, WBNB) to the new impl.
        //
        // The impl is created AND its initializer consumed inside NpmImplDeployer's constructor —
        // a single CREATE tx — so there is no separate initialize() tx for a bot to front-run
        // (an earlier non-atomic `new impl(); impl.initialize(0xdead)` was front-run on mainnet).
        address npmImpl = address(new NpmImplDeployer(address(factory), WBNB).impl());

        bytes memory npmInit = abi.encodeWithSelector(NonfungiblePositionManager.initialize.selector, tokenDescriptor);
        TransparentUpgradeableProxy npmProxy =
            new TransparentUpgradeableProxy(npmImpl, address(proxyAdmin), npmInit);

        // SwapRouter is not upgradeable; plain deploy against the factory.
        SwapRouter swapRouter = new SwapRouter(address(factory), WBNB);

        vm.stopBroadcast();

        out = Deployment({
            proxyAdmin: address(proxyAdmin),
            factory: address(factory),
            tokenDescriptor: tokenDescriptor,
            npmImpl: npmImpl,
            npmProxy: address(npmProxy),
            swapRouter: address(swapRouter)
        });

        console.log('--- deployed ---');
        console.log('ProxyAdmin:', out.proxyAdmin);
        console.log('Factory:', out.factory);
        console.log('TokenDescriptor:', out.tokenDescriptor);
        console.log('NPM impl:', out.npmImpl);
        console.log('NPM proxy:', out.npmProxy);
        console.log('SwapRouter:', out.swapRouter);
    }
}

/// @title Atomic NPM implementation deployer
/// @notice Deploys a NonfungiblePositionManager implementation and consumes its initializer within
/// this contract's constructor — i.e. inside a single CREATE transaction. Because the deploy and the
/// `initialize(0xdead)` happen in the same tx, there is no intervening block in which a bot can call
/// `initialize()` on the fresh impl. Read `impl()` afterwards for the deployed implementation address.
contract NpmImplDeployer {
    NonfungiblePositionManager public immutable impl;

    constructor(address factory_, address weth9_) {
        NonfungiblePositionManager i = new NonfungiblePositionManager(factory_, weth9_);
        // Close the impl-takeover window atomically; harmless even though NPM has no selfdestruct.
        i.initialize(address(0xdead));
        impl = i;
    }
}
