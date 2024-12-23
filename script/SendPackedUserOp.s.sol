// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { PackedUserOperation } from "lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import { HelperConfig } from "script/HelperConfig.s.sol";
import { IEntryPoint } from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MinimalAccount } from "src/ethereum/MinimalAccount.sol";
import { DevOpsTools } from "lib/foundry-devops/src/DevOpsTools.sol";

contract SendPackedUserOp is Script {
    // Import MessageHashUtils for EIP-191 signature formatting
    using MessageHashUtils for bytes32;

    // This is a test address used for demonstration purposes
    // In a production environment, you would use a properly vetted address
    // Make sure you trust this user - don't run this on Mainnet!!!!
    address constant RANDOM_APPROVER = 0x9EA9b0cc1919def1A3CfAEF4F7A66eE3c36F86fC;

    function run() public {
        // SETUP PHASE
        // Create a new configuration helper that manages network-specific addresses
        HelperConfig helperConfig = new HelperConfig();

        // Get the USDC token address for the current network
        // On local networks, this will be a mock token
        // On real networks, this would be the actual USDC contract
        address dest = helperConfig.getConfig().usdc;
        uint256 value = 0; // No ETH is being sent with this transaction

        // Get the most recently deployed MinimalAccount contract address
        // This uses the Foundry deployment artifacts to find the latest deployment
        address minimalAccountAddress = DevOpsTools.get_most_recent_deployment("MinimalAccount", block.chainid);

        // TRANSACTION DATA PREPARATION
        // Create the approval function call data for USDC
        // This would allow RANDOM_APPROVER to spend up to 1e18 tokens
        bytes memory functionData = abi.encodeWithSelector(IERC20.approve.selector, RANDOM_APPROVER, 1e18);

        // Wrap the approval call in the MinimalAccount's execute function
        // This is necessary because all transactions must go through the account's execute function
        bytes memory executeCalldata =
            abi.encodeWithSelector(MinimalAccount.execute.selector, dest, value, functionData);

        // Create and sign the UserOperation
        // This bundles all the transaction details into the format expected by the EntryPoint
        PackedUserOperation memory userOp =
            generateSignedUserOperation(executeCalldata, helperConfig.getConfig(), minimalAccountAddress);

        // Create an array of operations (in this case, just one)
        // The EntryPoint can handle multiple operations in a single call
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;

        // TRANSACTION SUBMISSION
        // Start broadcasting mode for transaction to be sent
        vm.startBroadcast();

        // Send the operation to the EntryPoint
        // The EntryPoint will:
        // 1. Verify the signature
        // 2. Execute the transaction
        // 3. Handle gas payments
        // The second parameter (account) is the beneficiary who receives the gas refund
        IEntryPoint(helperConfig.getConfig().entryPoint).handleOps(ops, payable(helperConfig.getConfig().account));

        // End broadcasting mode
        vm.stopBroadcast();
    }

    /**
     * @notice Creates a fully signed UserOperation ready for submission to the EntryPoint
     * @dev This function handles the complete process of creating and signing a UserOperation:
     * 1. Generates the basic operation structure
     * 2. Gets the operation hash
     * 3. Signs it with the appropriate private key
     *
     * @param callData The encoded function call that the smart account will execute
     * @param config Network configuration containing EntryPoint address and account details
     * @param minimalAccount Address of the smart account that will execute this operation
     * @return A complete PackedUserOperation with valid signature
     */
    function generateSignedUserOperation(
        bytes memory callData,
        HelperConfig.NetworkConfig memory config,
        address minimalAccount
    )
        public
        view
        returns (PackedUserOperation memory)
    {
        // 1. Generate the unsigned UserOperation
        // Subtract 1 from nonce because getNonce returns the next nonce, but we want the current one
        uint256 nonce = vm.getNonce(minimalAccount) - 1;
        PackedUserOperation memory userOp = _generateUnsignedUserOperation(callData, minimalAccount, nonce);

        // 2. Get the userOp hash that needs to be signed
        // First get the hash from EntryPoint (includes chainId and EntryPoint address)
        bytes32 userOpHash = IEntryPoint(config.entryPoint).getUserOpHash(userOp);
        // Then convert it to an Ethereum Signed Message hash (EIP-191 format)
        // This adds the prefix "\x19Ethereum Signed Message:\n32" to make it a personal message
        bytes32 digest = userOpHash.toEthSignedMessageHash();

        // 3. Sign the message with the appropriate private key
        uint8 v; // Recovery identifier (27 or 28)
        bytes32 r; // First 32 bytes of signature
        bytes32 s; // Last 32 bytes of signature

        // This is the private key for the default Anvil account
        uint256 ANVIL_DEFAULT_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

        // Use different private keys based on the network
        if (block.chainid == 31337) {
            // Anvil/local network
            (v, r, s) = vm.sign(ANVIL_DEFAULT_KEY, digest);
        } else {
            // Other networks (e.g., testnet, mainnet)
            (v, r, s) = vm.sign(config.account, digest);
        }

        // Pack the signature components into a single bytes array
        // The order (r,s,v) is important and must match what MinimalAccount.validateUserOp expects
        userOp.signature = abi.encodePacked(r, s, v);

        return userOp;
    }

    /**
     * @notice Creates an unsigned UserOperation with default gas parameters
     * @dev This function constructs the basic structure needed for an ERC-4337 UserOperation
     * before it gets signed. It's "unsigned" because the signature field is empty.
     *
     * @param callData The encoded function call that the smart account will execute
     * @param sender The address of the smart account that will execute this operation
     * @param nonce A unique number to prevent replay attacks, typically the account's current nonce
     * @return A PackedUserOperation struct with all fields filled except signature
     */
    function _generateUnsignedUserOperation(
        bytes memory callData,
        address sender,
        uint256 nonce
    )
        internal
        pure
        returns (PackedUserOperation memory)
    {
        // Set gas limits for verification and execution
        // 16777216 (2^24) is a reasonable upper limit that should cover most operations
        uint128 verificationGasLimit = 16777216; // Gas limit for signature verification & other checks
        uint128 callGasLimit = verificationGasLimit; // Gas limit for the actual transaction execution

        // Set gas prices for the transaction
        // Using low values here since this is mainly for testing
        uint128 maxPriorityFeePerGas = 256;
        uint128 maxFeePerGas = maxPriorityFeePerGas;

        // Create and return a PackedUserOperation
        // This is a special format required by ERC-4337's EntryPoint contract
        return PackedUserOperation({
            // Address of the smart account executing this operation
            sender: sender,
            // Unique identifier to prevent replay attacks
            nonce: nonce,
            // Empty initCode since we're not deploying a new account
            initCode: hex"",
            // The actual transaction data to be executed
            callData: callData,
            // Pack both gas limits into a single bytes32
            // Uses bit shifting to store both values:
            // - Upper 128 bits: verificationGasLimit
            // - Lower 128 bits: callGasLimit
            accountGasLimits: bytes32(uint256(verificationGasLimit) << 128 | callGasLimit),
            // Gas needed for pre-verification operations
            preVerificationGas: verificationGasLimit,
            // Pack both fee values into a single bytes32
            // Similar to accountGasLimits:
            // - Upper 128 bits: maxPriorityFeePerGas
            // - Lower 128 bits: maxFeePerGas
            gasFees: bytes32(uint256(maxPriorityFeePerGas) << 128 | maxFeePerGas),
            // No paymaster is being used (would handle gas fees for the user)
            paymasterAndData: hex"",
            // Empty signature - will be filled later by generateSignedUserOperation
            signature: hex""
        });
    }
}
