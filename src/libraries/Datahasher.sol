// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VerifiableCredential} from "../Types/Structs/Credentials.sol";


library DataHasher {
    function gethashAt(
        address sender,
        bytes memory params,
        VerifiableCredential memory vc
    ) internal view returns (bytes32){
        return keccak256(
            abi.encode(
                block.chainid,
                sender,
                params,
                vc
            )
        );
    }
}