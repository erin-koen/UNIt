// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/contracts/libraries/PoolKey.sol";
import "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import "@uniswap/v4-core/contracts/libraries/Currency.sol";
import "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiquidityHook {
    IPoolManager public immutable poolManager;
    IERC20 public immutable collateralToken;
    UNIt public immutable unitToken;

    // Pool key for the UNIt/collateral pool
    PoolKey public poolKey;

    // Current liquidity position
    int24 public currentTickLower;
    int24 public currentTickUpper;
    uint128 public currentLiquidity;

    // Constants for liquidity range
    int24 public constant TICK_SPACING = 60;
    int24 public constant RANGE_MULTIPLIER = 2;

    constructor(
        address _poolManager,
        address _collateralToken,
        address _unitToken
    ) {
        poolManager = IPoolManager(_poolManager);
        collateralToken = IERC20(_collateralToken);
        unitToken = UNIt(_unitToken);

        // Initialize pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(collateralToken)),
            currency1: Currency.wrap(address(unitToken)),
            fee: 3000, // 0.3% fee tier
            tickSpacing: TICK_SPACING,
            hooks: address(this)
        });
    }

    function depositLiquidity(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        // Calculate tick range based on current price
        (uint160 sqrtPriceX96, int24 currentTick, , , , , ) = poolManager.getSlot0(PoolId.toId(poolKey));

        // Set range around current price
        currentTickLower = currentTick - (TICK_SPACING * RANGE_MULTIPLIER);
        currentTickUpper = currentTick + (TICK_SPACING * RANGE_MULTIPLIER);

        // Calculate liquidity amount
        uint128 liquidity = _calculateLiquidity(
            amount,
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(currentTickLower),
            TickMath.getSqrtRatioAtTick(currentTickUpper)
        );

        // Add liquidity to pool
        poolManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: currentTickLower,
                tickUpper: currentTickUpper,
                liquidityDelta: int128(liquidity)
            })
        );

        currentLiquidity = liquidity;
    }

    function withdrawLiquidity(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        require(currentLiquidity > 0, "No liquidity to withdraw");

        // Calculate liquidity to withdraw
        uint128 liquidityToWithdraw = uint128((amount * uint256(currentLiquidity)) / collateralToken.balanceOf(address(this)));

        // Remove liquidity from pool
        poolManager.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams({
                tickLower: currentTickLower,
                tickUpper: currentTickUpper,
                liquidityDelta: -int128(liquidityToWithdraw)
            })
        );

        currentLiquidity -= liquidityToWithdraw;
    }

    function _calculateLiquidity(
        uint256 amount,
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96
    ) internal pure returns (uint128) {
        // Simplified liquidity calculation
        // In a real implementation, this would use more precise math
        return uint128(amount);
    }
}
