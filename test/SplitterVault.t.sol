// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SplitterVault} from "../src/SplitterVault.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Tests for SplitterVault: split math, access control, share updates.
contract SplitterVaultTest is Test {
    MockERC20 internal token;
    MockERC20 internal otherToken;
    SplitterVault internal vault;

    address internal proxy = makeAddr("callbackProxy");
    address internal reactive = makeAddr("paydayReactive");
    address internal mainWallet = makeAddr("mainWallet");
    address internal savingsWallet = makeAddr("savingsWallet");
    address internal gasReserve = makeAddr("gasReserve");
    address internal stranger = makeAddr("stranger");

    event Split(address indexed token, uint256 amount, uint256 mainAmount, uint256 savingsAmount, uint256 gasAmount);
    event SharesUpdated(uint256 mainShare, uint256 savingsShare, uint256 gasShare);

    function setUp() public {
        token = new MockERC20();
        otherToken = new MockERC20();
        // Deployer (this test contract) becomes the vault owner.
        vault = new SplitterVault(proxy, address(token), reactive, mainWallet, savingsWallet, gasReserve);
    }

    /// @dev Helper: invoke the vault's callback exactly as the Reactive
    /// callback proxy would — from the proxy, with the reactive contract as sender.
    function _callbackAsProxy(address sender, address token_, uint256 amount) internal {
        vm.prank(proxy);
        vault.callback(sender, abi.encode(token_, amount));
    }

    // ---- Split math ----

    function testSplitDefaultShares() public {
        token.mint(address(vault), 1_000 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit Split(address(token), 1_000 ether, 700 ether, 200 ether, 100 ether);
        _callbackAsProxy(reactive, address(token), 1_000 ether);

        assertEq(token.balanceOf(mainWallet), 700 ether);
        assertEq(token.balanceOf(savingsWallet), 200 ether);
        assertEq(token.balanceOf(gasReserve), 100 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testSplitRoundingGoesToGasReserve() public {
        // 101 * 70% = 70 (truncated), 101 * 20% = 20 (truncated),
        // remainder 11 goes to the gas reserve so nothing is left behind.
        token.mint(address(vault), 101);
        _callbackAsProxy(reactive, address(token), 101);

        assertEq(token.balanceOf(mainWallet), 70);
        assertEq(token.balanceOf(savingsWallet), 20);
        assertEq(token.balanceOf(gasReserve), 11);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testSplitSmallAmount() public {
        // 1 wei: both computed shares truncate to 0, the whole wei goes to gas.
        token.mint(address(vault), 1);
        _callbackAsProxy(reactive, address(token), 1);

        assertEq(token.balanceOf(mainWallet), 0);
        assertEq(token.balanceOf(savingsWallet), 0);
        assertEq(token.balanceOf(gasReserve), 1);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testSplitCapsAtVaultBalance() public {
        // Callback claims 1,000 but the vault only holds 500: split the 500.
        token.mint(address(vault), 500 ether);
        _callbackAsProxy(reactive, address(token), 1_000 ether);

        assertEq(token.balanceOf(mainWallet), 350 ether);
        assertEq(token.balanceOf(savingsWallet), 100 ether);
        assertEq(token.balanceOf(gasReserve), 50 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testSplitSequentialPayments() public {
        token.mint(address(vault), 100 ether);
        _callbackAsProxy(reactive, address(token), 100 ether);
        token.mint(address(vault), 50 ether);
        _callbackAsProxy(reactive, address(token), 50 ether);

        assertEq(token.balanceOf(mainWallet), 105 ether);
        assertEq(token.balanceOf(savingsWallet), 30 ether);
        assertEq(token.balanceOf(gasReserve), 15 ether);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    // ---- Access control: only the Reactive callback can trigger a split ----

    function testCallbackRevertsWhenNotProxy() public {
        token.mint(address(vault), 100 ether);
        vm.prank(stranger);
        vm.expectRevert("Authorized sender only");
        vault.callback(reactive, abi.encode(address(token), 100 ether));
        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function testCallbackRevertsWhenNotOwnerEither() public {
        // Even the vault owner cannot call callback() directly.
        token.mint(address(vault), 100 ether);
        vm.expectRevert("Authorized sender only");
        vault.callback(reactive, abi.encode(address(token), 100 ether));
        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function testCallbackRevertsForWrongReactiveSender() public {
        token.mint(address(vault), 100 ether);
        vm.prank(proxy);
        vm.expectRevert(SplitterVault.UnexpectedReactiveContract.selector);
        vault.callback(stranger, abi.encode(address(token), 100 ether));
        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function testCallbackRevertsForWrongToken() public {
        token.mint(address(vault), 100 ether);
        vm.prank(proxy);
        vm.expectRevert(SplitterVault.UnexpectedToken.selector);
        vault.callback(reactive, abi.encode(address(otherToken), 100 ether));
        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function testCallbackRevertsForZeroAmount() public {
        token.mint(address(vault), 100 ether);
        vm.prank(proxy);
        vm.expectRevert(SplitterVault.ZeroAmount.selector);
        vault.callback(reactive, abi.encode(address(token), 0));
    }

    function testCallbackRevertsWhenVaultEmpty() public {
        vm.prank(proxy);
        vm.expectRevert(SplitterVault.ZeroAmount.selector);
        vault.callback(reactive, abi.encode(address(token), 100 ether));
    }

    // ---- Share updates ----

    function testSetShares() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit SharesUpdated(5000, 3000, 2000);
        vault.setShares(5000, 3000, 2000);

        assertEq(vault.mainShare(), 5000);
        assertEq(vault.savingsShare(), 3000);
        assertEq(vault.gasShare(), 2000);

        token.mint(address(vault), 1_000 ether);
        _callbackAsProxy(reactive, address(token), 1_000 ether);
        assertEq(token.balanceOf(mainWallet), 500 ether);
        assertEq(token.balanceOf(savingsWallet), 300 ether);
        assertEq(token.balanceOf(gasReserve), 200 ether);
    }

    function testSetSharesRevertsOnBadSum() public {
        vm.expectRevert(SplitterVault.InvalidShares.selector);
        vault.setShares(5000, 3000, 1000); // sums to 9_000, not 10_000
        vm.expectRevert(SplitterVault.InvalidShares.selector);
        vault.setShares(6000, 3000, 2000); // sums to 11_000
        // Shares unchanged after failed updates.
        assertEq(vault.mainShare(), 7000);
        assertEq(vault.savingsShare(), 2000);
        assertEq(vault.gasShare(), 1000);
    }

    function testSetSharesRevertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(SplitterVault.UnauthorizedSender.selector);
        vault.setShares(5000, 3000, 2000);
    }

    function testSetSharesToZeroForOneDestination() public {
        vault.setShares(8000, 2000, 0);
        token.mint(address(vault), 100 ether);
        _callbackAsProxy(reactive, address(token), 100 ether);
        assertEq(token.balanceOf(mainWallet), 80 ether);
        assertEq(token.balanceOf(savingsWallet), 20 ether);
        assertEq(token.balanceOf(gasReserve), 0);
    }

    // ---- Constructor / ownership ----

    function testDefaults() public view {
        assertEq(vault.token(), address(token));
        assertEq(vault.reactiveContract(), reactive);
        assertEq(vault.mainWallet(), mainWallet);
        assertEq(vault.savingsWallet(), savingsWallet);
        assertEq(vault.gasReserve(), gasReserve);
        assertEq(vault.owner(), address(this));
        assertEq(vault.mainShare(), 7000);
        assertEq(vault.savingsShare(), 2000);
        assertEq(vault.gasShare(), 1000);
    }

    function testConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(SplitterVault.ZeroAddress.selector);
        new SplitterVault(proxy, address(0), reactive, mainWallet, savingsWallet, gasReserve);
        vm.expectRevert(SplitterVault.ZeroAddress.selector);
        new SplitterVault(proxy, address(token), address(0), mainWallet, savingsWallet, gasReserve);
        vm.expectRevert(SplitterVault.ZeroAddress.selector);
        new SplitterVault(proxy, address(token), reactive, address(0), savingsWallet, gasReserve);
    }

    function testTransferOwnership() public {
        address newOwner = makeAddr("newOwner");
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), newOwner);
        // Old owner can no longer set shares.
        vm.expectRevert(SplitterVault.UnauthorizedSender.selector);
        vault.setShares(5000, 3000, 2000);
        // New owner can.
        vm.prank(newOwner);
        vault.setShares(5000, 3000, 2000);
        assertEq(vault.mainShare(), 5000);
    }
}
