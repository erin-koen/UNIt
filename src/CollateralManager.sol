// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./UNIt.sol";
import "./LiquidityHook.sol";

contract CollateralManager is ReentrancyGuard {
    UNIt public immutable unitToken;
    LiquidityHook public immutable liquidityHook;

    // Collateral token (e.g., USDC)
    IERC20 public immutable collateralToken;

    // Collateralization ratio (e.g., 150% = 15000)
    uint256 public constant COLLATERALIZATION_RATIO = 15000;

    // Mapping of user addresses to their collateral amounts
    mapping(address => uint256) public userCollateral;

    // Total collateral in the system
    uint256 public totalCollateral;

    // Liquidity allocation percentage (e.g., 50% = 5000)
    uint256 public constant LIQUIDITY_ALLOCATION = 5000;

    constructor(
        address _unitToken,
        address _collateralToken,
        address _liquidityHook
    ) {
        unitToken = UNIt(_unitToken);
        collateralToken = IERC20(_collateralToken);
        liquidityHook = LiquidityHook(_liquidityHook);
    }

    function depositCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer collateral from user
        collateralToken.transferFrom(msg.sender, address(this), amount);

        // Update user's collateral
        userCollateral[msg.sender] += amount;
        totalCollateral += amount;

        // Calculate amount to allocate to liquidity
        uint256 liquidityAmount = (amount * LIQUIDITY_ALLOCATION) / 10000;

        // Approve and transfer to liquidity hook
        collateralToken.approve(address(liquidityHook), liquidityAmount);
        liquidityHook.depositLiquidity(liquidityAmount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(userCollateral[msg.sender] >= amount, "Insufficient collateral");

        // Calculate amount to withdraw from liquidity
        uint256 liquidityAmount = (amount * LIQUIDITY_ALLOCATION) / 10000;

        // Withdraw from liquidity hook
        liquidityHook.withdrawLiquidity(liquidityAmount);

        // Update user's collateral
        userCollateral[msg.sender] -= amount;
        totalCollateral -= amount;

        // Transfer collateral back to user
        collateralToken.transfer(msg.sender, amount);
    }

    function mintUNIt(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        // Calculate required collateral
        uint256 requiredCollateral = (amount * COLLATERALIZATION_RATIO) / 10000;
        require(userCollateral[msg.sender] >= requiredCollateral, "Insufficient collateral");

        // Mint UNIt tokens
        unitToken.mint(msg.sender, amount);
    }

    function burnUNIt(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        // Burn UNIt tokens
        unitToken.burn(msg.sender, amount);
    }
}
