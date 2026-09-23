// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import 'forge-std/Test.sol';

import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

import {IListaV3Factory} from '../../src/core/interfaces/IListaV3Factory.sol';
import {IListaV3Pool} from '../../src/core/interfaces/IListaV3Pool.sol';
import {ListaV3FactoryOwner} from '../../src/extensions/ListaV3FactoryOwner.sol';

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Rehearses the real handover against live BNB Chain state. Skipped unless run with
/// `--fork-url <bsc>`, so the default `forge test` stays offline.
///
///   forge test --match-path 'test/extensions/ListaV3FactoryOwnerForkTest.t.sol' \
///     --fork-url https://bsc-rpc.publicnode.com -vv
contract ListaV3FactoryOwnerForkTest is Test {
    address internal constant FACTORY = 0xcb010ed373523942706F730b89792aA1C1597b20;
    address internal constant REVENUE_COLLECTOR = 0x86E09296aeDA129D3b0b4c134B3202b84Cd8945C;
    address internal constant USDT_USDC_POOL = 0x46eE2C5F2b9De7C6e08Ffe3Bde8Dd88A46D6f568;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    address internal constant ADMIN = address(0xA0);
    address internal constant MANAGER_ADDR = address(0x11A);
    address internal constant BOT_ADDR = address(0xB07);

    modifier onlyBnbFork() {
        if (block.chainid != 56) return;
        _;
    }

    function _deploy() internal returns (ListaV3FactoryOwner) {
        ListaV3FactoryOwner impl = new ListaV3FactoryOwner(FACTORY);
        return
            ListaV3FactoryOwner(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeWithSelector(
                            ListaV3FactoryOwner.initialize.selector,
                            REVENUE_COLLECTOR,
                            ADMIN,
                            MANAGER_ADDR,
                            BOT_ADDR
                        )
                    )
                )
            );
    }

    /// @notice Full rehearsal: deploy, hand the factory over from the live owner, then let the bot
    /// sweep the fees actually sitting in the live pool.
    function testForkCollectsLiveProtocolFees() public onlyBnbFork {
        address liveOwner = IListaV3Factory(FACTORY).owner();
        ListaV3FactoryOwner feeOwner = _deploy();

        // The live owner is a multisig; impersonate the one call it would queue.
        vm.prank(liveOwner);
        IListaV3Factory(FACTORY).setOwner(address(feeOwner));
        assertTrue(feeOwner.isFactoryOwner());

        (uint128 pending0, uint128 pending1) = IListaV3Pool(USDT_USDC_POOL).protocolFees();
        emit log_named_uint('pending USDT (wei)', pending0);
        emit log_named_uint('pending USDC (wei)', pending1);
        assertTrue(pending0 > 1 || pending1 > 1, 'nothing accrued on the live pool');

        uint256 rcUsdtBefore = IERC20Minimal(USDT).balanceOf(REVENUE_COLLECTOR);
        uint256 rcUsdcBefore = IERC20Minimal(USDC).balanceOf(REVENUE_COLLECTOR);

        vm.prank(BOT_ADDR);
        (uint128 got0, uint128 got1) = feeOwner.collectProtocolFees(USDT_USDC_POOL);

        emit log_named_uint('collected USDT (wei)', got0);
        emit log_named_uint('collected USDC (wei)', got1);

        assertEq(got0, pending0 - 1);
        assertEq(got1, pending1 - 1);
        assertEq(IERC20Minimal(USDT).balanceOf(REVENUE_COLLECTOR), rcUsdtBefore + got0);
        assertEq(IERC20Minimal(USDC).balanceOf(REVENUE_COLLECTOR), rcUsdcBefore + got1);

        // The fee collector must be a pure conduit.
        assertEq(IERC20Minimal(USDT).balanceOf(address(feeOwner)), 0);
        assertEq(IERC20Minimal(USDC).balanceOf(address(feeOwner)), 0);
    }

    /// @notice The live owner keeps a way back out.
    function testForkEscapeHatchReturnsFactoryToMultisig() public onlyBnbFork {
        address liveOwner = IListaV3Factory(FACTORY).owner();
        ListaV3FactoryOwner feeOwner = _deploy();

        vm.prank(liveOwner);
        IListaV3Factory(FACTORY).setOwner(address(feeOwner));

        vm.prank(ADMIN);
        feeOwner.transferFactoryOwnership(liveOwner);

        assertEq(IListaV3Factory(FACTORY).owner(), liveOwner);
        assertFalse(feeOwner.isFactoryOwner());
    }
}
