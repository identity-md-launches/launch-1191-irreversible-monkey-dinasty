// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {MonkeyToken} from "../src/MonkeyToken.sol";

/// @title Deploy script for MonkeyToken
/// @notice Reviewable reference deployment. The token takes no constructor arguments, so there is
///         no configuration to read. On the IdentityMD launch the factory deploys the token itself
///         from its bytecode via `ProjectFactory.launchCustom`; this script is for local dry runs,
///         testnets, or a manual deployment outside the launch.
/// @dev `deploy()` is the function tests call directly. `run()` only wraps it in a broadcast and
///      never reads environment variables, so the tests stay independent of the caller.
contract DeployMonkeyToken is Script {
    /// @notice Deploys the token. Whoever calls this (the broadcaster) receives the whole supply.
    function deploy() public returns (MonkeyToken token) {
        token = new MonkeyToken();
    }

    function run() external returns (MonkeyToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
