// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Import core interfaces and libraries needed for account abstraction and signature verification
import { IAccount } from "lib/account-abstraction/contracts/interfaces/IAccount.sol";
import { PackedUserOperation } from "lib/account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS } from "lib/account-abstraction/contracts/core/Helpers.sol";
import { IEntryPoint } from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";

/**
 * @title MinimalAccount
 * @notice This contract implements a basic ERC-4337 compatible smart contract wallet (account abstraction).
 * @dev This account can:
 * 1. Receive and execute transactions through the EntryPoint contract
 * 2. Validate signatures from its owner
 * 3. Handle gas payments for transactions
 *
 * The account follows the "account abstraction" pattern, which means users can interact
 * with the blockchain without directly managing private keys or ETH for gas.
 */
contract MinimalAccount is IAccount, Ownable {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    // Thrown when a function restricted to EntryPoint is called by another address
    error MinimalAccount__NotFromEntryPoint();
    // Thrown when a function restricted to EntryPoint/owner is called by another address
    error MinimalAccount__NotFromEntryPointOrOwner();
    // Thrown when the account fails to execute a transaction
    error MiniamlAccount__CallFailed(bytes);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The EntryPoint contract that manages this account's transactions
     * @dev The EntryPoint is the central contract in ERC-4337 that:
     * 1. Receives all user operations (transactions)
     * 2. Validates signatures and nonces
     * 3. Handles gas payments
     * 4. Executes the actual transactions
     */
    IEntryPoint private immutable i_entryPoint;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensures only the EntryPoint contract can call the modified function
     * @dev This is crucial for security as the EntryPoint handles all transaction validation
     * and execution. Direct calls to these functions could bypass important checks.
     */
    modifier requireFromEntryPoint() {
        if (msg.sender != address(i_entryPoint)) {
            revert MinimalAccount__NotFromEntryPoint();
        }
        _;
    }

    /**
     * @notice Ensures only the EntryPoint or the account owner can call the modified function
     * @dev This allows both:
     * 1. Normal transactions through the EntryPoint (account abstraction flow)
     * 2. Direct transactions from the owner (traditional EOA flow)
     */
    modifier requireFromEntryPointOrOwner() {
        if (msg.sender != address(i_entryPoint) && msg.sender != owner()) {
            revert MinimalAccount__NotFromEntryPointOrOwner();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new smart contract account
     * @param entryPoint The address of the ERC-4337 EntryPoint contract
     * @dev The constructor also sets up the initial owner who can directly control the account
     * This is done through the Ownable constructor which sets msg.sender as owner
     */
    constructor(address entryPoint) Ownable(msg.sender) {
        i_entryPoint = IEntryPoint(entryPoint);
    }

    /**
     * @notice Allows the account to receive ETH directly
     * @dev This is needed for:
     * 1. Receiving gas refunds from the EntryPoint
     * 2. Receiving general ETH transfers to the account
     */
    receive() external payable { }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Executes a transaction from this account
     * @param dest The target contract address
     * @param value The amount of ETH to send
     * @param functionData The calldata for the transaction
     * @dev This function can be called either:
     * 1. By the EntryPoint (during normal account abstraction flow)
     * 2. Directly by the owner (as a backup or for testing)
     * It uses a low-level call to support any type of transaction
     */
    function execute(address dest, uint256 value, bytes calldata functionData) external requireFromEntryPointOrOwner {
        // Make the call to the target contract with specified value and data
        (bool success, bytes memory result) = dest.call{ value: value }(functionData);
        // Revert if the call fails, passing along the error message
        if (!success) {
            revert MiniamlAccount__CallFailed(result);
        }
    }

    /**
     * @notice Validates a UserOperation before execution
     * @notice This is the function that would contain all the logic for what parameters are needed to happen in order for a transaction to be signed, i.e 7 friends need to sign first, or google needs to sign first.
     * @param userOp The UserOperation to validate
     * @param userOpHash A hash of the UserOperation
     * @param missingAccountFunds The amount of ETH needed to pay for the operation
     * @return validationData Packed validation data indicating if the signature is valid
     * @dev This is the core validation function called by the EntryPoint. It:
     * 1. Verifies the signature is from the owner
     * 2. Handles any required gas payments
     * The function must return specific values:
     * - 0 (SIG_VALIDATION_SUCCESS) for success
     * - 1 (SIG_VALIDATION_FAILED) for failure
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    )
        external
        requireFromEntryPoint
        returns (uint256 validationData)
    {
        // Verify the signature on the UserOperation
        validationData = _validateSignature(userOp, userOpHash);
        _payPrefund(missingAccountFunds);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates the signature on a UserOperation
     * @param userOp The UserOperation containing the signature
     * @param userOpHash The hash of the UserOperation that was signed
     * @return validationData 0 if valid, 1 if invalid
     * @dev The function:
     * 1. Converts the hash to EIP-191 format (adds Ethereum signed message prefix)
     * 2. Recovers the signer's address using ECDSA
     * 3. Compares the signer with the account owner
     */
    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    )
        internal
        view
        returns (uint256 validationData)
    {
        // Convert the hash to an Ethereum signed message hash (EIP-191)
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        // Recover the signer's address from the signature
        address signer = ECDSA.recover(ethSignedMessageHash, userOp.signature);
        // Return failure if signer isn't the owner, success otherwise
        if (signer != owner()) {
            return SIG_VALIDATION_FAILED;
        }
        return SIG_VALIDATION_SUCCESS;
    }

    /**
     * @notice Handles payment of gas fees to the EntryPoint
     * @param missingAccountFunds The amount of ETH needed
     * @dev This function:
     * 1. Only transfers if funds are actually needed
     * 2. Uses maximum gas to ensure the transfer succeeds
     * 3. Doesn't check success as the EntryPoint handles failure cases
     */
    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds != 0) {
            // Transfer the required funds to the EntryPoint with maximum gas
            (bool success,) = payable(msg.sender).call{ value: missingAccountFunds, gas: type(uint256).max }("");
            (success);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the address of the EntryPoint contract
     * @return The EntryPoint contract address
     * @dev This is useful for:
     * 1. Verification by external contracts
     * 2. Integration with tools and frontends
     */
    function getEntryPoint() external view returns (address) {
        return address(i_entryPoint);
    }
}
