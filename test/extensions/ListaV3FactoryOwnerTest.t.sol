// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import 'forge-std/Test.sol';

import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {IListaV3Factory} from '../../src/core/interfaces/IListaV3Factory.sol';
import {IListaV3Pool} from '../../src/core/interfaces/IListaV3Pool.sol';
import {ListaV3FactoryOwner} from '../../src/extensions/ListaV3FactoryOwner.sol';

/// @dev The V3 stack is pinned to solc 0.7.6, so it is deployed by artifact rather than imported.
interface INpm {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract ListaV3FactoryOwnerTest is Test {
    IListaV3Factory internal factory;
    INpm internal npm;
    IRouter internal router;
    ListaV3FactoryOwner internal feeOwner;

    IERC20Like internal token0;
    IERC20Like internal token1;

    address internal constant REVENUE_COLLECTOR = address(0xFEEC011EC7);
    address internal constant ADMIN = address(0xAD31);
    address internal constant MANAGER_ADDR = address(0x11A);
    address internal constant BOT_ADDR = address(0xB07);
    address internal constant STRANGER = address(0x57A);
    address internal alice = address(0xA11CE);

    uint24 internal constant FEE = 3000;
    uint24 internal constant FEE_LOW = 500;
    uint160 internal constant INITIAL_SQRT_PRICE = 79228162514264337593543950336; // 1:1
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 887220;

    address internal pool;
    bytes32 internal BOT_ROLE;
    bytes32 internal MANAGER_ROLE;
    bytes32 internal ADMIN_ROLE;

    event ProtocolFeeCollected(address indexed pool, address indexed recipient, uint128 amount0, uint128 amount1);

