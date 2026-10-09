// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import 'forge-std/Script.sol';
import 'forge-std/console.sol';

import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

import {ListaV3FactoryOwner} from '../src/extensions/ListaV3FactoryOwner.sol';
import {IListaV3Factory} from '../src/core/interfaces/IListaV3Factory.sol';

/// @title Deploy ListaV3FactoryOwner (UUPS impl + ERC1967 proxy)
/// @notice Deploys only. Installing it is a separate privileged step: the factory's current owner
/// must call `factory.setOwner(<proxy>)`. On mainnet that owner is a multisig, so the calldata is
/// printed rather than called. TRANSFER_OWNERSHIP=true does the handover in-run — only when the
/// signer is itself the factory owner (i.e. testnet).
///
/// Env: ADMIN, MANAGER, BOT (required); FACTORY, REVENUE_COLLECTOR, TRANSFER_OWNERSHIP (optional).
///
/// Usage:
///   ADMIN=0x... MANAGER=0x... BOT=0x... forge script script/DeployV3FactoryOwner.s.sol:DeployV3FactoryOwner \
///     --rpc-url $BSC_RPC --private-key $PRIVATE_KEY --broadcast --verify \
///     --etherscan-api-key $BSCSCAN_API_KEY --slow
contract DeployV3FactoryOwner is Script {
    function run() external returns (address proxy, address impl) {
        address factory = _resolveFactory(block.chainid);
        address revenueCollector = _resolveRevenueCollector(block.chainid);
        address admin = vm.envAddress('ADMIN');
        address manager = vm.envAddress('MANAGER');
        address bot = vm.envAddress('BOT');
        bool doTransfer = vm.envOr('TRANSFER_OWNERSHIP', false);

        require(_hasCode(factory), 'FACTORY has no code on this chain');
        // A fee destination with no code would black-hole every future sweep.
        require(_hasCode(revenueCollector), 'REVENUE_COLLECTOR has no code on this chain');

        address currentOwner = IListaV3Factory(factory).owner();

        console.log('--- ListaV3FactoryOwner deploy ---');
        console.log('chainId:', block.chainid);
        console.log('deployer:', msg.sender);
        console.log('factory:', factory);
        console.log('factory owner (current):', currentOwner);
        console.log('revenueCollector:', revenueCollector);
        console.log('admin (DEFAULT_ADMIN_ROLE):', admin);
        console.log('manager (MANAGER):', manager);
        console.log('bot (BOT):', bot);
        console.log('transfer ownership in this run?:', doTransfer);

        bytes memory initData =
            abi.encodeWithSelector(ListaV3FactoryOwner.initialize.selector, revenueCollector, admin, manager, bot);

        vm.startBroadcast();
        ListaV3FactoryOwner implementation = new ListaV3FactoryOwner(factory);
        // The proxy initializes inside its own constructor, so init cannot be front-run.
        ERC1967Proxy proxy_ = new ERC1967Proxy(address(implementation), initData);

        if (doTransfer) {
            require(currentOwner == msg.sender, 'TRANSFER_OWNERSHIP set but signer is not factory owner');
            IListaV3Factory(factory).setOwner(address(proxy_));
        }
        vm.stopBroadcast();

        ListaV3FactoryOwner feeOwner = ListaV3FactoryOwner(address(proxy_));

        // Readback before anyone relies on it.
        require(feeOwner.factory() == factory, 'factory mismatch');
        require(feeOwner.revenueCollector() == revenueCollector, 'revenueCollector mismatch');
        require(feeOwner.hasRole(feeOwner.DEFAULT_ADMIN_ROLE(), admin), 'admin role missing');
        require(feeOwner.hasRole(feeOwner.MANAGER(), manager), 'manager role missing');
        require(feeOwner.hasRole(feeOwner.BOT(), bot), 'bot role missing');

        proxy = address(proxy_);
        impl = address(implementation);

        console.log('--- deployed ---');
        console.log('ListaV3FactoryOwner (proxy):', proxy);
        console.log('implementation:', impl);

        if (doTransfer) {
            require(IListaV3Factory(factory).owner() == proxy, 'ownership handover failed');
            console.log('factory owner is now the fee collector: INSTALLED');
        } else {
            console.log('');
            console.log('NOT yet installed. Have the factory owner execute:');
            console.log('  target:', factory);
            console.log('  calldata:');
            console.logBytes(abi.encodeWithSelector(IListaV3Factory.setOwner.selector, proxy));
        }
    }

    function _resolveFactory(uint256 chainId) internal returns (address) {
        address override_ = vm.envOr('FACTORY', address(0));
        if (override_ != address(0)) return override_;

        if (chainId == 56) return 0xcb010ed373523942706F730b89792aA1C1597b20; // BNB Chain
        if (chainId == 97) return 0x77C613328a47Fd7EDF4A9e82aF47021363CD7d14; // BNB Chain testnet

        revert('FACTORY not set: pass FACTORY=0x...');
    }

    /// @dev Lista's "DEX fee + liquidation profit" RevenueCollector. A balance custodian —
    /// liquidation fees and redeemed V2 LPs already arrive as plain ERC20 transfers, so fees pushed
    /// the same way need no registration.
    function _resolveRevenueCollector(uint256 chainId) internal returns (address) {
        address override_ = vm.envOr('REVENUE_COLLECTOR', address(0));
        if (override_ != address(0)) return override_;

        if (chainId == 56) return 0x86E09296aeDA129D3b0b4c134B3202b84Cd8945C; // BNB Chain

        revert('REVENUE_COLLECTOR not set: pass REVENUE_COLLECTOR=0x... (none deployed on this chain)');
    }

    function _hasCode(address a) internal view returns (bool) {
        return a.code.length > 0;
    }
}
