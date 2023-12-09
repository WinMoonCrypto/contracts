// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IWETH.sol";

/// @dev It saves in an ordered array the holders and the current
/// tickets count.
/// For calculating the winners, from the huge random number generated
/// a normalized random is generated by using the module method, adding 1 to have
/// a random from 1 to tickets.
/// So next step is to perform a binary search on the ordered array to get the
/// player O(log n)
/// Example:
// / 0 -> { 1, player1} as player1 has 1 ticket
// / 1 -> {51, player2} as player2 buys 50 ticket
// / 2 -> {52, player3} as player3 buys 1 ticket
// / 3 -> {53, player4} as player4 buys 1 ticket
// / 4 -> {153, player5} as player5 buys 100 ticket
/// So the setWinner method performs a binary search on that sorted array to get the upper bound.
/// If the random number generated is 150, the winner is player5. If the random number is 20, winner is player2

contract WINMOON is ERC20, ERC20Burnable, Ownable {
	struct EpochData {
		uint256 epoch;
		uint256 totalPlayers;
		uint256 totalWinners;
		uint256 totalEntries;
	}

	mapping(uint256 => EpochData) public epochs;
	// EpochData[] epochs;

	address[] private _allOwners;
	mapping(address owner => uint256) private _allOwnersIndex;

	address[] private _allSuperBoosts;
	mapping(address booster => uint256 index) private _allSuperBoostsIndex;

	// In order to calculate the winner, in this struct is saved for each bought the data
	struct EntriesData {
		uint256 currentEntriesLength; // current amount of entries bought
		address player; // wallet address of the player
	}
	// every epoch has a sorted array of EntriesData.

	struct PlayersData {
		address player; // wallet address of the player
		uint256 totalWins; // how many times has won
	}

	mapping(uint256 => EntriesData[]) public entriesList;

	// mapping epoch to entries
	mapping(uint256 => uint256) public totalEntries;

	mapping(uint256 => mapping(address => uint256)) public playerEntryIndex;

	// Percentage boost for each wallet.  100 = 100% = no boost
	mapping(address => uint256) public walletBoosts;

	// Mapping of epoch -> player -> boost
	mapping(uint256 _epoch => mapping(address _player => uint256 _boost))
		public epochBoosts; // 100 = 100% = no boost

	/// @dev Mapping of epochs to winners
	mapping(uint256 => address[]) public winners;

	/// @dev Mapping of epochs to winners
	mapping(uint256 => mapping(address => uint256)) public winnersIndex;

	// store addresses that a automatic market maker pairs. Any transfer from these addresses
	// should always be allowed
	mapping(address => bool) public automatedMarketMakerPairs;

	// uint256 public totalHolders = 0;
	uint256 public epoch = 0;
	uint256 public lastRollover;
	uint256 public immutable epochDuration = 86400;

	IUniswapV2Router02 public uniswapV2Router;
	address public uniswapV2Pair;
	address public WETH;

	address payable public feeReceiver;

	uint256 private constant BUY_DAILY_BOOST = 300;
	uint256 private constant BUY_BOOST_MIN_BUY = 0.1 ether;
	uint256 private constant LOGIN_DAILY_BOOST = 200;
	uint256 private constant SUPER_BOOST = 300;
	uint256 private constant SUPER_BOOST_COST = 1 ether;

	function totalHolders() public view virtual returns (uint256) {
		return _allOwners.length;
	}

	// exclude from all restrictions
	mapping(address => bool) private _excludeFromRestrictions;

	event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
	event ExcludeFromRestrictions(address indexed account, bool isExcluded);

	event BoughtSuperBoost(address indexed player, uint epoch);
	event BoughtWinMoon(
		address indexed player,
		uint epoch,
		uint bnbAmount,
		uint winmoonAmount
	);
	event NewWinner(uint indexed epoch, address winner);
	event PairInitialized(address router, address pair);
	event EthWithdraw(uint256 amount);
	event NewFeeReceiver(address payable account);

	constructor(
		address initialOwner,
		IUniswapV2Router02 _router,
		address payable _feeReceiver
	) ERC20("WINMOON.XYZ", "WINMOON") Ownable() {
		feeReceiver = _feeReceiver;
		_mint(initialOwner, 777777777 * 10 ** decimals());
		_transferOwnership(initialOwner);
		if (address(_router) != address(0)) {
			initializePair(_router, true);
		}
		_excludeFromRestrictions[address(this)] = true;
		_excludeFromRestrictions[initialOwner] = true;
	}

	function holder(uint256 index) external view returns (address) {
		return _allOwners[index];
	}

	// TODO test this
	function initializePair(
		IUniswapV2Router02 _uniswapV2Router,
		bool createPair
	) public onlyOwner {
		uniswapV2Router = _uniswapV2Router;

		if (createPair) {
			uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
				.createPair(address(this), uniswapV2Router.WETH());
		} else {
			uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory())
				.getPair(address(this), uniswapV2Router.WETH());
		}

		require(
			address(uniswapV2Router) != address(0) &&
				uniswapV2Pair != address(0),
			"Router and pair not set correctly"
		);
		_setAutomatedMarketMakerPair(uniswapV2Pair, true);
		WETH = uniswapV2Router.WETH();

		_approveTokenIfNeeded(WETH, address(uniswapV2Router));

		emit PairInitialized(address(uniswapV2Router), address(uniswapV2Pair));
	}

	function start(uint256 _startTime) external onlyOwner {
		require(epoch == 0);
		require(
			uniswapV2Pair != address(0) &&
				address(uniswapV2Router) != address(0),
			"Router and pair must be initialized"
		);

		lastRollover = _startTime;
		_calculateEntries();
	}

	function rollover() public {
		require(lastRollover > 0, "Cannot rollover before start");
		require(
			block.timestamp >= lastRollover + epochDuration,
			"Too soon, too soon"
		);
		epoch++;

		_calculateEntries();

		for (uint i = 0; i < numberOfWinners(); i++) {
			address thisWinner = getWinnerAddressFromRandom(
				epoch + epochDuration + numberOfWinners() + i //some nonsense numbers to feed the generator
			);
			winners[epoch].push(thisWinner);
			winnersIndex[epoch][thisWinner] = winners[epoch].length;
			emit NewWinner(epoch, thisWinner);
		}

		epochs[epoch] = EpochData({
			epoch: epoch,
			totalPlayers: totalPlayersFromEpoch(epoch),
			totalEntries: totalEntries[epoch],
			totalWinners: numberOfWinnersFromEpoch(epoch)
		});

		lastRollover += epochDuration;
	}

	/*  VIEWS  */

	function numberOfWinners() public view returns (uint256) {
		if (currentTotalPlayers() <= 100) {
			return 1;
		}

		return (currentTotalPlayers() / 100) + 1;
	}

	function oddsOfGettingDrawn(
		address account
	) external view returns (uint256) {
		uint256 playerEntriesPercent = currentPlayersEntries(account) * 100000;
		return playerEntriesPercent / currentTotalEntries();
	}

	function currentTotalEntries() internal view returns (uint256) {
		return totalEntries[epoch];
	}

	function currentTotalPlayers() internal view returns (uint256) {
		return entriesList[epoch].length;
	}

	function totalPlayersFromEpoch(
		uint256 _epoch
	) internal view returns (uint256) {
		return entriesList[_epoch].length;
	}

	function currentWinners() public view returns (address[] memory _winners) {
		uint i = 0;
		_winners = new address[](winners[epoch].length);
		while (winners[epoch].length > i) {
			_winners[i] = winners[epoch][i];
			i++;
		}
	}

	function numberOfWinnersFromEpoch(
		uint256 _epoch
	) internal view returns (uint256 _totalWinners) {
		_totalWinners = winners[_epoch].length;
	}

	function checkWinner(address player) public view returns (bool) {
		address[] memory currentWinningPlayers = currentWinners();
		uint i = 0;
		while (currentWinningPlayers.length > i) {
			if (player == currentWinningPlayers[i]) {
				return true;
			}
			i++;
		}
		return false;
	}

	function playerEntriesByEpoch(
		address account,
		uint256 _epoch
	) external view returns (uint256) {
		uint256 playerIndex = playerEntryIndex[_epoch][account];
		if (playerIndex > 0) {
			return
				entriesList[_epoch][playerIndex].currentEntriesLength -
				entriesList[_epoch][playerIndex - 1].currentEntriesLength;
		} else {
			return entriesList[_epoch][playerIndex].currentEntriesLength;
		}
	}

	function currentPlayersEntries(
		address account
	) public view returns (uint256) {
		uint256 numEntries = (walletBoosts[account] * 100) / 100;
		if (epochBoosts[epoch + 1][account] > 100) {
			numEntries = (numEntries * epochBoosts[epoch + 1][account]) / 100;
		}
		return numEntries;
	}

	function shouldRollover() internal view returns (bool) {
		if (lastRollover == 0 || epoch == 0) {
			return false;
		}
		return block.timestamp >= (lastRollover + epochDuration);
	}

	// Calculate the entries for the current epoch

	function _calculateEntries() internal {
		totalEntries[epoch] = 0;
		for (uint256 i = 0; i < _allOwners.length; i++) {
			address player = _allOwners[i];
			if (automatedMarketMakerPairs[player]) {
				continue;
			}

			uint256 numEntries = (walletBoosts[player] * 100) / 100;
			if (epochBoosts[epoch][player] > 100) {
				numEntries = (numEntries * epochBoosts[epoch][player]) / 100;
			}
			EntriesData memory entryBought = EntriesData({
				player: player,
				currentEntriesLength: uint256(totalEntries[epoch] + numEntries)
			});

			entriesList[epoch].push(entryBought);
			playerEntryIndex[epoch][player] = entriesList[epoch].length - 1;
			// update raffle variables
			totalEntries[epoch] = totalEntries[epoch] + numEntries;
		}
	}

	// helper method to get the winner address of a raffle
	/// @return the wallet that won the raffle
	/// @dev Uses a binary search on the sorted array to retreive the winner
	function getWinnerAddressFromRandom(
		uint nonce
	) public view returns (address) {
		if (epoch == 0 || entriesList[epoch].length == 0) {
			return address(0);
		}

		uint256 normalizedRandomNumber = (generateRandomNumber(nonce) %
			currentTotalEntries());
		uint256 position = findUpperBound(
			entriesList[epoch],
			normalizedRandomNumber
		);

		address candidate = entriesList[epoch][position].player;
		// general case
		if (candidate != address(0)) return candidate;
		else {
			bool ended = false;
			uint256 i = position;
			while (
				ended == false && entriesList[epoch][i].player == address(0)
			) {
				if (i == 0) i = entriesList[epoch].length - 1;
				else i = i - 1;
				if (i == position) ended == true;
			}
			return entriesList[epoch][i].player;
		}
	}

	function generateRandomNumber(
		uint randNonce
	) internal view returns (uint256) {
		uint256 blockNumber = block.number - 1; // Use the previous block's hash
		bytes32 lastBlockHash = blockhash(blockNumber);
		return
			uint256(
				keccak256(
					abi.encodePacked(
						_msgSender(),
						lastBlockHash,
						block.timestamp + randNonce
					)
				)
			);
	}

	/// @param array sorted array of EntriesBought. CurrentEntriesLength is the numeric field used to sort
	/// @param element uint256 to find. Goes from 1 to entriesLength
	/// @dev based on openzeppelin code (v4.0), modified to use an array of EntriesBought
	/// Searches a sorted array and returns the first index that contains a value greater or equal to element.
	/// If no such index exists (i.e. all values in the array are strictly less than element), the array length is returned. Time complexity O(log n).
	/// array is expected to be sorted in ascending order, and to contain no repeated elements.
	/// https://docs.openzeppelin.com/contracts/3.x/api/utils#Arrays-findUpperBound-uint256---uint256-
	function findUpperBound(
		EntriesData[] storage array,
		uint256 element
	) internal view returns (uint256) {
		if (array.length == 0) {
			return 0;
		}

		uint256 low = 0;
		uint256 high = array.length;

		while (low < high) {
			uint256 mid = Math.average(low, high);

			// Note that mid will always be strictly less than high (i.e. it will be a valid array index)
			// because Math.average rounds down (it does integer division with truncation).
			if (array[mid].currentEntriesLength > element) {
				high = mid;
			} else {
				low = mid + 1;
			}
		}

		// At this point `low` is the exclusive upper bound. We will return the inclusive upper bound.
		if (low > 0 && array[low - 1].currentEntriesLength == element) {
			return low - 1;
		} else {
			return low;
		}
	}

	// function _afterTokenTransfer(
	// 	address from,
	// 	address to,
	// 	uint256 amount
	// ) internal virtual override {
	// 	super._afterTokenTransfer(from, to, amount);

	// 	// Check after transfer if rollover should occur
	// }

	function _beforeTokenTransfer(
		address from,
		address to,
		uint256 amount
	) internal virtual override {
		super._beforeTokenTransfer(from, to, amount);

		if (shouldRollover()) {
			rollover();
		}

		// Transfer is disabled by default.  Following functions will potentially enable it
		bool transferAllowed = false;

		// Allow initial mint and future burns
		if (from == address(0) || to == address(0)) {
			transferAllowed = true;
		}

		// Epoch 0, transfers are allowed
		if (epoch == 0) {
			transferAllowed = true;
		}

		// if any account belongs to _isExcludedFromRestictions account then allow
		if (_excludeFromRestrictions[from] || _excludeFromRestrictions[to]) {
			transferAllowed = true;
		}

		// This is a buy
		if (automatedMarketMakerPairs[from]) {
			transferAllowed = true;
		}

		// IF is a winner!
		// All transfers are allowed from a winner, including sells
		if (checkWinner(from)) {
			transferAllowed = true;
		}

		require(
			transferAllowed,
			"This transfer is not allowed. Only winners can transfer"
		);

		// Remove owner from list of owners
		if (from != address(0) && balanceOf(from) == amount) {
			_removeOwnerFromAllOwnersEnumeration(from);
		}

		// Add owner to list of owners and adjust wallet boost
		if (to != address(0) && balanceOf(to) == 0) {
			_addOwnerToAllTokensEnumeration(to);
			if (walletBoosts[to] == 0) {
				walletBoosts[to] = 100;
			}
		}
	}

	/* **************
	BUY BOOSTS
	************** */

	function addLoginDailyBoost(address player) internal {
		if (epochBoosts[epoch + 1][player] == BUY_DAILY_BOOST) {
			epochBoosts[epoch + 1][player] =
				BUY_DAILY_BOOST +
				LOGIN_DAILY_BOOST;
		} else {
			epochBoosts[epoch + 1][player] = LOGIN_DAILY_BOOST;
		}
	}

	function addBuyDailyBoost(address player) internal {
		if (epochBoosts[epoch + 1][player] == LOGIN_DAILY_BOOST) {
			epochBoosts[epoch + 1][player] =
				BUY_DAILY_BOOST +
				LOGIN_DAILY_BOOST;
		} else {
			epochBoosts[epoch + 1][player] = BUY_DAILY_BOOST;
		}
	}

	function addBothDailyBoost(address player) internal {
		epochBoosts[epoch + 1][player] = BUY_DAILY_BOOST + LOGIN_DAILY_BOOST;
	}

	function addSuperBoost(address player) internal {
		walletBoosts[player] = SUPER_BOOST;
	}

	function buySuperBoost() external payable {
		require(msg.value >= SUPER_BOOST_COST, "Not enough Ether/BNB Sent");
		addSuperBoost(_msgSender());
		(bool sent, ) = feeReceiver.call{ value: msg.value }("");
		require(sent, "Failed to send ETH");
		emit BoughtSuperBoost(_msgSender(), epoch);
	}

	function dailyLoginBoost() external {
		addLoginDailyBoost(_msgSender());
	}

	/* **************
	SWAP and Estimates
	************** */

	function buyWithETH(uint256 amountMinimum) external payable returns (bool) {
		require(msg.value >= 1000, "Insignificant input amount");

		IWETH(WETH).deposit{ value: msg.value }();
		uint256 _wethBalance = IERC20(WETH).balanceOf(address(this));
		uint256 _beforeBalance = IERC20(address(this)).balanceOf(_msgSender());
		_swap(
			address(this),
			amountMinimum == 0
				? (estimateSwap(_wethBalance) * 97) / 100
				: amountMinimum,
			WETH,
			_wethBalance,
			_msgSender()
		);
		uint256 boughtAmount = IERC20(address(this)).balanceOf(_msgSender()) -
			_beforeBalance;
		if (msg.value >= BUY_BOOST_MIN_BUY) {
			addBothDailyBoost(_msgSender());
		} else {
			addLoginDailyBoost(_msgSender());
		}

		emit BoughtWinMoon(_msgSender(), epoch, msg.value, boughtAmount);
		return true;
	}

	function estimateSwap(
		uint256 fullInvestmentIn
	) public view returns (uint256 swapAmountOut) {
		IUniswapV2Pair pair = IUniswapV2Pair(uniswapV2Pair);
		bool isInputA = pair.token0() == WETH;
		require(
			isInputA || pair.token1() == WETH,
			"Input token not present in liqudity pair"
		);

		(uint256 reserveA, uint256 reserveB, ) = pair.getReserves();
		(reserveA, reserveB) = isInputA
			? (reserveA, reserveB)
			: (reserveB, reserveA);

		swapAmountOut = uniswapV2Router.getAmountOut(
			fullInvestmentIn,
			reserveA,
			reserveB
		);
	}

	function _swap(
		address tokenOut,
		uint256 tokenAmountOutMin,
		address tokenIn,
		uint256 tokenInAmount,
		address _to
	) internal {
		uint256 wethAmount;

		if (tokenIn == WETH) {
			wethAmount = tokenInAmount;
		} else {
			IUniswapV2Pair pair = IUniswapV2Pair(uniswapV2Pair);
			bool isInputA = pair.token0() == tokenIn;
			require(
				isInputA || pair.token1() == tokenIn,
				"Input token not present in input pair"
			);
			address[] memory path;

			path = new address[](2);
			path[0] = tokenIn;
			path[1] = WETH;
			uniswapV2Router
				.swapExactTokensForTokensSupportingFeeOnTransferTokens(
					tokenInAmount,
					tokenAmountOutMin,
					path,
					_to,
					block.timestamp
				);
			wethAmount = IERC20(WETH).balanceOf(address(this));
		}

		if (tokenOut != WETH) {
			address[] memory basePath;

			basePath = new address[](2);
			basePath[0] = WETH;
			basePath[1] = tokenOut;

			uniswapV2Router
				.swapExactTokensForTokensSupportingFeeOnTransferTokens(
					wethAmount,
					tokenAmountOutMin,
					basePath,
					_to,
					block.timestamp
				);
		}
	}

	function withdraw() external onlyOwner {
		uint256 amount = address(this).balance;
		require(amount > 0, "Nothing to withdraw; contract balance empty");

		address _owner = owner();
		(bool sent, ) = _owner.call{ value: amount }("");
		require(sent, "Failed to send Ether");
		emit EthWithdraw(amount);
	}

	/* ******************
	Admin / internal functions
	****************** */

	function isExcludeFromRestrictions(
		address account
	) external view returns (bool) {
		return _excludeFromRestrictions[account];
	}

	function excludeFromRestrictions(
		address account,
		bool excluded
	) external onlyOwner {
		require(
			_excludeFromRestrictions[account] != excluded,
			"Account is already the value of 'excluded'"
		);
		_excludeFromRestrictions[account] = excluded;

		emit ExcludeFromRestrictions(account, excluded);
	}

	function setFeeReceiver(address payable account) external onlyOwner {
		require(
			account != address(0),
			"Cannot set fee receiver to zero address"
		);
		feeReceiver = account;
		emit NewFeeReceiver(account);
	}

	function setAutomatedMarketMakerPair(
		address pair,
		bool value
	) external onlyOwner {
		_setAutomatedMarketMakerPair(pair, value);
	}

	function _setAutomatedMarketMakerPair(address pair, bool value) private {
		require(
			automatedMarketMakerPairs[pair] != value,
			"Automated market maker pair is already set to that value"
		);
		automatedMarketMakerPairs[pair] = value;

		emit SetAutomatedMarketMakerPair(pair, value);
	}

	function _addOwnerToAllTokensEnumeration(address account) private {
		_allOwnersIndex[account] = _allOwners.length;
		_allOwners.push(account);
	}

	function _removeOwnerFromAllOwnersEnumeration(address account) private {
		// To prevent a gap in the tokens array, we store the last token in the index of the token to delete, and
		// then delete the last slot (swap and pop).

		uint256 lastOwnerIndex = _allOwners.length - 1;
		uint256 ownerIndex = _allOwnersIndex[account];

		// When the token to delete is the last token, the swap operation is unnecessary. However, since this occurs so
		// rarely (when the last minted token is burnt) that we still do the swap here to avoid the gas cost of adding
		// an 'if' statement (like in _removeTokenFromOwnerEnumeration)
		address lastOwner = _allOwners[lastOwnerIndex];

		_allOwners[ownerIndex] = lastOwner; // Move the last token to the slot of the to-delete token
		_allOwnersIndex[lastOwner] = ownerIndex; // Update the moved token's index

		// This also deletes the contents at the last position of the array
		delete _allOwnersIndex[account];
		_allOwners.pop();
	}

	function _approveTokenIfNeeded(address token, address spender) private {
		if (IERC20(token).allowance(address(this), spender) == 0) {
			IERC20(token).approve(spender, type(uint256).max);
		}
	}

	receive() external payable {}
}