    function setUp() public {
        factory = IListaV3Factory(deployCode('ListaV3Factory.sol:ListaV3Factory'));
        address proxyAdmin = deployCode('ProxyAdmin.sol:ProxyAdmin');

        address npmImpl =
            deployCode('NonfungiblePositionManager.sol:NonfungiblePositionManager', abi.encode(factory, address(0xdead)));
        bytes memory npmInit = abi.encodeWithSignature('initialize(address)', address(0));
        npm = INpm(
            deployCode(
                'TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy',
                abi.encode(npmImpl, proxyAdmin, npmInit)
            )
        );
        router = IRouter(deployCode('out/SwapRouter.sol/SwapRouter.json', abi.encode(factory, address(0xdead))));

        address a = deployCode('out/TestERC20.sol/TestERC20.json', abi.encode(type(uint128).max));
        address b = deployCode('out/TestERC20.sol/TestERC20.json', abi.encode(type(uint128).max));
        (token0, token1) = a < b ? (IERC20Like(a), IERC20Like(b)) : (IERC20Like(b), IERC20Like(a));

        token0.transfer(alice, 1e24);
        token1.transfer(alice, 1e24);
        vm.startPrank(alice);
        token0.approve(address(npm), type(uint256).max);
        token1.approve(address(npm), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();

        pool = _createPoolWithLiquidity(FEE);

        ListaV3FactoryOwner impl = new ListaV3FactoryOwner(address(factory));
        feeOwner = ListaV3FactoryOwner(
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
        BOT_ROLE = feeOwner.BOT();
        MANAGER_ROLE = feeOwner.MANAGER();
        ADMIN_ROLE = feeOwner.DEFAULT_ADMIN_ROLE();

        factory.setOwner(address(feeOwner));
    }

    // --- installation ---

    function testInstalledAsFactoryOwner() public {
        assertEq(factory.owner(), address(feeOwner));
        assertTrue(feeOwner.isFactoryOwner());
        assertEq(feeOwner.factory(), address(factory));
        assertEq(feeOwner.revenueCollector(), REVENUE_COLLECTOR);
        assertTrue(feeOwner.hasRole(ADMIN_ROLE, ADMIN));
        assertTrue(feeOwner.hasRole(MANAGER_ROLE, MANAGER_ADDR));
        assertTrue(feeOwner.hasRole(BOT_ROLE, BOT_ADDR));
        assertEq(feeOwner.getRoleAdmin(BOT_ROLE), MANAGER_ROLE);
        assertEq(feeOwner.getRoleAdmin(MANAGER_ROLE), ADMIN_ROLE);
    }

    function testImplementationCannotBeInitialized() public {
        ListaV3FactoryOwner impl = new ListaV3FactoryOwner(address(factory));
        vm.expectRevert();
        impl.initialize(REVENUE_COLLECTOR, ADMIN, MANAGER_ADDR, BOT_ADDR);
    }

    function testProxyCannotBeReinitialized() public {
        vm.expectRevert();
        feeOwner.initialize(REVENUE_COLLECTOR, STRANGER, STRANGER, STRANGER);
    }

    function testRejectsZeroArgs() public {
        vm.expectRevert(bytes('factory=0'));
        new ListaV3FactoryOwner(address(0));

        ListaV3FactoryOwner impl = new ListaV3FactoryOwner(address(factory));
        string[4] memory errs = ['revenueCollector=0', 'admin=0', 'manager=0', 'bot=0'];
        for (uint256 i = 0; i < 4; i++) {
            address[4] memory args = [REVENUE_COLLECTOR, ADMIN, MANAGER_ADDR, BOT_ADDR];
            args[i] = address(0);
            vm.expectRevert(bytes(errs[i]));
            new ERC1967Proxy(
                address(impl),
                abi.encodeWithSelector(
                    ListaV3FactoryOwner.initialize.selector, args[0], args[1], args[2], args[3]
                )
            );
        }
    }

    // --- core flow ---

    function testBotCollectsAccruedFeesToRevenueCollector() public {
        vm.prank(MANAGER_ADDR);
        feeOwner.setFeeProtocol(pool, 5, 5);

        _swap(address(token0), address(token1), 5e18);
        _swap(address(token1), address(token0), 5e18);

        (uint128 pending0, uint128 pending1) = IListaV3Pool(pool).protocolFees();
        assertTrue(pending0 > 1 && pending1 > 1, 'no protocol fees accrued');

        // The pool retains 1 wei per side to keep its storage slot warm.
        uint128 expect0 = pending0 - 1;
        uint128 expect1 = pending1 - 1;

        vm.expectEmit(true, true, true, true);
        emit ProtocolFeeCollected(pool, REVENUE_COLLECTOR, expect0, expect1);

        vm.prank(BOT_ADDR);
        (uint128 got0, uint128 got1) = feeOwner.collectProtocolFees(pool);

        assertEq(got0, expect0);
        assertEq(got1, expect1);
        assertEq(token0.balanceOf(REVENUE_COLLECTOR), expect0);
        assertEq(token1.balanceOf(REVENUE_COLLECTOR), expect1);

        // The collector itself must never end up holding funds.
        assertEq(token0.balanceOf(address(feeOwner)), 0);
        assertEq(token1.balanceOf(address(feeOwner)), 0);
    }

    function testCollectRequiresBotRole() public {
        vm.prank(MANAGER_ADDR);
        feeOwner.setFeeProtocol(pool, 5, 5);
        _swap(address(token0), address(token1), 5e18);

        address[] memory pools = new address[](1);
        pools[0] = pool;

        // Not even DEFAULT_ADMIN_ROLE may collect without BOT.
        for (uint256 i = 0; i < 2; i++) {
            address caller = i == 0 ? STRANGER : ADMIN;
            vm.startPrank(caller);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, BOT_ROLE)
            );
            feeOwner.collectProtocolFees(pool);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, BOT_ROLE)
            );
            feeOwner.collectProtocolFeesBatch(pools);
            vm.stopPrank();
        }

