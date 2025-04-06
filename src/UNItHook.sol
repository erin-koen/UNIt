// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../lib/v4-core/src/interfaces/IPoolManager.sol";
import "../lib/v4-core/src/interfaces/IHooks.sol";
import "../lib/v4-core/src/types/PoolKey.sol";
import "../lib/v4-core/src/types/PoolId.sol";
import "../lib/v4-core/src/types/Currency.sol";
import "../lib/v4-core/src/libraries/TickMath.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "./UNIt.sol";

contract UNItHook is IHooks {
    IPoolManager public immutable poolManager;
    UNIt public immutable unitToken;
    IERC20 public immutable collateralToken;

    // Pool key for the UNIt/collateral pool
    PoolKey public poolKey;

    // Constants
    uint256 public constant MIN_COLLATERAL_RATIO = 11000; // 110%
    uint256 public constant LIQUIDATION_PENALTY = 1000; // 10%
    uint256 public constant REDEMPTION_FEE = 50; // 0.5%

    // Trove management
    struct Trove {
        uint256 collateral;
        int256 debt;
        uint256 stake;
        uint8 status; // 0: non-existent, 1: active, 2: closed by owner, 3: closed by liquidation
    }

    mapping(address => Trove) public troves;
    uint256 public totalCollateral;
    int256 public totalDebt;

    // Stability Pool
    struct StabilityDeposit {
        uint256 amount;
        uint256 stake;
    }

    mapping(address => StabilityDeposit) public stabilityDeposits;
    uint256 public totalStabilityDeposits;

    // Events
    event TroveUpdated(address indexed owner, uint256 collateral, int256 debt);
    event TroveLiquidated(address indexed owner, uint256 collateral, int256 debt);
    event StabilityDepositUpdated(address indexed owner, uint256 amount);
    event Redemption(uint256 amount, uint256 collateral);
    event RevenueGenerated(uint256 amount);

    constructor(address _poolManager, address _unitToken, address _collateralToken) {
        poolManager = IPoolManager(_poolManager);
        unitToken = UNIt(_unitToken);
        collateralToken = IERC20(_collateralToken);

        // Initialize pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(collateralToken)),
            currency1: Currency.wrap(address(unitToken)),
            fee: 3000, // 0.3% fee tier
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });
    }

    // Core hook functions
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == address(poolManager), "Only pool manager");

        // Check if redemption is triggered
        if (_shouldTriggerRedemption(params)) {
            _processRedemption(uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified));
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        require(msg.sender == address(poolManager), "Only pool manager");

        // Check for undercollateralized troves
        _processLiquidations();

        // Calculate and distribute revenue
        uint256 revenue = _calculateRevenue(delta);
        if (revenue > 0) {
            unitToken.distributeRevenue(revenue);
            emit RevenueGenerated(revenue);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    // Internal functions
    function _updateTrove(address owner, uint256 collateralDelta, int256 debtDelta) internal {
        Trove storage trove = troves[owner];

        if (trove.status == 0) {
            trove.status = 1;
        }

        trove.collateral += collateralDelta;
        trove.debt += debtDelta;

        totalCollateral += collateralDelta;
        totalDebt += debtDelta;

        emit TroveUpdated(owner, trove.collateral, trove.debt);
    }

    function _processLiquidations() internal {
        // Get current price from Uniswap pool
        bytes32 poolId = keccak256(abi.encode(poolKey));
        uint160 sqrtPriceX96 = _getCurrentPrice(poolId);
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 96);

        // Iterate through troves and check collateralization
        // Note: In production, we'd want to use a sorted list for efficiency
        address[] memory troveOwners = _getActiveTroveOwners();

        for (uint256 i = 0; i < troveOwners.length; i++) {
            address owner = troveOwners[i];
            Trove storage trove = troves[owner];

            if (trove.status != 1) continue; // Skip non-active troves

            uint256 collateralValue = (trove.collateral * price) / 1e18;
            uint256 minCollateralValue =
                (uint256(trove.debt > 0 ? trove.debt : -trove.debt) * MIN_COLLATERAL_RATIO) / 10000;

            if (collateralValue < minCollateralValue) {
                // Calculate liquidation reward
                uint256 liquidationReward = (trove.collateral * LIQUIDATION_PENALTY) / 10000;

                // Distribute collateral to stability pool
                if (totalStabilityDeposits > 0) {
                    uint256 stabilityPoolShare = trove.collateral - liquidationReward;
                    _distributeToStabilityPool(stabilityPoolShare);
                }

                // Update trove status
                trove.status = 3; // Closed by liquidation
                totalCollateral -= trove.collateral;
                totalDebt -= trove.debt;

                emit TroveLiquidated(owner, trove.collateral, trove.debt);
            }
        }
    }

    function _processRedemption(uint256 amount) internal {
        require(amount > 0, "Redemption amount must be positive");
        require(totalCollateral > 0, "No collateral available");

        // Get current price from Uniswap pool
        bytes32 poolId = keccak256(abi.encode(poolKey));
        uint160 sqrtPriceX96 = _getCurrentPrice(poolId);
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 96);

        // Calculate redemption fee
        uint256 fee = (amount * REDEMPTION_FEE) / 10000;
        uint256 amountAfterFee = amount - fee;

        // Calculate collateral to send
        uint256 collateralToSend = (amountAfterFee * 1e18) / price;
        require(collateralToSend <= totalCollateral, "Insufficient collateral");

        // Update total debt and collateral
        totalDebt -= int256(amount);
        totalCollateral -= collateralToSend;

        // Transfer collateral to redeemer
        collateralToken.transfer(msg.sender, collateralToSend);

        // Distribute fee to revenue recipient
        unitToken.distributeRevenue(fee);

        emit Redemption(amount, collateralToSend);
    }

    function _shouldTriggerRedemption(IPoolManager.SwapParams calldata params) internal view returns (bool) {
        // Get current price from Uniswap pool
        bytes32 poolId = keccak256(abi.encode(poolKey));
        uint160 sqrtPriceX96 = _getCurrentPrice(poolId);
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 96);

        // Check if swap would push price below peg (1:1)
        if (params.zeroForOne) {
            // Selling UNIt for collateral
            return price < 1e18;
        } else {
            // Buying UNIt with collateral
            return false;
        }
    }

    function _getCollateralValue(int256 liquidityDelta) internal view returns (uint256) {
        // Get current price from Uniswap pool
        bytes32 poolId = keccak256(abi.encode(poolKey));
        uint160 sqrtPriceX96 = _getCurrentPrice(poolId);
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 96);

        // Calculate collateral value based on liquidity and price
        return uint256(liquidityDelta > 0 ? liquidityDelta : -liquidityDelta) * price / 1e18;
    }

    function _calculateRevenue(BalanceDelta delta) internal pure returns (uint256) {
        // Calculate revenue from swap fees
        // This is a simplified version - in production, you'd want to calculate
        // the actual fees based on the pool's fee tier and the swap amount
        if (delta.amount0() > 0) {
            return uint256(uint128(delta.amount0()));
        } else if (delta.amount1() < 0) {
            return uint256(uint128(-delta.amount1()));
        }
        return 0;
    }

    function _distributeToStabilityPool(uint256 amount) internal {
        // Distribute collateral to stability pool depositors
        // This is a simplified version - in production, you'd want to calculate
        // the share for each depositor based on their stake
        uint256 totalStake = 0;
        address[] memory depositors = _getStabilityDepositors();

        for (uint256 i = 0; i < depositors.length; i++) {
            totalStake += stabilityDeposits[depositors[i]].stake;
        }

        for (uint256 i = 0; i < depositors.length; i++) {
            address depositor = depositors[i];
            uint256 share = (amount * stabilityDeposits[depositor].stake) / totalStake;
            collateralToken.transfer(depositor, share);
        }
    }

    function _getActiveTroveOwners() internal view returns (address[] memory) {
        // This is a simplified version - in production, you'd want to use
        // a more efficient data structure for tracking active troves
        address[] memory owners = new address[](100); // Arbitrary size
        uint256 count = 0;

        for (uint256 i = 0; i < 100; i++) {
            address owner = address(uint160(i + 1));
            if (troves[owner].status == 1) {
                owners[count] = owner;
                count++;
            }
        }

        // Resize array to actual count
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = owners[i];
        }

        return result;
    }

    function _getStabilityDepositors() internal view returns (address[] memory) {
        // This is a simplified version - in production, you'd want to use
        // a more efficient data structure for tracking stability depositors
        address[] memory depositors = new address[](100); // Arbitrary size
        uint256 count = 0;

        for (uint256 i = 0; i < 100; i++) {
            address depositor = address(uint160(i + 1));
            if (stabilityDeposits[depositor].amount > 0) {
                depositors[count] = depositor;
                count++;
            }
        }

        // Resize array to actual count
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = depositors[i];
        }

        return result;
    }

    function _getCurrentPrice(bytes32 poolId) internal view returns (uint160) {
        // For now, return a fixed price of 1:1
        // In production, we would need to implement proper price fetching
        return uint160(1 << 96);
    }
}
