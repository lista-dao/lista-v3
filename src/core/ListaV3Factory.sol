// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import 'lib/openzeppelin-contracts-upgradeable/contracts/proxy/Initializable.sol';

import './interfaces/IListaV3Factory.sol';

import './ListaV3PoolDeployer.sol';

import './ListaV3Pool.sol';

/// @title Canonical Lista V3 factory
/// @notice Deploys Lista V3 pools and manages ownership and control over pool protocol fees
/// @dev Deployed behind a TransparentUpgradeableProxy; initialize() replaces the constructor.
contract ListaV3Factory is IListaV3Factory, ListaV3PoolDeployer, Initializable {
    /// @inheritdoc IListaV3Factory
    address public override owner;

    /// @inheritdoc IListaV3Factory
    mapping(uint24 => int24) public override feeAmountTickSpacing;
    /// @inheritdoc IListaV3Factory
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;

    /// @dev Reserved for future layout additions behind the proxy.
    uint256[50] private __gap;

    function initialize(address owner_) external initializer {
        require(owner_ != address(0));
        owner = owner_;
        emit OwnerChanged(address(0), owner_);

        feeAmountTickSpacing[500] = 10;
        emit FeeAmountEnabled(500, 10);
        feeAmountTickSpacing[3000] = 60;
        emit FeeAmountEnabled(3000, 60);
        feeAmountTickSpacing[10000] = 200;
        emit FeeAmountEnabled(10000, 200);
    }

    /// @inheritdoc IListaV3Factory
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external override returns (address pool) {
        require(tokenA != tokenB);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0));
        int24 tickSpacing = feeAmountTickSpacing[fee];
        require(tickSpacing != 0);
        require(getPool[token0][token1][fee] == address(0));
        pool = deploy(address(this), token0, token1, fee, tickSpacing);
        getPool[token0][token1][fee] = pool;
        // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses
        getPool[token1][token0][fee] = pool;
        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    /// @inheritdoc IListaV3Factory
    function setOwner(address _owner) external override {
        require(msg.sender == owner);
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    /// @inheritdoc IListaV3Factory
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override {
        require(msg.sender == owner);
        require(fee < 1000000);
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(tickSpacing > 0 && tickSpacing < 16384);
        require(feeAmountTickSpacing[fee] == 0);

        feeAmountTickSpacing[fee] = tickSpacing;
        emit FeeAmountEnabled(fee, tickSpacing);
    }
}
