// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import "@uniswap/v4-core/contracts/libraries/PoolKey.sol";
import "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import "@uniswap/v4-core/contracts/libraries/Currency.sol";
import "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./UNIt.sol";

contract UNItHook {
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
        uint256 debt;
        uint256 stake;
        uint8 status; // 0: non-existent, 1: active, 2: closed by owner, 3: closed by liquidation
    }

    mapping(address => Trove) public troves;
    uint256 public totalCollateral;
    uint256 public totalDebt;

    // Stability Pool
    struct StabilityDeposit {
        uint256 amount;
        uint256 stake;
    }

    mapping(address => StabilityDeposit) public stabilityDeposits;
    uint256 public totalStabilityDeposits;

    // Events
    event TroveUpdated(address indexed owner, uint256 collateral, uint256 debt);
    event TroveLiquidated(address indexed owner, uint256 collateral, uint256 debt);
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
            hooks: address(this)
        });
    }

    // Core hook functions
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        require(msg.sender == address(poolManager), "Only pool manager");

        // Extract mint amount from hookData
        uint256 mintAmount = abi.decode(hookData, (uint256));

        // Calculate collateral value
        uint256 collateralValue = _getCollateralValue(params.liquidityDelta);

        // Check if minting is allowed
        if (mintAmount > 0) {
            require(collateralValue >= (mintAmount * MIN_COLLATERAL_RATIO) / 10000, "Insufficient collateral");

            // Update trove
            _updateTrove(sender, collateralValue, mintAmount);

            // User can mint tokens themselves
            unitToken.mint(sender, mintAmount);
        }

        return UNItHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        require(msg.sender == address(poolManager), "Only pool manager");

        // Extract repay amount from hookData
        uint256 repayAmount = abi.decode(hookData, (uint256));

        // Check if repayment is required
        if (repayAmount > 0) {
            require(unitToken.balanceOf(sender) >= repayAmount, "Insufficient UNIt balance");

            // User can burn tokens themselves
            unitToken.burn(sender, repayAmount);

            // Update trove
            _updateTrove(sender, 0, -repayAmount);
        }

        return UNItHook.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        require(msg.sender == address(poolManager), "Only pool manager");

        // Check if redemption is triggered
        if (_shouldTriggerRedemption(params)) {
            _processRedemption(params.amountSpecified);
            return 0; // Halt normal swap execution
        }

        return UNItHook.beforeSwap.selector;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external {
        require(msg.sender == address(poolManager), "Only pool manager");

        // Check for undercollateralized troves
        _processLiquidations();

        // Calculate and distribute revenue
        uint256 revenue = _calculateRevenue(delta);
        if (revenue > 0) {
            unitToken.distributeRevenue(revenue);
            emit RevenueGenerated(revenue);
        }
    }

    // Internal functions
    function _updateTrove(address owner, uint256 collateralDelta, uint256 debtDelta) internal {
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
        (uint160 sqrtPriceX96,,,,,,) = poolManager.getSlot0(PoolId.toId(poolKey));
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 96);

        // Iterate through troves and check collateralization
        // Note: In production, we'd want to use a sorted list for efficiency
        address[] memory troveOwners = _getActiveTroveOwners();

        for (uint256 i = 0; i < troveOwners.length; i++) {
            address owner = troveOwners[i];
            Trove storage trove = troves[owner];

            if (trove.status != 1) continue; // Skip non-active troves

            uint256 collateralValue = (trove.collateral * price) / 1e18;
            uint256 minCollateralValue = (trove.debt * MIN_COLLATERAL_RATIO) / 10000;

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
        (uint160 sqrtPriceX96,,,,,,) = poolManager.getSlot0(PoolId.toId(poolKey));
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 96);

        // Calculate redemption fee
        uint256 fee = (amount * REDEMPTION_FEE) / 10000;
        uint256 amountAfterFee = amount - fee;

        // Calculate collateral to send
        uint256 collateralToSend = (amountAfterFee * 1e18) / price;
        require(collateralToSend <= totalCollateral, "Insufficient collateral");

        // Update total debt and collateral
        totalDebt -= amount;
        totalCollateral -= collateralToSend;

        // Transfer collateral to redeemer
        collateralToken.transfer(msg.sender, collateralToSend);

        // Distribute fee to revenue recipient
        unitToken.distributeRevenue(fee);

        emit Redemption(amount, collateralToSend);
    }

    function _shouldTriggerRedemption(IPoolManager.SwapParams calldata params) internal view returns (bool) {
        // Get current price from Uniswap pool
        (uint160 sqrtPriceX96,,,,,,) = poolManager.getSlot0(PoolId.toId(poolKey));
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

    function _getCollateralValue(uint128 liquidity) internal view returns (uint256) {
        // Get current price from Uniswap pool
        (uint160 sqrtPriceX96,,,,,,) = poolManager.getSlot0(PoolId.toId(poolKey));
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / (1 << 96);

        // Calculate collateral value based on liquidity and price
        // This is a simplified calculation - in production, we'd want to use more precise math
        return (uint256(liquidity) * price) / 1e18;
    }

    function _calculateRevenue(BalanceDelta delta) internal pure returns (uint256) {
        // Calculate revenue from swap fees
        // In production, we'd want to track fees more precisely
        return uint256(delta.amount0()) > 0 ? uint256(delta.amount0()) : 0;
    }

    // Helper functions
    function _getActiveTroveOwners() internal view returns (address[] memory) {
        // Note: This is a simplified implementation
        // In production, we'd want to use a more efficient data structure
        address[] memory owners = new address[](100); // Arbitrary size
        uint256 count = 0;

        for (uint256 i = 0; i < 100; i++) {
            address owner = address(uint160(i + 1));
            if (troves[owner].status == 1) {
                owners[count] = owner;
                count++;
            }
        }

        // Resize array
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = owners[i];
        }

        return result;
    }

    function _distributeToStabilityPool(uint256 amount) internal {
        // Distribute collateral to stability pool depositors proportionally
        if (totalStabilityDeposits == 0) return;

        uint256 remainingAmount = amount;
        address[] memory depositors = _getStabilityPoolDepositors();

        for (uint256 i = 0; i < depositors.length; i++) {
            address depositor = depositors[i];
            StabilityDeposit storage deposit = stabilityDeposits[depositor];

            if (deposit.amount == 0) continue;

            uint256 share = (amount * deposit.amount) / totalStabilityDeposits;
            if (share > remainingAmount) {
                share = remainingAmount;
            }

            collateralToken.transfer(depositor, share);
            remainingAmount -= share;

            if (remainingAmount == 0) break;
        }
    }

    function _getStabilityPoolDepositors() internal view returns (address[] memory) {
        // Note: This is a simplified implementation
        // In production, we'd want to use a more efficient data structure
        address[] memory depositors = new address[](100); // Arbitrary size
        uint256 count = 0;

        for (uint256 i = 0; i < 100; i++) {
            address depositor = address(uint160(i + 1));
            if (stabilityDeposits[depositor].amount > 0) {
                depositors[count] = depositor;
                count++;
            }
        }

        // Resize array
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = depositors[i];
        }

        return result;
    }

    // Public functions for stability pool
    function provideToStabilityPool(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        unitToken.transferFrom(msg.sender, address(this), amount);

        StabilityDeposit storage deposit = stabilityDeposits[msg.sender];
        deposit.amount += amount;
        deposit.stake += amount;

        totalStabilityDeposits += amount;

        emit StabilityDepositUpdated(msg.sender, deposit.amount);
    }

    function withdrawFromStabilityPool(uint256 amount) external {
        StabilityDeposit storage deposit = stabilityDeposits[msg.sender];
        require(deposit.amount >= amount, "Insufficient deposit");

        deposit.amount -= amount;
        deposit.stake -= amount;

        totalStabilityDeposits -= amount;

        unitToken.transfer(msg.sender, amount);

        emit StabilityDepositUpdated(msg.sender, deposit.amount);
    }
}
