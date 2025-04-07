// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/UNIt.sol";
import "../src/UNItHook.sol";
import "../lib/v4-core/src/interfaces/IPoolManager.sol";
import "../lib/v4-core/src/types/PoolKey.sol";
import "../lib/v4-core/src/types/PoolId.sol";
import "../lib/v4-core/src/types/Currency.sol";
import "../lib/v4-core/src/types/BalanceDelta.sol";
import "../lib/v4-core/src/libraries/TickMath.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract UNItHookTest is Test {
    UNIt public unitToken;
    UNItHook public hook;
    IPoolManager public poolManager;
    IERC20 public collateralToken;

    address public constant POOL_MANAGER = address(1);
    address public constant COLLATERAL_TOKEN = address(2);
    address public constant USER = address(3);
    address public constant REVENUE_RECIPIENT = address(4);

    function setUp() public {
        vm.startPrank(USER);

        // Deploy UNIt token with revenue recipient
        unitToken = new UNIt(REVENUE_RECIPIENT);

        // Deploy hook
        hook = new UNItHook(POOL_MANAGER, address(unitToken), COLLATERAL_TOKEN);

        // Set up mock pool manager
        poolManager = IPoolManager(POOL_MANAGER);

        // Set up mock collateral token
        collateralToken = IERC20(COLLATERAL_TOKEN);

        vm.stopPrank();
    }

    function testAddLiquidity() public {
        vm.startPrank(USER);

        // Prepare pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(COLLATERAL_TOKEN),
            currency1: Currency.wrap(address(unitToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        // Prepare modify liquidity params
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: bytes32(0)});

        // Prepare hook data (mint amount)
        bytes memory hookData = abi.encode(uint256(100));

        // Call hook
        bytes4 selector = hook.beforeAddLiquidity(USER, key, params, hookData);

        // Verify selector
        assertEq(selector, hook.beforeAddLiquidity.selector);

        vm.stopPrank();
    }

    function testRemoveLiquidity() public {
        vm.startPrank(USER);

        // Prepare pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(COLLATERAL_TOKEN),
            currency1: Currency.wrap(address(unitToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        // Prepare modify liquidity params
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: bytes32(0)});

        // Prepare hook data (repay amount)
        bytes memory hookData = abi.encode(uint256(100));

        // Call hook
        bytes4 selector = hook.beforeRemoveLiquidity(USER, key, params, hookData);

        // Verify selector
        assertEq(selector, hook.beforeRemoveLiquidity.selector);

        vm.stopPrank();
    }

    function testSwap() public {
        vm.startPrank(POOL_MANAGER);

        // Prepare pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(COLLATERAL_TOKEN),
            currency1: Currency.wrap(address(unitToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        // Prepare swap params
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1000, sqrtPriceLimitX96: 0});

        // Call hook
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(POOL_MANAGER, key, params, "");

        // Verify selector
        assertEq(selector, hook.beforeSwap.selector);

        vm.stopPrank();
    }

    function testAfterSwap() public {
        vm.startPrank(POOL_MANAGER);

        // Prepare pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(COLLATERAL_TOKEN),
            currency1: Currency.wrap(address(unitToken)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        // Prepare swap params
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1000, sqrtPriceLimitX96: 0});

        // Prepare balance delta
        BalanceDelta delta = BalanceDelta.wrap(0);

        // Call hook
        (bytes4 selector, int128 hookDelta) = hook.afterSwap(POOL_MANAGER, key, params, delta, "");

        // Verify selector
        assertEq(selector, hook.afterSwap.selector);

        vm.stopPrank();
    }
}

// Mock contracts for testing
contract MockERC20 is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_allowances[from][msg.sender] >= amount, "Insufficient allowance");
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }

    // Test helper functions
    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        _balances[from] -= amount;
        _totalSupply -= amount;
    }
}

