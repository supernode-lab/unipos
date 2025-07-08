// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


    struct SignedCredential {
        VerifiableCredential vc;
        bytes signature;
    }

    struct VerifiableCredential {
        uint64 nonce;
        uint64 epochIssued;
        uint64 epochValidUntil;
        bytes4 action;
    }



