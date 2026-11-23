// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AbstractCallback} from "reactive-lib/abstract-base/AbstractCallback.sol";

/// @notice Minimal ERC-20 interface used by the vault (transfer + balance only).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title SplitterVault
/// @notice Receiving vault for the Payday Splitter (Reactive Omni Buildathon,
/// Set It and Forget It track). It holds incoming ERC-20 payments on Base Sepolia
/// and splits each payment across three fixed destinations:
/// main wallet / savings wallet / gas reserve.
///
/// The split is triggered ONLY by a Reactive Network callback:
///  - `callback()` can only be called by the destination-chain callback proxy
///    (AbstractCallback.authorizedSenderOnly), and
///  - the `sender` argument must be the PaydayReactive contract deployed on
///    Reactive Lasna (checked against immutable `reactiveContract`).
/// Nobody else — not the owner, not any bot, not a direct EOA call — can
/// trigger a split. The owner can only change the shares, never the destinations.
///
/// @dev Shares are in basis points (BPS = 10_000). Defaults: 70% / 20% / 10%.
/// The gas-reserve share receives the rounding remainder, so a split always
/// sweeps the full amount out of the vault — no dust is left behind.
/// A simple reentrancy lock guards the external token transfers.
/// The vault inherits AbstractPayer (via AbstractCallback), so it can hold native
/// currency to cover Reactive callback fees via `pay()` / `coverDebt()`.
contract SplitterVault is AbstractCallback {
    uint256 public constant BPS = 10_000;

    /// @notice The single payment token this vault splits (set at deploy).
    address public immutable token;
    /// @notice The PaydayReactive contract on Reactive Lasna allowed to trigger splits.
    address public immutable reactiveContract;
    /// @notice Fixed destinations (set at deploy, never changeable).
    address public immutable mainWallet;
    address public immutable savingsWallet;
    address public immutable gasReserve;

    address public owner;

    uint256 public mainShare;
    uint256 public savingsShare;
    uint256 public gasShare;

    bool private locked;

    event Split(address indexed token, uint256 amount, uint256 mainAmount, uint256 savingsAmount, uint256 gasAmount);
    event SharesUpdated(uint256 mainShare, uint256 savingsShare, uint256 gasShare);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error UnauthorizedSender();
    error UnexpectedReactiveContract();
    error UnexpectedToken();
    error ZeroAmount();
    error InvalidShares();
    error ZeroAddress();
    error Reentrant();
    error TransferFailed();

    modifier nonReentrant() {
        if (locked) revert Reentrant();
        locked = true;
        _;
        locked = false;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedSender();
        _;
    }

    /// @param _callbackProxy Reactive callback proxy on the destination chain
    /// (Base Sepolia). Only this address can invoke `callback()`.
    /// @param _token The ERC-20 payment token to split.
    /// @param _reactiveContract The PaydayReactive contract on Reactive Lasna.
    /// @param _mainWallet Destination for the main share (fixed forever).
    /// @param _savingsWallet Destination for the savings share (fixed forever).
    /// @param _gasReserve Destination for the gas-reserve share (fixed forever).
    constructor(
        address _callbackProxy,
        address _token,
        address _reactiveContract,
        address _mainWallet,
        address _savingsWallet,
        address _gasReserve
    ) AbstractCallback(_callbackProxy) {
        if (
            _token == address(0) || _reactiveContract == address(0) || _mainWallet == address(0)
                || _savingsWallet == address(0) || _gasReserve == address(0)
        ) revert ZeroAddress();
        token = _token;
        reactiveContract = _reactiveContract;
        mainWallet = _mainWallet;
        savingsWallet = _savingsWallet;
        gasReserve = _gasReserve;
        owner = msg.sender;
        mainShare = 7000;
        savingsShare = 2000;
        gasShare = 1000;
    }

    /// @notice Reactive callback entry point. The destination-chain callback proxy
    /// calls this with the reactive contract as `sender` and the payload the
    /// reactive contract emitted: abi.encode(token, amount).
    /// @param sender Address of the reactive contract that emitted the callback.
    /// @param payload abi.encode(address token, uint256 amount).
    function callback(address sender, bytes calldata payload) external nonReentrant authorizedSenderOnly {
        if (sender != reactiveContract) revert UnexpectedReactiveContract();
        (address token_, uint256 amount) = abi.decode(payload, (address, uint256));
        if (token_ != token) revert UnexpectedToken();
        if (amount == 0) revert ZeroAmount();

        uint256 balance = IERC20(token).balanceOf(address(this));
        // Split what is actually here; never more than the vault holds.
        uint256 toSplit = amount > balance ? balance : amount;
        if (toSplit == 0) revert ZeroAmount();

        uint256 mainAmount = (toSplit * mainShare) / BPS;
        uint256 savingsAmount = (toSplit * savingsShare) / BPS;
        // Remainder goes to the gas reserve so the split always sums to toSplit.
        uint256 gasAmount = toSplit - mainAmount - savingsAmount;

        // Emit first: if any transfer below reverts, the whole tx (and log) reverts.
        emit Split(token, toSplit, mainAmount, savingsAmount, gasAmount);

        _send(mainWallet, mainAmount);
        _send(savingsWallet, savingsAmount);
        _send(gasReserve, gasAmount);
    }

    /// @notice Change the split shares. Destinations cannot be changed.
    /// Shares must sum to exactly BPS (10_000).
    function setShares(uint256 _mainShare, uint256 _savingsShare, uint256 _gasShare) external onlyOwner {
        if (_mainShare + _savingsShare + _gasShare != BPS) revert InvalidShares();
        mainShare = _mainShare;
        savingsShare = _savingsShare;
        gasShare = _gasShare;
        emit SharesUpdated(_mainShare, _savingsShare, _gasShare);
    }

    /// @notice Transfer ownership (share admin only; destinations stay fixed).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        // NOTE: forge flags this with reentrancy-no-eth, but _send is only
        // reachable from callback(), which holds the nonReentrant lock.
        bool ok = IERC20(token).transfer(to, amount);
        if (!ok) revert TransferFailed();
    }
}
