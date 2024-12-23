// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { MinimalAccount } from "src/MinimalAccount.sol";
import { HelperConfig } from "./HelperConfig.s.sol";

/**
 * @title DeployMinimal
 * @notice Deployment script for the MinimalAccount smart contract wallet system
 * @dev This contract handles the deployment of our Account Abstraction (ERC-4337) compatible wallet.
 * It works in conjunction with HelperConfig to ensure proper setup across different networks.
 *
 * The deployment process:
 * 1. Gets network-specific configuration (addresses, settings)
 * 2. Deploys a new MinimalAccount (smart contract wallet)
 * 3. Transfers ownership to the deployer
 */
contract DeployMinimal is Script {
    function run() public {
        deployMinimalAccount();
    }

    /**
     * @notice Deploys a new MinimalAccount smart contract wallet
     * @dev This function:
     * 1. Creates a new HelperConfig to get network-specific settings
     * 2. Uses the network's EntryPoint address from config
     * 3. Broadcasts transactions using the configured account
     * 4. Deploys MinimalAccount with proper EntryPoint
     * 5. Transfers ownership to the transaction sender
     *
     * The process is different for each network:
     * - Local (Anvil): Uses fresh deployments of EntryPoint
     * - Testnet (Sepolia): Uses existing EntryPoint address
     * - Other networks: Must be configured in HelperConfig first
     *
     * @return helperconfig The configuration object used for deployment
     * @return minimalAccount The deployed smart contract wallet
     */
    function deployMinimalAccount() public returns (HelperConfig, MinimalAccount) {
        // Get network-specific configuration (EntryPoint address, test tokens, etc.)
        HelperConfig helperconfig = new HelperConfig();
        // Extract the specific network settings we need for this deployment
        HelperConfig.NetworkConfig memory config = helperconfig.getConfig();

        // Start recording transactions for deployment
        // Uses the account specified in config (different for each network)
        vm.startBroadcast(config.account);

        // Deploy new MinimalAccount, connecting it to the network's EntryPoint
        // The EntryPoint is crucial as it handles all AA (Account Abstraction) operations
        MinimalAccount minimalAccount = new MinimalAccount(config.entryPoint);

        // Transfer ownership of the account to the deployer
        // This is important because:
        // 1. Initially, the contract is owned by the deployment account
        // 2. We want the deployer (msg.sender) to control the account
        // 3. The owner can perform direct transactions (bypassing EntryPoint)
        minimalAccount.transferOwnership(config.account);

        // Stop recording transactions
        vm.stopBroadcast();

        // Return both config and account for use in tests or further setup
        return (helperconfig, minimalAccount);
    }
}
