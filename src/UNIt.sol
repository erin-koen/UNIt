// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract UNIt is ERC20 {
    // Address where revenue is automatically sent
    address public immutable revenueRecipient;

    // Events
    event RevenueDistributed(uint256 amount);

    constructor(address _revenueRecipient) ERC20("UNIt", "UNIT") {
        require(_revenueRecipient != address(0), "Invalid revenue recipient");
        revenueRecipient = _revenueRecipient;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function distributeRevenue(uint256 amount) external {
        _transfer(address(this), revenueRecipient, amount);
        emit RevenueDistributed(amount);
    }
}
