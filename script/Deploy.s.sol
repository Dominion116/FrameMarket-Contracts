// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {FrameMarket} from "../src/FrameMarket.sol";

contract DeployScript is Script {
    function run() external returns (FrameMarket) {
        uint16 feeBps = 250; // 2.5%
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        
        vm.startBroadcast();
        
        FrameMarket market = new FrameMarket(feeBps, feeRecipient);
        
        console2.log("FrameMarket deployed to:", address(market));
        console2.log("Fee:", feeBps, "bps");
        console2.log("Fee Recipient:", feeRecipient);
        
        vm.stopBroadcast();
        
        return market;
    }
}