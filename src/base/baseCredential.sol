// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SignedCredential} from "../Types/Structs/Credentials.sol";
import {DataHasher} from "../libraries/Datahasher.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

abstract contract BaseCredential is AccessControl {
    error InvalidVersion();
    error DataExpired();
    error NonceTooLow();
    error InvalidSig();

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");
    mapping(address provider => uint256 nonce)public user2nonce;
    uint8 private _validatorThreshold = 1;


    constructor(address governor) {
        require(governor != address(0), "Governor cannot be zero");
        _setRoleAdmin(GOVERNOR_ROLE, GOVERNOR_ROLE);
        _setRoleAdmin(VALIDATOR_ROLE, GOVERNOR_ROLE);
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(VALIDATOR_ROLE, governor);
    }

    modifier validateAndBurnCred(SignedCredential calldata sc, bytes memory params){
        _validateAndBurnCred(DataHasher.gethashAt(msg.sender, params, sc.vc), sc);
        _;
    }

    function addValidator(address account) external {
        grantRole(VALIDATOR_ROLE, account);
    }

    function removeValidator(address account) external {
        revokeRole(VALIDATOR_ROLE, account);
    }

    function requireValidator(address account) public view {
        require(hasRole(VALIDATOR_ROLE, account), "Validator only");
    }

    function isValidator(address account) public view returns (bool) {
        return hasRole(VALIDATOR_ROLE, account);
    }

    function getRequiredValidatorSignatures()
    public
    view
    returns (uint8)
    {
        return _validatorThreshold;
    }

    function setRequiredValidatorSignatures(
        uint8 value
    ) public onlyRole(GOVERNOR_ROLE) {
        _validatorThreshold = value;
    }


    function _validateAndBurnCred(
        bytes32 dataHash,
        SignedCredential calldata sc
    ) internal {
        checkValidatorSignatures(dataHash, sc.signature);
        _checkScParam(sc);
    }

    function _checkScParam(SignedCredential calldata sc) internal {
        if (sc.vc.nonce <= user2nonce[msg.sender]) {
            revert NonceTooLow();
        }

        if (!(block.number >= sc.vc.epochIssued &&
            block.number <= sc.vc.epochValidUntil)) {
            revert DataExpired();
        }

        if (sc.vc.action != msg.sig) {
            revert InvalidSig();
        }

        user2nonce[msg.sender] = sc.vc.nonce;
    }

    function checkValidatorSignatures(
        bytes32 dataHash,
        bytes calldata signatures
    ) internal view {
        require(
            signatures.length >= (_validatorThreshold * 65),
            "Invalid signature len"
        );
        address[] memory signers = new address[](_validatorThreshold);
        for (uint256 i = 0; i < _validatorThreshold; i++) {
            signers[i] = ECDSA.recover(dataHash, signatures[i * 65 : (i + 1) * 65]);
            requireValidator(signers[i]);
            for (uint256 j = 0; j < i; j++) {
                require(signers[j] != signers[i], "Dupplicate signer");
            }
        }
    }

}