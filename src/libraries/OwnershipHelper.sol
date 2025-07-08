// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownership} from "../Types/Structs/Ownership.sol";


library OwnershipHelper {
    error OwnableUnauthorizedAccount(address account);

    error OwnableInvalidOwner(address owner);

    error OwnableInited();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);



    function initOwnership(Ownership storage ownership, address initialOwner) internal {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }

        if (ownership.owner != address(0)) {
            revert OwnableInited();
        }

        ownership.owner = initialOwner;
    }

    function checkOwnership(
        Ownership memory ownership
    ) internal view {
        if (ownership.owner != msg.sender) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
    }

    function transferOwnership(Ownership storage ownership, address newOwner) internal {
        checkOwnership(ownership);
        ownership.pending = newOwner;
    }

    function acceptOwnership(Ownership storage ownership) internal {
        if (ownership.pending != msg.sender) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }

        address newOwner = ownership.pending;
        address oldOwner = ownership.owner;
        ownership.pending = address(0);
        ownership.owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}