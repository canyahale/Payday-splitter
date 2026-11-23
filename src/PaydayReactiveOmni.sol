// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";

/// @title PaydayReactiveOmni
/// @notice Omni-pattern port of PaydayReactive for the Payday Splitter
/// (Reactive Omni Buildathon, Set It and Forget It track). Deploy on Reactive
/// Lasna (chain 5318007).
///
/// WHY THIS EXISTS: the legacy PaydayReactive (vmOnly + service.subscribe +
/// `emit Callback`) is deployed at
/// 0x7a41A895375394Fd47E973e113EC7aA582f4204a, but its react() reverts at
/// entry on Omni — the RVM no longer exists, so the vmOnly modifier can never
/// pass. The contract is blacklisted with 0.0123389 REACT debt on the Omni
/// side and its 1 lREACT of legacy-proxy reserves is stranded. This port
/// replaces it. It was generated from Reactive's own MCP template
/// (plan_rc + get_rc_template, reactive-lib-omni commit 3ade0dc) and follows the
/// Omni API exactly: onlySystem + SYSTEM.subscribe on
/// 0x8888888888888888888888888888888888888888 +
/// SYSTEM.requestCallbackV_1_0. No legacy APIs are used.
///
/// BEHAVIOUR (same as the legacy contract): subscribes to Transfer events of
/// one ERC-20 token on one origin chain (Base Sepolia, chain 84532),
/// filtered to the SplitterVault as recipient (topic_2 = vault address).
/// Whenever a payment lands in the vault, react() parses the amount and
/// requests a callback to the vault that triggers the split.
///
/// VAULT COMPATIBILITY — READ THIS: the SplitterVault interface is UNCHANGED.
/// The vault exposes `callback(address sender, bytes payload)` (legacy
/// AbstractCallback) and splits abi.decode(payload, (token, amount)) only
/// when msg.sender is the Base Sepolia callback proxy and sender is the
/// reactive contract it was deployed with. The Omni callback payload is an
/// ABI-encoded function call, and the network overwrites the first argument
/// slot with the requesting reactive contract's address. So this contract
/// encodes the payload as a call to the vault's existing entry point:
///   abi.encodeWithSignature("callback(address,bytes)", address(0),
///                             abi.encode(token, amount))
/// The proxy overwrites the address(0) placeholder with this contract's
/// address and calls vault.callback(this, abi.encode(token, amount)) —
/// exactly what the vault already expects. No vault code change is needed.
/// BUT the vault's reactive-contract address is immutable, so the vault MUST
/// be redeployed pointing at this contract's new address (see
/// DEPLOY-RUNBOOK.md §7). The old vault (0x086a674515B4de3A805055C41F9819D8b6E4d686)
/// still points at the blacklisted legacy contract and its 1,000 MPT is
/// stranded test tokens.
///
/// @dev react() returns early instead of reverting on unexpected logs: the
/// subscription topics already filter, and a reverted reaction is still
/// charged in full (MCP pitfall #10). The same origin log can trigger twice
/// (no dedup, MCP pitfall #12); that is safe here because the vault splits
/// min(amount, balance) and sweeps what is actually present, so a duplicate
/// callback can only split funds that are really in the vault, never
/// double-pay.
contract PaydayReactiveOmni is AbstractReactive {
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

    address private immutable _owner;

    event PaymentSeen(address indexed token, address indexed vault, uint256 amount);

    error NotOwner(address caller);
    error UnexpectedLog();
    error ZeroAddress();

    /// @param _originChainId EIP-155 chain id of the origin chain (84532 = Base Sepolia).
    /// @param _token ERC-20 token contract to watch for Transfer events.
    /// @param _vault SplitterVault address (Transfer recipient filter + callback target).
    /// @param _callbackGasLimit Gas limit for the callback on the destination chain.
    /// @dev Payable so the contract can be funded with REACT at deployment.
    /// Subscribes in the constructor: it must be the contract itself that
    /// calls subscribe(), never the deployer EOA.
    constructor(uint256 _originChainId, address _token, address _vault, uint64 _callbackGasLimit) payable {
        if (_token == address(0) || _vault == address(0)) revert ZeroAddress();
        _owner = msg.sender;
        originChainId = _originChainId;
        token = _token;
        vault = _vault;
        callbackGasLimit = _callbackGasLimit;
        _subscribe();
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner(msg.sender);
        _;
    }

    /// @notice Stop reacting, and paying for reactions.
    function pause() external onlyOwner {
        _unsubscribe();
    }

    /// @notice Resume. Settles debt from the balance first: a contract in debt receives nothing.
    function resume() external payable onlyOwner {
        _coverDebt();
        _subscribe();
    }

    /// @inheritdoc IReactive
    /// @notice System-contract entry point. Fired for each Transfer to the vault.
    /// @param log_ The intercepted log record (see IReactive.LogRecord).
    function react(LogRecord calldata log_) external override onlySystem {
        if (
            log_.chainId != originChainId || log_.contractAddress != token || log_.topic0 != TRANSFER_TOPIC
                || log_.topic2 != uint256(uint160(vault))
        ) {
            return;
        }
        if (log_.data.length < 32) return;
        uint256 amount = abi.decode(log_.data, (uint256));
        if (amount == 0) return;

        emit PaymentSeen(token, vault, amount);
        // Payload is a call to the vault's EXISTING callback(address,bytes)
        // entry point. The first argument is the address(0) placeholder the
        // network overwrites with this contract's address (see contract docs).
        bytes memory payload = abi.encodeWithSignature("callback(address,bytes)", address(0), abi.encode(token, amount));
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: originChainId, recipient: vault, gasLimit: callbackGasLimit, payload: payload
            })
        );
    }

    // subscribe() and unsubscribe() share the same six arguments: an
    // unsubscribe that differs does nothing.
    //
    // The code-length guard is a deliberate deviation from the MCP template
    // (which subscribes unconditionally): Solidity high-level calls revert
    // when the target holds no code, so deploying in Foundry without the
    // system contract etched reverts the constructor. On Lasna the system
    // contract always exists at 0x8888..., so the guard never changes
    // live behaviour — it only keeps the contract testable off-network.
    // (Proven by the legacy contract's identical guard and by this
    // contract's setUp reverting before the guard was added.)
    function _subscribe() internal {
        if (address(SYSTEM).code.length > 0) {
            SYSTEM.subscribe(
                originChainId, token, TRANSFER_TOPIC, REACTIVE_IGNORE, uint256(uint160(vault)), REACTIVE_IGNORE
            );
        }
    }

    function _unsubscribe() internal {
        SYSTEM.unsubscribe(
            originChainId, token, TRANSFER_TOPIC, REACTIVE_IGNORE, uint256(uint160(vault)), REACTIVE_IGNORE
        );
    }
}
