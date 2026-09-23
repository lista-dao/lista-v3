// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {AccessControlEnumerableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';

import {IListaV3Factory} from '../core/interfaces/IListaV3Factory.sol';
import {IListaV3Pool} from '../core/interfaces/IListaV3Pool.sol';

/// @title Factory owner that automates Lista V3 protocol-fee collection
/// @notice Installed as `ListaV3Factory.owner()`. Re-exposes every power ownership confers —
/// anything missing here becomes unreachable until this contract is upgraded or replaced.
/// @dev Roles: BOT triggers collection, MANAGER tunes fee config and the destination and is also
/// BOT's role admin (bot-key rotation is routine ops), DEFAULT_ADMIN_ROLE holds MANAGER membership,
/// upgrades and the factory escape hatch.
/// BOT picks when fees move; the destination is MANAGER-only storage, never a parameter, so a
/// compromised bot key cannot redirect funds. Fees go pool -> revenueCollector in one call; this
/// contract never custodies them and has no sweep function.
contract ListaV3FactoryOwner is UUPSUpgradeable, AccessControlEnumerableUpgradeable {
    /// @dev Triggers fee collection. Holds no power over where fees land.
    bytes32 public constant BOT = keccak256('BOT');

    /// @dev Day-to-day config: protocol-fee split, fee tiers, the fee destination, and BOT membership.
    bytes32 public constant MANAGER = keccak256('MANAGER');

    /// @notice The Lista V3 factory this contract owns. Immutable: this contract's identity is
    /// "owner of this factory" — retargeting it means deploying a new instance, not upgrading.
    address public immutable factory;

    /// @notice Destination for collected fees. MANAGER-only, never caller-supplied.
    address public revenueCollector;

    event ProtocolFeeCollected(address indexed pool, address indexed recipient, uint128 amount0, uint128 amount1);
    event RevenueCollectorChanged(address indexed previous, address indexed current);

    constructor(address _factory) {
        require(_factory != address(0), 'factory=0');
        factory = _factory;
        _disableInitializers();
    }

    function initialize(
        address _revenueCollector,
        address _admin,
        address _manager,
        address _bot
    ) external initializer {
        require(_revenueCollector != address(0), 'revenueCollector=0');
        require(_admin != address(0), 'admin=0');
        require(_manager != address(0), 'manager=0');
        require(_bot != address(0), 'bot=0');

        __AccessControlEnumerable_init();
        __UUPSUpgradeable_init();

        revenueCollector = _revenueCollector;

        // MANAGER rotates bot keys without touching DEFAULT_ADMIN_ROLE. Note the consequence: an
        // account holding only DEFAULT_ADMIN_ROLE cannot grant BOT directly — it must grant itself
        // MANAGER first.
        _setRoleAdmin(BOT, MANAGER);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MANAGER, _manager);
        _grantRole(BOT, _bot);

        emit RevenueCollectorChanged(address(0), _revenueCollector);
    }

    // --- automation ---

    /// @notice Sweep one pool's protocol fees to `revenueCollector`.
    /// @dev The pool leaves 1 wei per side behind on a full sweep, so "empty" is a balance of 0 or 1.
    function collectProtocolFees(address pool) public onlyRole(BOT) returns (uint128 amount0, uint128 amount1) {
        _requireListaPool(pool);

        (uint128 pending0, uint128 pending1) = IListaV3Pool(pool).protocolFees();
        if (pending0 <= 1 && pending1 <= 1) return (0, 0);

        address recipient = revenueCollector;
        (amount0, amount1) = IListaV3Pool(pool).collectProtocol(recipient, type(uint128).max, type(uint128).max);

        emit ProtocolFeeCollected(pool, recipient, amount0, amount1);
    }

    /// @dev Strict: a non-pool entry reverts the batch rather than being skipped, so a bad bot list
    /// surfaces instead of silently under-collecting. Empty pools are no-ops, not failures.
    function collectProtocolFeesBatch(address[] calldata pools) external onlyRole(BOT) {
        for (uint256 i = 0; i < pools.length; i++) {
            collectProtocolFees(pools[i]);
        }
    }

    // --- views ---

    /// @notice Claimable fees per pool. Treat 1 as nothing to collect (see `collectProtocolFees`).
    function pendingProtocolFees(address[] calldata pools)
        external
        view
        returns (uint128[] memory amounts0, uint128[] memory amounts1)
    {
        amounts0 = new uint128[](pools.length);
        amounts1 = new uint128[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            (amounts0[i], amounts1[i]) = IListaV3Pool(pools[i]).protocolFees();
        }
    }

    /// @notice False means this contract is not installed and every admin function below is inert.
    function isFactoryOwner() external view returns (bool) {
        return IListaV3Factory(factory).owner() == address(this);
    }

    // --- manager ---

    /// @notice `n` means 1/n of the swap fee; valid n is 0 or 4..10.
    function setFeeProtocol(
        address pool,
        uint8 feeProtocol0,
        uint8 feeProtocol1
    ) external onlyRole(MANAGER) {
        _requireListaPool(pool);
        IListaV3Pool(pool).setFeeProtocol(feeProtocol0, feeProtocol1);
    }

    function enableFeeAmount(uint24 fee, int24 tickSpacing) external onlyRole(MANAGER) {
        IListaV3Factory(factory).enableFeeAmount(fee, tickSpacing);
    }

    function setRevenueCollector(address _revenueCollector) external onlyRole(MANAGER) {
        require(_revenueCollector != address(0), 'revenueCollector=0');
        emit RevenueCollectorChanged(revenueCollector, _revenueCollector);
        revenueCollector = _revenueCollector;
    }

    // --- default admin ---

    /// @notice Hand the factory to `newOwner`. One-way and immediate — the factory's own `setOwner`
    /// is single-step. An unreachable address permanently freezes fee-tier and protocol-fee admin.
    function transferFactoryOwnership(address newOwner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newOwner != address(0), 'newOwner=0');
        IListaV3Factory(factory).setOwner(newOwner);
    }

    /// @dev `factory` lives in implementation bytecode, so an upgrade that forgot to re-pass it
    /// would silently rebind this proxy to another factory — invisible in proxy storage. Immutables
    /// need no storage, so read it straight off the new implementation and refuse a mismatch.
    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(ListaV3FactoryOwner(newImplementation).factory() == factory, 'factory immutable mismatch');
    }

    /// @dev Without this, a caller could aim this contract's privileged `msg.sender` at an address
    /// of their choosing. Also rejects EOAs.
    function _requireListaPool(address pool) internal view {
        IListaV3Pool p = IListaV3Pool(pool);
        require(IListaV3Factory(factory).getPool(p.token0(), p.token1(), p.fee()) == pool, 'not a Lista V3 pool');
    }
}
