// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {PaydayReactive} from "../src/PaydayReactive.sol";

/// @notice Stand-in for the Reactive Network system contract (0xfffFfF).
/// Only used to prove the subscription fires when the system contract exists.
contract MockSystemContract {
    event Subscribed(uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, uint256 t3);

    function subscribe(uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        emit Subscribed(chainId, c, t0, t1, t2, t3);
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/// @notice Tests for PaydayReactive: subscription params, react() filtering,
/// and the Callback emission that triggers the vault split.
contract PaydayReactiveTest is Test {
    PaydayReactive internal reactive;

    uint256 internal constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    address internal token = makeAddr("payToken");
    address internal vault = makeAddr("splitterVault");
    uint64 internal constant CALLBACK_GAS_LIMIT = 300_000;

    uint256 internal constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));

    event PaymentSeen(address indexed token, address indexed vault, uint256 amount);
    event Callback(uint256 indexed chain_id, address indexed _contract, uint64 indexed gas_limit, bytes payload);

    function setUp() public {
        reactive = new PaydayReactive(ORIGIN_CHAIN_ID, token, vault, CALLBACK_GAS_LIMIT);
    }

    function _log(address contract_, uint256 topic0, uint256 topic2, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: contract_,
            topic_0: topic0,
            topic_1: 0,
            topic_2: topic2,
            topic_3: 0,
            data: data,
            block_number: 1,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _paymentLog(uint256 amount) internal view returns (IReactive.LogRecord memory) {
        return _log(token, TRANSFER_TOPIC, uint256(uint160(vault)), abi.encode(amount));
    }

    // ---- Constructor / subscription params ----

    function testParams() public view {
        assertEq(reactive.originChainId(), ORIGIN_CHAIN_ID);
        assertEq(reactive.token(), token);
        assertEq(reactive.vault(), vault);
        assertEq(reactive.callbackGasLimit(), CALLBACK_GAS_LIMIT);
        assertEq(reactive.TRANSFER_TOPIC(), uint256(keccak256("Transfer(address,address,uint256)")));
    }

    // ---- Subscription ----

    function testSubscribesWhenSystemContractExists() public {
        MockSystemContract mock = new MockSystemContract();
        address systemAddr = address(0x0000000000000000000000000000000000fffFfF);
        vm.etch(systemAddr, address(mock).code);

        vm.recordLogs();
        new PaydayReactive(ORIGIN_CHAIN_ID, token, vault, CALLBACK_GAS_LIMIT);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("Subscribed(uint256,address,uint256,uint256,uint256,uint256)"));
        (uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, uint256 t3) =
            abi.decode(logs[0].data, (uint256, address, uint256, uint256, uint256, uint256));
        assertEq(chainId, ORIGIN_CHAIN_ID);
        assertEq(c, token);
        assertEq(t0, TRANSFER_TOPIC);
        // topic_1 ignored (any sender).
        assertEq(t1, uint256(0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad));
        // topic_2 filters to the vault as Transfer recipient.
        assertEq(t2, uint256(uint160(vault)));
        assertEq(t3, uint256(0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad));
    }

    function testNoSubscriptionWithoutSystemContract() public {
        // setUp's deployment (no system contract etched) emitted nothing.
        vm.recordLogs();
        new PaydayReactive(ORIGIN_CHAIN_ID, token, vault, CALLBACK_GAS_LIMIT);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ---- react(): happy path ----

    function testReactEmitsCallback() public {
        uint256 amount = 1_234 ether;
        vm.expectEmit(true, true, false, true, address(reactive));
        emit PaymentSeen(token, vault, amount);
        vm.expectEmit(true, true, true, true, address(reactive));
        emit Callback(ORIGIN_CHAIN_ID, vault, CALLBACK_GAS_LIMIT, abi.encode(token, amount));
        reactive.react(_paymentLog(amount));
    }

    function testReactPayloadDecodesToTokenAndAmount() public {
        uint256 amount = 42;
        vm.recordLogs();
        reactive.react(_paymentLog(amount));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // PaymentSeen + Callback.
        assertEq(logs.length, 2);
        // The Callback log's data is abi.encode(bytes payload) — the payload
        // itself is dynamic, so decode twice.
        bytes memory payload = abi.decode(logs[1].data, (bytes));
        (address decodedToken, uint256 decodedAmount) = abi.decode(payload, (address, uint256));
        assertEq(decodedToken, token);
        assertEq(decodedAmount, amount);
    }

    // ---- react(): filtering ----

    function testReactRevertsForWrongContract() public {
        IReactive.LogRecord memory log = _paymentLog(100);
        log._contract = makeAddr("otherToken");
        vm.expectRevert(PaydayReactive.UnexpectedLog.selector);
        reactive.react(log);
    }

    function testReactRevertsForWrongTopic() public {
        IReactive.LogRecord memory log = _paymentLog(100);
        log.topic_0 = uint256(keccak256("Approval(address,address,uint256)"));
        vm.expectRevert(PaydayReactive.UnexpectedLog.selector);
        reactive.react(log);
    }

    function testReactRevertsForWrongRecipient() public {
        IReactive.LogRecord memory log = _paymentLog(100);
        log.topic_2 = uint256(uint160(makeAddr("someoneElse")));
        vm.expectRevert(PaydayReactive.UnexpectedLog.selector);
        reactive.react(log);
    }

    function testReactIgnoresZeroAmount() public {
        vm.recordLogs();
        reactive.react(_paymentLog(0));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testReactIgnoresMalformedData() public {
        IReactive.LogRecord memory log = _paymentLog(100);
        log.data = hex"1234"; // shorter than 32 bytes
        vm.recordLogs();
        reactive.react(log);
        assertEq(vm.getRecordedLogs().length, 0);
    }
}
