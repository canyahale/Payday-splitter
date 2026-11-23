// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SplitterVault} from "../src/SplitterVault.sol";

/// @notice Step 1 of 2: deploy the SplitterVault on Base Sepolia.
/// @dev The vault's reactive-contract address is immutable, so the Lasna
/// PaydayReactive address must be known BEFORE this runs. Predict it from the
/// deployer's Lasna nonce (nothing else may be deployed from that account on
/// Lasna in between):
///   cast compute-address <deployer> --nonce <lasna-nonce>
/// then pass it as REACTIVE_ADDRESS. After this, run DeployReactive.s.sol on
/// Lasna and check the deployed reactive address matches the prediction.
/// Required env vars: PRIVATE_KEY, TOKEN, REACTIVE_ADDRESS, MAIN_WALLET,
/// SAVINGS_WALLET, GAS_RESERVE, CALLBACK_PROXY (Reactive callback proxy on
/// Base Sepolia).
/// Run with: forge script script/DeployVault.s.sol --rpc-url <base-sepolia>
///   --broadcast
contract DeployVault is Script {
    function run() external {
        address token = vm.envAddress("TOKEN");
        address reactive = vm.envAddress("REACTIVE_ADDRESS");
        address mainWallet = vm.envAddress("MAIN_WALLET");
        address savingsWallet = vm.envAddress("SAVINGS_WALLET");
        address gasReserve = vm.envAddress("GAS_RESERVE");
        address callbackProxy = vm.envAddress("CALLBACK_PROXY");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        SplitterVault vault = new SplitterVault(callbackProxy, token, reactive, mainWallet, savingsWallet, gasReserve);
        vm.stopBroadcast();
        console.log("SplitterVault (Base Sepolia):", address(vault));
        console.log("Reactive contract (expected):", reactive);
    }
}
