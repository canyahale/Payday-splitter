// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {PaydayReactiveOmni} from "../src/PaydayReactiveOmni.sol";

/// @notice Stand-in for the Reactive Network Omni system contract
/// (0x8888888888888888888888888888888888888888). Records subscribe /
/// unsubscribe / requestCallbackV_1_0 calls so the tests can assert on them.
contract MockOmniSystemContract {
    event Subscribed(uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, uint256 t3);
    event Unsubscribed(uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, uint256 t3);
    event CallbackRequested(uint256 chainId, address recipient, uint64 gasLimit, bytes payload);

    function subscribe(uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        emit Subscribed(chainId, c, t0, t1, t2, t3);
    }

    function unsubscribe(uint256 chainId, address c, uint256 t1_, uint256 t2_, uint256 t3_, uint256 t4_) external {
        emit Unsubscribed(chainId, c, t1_, t2_, t3_, t4_);
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config) external {
        emit CallbackRequested(config.chainId, config.recipient, config.gasLimit, config.payload);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/// @notice Tests for PaydayReactiveOmni: subscription params, react()
/// filtering, and the requestCallbackV_1_0 call that triggers the vault
/// split — including the payload compatibility with the UNCHANGED legacy
/// vault interface (callback(address,bytes) with an address(0) placeholder
/// first argument).
contract PaydayReactiveOmniTest is Test {
    PaydayReactiveOmni internal reactive;

    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;

    uint256 internal constant ORIGIN_CHAIN_ID = 84532; // Base Sepolia
    address internal token = makeAddr("payToken");
    address internal vault = makeAddr("splitterVault");
    uint64 internal constant CALLBACK_GAS_LIMIT = 300_000;

    uint256 internal constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));

    event PaymentSeen(address indexed token, address indexed vault, uint256 amount);
    event Subscribed(uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, uint256 t3);
    event Unsubscribed(uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, uint256 t3);
    event CallbackRequested(uint256 chainId, address recipient, uint64 gasLimit, bytes payload);

    function setUp() public {
        // No system contract etched: mirrors the legacy test setup and proves
        // the constructor does not revert when SYSTEM has no code.
        reactive = new PaydayReactiveOmni(ORIGIN_CHAIN_ID, token, vault, CALLBACK_GAS_LIMIT);
    }

    function _log(address contract_, uint256 topic0, uint256 topic2, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: ORIGIN_CHAIN_ID,
            contractAddress: contract_,
            topic0: topic0,
            topic1: 0,
            topic2: topic2,
            topic3: 0,
            data: data,
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _paymentLog(uint256 amount) internal view returns (IReactive.LogRecord memory) {
        return _log(token, TRANSFER_TOPIC, uint256(uint160(vault)), abi.encode(amount));
    }

    function _etchSystem() internal returns (MockOmniSystemContract mock) {
        mock = new MockOmniSystemContract();
        vm.etch(SYSTEM_ADDR, address(mock).code);
    }

    // ---- Constructor / params ----

    function testParams() public view {
        assertEq(reactive.originChainId(), ORIGIN_CHAIN_ID);
        assertEq(reactive.token(), token);
        assertEq(reactive.vault(), vault);
        assertEq(reactive.callbackGasLimit(), CALLBACK_GAS_LIMIT);
        assertEq(reactive.TRANSFER_TOPIC(), uint256(keccak256("Transfer(address,address,uint256)")));
    }

    function testConstructorRevertsForZeroTokenOrVault() public {
        vm.expectRevert(PaydayReactiveOmni.ZeroAddress.selector);
        new PaydayReactiveOmni(ORIGIN_CHAIN_ID, address(0), vault, CALLBACK_GAS_LIMIT);
        vm.expectRevert(PaydayReactiveOmni.ZeroAddress.selector);
        new PaydayReactiveOmni(ORIGIN_CHAIN_ID, token, address(0), CALLBACK_GAS_LIMIT);
    }

    // ---- Subscription ----

    function testSubscribesWhenSystemContractExists() public {
        _etchSystem();
        vm.recordLogs();
        new PaydayReactiveOmni(ORIGIN_CHAIN_ID, token, vault, CALLBACK_GAS_LIMIT);
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
        // setUp's deployment (no system contract etched) emitted nothing and
        // did not revert: the subscribe call to a no-code SYSTEM is a no-op.
        vm.recordLogs();
        new PaydayReactiveOmni(ORIGIN_CHAIN_ID, token, vault, CALLBACK_GAS_LIMIT);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // ---- react(): happy path ----

    function testReactRequestsCallback() public {
        _etchSystem();
        uint256 amount = 1_234 ether;

        vm.prank(SYSTEM_ADDR);
        vm.expectEmit(true, true, false, true, address(reactive));
        emit PaymentSeen(token, vault, amount);
        // The mock system contract records the callback request.
        vm.expectEmit(false, false, false, true, SYSTEM_ADDR);
        emit CallbackRequested(
            ORIGIN_CHAIN_ID,
            vault,
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSignature("callback(address,bytes)", address(0), abi.encode(token, amount))
        );
        reactive.react(_paymentLog(amount));
    }

    function testReactPayloadIsVaultCallbackCall() public {
        _etchSystem();
        uint256 amount = 42;

        vm.prank(SYSTEM_ADDR);
        vm.recordLogs();
        reactive.react(_paymentLog(amount));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // PaymentSeen (from the RC) + CallbackRequested (from the mock SYSTEM).
        assertEq(logs.length, 2);

        bytes memory payload;
        {
            // CallbackRequested has no indexed params: data is
            // abi.encode(chainId, recipient, gasLimit, payload).
            (uint256 cbChainId, address cbRecipient, uint64 cbGasLimit, bytes memory p) =
                abi.decode(logs[1].data, (uint256, address, uint64, bytes));
            assertEq(cbChainId, ORIGIN_CHAIN_ID);
            assertEq(cbRecipient, vault);
            assertEq(cbGasLimit, CALLBACK_GAS_LIMIT);
            payload = p;
        }
        // The payload must be a call to the vault's EXISTING
        // callback(address,bytes) entry point: 4-byte selector + ABI args.
        assertEq(bytes4(payload), bytes4(keccak256("callback(address,bytes)")));
        // Decode the arguments after the selector.
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
        (address placeholder, bytes memory inner) = abi.decode(args, (address, bytes));
        // First argument is the address(0) placeholder the network overwrites
        // with this contract's address — it must NOT already hold a real
        // address, or the vault's sender check would see the wrong value.
        assertEq(placeholder, address(0));
        (address decodedToken, uint256 decodedAmount) = abi.decode(inner, (address, uint256));
        assertEq(decodedToken, token);
        assertEq(decodedAmount, amount);
    }

    function testReactRevertsForNonSystemCaller() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM_ADDR));
        reactive.react(_paymentLog(100));
    }

    // ---- react(): filtering (early return, never revert) ----

    function _assertNoCallbackRequested(IReactive.LogRecord memory log) internal {
        _etchSystem();
        vm.prank(SYSTEM_ADDR);
        vm.recordLogs();
        reactive.react(log);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != keccak256("CallbackRequested(uint256,address,uint64,bytes)"),
                "unexpected callback requested"
            );
            assertTrue(logs[i].topics[0] != keccak256("PaymentSeen(address,address,uint256)"), "unexpected PaymentSeen");
        }
    }

    function testReactIgnoresWrongChain() public {
        IReactive.LogRecord memory log = _paymentLog(100);
        log.chainId = 1;
        _assertNoCallbackRequested(log);
    }

    function testReactIgnoresWrongContract() public {
        IReactive.LogRecord memory log = _paymentLog(100);
        log.contractAddress = makeAddr("otherToken");
        _assertNoCallbackRequested(log);
    }

    function testReactIgnoresWrongTopic() public {
        IReactive.LogRecord memory log = _paymentLog(100);
        log.topic0 = uint256(keccak256("Approval(address,address,uint256)"));
        _assertNoCallbackRequested(log);
    }

    function testReactIgnoresWrongRecipient() public {
        IReactive.LogRecord memory log = _paymentLog(100);
        log.topic2 = uint256(uint160(makeAddr("someoneElse")));
        _assertNoCallbackRequested(log);
    }

    function testReactIgnoresZeroAmount() public {
        _assertNoCallbackRequested(_paymentLog(0));
    }

    function testReactIgnoresMalformedData() public {
        IReactive.LogRecord memory log = _paymentLog(100);
        log.data = hex"1234"; // shorter than 32 bytes
        _assertNoCallbackRequested(log);
    }

    // ---- pause / resume ----

    function testPauseUnsubscribesAndResumeResubscribes() public {
        MockOmniSystemContract mock = _etchSystem();
        // Redeploy so the constructor subscribes against the etched mock.
        PaydayReactiveOmni rc = new PaydayReactiveOmni(ORIGIN_CHAIN_ID, token, vault, CALLBACK_GAS_LIMIT);
        // Clear the constructor's Subscribed log.
        vm.recordLogs();
        rc.pause();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("Unsubscribed(uint256,address,uint256,uint256,uint256,uint256)"));

        vm.recordLogs();
        rc.resume();
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("Subscribed(uint256,address,uint256,uint256,uint256,uint256)"));
        // Silence unused-variable warning (mock is only needed for etch).
        assertTrue(address(mock) != address(0));
    }

    function testPauseAndResumeRevertForNonOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PaydayReactiveOmni.NotOwner.selector, attacker));
        reactive.pause();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(PaydayReactiveOmni.NotOwner.selector, attacker));
        reactive.resume();
    }
}