contract MockPoolManager is IPoolManager {
    mapping(bytes32 => Pool) private pools;
    mapping(address => mapping(uint256 => uint256)) private _balances;
    mapping(address => mapping(address => mapping(uint256 => uint256))) private _allowances;
    mapping(address => mapping(address => bool)) private _operators;
    mapping(Currency => uint256) private _protocolFeesAccrued;
    address private _protocolFeeController;

    struct Pool {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint256 fee;
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        bytes32 poolId = keccak256(abi.encode(key));
        pools[poolId] = Pool({sqrtPriceX96: sqrtPriceX96, tick: 0, liquidity: 0, fee: uint256(key.fee)});
        return 0;
    }

    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes calldata hookData
    ) external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        bytes32 poolId = keccak256(abi.encode(key));
        Pool storage pool = pools[poolId];

        // Safe conversion of liquidityDelta to uint128
        if (params.liquidityDelta >= 0) {
            pool.liquidity = pool.liquidity + uint128(uint256(params.liquidityDelta));
        } else {
            pool.liquidity = pool.liquidity - uint128(uint256(-params.liquidityDelta));
        }

        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata hookData)
        external
        returns (BalanceDelta delta)
    {
        return BalanceDelta.wrap(0);
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        returns (BalanceDelta delta)
    {
        return BalanceDelta.wrap(0);
    }

    function take(Currency currency, address to, uint256 amount) external {
        // No-op
    }

    function settle() external payable returns (uint256) {
        return 0;
    }

    function settleFor(address recipient) external payable returns (uint256) {
        return 0;
    }

    function mint(Currency currency, address to, uint256 amount) external {
        // No-op
    }

    function burn(Currency currency, address to, uint256 amount) external {
        // No-op
    }

    function mint(address to, uint256 id, uint256 amount) external {
        _balances[to][id] += amount;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        _balances[from][id] -= amount;
    }

    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return _balances[owner][id];
    }

    function allowance(address owner, address spender, uint256 id) external view returns (uint256) {
        return _allowances[owner][spender][id];
    }

    function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender][id] = amount;
        return true;
    }

    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool) {
        _balances[msg.sender][id] -= amount;
        _balances[receiver][id] += amount;
        return true;
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool) {
        require(_allowances[sender][msg.sender][id] >= amount, "Insufficient allowance");
        _allowances[sender][msg.sender][id] -= amount;
        _balances[sender][id] -= amount;
        _balances[receiver][id] += amount;
        return true;
    }

    function isOperator(address owner, address spender) external view returns (bool) {
        return _operators[owner][spender];
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        _operators[msg.sender][operator] = approved;
        return true;
    }

    function lock(bytes calldata data) external returns (bytes memory) {
        bytes32 poolId = abi.decode(data, (bytes32));
        Pool storage pool = pools[poolId];
        return abi.encode(pool.sqrtPriceX96, pool.tick, 0, 0, 0, 60, true);
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return data;
    }

    function clear(Currency currency, uint256 amount) external {
        // No-op
    }

    function sync(Currency currency) external {
        // No-op
    }

    function collectProtocolFees(address recipient, Currency currency, uint256 amount) external returns (uint256) {
        _protocolFeesAccrued[currency] -= amount;
        return amount;
    }

    function collectProtocolFees(PoolKey calldata key, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        return (0, 0);
    }

    function protocolFeesAccrued(Currency currency) external view returns (uint256) {
        return _protocolFeesAccrued[currency];
    }

    function protocolFeeController() external view returns (address) {
        return _protocolFeeController;
    }

    function setProtocolFee(PoolKey calldata key, uint24 newProtocolFee) external {
        // No-op
    }

    function setProtocolFeeController(address controller) external {
        _protocolFeeController = controller;
    }

    function updateDynamicLPFee(PoolKey calldata key, uint24 newDynamicLPFee) external {
        // No-op
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return bytes32(0);
    }

    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function exttload(bytes32 slot) external view returns (bytes32) {
        return bytes32(0);
    }

    function exttload(bytes32[] calldata slots) external view returns (bytes32[] memory) {
        return new bytes32[](0);
    }
}
