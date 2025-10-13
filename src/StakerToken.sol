// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20Snapshot, ERC20 } from "@openzeppelin/contracts@4.9.5/token/ERC20/extensions/ERC20Snapshot.sol";
import { IERC20Metadata } from "@openzeppelin/contracts@4.9.5/token/ERC20/extensions/IERC20Metadata.sol";

contract StakerToken is ERC20Snapshot {
    address public immutable STAKER;
    address private _token;
    mapping(uint => uint) private _snapshotTime;

    modifier onlyStaker {
        require(msg.sender == STAKER, "Only Staker");
        _;
    }

    constructor(address staker) ERC20("", "") {
        STAKER = staker;
    }

    function initialize(address token) external {
        require(_token == address(0), "Already initialized");
        require(token != address(0), "Invalid token address");
        _token = token;
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);

        if (from != address(0) && to != address(0)) {
            // transfer
            revert("Transfers disabled");
        }
    }

    function mint(address to, uint tokens) external onlyStaker {
        _mint(to, tokens);
    }

    function burn(address from, uint tokens) external onlyStaker {
        _burn(from, tokens);
    }

    function snapshot() external returns (uint256 snapshotId) {
        snapshotId = _snapshot();
        _snapshotTime[snapshotId] = block.timestamp;
    }

    function name() public view override returns (string memory) {
        return string.concat("Staked ", IERC20Metadata(_token).name());
    }

    function symbol() public view override returns (string memory) {
        return string.concat("st", IERC20Metadata(_token).symbol());
    }

    function decimals() public view override returns (uint8) {
        return IERC20Metadata(_token).decimals();
    }

    function getToken() external view returns (address) {
        return _token;
    }

    function getCurrentSnapshotId() external view returns (uint currentSnapshotId) {
        return _getCurrentSnapshotId();
    }

    function getSnapshotTime(uint snapshotId) external view returns (uint timestamp) {
        return _snapshotTime[snapshotId];
    }
}