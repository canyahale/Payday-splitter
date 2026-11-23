// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {PaydayReactiveOmni} from "../src/PaydayReactiveOmni.sol";

/// @notice Omni redeploy, step 2 of 2: deploy PaydayReactiveOmni on Reactive
/// Lasna (chain 5318007). Run AFTER the vault has been redeployed pointing
/// at this contract's predicted address (see DEPLOY-RUNBOOK.md §7), from the
/// same deployer account whose Lasna nonce was used to predict it.
/// @dev The script verifies the deployed address matches REACTIVE_ADDRESS (the
/// address the new vault was deployed with). If it does not match, the vault
/// points at the wrong reactive contract — do NOT proceed; redeploy the vault
/// with the correct address instead.
/// Required env vars: PRIVATE_KEY, ORIGIN_CHAIN_ID (84532), TOKEN, VAULT,
/// REACTIVE_ADDRESS (predicted address), CALLBACK_GAS_LIMIT (e.g. 300000).
/// Run with: forge script script/DeployReactiveOmni.s.sol --rpc-url <lasna>
///   --broadcast
/// NOTE: the constructor is payable — pass value to fund REACT reserves at
/// deployment via --value, or fund afterwards with depositTo on the Omni
/// system contract (0x8888888888888888888888888888888888888888).
contract DeployReactiveOmni is Script {
    function run() external {
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        address token = vm.envAddress("TOKEN");
        address vault = vm.envAddress("VAULT");
        address expected = vm.envAddress("REACTIVE_ADDRESS");
        uint64 callbackGasLimit = uint64(vm.envUint("CALLBACK_GAS_LIMIT"));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        PaydayReactiveOmni reactive = new PaydayReactiveOmni(originChainId, token, vault, callbackGasLimit);
        vm.stopBroadcast();

        require(address(reactive) == expected, "reactive address mismatch: redeploy vault");
        console.log("PaydayReactiveOmni (Lasna):", address(reactive));
        console.log("Vault (Base Sepolia):", vault);
    }
}
