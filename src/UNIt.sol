// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract UNIt is ERC20, Ownable {
    // Address of the collateral manager that can mint/burn tokens
    address public collateralManager;

    constructor() ERC20("UNIt", "UNIT") Ownable(msg.sender) {}

    function setCollateralManager(address _collateralManager) external onlyOwner {
        collateralManager = _collateralManager;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == collateralManager, "Only collateral manager can mint");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == collateralManager, "Only collateral manager can burn");
        _burn(from, amount);
    }
}
