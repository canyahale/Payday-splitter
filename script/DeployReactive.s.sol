// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PaydayReactive} from "../src/PaydayReactive.sol";

/// @notice Step 2 of 2: deploy the PaydayReactive contract on Reactive Lasna
/// (chain 5318007). Run AFTER DeployVault.s.sol, from the same deployer account
/// whose Lasna nonce was used to predict this contract's address.
/// @dev The script verifies the deployed address matches REACTIVE_ADDRESS (the
/// address the vault was deployed with). If it does not match, the vault points
/// at the wrong reactive contract — do NOT proceed; redeploy the vault with the
/// correct address instead.
/// Required env vars: PRIVATE_KEY, ORIGIN_CHAIN_ID (84532), TOKEN, VAULT,
/// REACTIVE_ADDRESS (predicted address from step 1), CALLBACK_GAS_LIMIT
/// (e.g. 300000).
/// Run with: forge script script/DeployReactive.s.sol --rpc-url <lasna>
///   --broadcast
contract DeployReactive is Script {
    function run() external {
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        address token = vm.envAddress("TOKEN");
        address vault = vm.envAddress("VAULT");
        address expected = vm.envAddress("REACTIVE_ADDRESS");
        uint64 callbackGasLimit = uint64(vm.envUint("CALLBACK_GAS_LIMIT"));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        PaydayReactive reactive = new PaydayReactive(originChainId, token, vault, callbackGasLimit);
        vm.stopBroadcast();

        require(address(reactive) == expected, "reactive address mismatch: redeploy vault");
        console.log("PaydayReactive (Lasna):", address(reactive));
        console.log("Vault (Base Sepolia):", vault);
    }
}
