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

// MinimalAccount implements IAccount interface for ERC-4337 compatibility and inherits Ownable for access control
contract MinimalAccount is IAccount, Ownable {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error MinimalAccount__NotFromEntryPoint();
    error MinimalAccount__NotFromEntryPointOrOwner();
    error MiniamlAccount__CallFailed(bytes);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // Store the EntryPoint contract address - this is the central contract that handles all UserOperations
    IEntryPoint private immutable i_entryPoint;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    // Ensures function can only be called by the EntryPoint contract
    modifier requireFromEntryPoint() {
        if (msg.sender != address(i_entryPoint)) {
            revert MinimalAccount__NotFromEntryPoint();
        }
        _;
    }

    // Ensures function can only be called by either the EntryPoint or the account owner
    modifier requireFromEntryPointOrOwner() {
        if (msg.sender != address(i_entryPoint) && msg.sender != owner()) {
            revert MinimalAccount__NotFromEntryPointOrOwner();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // Initialize the account with the EntryPoint address and set the initial owner
    constructor(address entryPoint) Ownable(msg.sender) {
        i_entryPoint = IEntryPoint(entryPoint);
    }

    // Allow the contract to receive ETH directly
    receive() external payable { }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // the execute function allows this account to send transactions
    // Execute arbitrary transactions from this account - can only be called by EntryPoint or owner
    function execute(address dest, uint256 value, bytes calldata functionData) external requireFromEntryPointOrOwner {
        // Make the call to the target contract with specified value and data
        (bool success, bytes memory result) = dest.call{ value: value }(functionData);
        // Revert if the call fails, passing along the error message
        if (!success) {
            revert MiniamlAccount__CallFailed(result);
        }
    }

    // this is the function that would contain all the logic for what parameters are needed to happen in order for a transaction to be signed, i.e 7 friends need to sign first, or google needs to sign first.
    // A signature is valid, if it's the MinimalAccount owner
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
        // _validateNonce()
        _payPrefund(missingAccountFunds);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // EIP-191 version of the signed hash
    // Verify that the UserOperation was signed by the account owner
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

    // Handle prefunding the EntryPoint for gas costs if needed
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

    // Return the address of the EntryPoint contract this account uses
    function getEntryPoint() external view returns (address) {
        return address(i_entryPoint);
    }
}
