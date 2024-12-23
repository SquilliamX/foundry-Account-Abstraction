// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";
import { DeployMinimal } from "script/DeployMinimal.s.sol";
import { MinimalAccount } from "src/MinimalAccount.sol";
import { HelperConfig } from "script/HelperConfig.s.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { SendPackedUserOp, PackedUserOperation, IEntryPoint } from "script/SendPackedUserOp.s.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract MinimalAccountTest is Test {
    // Import OpenZeppelin's MessageHashUtils for EIP-191 signature formatting
    // This is crucial for creating Ethereum signed message hashes that match what wallets produce
    using MessageHashUtils for bytes32;

    // Configuration helper that manages network-specific contract addresses and settings
    // This allows tests to work across different networks (local, testnet, mainnet)
    HelperConfig helperConfig;

    // The smart contract wallet we're testing
    // This is our implementation of ERC-4337 (Account Abstraction)
    MinimalAccount minimalAccount;

    // Mock USDC token for testing
    // We use a mock instead of real USDC to have full control over token behavior
    ERC20Mock usdc;

    // Helper contract that demonstrates how to create and send UserOperations
    // This shows the complete flow of creating a transaction through Account Abstraction
    SendPackedUserOp sendPackedUserOp;

    // Test address representing a random user
    // Created using Forge's makeAddr helper for deterministic test addresses
    address randomUser = makeAddr("randomUser");

    // Standard amount for testing token operations
    // Using 1e18 (1 token) as a round number that works with most ERC20 decimals
    uint256 constant AMOUNT = 1e18;

    /**
     * @notice Test setup that runs before each test
     * @dev This setup:
     * 1. Deploys a fresh MinimalAccount using DeployMinimal script
     *    - This also sets up the EntryPoint contract through HelperConfig
     *    - The account owner will be the test contract address
     *
     * 2. Creates a new mock USDC token
     *    - This gives us a token we can freely mint for testing
     *    - Allows testing approve/transfer operations safely
     *
     * 3. Creates SendPackedUserOp helper
     *    - This will help us create valid UserOperations
     *    - Handles all the complex signature and packing logic
     */
    function setUp() public {
        // Deploy a fresh MinimalAccount using our deployment script
        DeployMinimal deployMinimal = new DeployMinimal();
        (helperConfig, minimalAccount) = deployMinimal.deployMinimalAccount();

        // Deploy a fresh mock USDC token for testing
        usdc = new ERC20Mock();

        // Create helper for generating UserOperations
        sendPackedUserOp = new SendPackedUserOp();
    }

    /**
     * @notice Tests that the account owner can directly execute transactions
     * @dev This test verifies the traditional (non-AA) transaction path where the owner
     * directly interacts with the smart account without going through EntryPoint
     */
    function testOwnerCanExecuteCommands() public {
        // ARRANGE
        // Verify the account starts with zero USDC balance
        // This establishes our baseline state before the test
        assertEq(usdc.balanceOf(address(minimalAccount)), 0);

        // Set up the transaction parameters:
        // 1. dest: The USDC contract address (target of our transaction)
        address dest = address(usdc);
        // 2. value: Amount of ETH to send (0 since we're just calling a function)
        uint256 value = 0;
        // 3. functionData: Encode the mint function call with our parameters
        // - This creates the exact bytes that would be sent to the contract
        // - We're calling mint(address,uint256) with our account address and AMOUNT
        bytes memory functionData = abi.encodeWithSelector(ERC20Mock.mint.selector, address(minimalAccount), AMOUNT);

        // ACT
        // Simulate the transaction coming from the account owner
        // vm.prank is a Foundry cheatcode that makes the next call appear to come from the specified address
        vm.prank(minimalAccount.owner());
        // Execute the transaction through our smart account
        // This calls the execute function which is protected by requireFromEntryPointOrOwner
        minimalAccount.execute(dest, value, functionData);

        // ASSERT
        // Verify the mint was successful by checking the new balance
        // The account should now have AMOUNT tokens
        assertEq(usdc.balanceOf(address(minimalAccount)), AMOUNT);
    }

    /**
     * @notice Tests that non-owners cannot directly execute transactions
     * @dev This test verifies that the account's security prevents unauthorized access
     * This is crucial because:
     * 1. Only the owner should have direct access
     * 2. All other interactions must go through EntryPoint (the AA flow)
     */
    function testNonOwnerCannotExecuteCommands() public {
        // ARRANGE
        // Verify the account starts with zero USDC balance
        assertEq(usdc.balanceOf(address(minimalAccount)), 0);

        // Set up the same transaction parameters as the previous test
        address dest = address(usdc);
        uint256 value = 0;
        bytes memory functionData = abi.encodeWithSelector(ERC20Mock.mint.selector, address(minimalAccount), AMOUNT);

        // ACT & ASSERT
        // Simulate the transaction coming from a random unauthorized address
        vm.prank(randomUser);
        // Expect the transaction to revert with our custom error
        // This error comes from the requireFromEntryPointOrOwner modifier
        vm.expectRevert(MinimalAccount.MinimalAccount__NotFromEntryPointOrOwner.selector);
        // Attempt to execute the transaction (should fail)
        minimalAccount.execute(dest, value, functionData);
    }

    /**
     * @notice Tests the signature verification process for Account Abstraction transactions
     * @dev This test verifies that we can correctly recover the signer's address from a signed UserOperation
     * This is crucial for Account Abstraction because:
     * 1. Users sign transactions off-chain (like with MetaMask)
     * 2. The EntryPoint must verify these signatures on-chain
     * 3. The signature proves the owner authorized the transaction
     */
    function testRecoverSignedOp() public {
        // ARRANGE
        // First verify our starting state - account should have no USDC
        assertEq(usdc.balanceOf(address(minimalAccount)), 0);

        // Set up a test transaction to mint USDC tokens
        // 1. dest: The USDC contract we're interacting with
        address dest = address(usdc);
        // 2. value: No ETH being sent with this call
        uint256 value = 0;
        // 3. functionData: Encode the mint function call
        // This creates the exact bytes that would be sent to mint USDC
        bytes memory functionData = abi.encodeWithSelector(ERC20Mock.mint.selector, address(minimalAccount), AMOUNT);

        // Wrap the USDC mint call inside our account's execute function
        // This is necessary because all transactions must go through execute()
        // The executeCallData contains: execute(dest, value, functionData)
        bytes memory executeCallData =
            abi.encodeWithSelector(MinimalAccount.execute.selector, dest, value, functionData);

        // Create a complete UserOperation with valid signature
        // This simulates what a wallet (like MetaMask) would create
        // The helper handles all the complex UserOp creation and signing
        PackedUserOperation memory packedUserOp = sendPackedUserOp.generateSignedUserOperation(
            executeCallData, helperConfig.getConfig(), address(minimalAccount)
        );

        // Get the hash that was signed
        // This hash uniquely identifies the UserOperation and includes:
        // - All operation parameters
        // - The chain ID
        // - The EntryPoint address
        bytes32 userOperationHash = IEntryPoint(helperConfig.getConfig().entryPoint).getUserOpHash(packedUserOp);

        // ACT
        // Recover the signer's address from the signature
        // 1. Convert hash to EIP-191 format (adds Ethereum message prefix)
        // 2. Use ECDSA to recover the address that created this signature
        address actualSigner = ECDSA.recover(userOperationHash.toEthSignedMessageHash(), packedUserOp.signature);

        // ASSERT
        // Verify the recovered signer matches our account's owner
        // This proves the signature was created by the rightful owner
        assertEq(actualSigner, minimalAccount.owner());
    }

    /**
     * @notice Tests the validation process of UserOperations by the smart account
     * @dev This test verifies that:
     * 1. The account can properly validate signatures from its owner
     * 2. The EntryPoint's validation process works correctly
     * 3. The account handles gas prefunding properly
     */
    function testValidationOfUserOps() public {
        // ARRANGE
        // First verify the account starts with zero USDC balance
        // This establishes our baseline state
        assertEq(usdc.balanceOf(address(minimalAccount)), 0);

        // Set up the transaction parameters for a USDC mint operation:
        // 1. dest: The USDC contract we want to interact with
        address dest = address(usdc);
        // 2. value: No ETH being sent with this call
        uint256 value = 0;
        // 3. functionData: Encode the mint function call
        // This creates the exact bytes that would be sent to mint USDC tokens
        bytes memory functionData = abi.encodeWithSelector(ERC20Mock.mint.selector, address(minimalAccount), AMOUNT);

        // Wrap the USDC mint call inside our account's execute function
        // We need this because all transactions must go through execute()
        // This creates: execute(dest, value, functionData)
        bytes memory executeCallData =
            abi.encodeWithSelector(MinimalAccount.execute.selector, dest, value, functionData);

        // Create a complete UserOperation with valid signature using our helper
        // This simulates what a wallet (like MetaMask) would create
        // The helper handles all the complex UserOp creation and signing
        PackedUserOperation memory packedUserOp = sendPackedUserOp.generateSignedUserOperation(
            executeCallData, helperConfig.getConfig(), address(minimalAccount)
        );

        // Get the hash that was signed
        // This hash uniquely identifies the UserOperation and includes:
        // - All operation parameters
        // - The chain ID
        // - The EntryPoint address
        bytes32 userOperationHash = IEntryPoint(helperConfig.getConfig().entryPoint).getUserOpHash(packedUserOp);

        // Set how much ETH the account needs for gas
        // In real scenarios, this would be calculated based on gas prices
        uint256 missingAccountFunds = 1e18;

        // ACT
        // Simulate the EntryPoint calling validateUserOp
        // vm.prank makes the next call appear to come from the EntryPoint
        vm.prank(helperConfig.getConfig().entryPoint);
        // Call validateUserOp which:
        // 1. Verifies the signature
        // 2. Handles gas prefunding
        // 3. Returns validation status (0 = success, 1 = failure)
        uint256 validationData = minimalAccount.validateUserOp(packedUserOp, userOperationHash, missingAccountFunds);

        // ASSERT
        // Verify the validation was successful (should return 0)
        assertEq(validationData, 0);
    }

    /**
     * @notice Tests that the EntryPoint can successfully execute operations through the account
     * @dev This test verifies the complete Account Abstraction flow:
     * 1. Creating a valid UserOperation
     * 2. Submitting it through EntryPoint
     * 3. Successful execution of the intended transaction
     */
    function testEntryPointCanExecuteCommands() public {
        // ARRANGE
        // Verify starting state - account should have no USDC
        assertEq(usdc.balanceOf(address(minimalAccount)), 0);

        // Set up the transaction parameters for a USDC mint:
        // 1. dest: The USDC contract address
        address dest = address(usdc);
        // 2. value: No ETH being sent
        uint256 value = 0;
        // 3. functionData: Encode the mint function call
        bytes memory functionData = abi.encodeWithSelector(ERC20Mock.mint.selector, address(minimalAccount), AMOUNT);

        // Wrap the mint call in execute function data
        // This is required because all transactions go through execute()
        bytes memory executeCallData =
            abi.encodeWithSelector(MinimalAccount.execute.selector, dest, value, functionData);

        // Create a signed UserOperation
        // This contains all the transaction details and a valid signature
        PackedUserOperation memory packedUserOp = sendPackedUserOp.generateSignedUserOperation(
            executeCallData, helperConfig.getConfig(), address(minimalAccount)
        );

        // Give the account some ETH for gas
        // vm.deal is a Foundry cheatcode that sets an address's ETH balance
        vm.deal(address(minimalAccount), AMOUNT);

        // Create an array of operations (EntryPoint can handle multiple)
        // In this case, we're just sending one operation
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = packedUserOp;

        // ACT
        // Simulate the call coming from a random user
        // In reality, this could be a bundler submitting transactions
        vm.prank(randomUser);
        // Submit the operation to EntryPoint
        // The EntryPoint will:
        // 1. Validate the signature
        // 2. Handle gas payments
        // 3. Execute the transaction
        IEntryPoint(helperConfig.getConfig().entryPoint).handleOps(ops, payable(randomUser));

        // ASSERT
        // Verify the mint was successful
        // The account should now have AMOUNT tokens
        assertEq(usdc.balanceOf(address(minimalAccount)), AMOUNT);
    }
}
