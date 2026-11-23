// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @title PaydayReactive
/// @notice Reactive contract for the Payday Splitter (Reactive Omni Buildathon,
/// Set It and Forget It track). Deployed on Reactive Lasna (chain 5318007).
///
/// It subscribes to Transfer events of one ERC-20 token on one origin chain
/// (Base Sepolia, chain 84532), filtered to the SplitterVault as recipient
/// (topic_2 = vault address). Whenever a payment lands in the vault, `react()`
/// parses the amount and emits a Callback requesting the vault to split it.
///
/// The callback payload is abi.encode(token, amount); the destination-chain
/// callback proxy delivers it to SplitterVault.callback(sender, payload),
/// where `sender` is this contract's address.
///
/// @dev Subscription happens in the constructor, which runs on the Reactive
/// Network (vm == false there). `react()` runs inside the ReactVM (vm == true),
/// enforced by the vmOnly modifier from AbstractReactive.
contract PaydayReactive is AbstractReactive {
    /// @notice keccak256("Transfer(address,address,uint256)").
    uint256 public constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));

    /// @notice Origin chain whose Transfer events are watched (Base Sepolia: 84532).
    uint256 public immutable originChainId;
    /// @notice The ERC-20 payment token being watched.
    address public immutable token;
    /// @notice The SplitterVault receiving the payments (also the callback target).
    address public immutable vault;
    /// @notice Gas limit for the callback transaction on the destination chain.
    uint64 public immutable callbackGasLimit;

    event PaymentSeen(address indexed token, address indexed vault, uint256 amount);

    error UnexpectedLog();
    error ZeroAddress();

    /// @param _originChainId EIP-155 chain id of the origin chain (84532 = Base Sepolia).
    /// @param _token ERC-20 token contract to watch for Transfer events.
    /// @param _vault SplitterVault address (Transfer recipient filter + callback target).
    /// @param _callbackGasLimit Gas limit for the callback on the destination chain.
    constructor(uint256 _originChainId, address _token, address _vault, uint64 _callbackGasLimit) {
        if (_token == address(0) || _vault == address(0)) revert ZeroAddress();
        originChainId = _originChainId;
        token = _token;
        vault = _vault;
        callbackGasLimit = _callbackGasLimit;
        // On the Reactive Network the system contract always exists at
        // 0x0000000000000000000000000000000000fffFfF. Skip the subscription
        // when it is absent (Foundry tests, wrong chain): there is nothing to
        // subscribe to there, and react() stays testable because detectVm()
        // sets vm = true in that case.
        if (address(service).code.length > 0) {
            service.subscribe(
                _originChainId, _token, TRANSFER_TOPIC, REACTIVE_IGNORE, uint256(uint160(_vault)), REACTIVE_IGNORE
            );
        }
    }

    /// @notice ReactVM entry point. Fired for each Transfer to the vault.
    /// @param log The intercepted log record (see IReactive.LogRecord).
    function react(LogRecord calldata log) external override vmOnly {
        if (log._contract != token || log.topic_0 != TRANSFER_TOPIC || log.topic_2 != uint256(uint160(vault))) {
            revert UnexpectedLog();
        }
        if (log.data.length < 32) return;
        uint256 amount = abi.decode(log.data, (uint256));
        if (amount == 0) return;

        emit PaymentSeen(token, vault, amount);
        emit Callback(originChainId, vault, callbackGasLimit, abi.encode(token, amount));
    }
}
