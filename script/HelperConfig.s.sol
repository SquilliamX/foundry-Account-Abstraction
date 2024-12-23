// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title HelperConfig
 * @notice Configuration management for different blockchain networks
 * @dev This contract provides network-specific configurations for our smart contract system.
 * It handles different setups for:
 * 1. Local testing (Anvil)
 * 2. Ethereum Sepolia testnet
 * 3. zkSync Sepolia testnet
 * Each network needs different contract addresses and configurations.
 */
import { Script, console2 } from "forge-std/Script.sol";
import { MinimalAccount } from "src/MinimalAccount.sol";
import { EntryPoint } from "lib/account-abstraction/contracts/core/EntryPoint.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    error HelperConfig__InvalidChainId();

    /**
     * @dev Struct to hold network-specific configurations
     * @param entryPoint The address of the ERC-4337 EntryPoint contract that manages account abstraction
     * @param usdc The address of the USDC token contract (either real or mocked)
     * @param account The address of the test wallet for transactions
     */
    struct NetworkConfig {
        address entryPoint;
        address usdc;
        address account;
    }

    // Chain IDs for different networks
    // Sepolia is Ethereum's testnet for developers
    uint256 constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    // zkSync is a Layer 2 scaling solution, this is their testnet
    uint256 constant ZKSYNC_SEPOLIA_CHAIN_ID = 300;
    // Anvil is Foundry's local development network, similar to Ganache
    uint256 constant LOCAL_CHAIN_ID = 31337;

    // Pre-defined wallet addresses for testing
    // A burner wallet is a temporary wallet used for testing
    address constant BURNER_WALLET = 0x3140fCE59242838A59149FfE25076703CcaaA528;
    // Default wallet address used by Foundry for testing
    // address constant FOUNDRY_DEFAULT_WALLET = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    // Default account that comes with Anvil when started
    // This account has test ETH and is used as the deployer
    address constant ANVIL_DEFAULT_ACCOUNT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    // Storage for network configurations
    // Stores the local network (Anvil) configuration separately since it needs special handling
    NetworkConfig public localNetworkConfig;
    // Maps chain IDs to their respective configurations
    // This allows us to easily retrieve settings for any supported network
    mapping(uint256 chainId => NetworkConfig) public networkConfigs;

    /**
     * @dev Constructor initializes network configurations
     * We only set up Sepolia initially because:
     * 1. It's a stable testnet with known addresses
     * 2. Local network (Anvil) needs special handling with mock deployments
     * 3. zkSync might need different configurations based on their development status
     */
    constructor() {
        networkConfigs[ETH_SEPOLIA_CHAIN_ID] = getEthSepoliaConfig();
    }

    /**
     * @dev Returns the configuration for the current network
     * Uses block.chainid to automatically detect which network we're on
     * This makes the contract self-configuring based on where it's deployed
     * @return NetworkConfig configuration for the current network
     */
    function getConfig() public returns (NetworkConfig memory) {
        return getConfigByChainId(block.chainid);
    }

    /**
     * @dev Returns configuration for a specific chain ID
     * This function implements the following logic:
     * 1. For local network (Anvil) - creates new contracts if needed
     * 2. For known networks - returns their pre-configured settings
     * 3. For unknown networks - reverts with an error
     *
     * @param chainId the blockchain network identifier
     * @return NetworkConfig configuration for the specified network
     *
     * The function uses EntryPoint address as a check for existing config
     * because EntryPoint is required for all networks (it's the core of ERC-4337)
     */
    function getConfigByChainId(uint256 chainId) public returns (NetworkConfig memory) {
        // For local testing network (Anvil)
        if (chainId == LOCAL_CHAIN_ID) {
            return getOrCreateAnvilEthConfig();
        }
        // For known networks (checks if EntryPoint is configured)
        else if (networkConfigs[chainId].entryPoint != address(0)) {
            return networkConfigs[chainId];
        }
        // For unsupported networks
        else {
            revert HelperConfig__InvalidChainId();
        }
    }

    /**
     * @notice Returns configuration for Ethereum Sepolia testnet
     * @dev This network uses:
     * - EntryPoint: The official ERC-4337 EntryPoint contract on Sepolia
     * - USDC: The official USDC contract on Sepolia
     * - Account: A burner wallet for testing (address(1))
     * These addresses are hardcoded because they're well-known contract addresses
     * that don't change on Sepolia
     */
    function getEthSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            entryPoint: 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789, // Official EntryPoint contract
            usdc: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // Official USDC contract
            account: BURNER_WALLET // Test wallet address
         });
    }

    /**
     * @notice Returns configuration for zkSync Sepolia testnet
     * @dev Currently uses:
     * - EntryPoint: address(0) as it's not yet deployed on zkSync
     * - USDC: Same as Ethereum's USDC address (this might need updating)
     * - Account: Same burner wallet as other networks
     * This configuration is a placeholder until zkSync Sepolia is fully supported
     */
    function getZkSyncSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            entryPoint: address(0),
            usdc: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // Using ETH USDC address
            account: BURNER_WALLET // Test wallet address
         });
    }

    /**
     * @notice Sets up or returns existing configuration for local Anvil network
     * @dev This function:
     * 1. Checks if we already have a configuration (to avoid redeploying)
     * 2. If not, deploys fresh instances of:
     *    - EntryPoint: For handling account abstraction operations
     *    - ERC20Mock: A test USDC token we can freely mint
     * 3. Uses Anvil's default account for testing
     * @return NetworkConfig containing all necessary contract addresses
     */
    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        // Return cached config if it exists (check if account is set)
        if (localNetworkConfig.account != address(0)) {
            return localNetworkConfig;
        }

        // deploy mocks
        console2.log("Deploying mocks...");
        vm.startBroadcast(ANVIL_DEFAULT_ACCOUNT);
        EntryPoint entryPoint = new EntryPoint(); // Fresh EntryPoint for testing
        ERC20Mock erc20Mock = new ERC20Mock(); // Fresh USDC mock for testing
        vm.stopBroadcast();
        console2.log("Mocks deployed!");

        // Cache and return the new configuration
        localNetworkConfig =
            NetworkConfig({ entryPoint: address(entryPoint), usdc: address(erc20Mock), account: ANVIL_DEFAULT_ACCOUNT });
        return localNetworkConfig;
    }
}
