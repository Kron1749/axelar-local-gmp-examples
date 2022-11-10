// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import '../abstract/Ownable.sol';
import '../abstract/Pausable.sol';
import { AxelarExecutable } from '@axelar-network/axelar-gmp-sdk-solidity/contracts/executables/AxelarExecutable.sol';
import { IAxelarGateway } from '@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol';
import { IAxelarGasService } from '@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol';
import '../abstract/ReentrancyGuard.sol';
import '../../node_modules/openzeppelin-solidity/contracts/interfaces/IERC20.sol';

contract DistributionExecutable is AxelarExecutable, Ownable, Pausable, ReentrancyGuard {
    IAxelarGasService public immutable gasReceiver;
    string public s_treasuryString;
    address[] public s_treasuryAddr;
    address public adminAddress; // address of the admin
    address public operatorAddress; // address of the operator
    address public gameToken; // you can pay with this token only
    uint256 public gameFee;
    mapping(uint256 => RoundInfo) public ledger; // key on roundId
    mapping(address => uint256[]) public userRounds; // value is roundId
    mapping(address => uint256) public userWinnings; // value is balance
    uint8[] public brackets;
    uint256[] public winnings;
    uint8 public threshold;

    struct RoundInfo {
        address playerAddress;
        uint256 roundId;
        uint256 amount;
        bool updated; // default false
        bool claimed; // default false
    }

    event NewOperatorAddress(address operator);
    event NewGameToken(address tokenAddress);
    event GameFeeSet(uint256 gameFee);
    event GameEntered(uint256 roundId, address user, uint256 gameFee, uint8 bracket, uint256 amount);
    event ResultUpdated(uint256 roundId, uint256 amount, uint8 bracket);
    event TreasuryClaim(uint256 amount);
    event PlayerClaimed(address player, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == adminAddress, 'Not admin');
        _;
    }

    modifier onlyAdminOrOperator() {
        require(msg.sender == adminAddress || msg.sender == operatorAddress, 'Not operator/admin');
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operatorAddress, 'Not operator');
        _;
    }

    modifier notContract() {
        require(!_isContract(msg.sender), 'Contract not allowed');
        require(msg.sender == tx.origin, 'Proxy contract not allowed');
        _;
    }

    constructor(
        address gateway_,
        address gasReceiver_,
        string  memory _treasury,
        address _treasuryAddr,
        address _adminAddress,
        address _operatorAddress,
        address _gameTokenAddress,
        uint256 _gameFee
    ) AxelarExecutable(gateway_) {
        gasReceiver = IAxelarGasService(gasReceiver_);
        s_treasuryString = _treasury;
        s_treasuryAddr.push(_treasuryAddr);
        adminAddress = _adminAddress;
        operatorAddress = _operatorAddress;
        gameToken = _gameTokenAddress;
        gameFee = _gameFee;
    }

    function test(
        string memory destinationAddress,
        address[] calldata destinationAddresses,
        string memory symbol,
        uint256 amount) external payable {
            string memory destinationChain = 'Fantom';
        sendToMany(destinationChain, destinationAddress, destinationAddresses, symbol, amount);
    }

    function sendToMany(
        string memory destinationChain,
        string memory destinationAddress,
        address[] memory destinationAddresses,
        string memory symbol,
        uint256 amount
    ) public payable {
        address tokenAddress = gateway.tokenAddresses(symbol);
        IERC20(tokenAddress).approve(address(gateway), amount);
        bytes memory payload = abi.encode(destinationAddresses);
        if (msg.value > 0) {
            gasReceiver.payNativeGasForContractCallWithToken{ value: msg.value }(
                address(this),
                destinationChain,
                destinationAddress,
                payload,
                symbol,
                amount,
                address(this)
            );
        }
        gateway.callContractWithToken(destinationChain, destinationAddress, payload, symbol, amount);
    }

    function _executeWithToken(
        string calldata,
        string calldata,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 amount
    ) internal override {
        address[] memory recipients = abi.decode(payload, (address[]));
        address tokenAddress = gateway.tokenAddresses(tokenSymbol);

        uint256 sentAmount = amount / recipients.length;
        for (uint256 i = 0; i < recipients.length; i++) {
            IERC20(tokenAddress).transfer(recipients[i], sentAmount);
        }
    }

    function setOperator(address _operatorAddress) external onlyAdmin {
        require(_operatorAddress != address(0), 'Cannot be zero address');
        operatorAddress = _operatorAddress;

        emit NewOperatorAddress(_operatorAddress);
    }

    function setBrackets(uint8[] calldata _brackets) external onlyAdmin {
        brackets = _brackets;
    }

    function setWinnings(uint256[] calldata _winnings) external onlyAdmin {
        winnings = _winnings;
    }

    function setThreshold(uint8 _threshold) external onlyAdmin {
        threshold = _threshold;
    }

    function setGameFee(uint256 _gameFee) external onlyAdmin {
        require(_gameFee != 0, 'Game cannot be free');
        gameFee = _gameFee;

        emit GameFeeSet(_gameFee);
    }

    function setGameToken(address tokenAddress) external onlyAdmin {
        require(tokenAddress != address(0), 'Cannot be zero address');
        gameToken = tokenAddress;

        emit NewGameToken(tokenAddress);
    }

    function enterGame(uint256 _roundId) external whenNotPaused nonReentrant notContract {
        require(_roundId != 0, 'missing RoundId');

        RoundInfo storage roundInfo = ledger[_roundId];
        if (roundInfo.playerAddress != address(0x0)) {
            revert('existing roundId');
        }

        bool success = IERC20(gameToken).transferFrom(msg.sender, address(this), gameFee);

        if (success) {
            roundInfo.playerAddress = msg.sender;
            roundInfo.amount = gameFee;
            roundInfo.roundId = _roundId;
            userRounds[msg.sender].push(_roundId);

            uint256[2] memory result = setRoundResult(_roundId);

            emit GameEntered(_roundId, msg.sender, gameFee, uint8(result[0]), result[1]);
        } else {
            revert('round was not paid for');
        }
    }

    function claim() external whenNotPaused nonReentrant notContract {
        uint256 claimValue = userWinnings[msg.sender];
        if (claimValue == 0) {
            revert('nothing to claim');
        }

        userWinnings[msg.sender] = 0;
        for (uint256 i = 0; i < userRounds[msg.sender].length; i++) {
            uint256 round = userRounds[msg.sender][i];
            RoundInfo storage legerRound = ledger[round];
            if (legerRound.updated && !legerRound.claimed) {
                legerRound.claimed = true;
            }
        }

        IERC20(gameToken).transfer(msg.sender, claimValue);
        emit PlayerClaimed(msg.sender, claimValue);
    }

    function setRoundResult(uint256 _roundId) internal returns (uint256[2] memory) {
        if (ledger[_roundId].playerAddress == address(0x0)) {
            revert('not existing roundId');
        }

        uint256 amount = 0;
        uint8 bracket = 100;
        if (getPseudoRandom(_roundId + 1) <= threshold) {
            bracket = getBracketForRound(_roundId);
            amount = winnings[bracket];
        }
        RoundInfo storage roundInfo = ledger[_roundId];
        roundInfo.amount = amount;
        roundInfo.updated = true;
        userWinnings[roundInfo.playerAddress] = userWinnings[roundInfo.playerAddress] + amount;

        uint256[2] memory result = [bracket, amount];
        return result;
    }

    function getBracketForRound(uint256 _roundId) internal view returns (uint8) {
        uint8 randomNumber = getPseudoRandom(_roundId);
        for (uint8 i = 0; i < brackets.length; i++) {
            if (randomNumber <= brackets[i]) {
                return i;
            }
        }
        return 100;
    }

    function getPseudoRandom(uint256 _roundId) internal view returns (uint8) {
        uint8 number = uint8(uint256(keccak256(abi.encodePacked(block.timestamp, block.difficulty))) % 100);
        return uint8(uint256(keccak256(abi.encodePacked(number + 1, _roundId))) % 100);
    }

    function claimTreasury(uint256 value) external payable nonReentrant onlyAdmin {
        // address[] calldata destinationAddresses
        string memory symbol = 'aUSDC';
        string memory destinationChain = 'Fantom';
        string memory destinationAddress = toAsciiString(address(this));
        address[] memory destinationAddresses = s_treasuryAddr;
        
        sendToMany(destinationChain, destinationAddress, destinationAddresses, symbol, value);


        emit TreasuryClaim(value);
    }

    function toAsciiString(address x) internal pure returns (string memory) {
        bytes memory s = new bytes(40);
        for (uint i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint(uint160(x)) / (2**(8*(19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2*i] = char(hi);
            s[2*i+1] = char(lo);            
        }
        return string(s);
    }

    function char(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }
    function getUserWinnings(address _address) external view returns (uint256) {
        return userWinnings[_address];
    }

    function getUserRounds(address _address) external view returns (uint256[] memory) {
        return userRounds[_address];
    }

    function getLegerEntryForRoundId(uint256 _roundId) external view returns (RoundInfo memory) {
        return ledger[_roundId];
    }

    function _isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}
