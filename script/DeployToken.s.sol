// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/MockERC20.sol";

/// @notice Step 0 of 3: deploy the MockERC20 payment token on Base Sepolia
/// and mint 1,000,000 MPT to the deployer (test payments come from there).
/// Run BEFORE DeployVault.s.sol. Does not touch the Lasna nonce.
/// Required env vars: PRIVATE_KEY.
/// Run with: forge script script/DeployToken.s.sol --rpc-url <base-sepolia>
///   --broadcast
contract DeployToken is Script {
    function run() external {
        // FIX 2026-11-23: msg.sender inside a broadcast is the script
        // contract, NOT the deployer — minting to it stranded the supply.
        // Derive the deployer address from the key instead.
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        MockERC20 token = new MockERC20();
        token.mint(deployer, 1_000_000 ether);
        vm.stopBroadcast();
        console.log("MockERC20 (Base Sepolia):", address(token));
        console.log("Minted 1,000,000 MPT to deployer:", deployer);
    }
}
