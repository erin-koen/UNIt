// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/contracts/libraries/PoolKey.sol";
import "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import "@uniswap/v4-core/contracts/libraries/Currency.sol";
import "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import "../src/UNIt.sol";
import "../src/UNItHook.sol";

contract UNItHookTest is Test {
    IPoolManager poolManager;
    UNIt unitToken;
    IERC20 collateralToken;
    UNItHook hook;

    address alice = address(1);
    address bob = address(2);
    address charlie = address(3);

    function setUp() public {
        // Deploy test tokens
        unitToken = new UNIt(address(0)); // Revenue recipient will be set later
        collateralToken = IERC20(address(new MockERC20("Collateral", "COL", 18)));

        // Deploy pool manager
        poolManager = IPoolManager(address(new MockPoolManager()));

        // Deploy hook
        hook = new UNItHook(address(poolManager), address(unitToken), address(collateralToken));

        // Set up initial balances
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);

        // Mint test tokens
        MockERC20(address(collateralToken)).mint(alice, 1000 ether);
        MockERC20(address(collateralToken)).mint(bob, 1000 ether);
        MockERC20(address(collateralToken)).mint(charlie, 1000 ether);
    }

    function testAddLiquidityAndMint() public {
        vm.startPrank(alice);

        // Approve collateral token
        collateralToken.approve(address(hook), 100 ether);

        // Add liquidity and mint UNIt
        uint256 mintAmount = 50 ether;
        bytes memory hookData = abi.encode(mintAmount);

        // Mock pool manager call
        vm.mockCall(address(poolManager), abi.encodeWithSelector(IPoolManager.modifyPosition.selector), abi.encode(0));

        hook.beforeAddLiquidity(
            alice,
            hook.poolKey(),
            IPoolManager.ModifyPositionParams({tickLower: -60, tickUpper: 60, liquidityDelta: 100 ether}),
            hookData
        );

        // Check trove was created
        (uint256 collateral, uint256 debt,,) = hook.troves(alice);
        assertEq(collateral, 100 ether);
        assertEq(debt, mintAmount);

        // Check UNIt was minted
        assertEq(unitToken.balanceOf(alice), mintAmount);

        vm.stopPrank();
    }

    function testRemoveLiquidityAndRepay() public {
        // First add liquidity and mint
        testAddLiquidityAndMint();

        vm.startPrank(alice);

        // Approve UNIt token
        unitToken.approve(address(hook), 25 ether);

        // Remove liquidity and repay
        uint256 repayAmount = 25 ether;
        bytes memory hookData = abi.encode(repayAmount);

        // Mock pool manager call
        vm.mockCall(address(poolManager), abi.encodeWithSelector(IPoolManager.modifyPosition.selector), abi.encode(0));

        hook.beforeRemoveLiquidity(
            alice,
            hook.poolKey(),
            IPoolManager.ModifyPositionParams({tickLower: -60, tickUpper: 60, liquidityDelta: -50 ether}),
            hookData
        );

        // Check trove was updated
        (uint256 collateral, uint256 debt,,) = hook.troves(alice);
        assertEq(collateral, 50 ether);
        assertEq(debt, 25 ether);

        // Check UNIt was burned
        assertEq(unitToken.balanceOf(alice), 25 ether);

        vm.stopPrank();
    }

    function testStabilityPool() public {
        // First add liquidity and mint
        testAddLiquidityAndMint();

        vm.startPrank(bob);

        // Approve UNIt token
        unitToken.approve(address(hook), 10 ether);

        // Provide to stability pool
        hook.provideToStabilityPool(10 ether);

        // Check stability deposit
        (uint256 amount,) = hook.stabilityDeposits(bob);
        assertEq(amount, 10 ether);
        assertEq(hook.totalStabilityDeposits(), 10 ether);

        // Withdraw from stability pool
        hook.withdrawFromStabilityPool(5 ether);

        // Check stability deposit
        (amount,) = hook.stabilityDeposits(bob);
        assertEq(amount, 5 ether);
        assertEq(hook.totalStabilityDeposits(), 5 ether);

        vm.stopPrank();
    }

    function testLiquidation() public {
        // First add liquidity and mint
        testAddLiquidityAndMint();

        // Provide to stability pool
        vm.startPrank(bob);
        unitToken.approve(address(hook), 10 ether);
        hook.provideToStabilityPool(10 ether);
        vm.stopPrank();

        // Mock price drop to trigger liquidation
        vm.mockCall(
            address(poolManager),
            abi.encodeWithSelector(IPoolManager.getSlot0.selector),
            abi.encode(
                TickMath.getSqrtRatioAtTick(-100), // Price below liquidation threshold
                0,
                0,
                0,
                0,
                0,
                false
            )
        );

        // Process liquidations
        hook.afterSwap(
            alice,
            hook.poolKey(),
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: 0}),
            BalanceDelta({amount0: 0, amount1: 0}),
            ""
        );

        // Check trove was liquidated
        (uint256 collateral, uint256 debt,, uint8 status) = hook.troves(alice);
        assertEq(status, 3); // Closed by liquidation
        assertEq(collateral, 0);
        assertEq(debt, 0);
    }
}

// Mock contracts for testing
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockPoolManager is IPoolManager {
    function getSlot0(bytes32) external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (TickMath.getSqrtRatioAtTick(0), 0, 0, 0, 0, 0, false);
    }

    function modifyPosition(PoolKey calldata, IPoolManager.ModifyPositionParams calldata, bytes calldata)
        external
        returns (BalanceDelta)
    {
        return BalanceDelta({amount0: 0, amount1: 0});
    }

    function swap(PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata) external returns (BalanceDelta) {
        return BalanceDelta({amount0: 0, amount1: 0});
    }

    function donate(PoolKey calldata, uint256, uint256, bytes calldata) external returns (BalanceDelta) {
        return BalanceDelta({amount0: 0, amount1: 0});
    }

    function take(PoolKey calldata, address, uint256, bytes calldata) external returns (BalanceDelta) {
        return BalanceDelta({amount0: 0, amount1: 0});
    }

    function settle(PoolKey calldata, address, bool, uint256, uint256) external returns (uint128, uint128) {
        return (0, 0);
    }
}
