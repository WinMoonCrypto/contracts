// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";

contract FeeHandler is Ownable {
	event EthWithdraw(uint256 amount);

	constructor(address _initialOwner) Ownable() {
		_transferOwnership(_initialOwner);
	}

	receive() external payable {}

	function withdraw() public onlyOwner {
		uint256 amount = address(this).balance;
		require(amount > 0, "Nothing to withdraw; contract balance empty");

		address _owner = owner();
		(bool sent, ) = _owner.call{ value: amount }("");
		require(sent, "Failed to send Ether");
		emit EthWithdraw(amount);
	}
}