        assertEq(token0.balanceOf(REVENUE_COLLECTOR), 0);
    }

    function testCollectWithNothingPendingIsNoop() public {
        vm.prank(MANAGER_ADDR);
        feeOwner.setFeeProtocol(pool, 5, 5);
        _swap(address(token0), address(token1), 5e18);

        vm.prank(BOT_ADDR);
        feeOwner.collectProtocolFees(pool);
        uint256 afterFirst = token0.balanceOf(REVENUE_COLLECTOR);

        vm.prank(BOT_ADDR);
        (uint128 got0, uint128 got1) = feeOwner.collectProtocolFees(pool);
        assertEq(got0, 0);
        assertEq(got1, 0);
        assertEq(token0.balanceOf(REVENUE_COLLECTOR), afterFirst);
    }

    function testBatchCollectAcrossPools() public {
        address pool2 = _createPoolWithLiquidity(FEE_LOW);

        vm.startPrank(MANAGER_ADDR);
        feeOwner.setFeeProtocol(pool, 5, 5);
        feeOwner.setFeeProtocol(pool2, 5, 5);
        vm.stopPrank();

        _swap(address(token0), address(token1), 5e18);
        _swapVia(FEE_LOW, address(token0), address(token1), 5e18);

        address[] memory pools = new address[](2);
        pools[0] = pool;
        pools[1] = pool2;

        (uint128[] memory p0, ) = feeOwner.pendingProtocolFees(pools);
        assertTrue(p0[0] > 1 && p0[1] > 1);

        vm.prank(BOT_ADDR);
        feeOwner.collectProtocolFeesBatch(pools);

        assertEq(token0.balanceOf(REVENUE_COLLECTOR), uint256(p0[0] - 1) + uint256(p0[1] - 1));
    }

    // --- pool validation ---

    function testRejectsAddressThatIsNotAFactoryPool() public {
        ForeignPool foreign = new ForeignPool(address(token0), address(token1), FEE);

        vm.prank(BOT_ADDR);
        vm.expectRevert(); // EOA: no token0() to call
        feeOwner.collectProtocolFees(STRANGER);

        vm.prank(BOT_ADDR);
        vm.expectRevert(bytes('not a Lista V3 pool'));
        feeOwner.collectProtocolFees(address(foreign));

        vm.prank(MANAGER_ADDR);
        vm.expectRevert(bytes('not a Lista V3 pool'));
        feeOwner.setFeeProtocol(address(foreign), 5, 5);
    }

    // --- access control ---

    /// @notice Config is MANAGER-gated — DEFAULT_ADMIN_ROLE does not implicitly hold it.
    function testConfigFunctionsRequireManagerRole() public {
        for (uint256 i = 0; i < 2; i++) {
            address caller = i == 0 ? BOT_ADDR : ADMIN;
            bytes memory err = abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                caller,
                MANAGER_ROLE
            );
            vm.startPrank(caller);
            vm.expectRevert(err);
            feeOwner.setFeeProtocol(pool, 5, 5);
            vm.expectRevert(err);
            feeOwner.enableFeeAmount(1234, 60);
            vm.expectRevert(err);
            feeOwner.setRevenueCollector(caller);
            vm.stopPrank();
        }

        // Neither the bot nor the manager picks where fees go without the other's consent.
        assertEq(feeOwner.revenueCollector(), REVENUE_COLLECTOR);
    }

    /// @notice The escape hatch stays with DEFAULT_ADMIN_ROLE — MANAGER must not reach it.
    function testFactoryOwnershipTransferRequiresDefaultAdminRole() public {
        for (uint256 i = 0; i < 2; i++) {
            address caller = i == 0 ? BOT_ADDR : MANAGER_ADDR;
            vm.prank(caller);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ADMIN_ROLE
                )
            );
            feeOwner.transferFactoryOwnership(caller);
        }
        assertEq(factory.owner(), address(feeOwner));
    }

    function testAdminCanRetargetRevenueCollector() public {
        address newCollector = address(0xC011EC);
        vm.prank(MANAGER_ADDR);
        feeOwner.setRevenueCollector(newCollector);

        vm.prank(MANAGER_ADDR);
        feeOwner.setFeeProtocol(pool, 5, 5);
        _swap(address(token0), address(token1), 5e18);

        vm.prank(BOT_ADDR);
        feeOwner.collectProtocolFees(pool);
        assertTrue(token0.balanceOf(newCollector) > 0);
        assertEq(token0.balanceOf(REVENUE_COLLECTOR), 0);

        vm.prank(MANAGER_ADDR);
        vm.expectRevert(bytes('revenueCollector=0'));
        feeOwner.setRevenueCollector(address(0));
    }

    function testEnableFeeAmountThroughOwner() public {
        assertEq(factory.feeAmountTickSpacing(1234), int24(0));
        vm.prank(MANAGER_ADDR);
        feeOwner.enableFeeAmount(1234, 60);
        assertEq(factory.feeAmountTickSpacing(1234), int24(60));
    }

    /// @notice BOT's role admin is MANAGER, so bot-key rotation never needs DEFAULT_ADMIN_ROLE.
    function testManagerCanRotateBotRole() public {
        address newBot = address(0xB072);

        // DEFAULT_ADMIN_ROLE alone cannot grant BOT — MANAGER is BOT's admin.
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ADMIN, MANAGER_ROLE)
        );
        feeOwner.grantRole(BOT_ROLE, newBot);

        vm.startPrank(MANAGER_ADDR);
        feeOwner.revokeRole(BOT_ROLE, BOT_ADDR);
        feeOwner.grantRole(BOT_ROLE, newBot);
        vm.stopPrank();

        vm.prank(MANAGER_ADDR);
        feeOwner.setFeeProtocol(pool, 5, 5);
        _swap(address(token0), address(token1), 5e18);

        // The rotated-out key is dead.
        vm.prank(BOT_ADDR);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOT_ADDR, BOT_ROLE)
        );
        feeOwner.collectProtocolFees(pool);

        vm.prank(newBot);
        (uint128 got0, ) = feeOwner.collectProtocolFees(pool);
        assertTrue(got0 > 0);
    }

    // --- escape hatch ---

    function testTransferFactoryOwnershipEscapeHatch() public {
        address multisig = address(0x5AFE);

        vm.prank(ADMIN);
        feeOwner.transferFactoryOwnership(multisig);

        assertEq(factory.owner(), multisig);
        assertFalse(feeOwner.isFactoryOwner());

        vm.prank(ADMIN);
        vm.expectRevert();
        feeOwner.setFeeProtocol(pool, 5, 5);

        vm.prank(ADMIN);
        vm.expectRevert(bytes('newOwner=0'));
        feeOwner.transferFactoryOwnership(address(0));
    }

    // --- upgradeability ---

    function testUpgradeRequiresDefaultAdminRole() public {
        address newImpl = address(new ListaV3FactoryOwner(address(factory)));
        // Build the expected error first: an external call after vm.prank would consume it.
        bytes memory err = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            MANAGER_ADDR,
            ADMIN_ROLE
        );

        vm.prank(MANAGER_ADDR);
        vm.expectRevert(err);
        feeOwner.upgradeToAndCall(newImpl, '');

        vm.prank(ADMIN);
        feeOwner.upgradeToAndCall(newImpl, '');

        // State survives the upgrade.
        assertEq(feeOwner.factory(), address(factory));
        assertEq(feeOwner.revenueCollector(), REVENUE_COLLECTOR);
        assertTrue(feeOwner.hasRole(BOT_ROLE, BOT_ADDR));
        assertTrue(feeOwner.isFactoryOwner());
    }

    /// @notice An upgrade that forgot to re-pass the factory immutable must be refused, not silently
    /// rebind the proxy to another factory.
    function testUpgradeRejectsImplementationWithDifferentFactory() public {
        address otherFactory = deployCode('ListaV3Factory.sol:ListaV3Factory');
        address badImpl = address(new ListaV3FactoryOwner(otherFactory));

        vm.prank(ADMIN);
        vm.expectRevert(bytes('factory immutable mismatch'));
        feeOwner.upgradeToAndCall(badImpl, '');

        assertEq(feeOwner.factory(), address(factory));
    }

    // --- helpers ---

    function _createPoolWithLiquidity(uint24 fee) internal returns (address p) {
        p = npm.createAndInitializePoolIfNecessary(address(token0), address(token1), fee, INITIAL_SQRT_PRICE);
        vm.prank(alice);
        npm.mint(
            INpm.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: fee,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 1e20,
                amount1Desired: 1e20,
                amount0Min: 0,
                amount1Min: 0,
                recipient: alice,
                deadline: block.timestamp + 1000
            })
        );
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        _swapVia(FEE, tokenIn, tokenOut, amountIn);
    }

    function _swapVia(uint24 fee, address tokenIn, address tokenOut, uint256 amountIn) internal {
        vm.prank(alice);
        router.exactInputSingle(
            IRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: alice,
                deadline: block.timestamp + 1000,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }
}

/// @dev Pool-shaped but not deployed by the factory — must be rejected by `_requireListaPool`.
contract ForeignPool {
    address public token0;
    address public token1;
    uint24 public fee;

    constructor(address _token0, address _token1, uint24 _fee) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
    }

    function protocolFees() external pure returns (uint128, uint128) {
        return (type(uint128).max, type(uint128).max);
    }

    function collectProtocol(address, uint128, uint128) external pure returns (uint128, uint128) {
        return (0, 0);
    }
}
