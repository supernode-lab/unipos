// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseError} from "../interfaces/BaseError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Hash Time-Locked Contract (HTLC) for cross-chain atomic swaps (Native + ERC20)
/// @author you
/// @notice Deploy on both chains. Use the same secretHash (keccak256(preimage)).
contract HTLC is BaseError, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error AlreadyExists();
    error NotFound();
    error AlreadyClaimed();
    error AlreadyRefunded();
    error NotFunded();
    error HashlockMismatch();
    error NotBeforeExpiry(); // for claim
    error NotAfterExpiry();  // for refund
    error NothingToWithdraw();

    struct Swap {
        address sender;       // who locked the funds
        address recipient;    // who can claim with preimage
        address token;        // NATIVE for coin, or ERC20 token address
        uint256 amount;       // actual amount escrowed
        uint64 timelock;     // unix timestamp (seconds)
        bytes32 hashlock;     // keccak256(preimage)
        bool claimed;
        bool refunded;
        bytes32 preimage;     // revealed on claim
    }

    event Locked(
        bytes32 swapId,
        address sender,
        address recipient,
        address token,
        uint256 amount,
        uint64  timelock,
        bytes32 hashlock
    );
    event Claimed(bytes32 swapId, bytes32 preimage);
    event Refunded(bytes32 swapId);


// swapId => Swap
    mapping(bytes32 => Swap) public swaps;

// sender => incrementing nonce to mix into swapId
    mapping(address => uint256) private nonces;

/// @notice Lock native (token==address(0)) or ERC20 with a hashlock+timelock (pulls tokens via transferFrom)
/// @param token ERC20 token address
/// @param amount intended amount (actual credited = balance diff)
/// @return swapId deterministic ID including sender nonce
    function lockToken(
        address token,
        uint256 amount,
        address recipient,
        bytes32 hashlock,
        uint64 timelock
    ) external payable nonReentrant returns (bytes32 swapId) {
        if (recipient == address(0)) revert InvalidParameter("recipient");
        if (hashlock == bytes32(0)) revert InvalidParameter("hashlock");
        if (amount == 0) revert  InvalidParameter("amount");
        if (timelock <= block.timestamp) revert InvalidParameter("timelock");

        uint256 nonce = ++nonces[msg.sender];
        swapId = keccak256(abi.encodePacked(block.chainid, msg.sender, recipient, token, amount, timelock, hashlock, nonce));
        if (swaps[swapId].sender != address(0)) revert AlreadyExists();

        if (token == address(0)) {
            if (msg.value != amount) revert InvalidParameter("msg.value");
        } else {
            if (msg.value != 0) revert InvalidParameter("msg.value");
            uint256 beforeBal = IERC20(token).balanceOf(address(this));
            // pull funds (requires prior approve)
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            uint256 afterBal = IERC20(token).balanceOf(address(this));
            uint256 credited = afterBal - beforeBal; // supports fee-on-transfer tokens

            if (credited == 0) revert NotFunded();
            amount = credited;
        }


        swaps[swapId] = Swap({
            sender: msg.sender,
            recipient: recipient,
            token: token,
            amount: amount,
            timelock: timelock,
            hashlock: hashlock,
            claimed: false,
            refunded: false,
            preimage: 0x0
        });

        emit Locked(swapId, msg.sender, recipient, token, amount, timelock, hashlock);
    }

/// @notice Claim funds by providing the correct preimage before timelock
    function claim(bytes32 swapId, bytes32 preimage) external nonReentrant {
        Swap storage s = swaps[swapId];
        if (s.sender == address(0)) revert NotFound();
        if (s.claimed) revert AlreadyClaimed();
        if (s.refunded) revert AlreadyRefunded();
        if (msg.sender != s.recipient) revert UnauthorizedCaller(msg.sender);
        if (block.timestamp > s.timelock) revert NotBeforeExpiry();
        if (keccak256(abi.encodePacked(preimage)) != s.hashlock) revert HashlockMismatch();

        s.claimed = true;
        s.preimage = preimage;

        _payout(s.recipient, s.token, s.amount);
        emit Claimed(swapId, preimage);
    }

/// @notice Refund to sender after timelock passes if not claimed
    function refund(bytes32 swapId) external nonReentrant {
        Swap storage s = swaps[swapId];
        if (s.sender == address(0)) revert NotFound();
        if (s.refunded) revert AlreadyRefunded();
        if (s.claimed) revert AlreadyClaimed();
        if (msg.sender != s.sender) revert UnauthorizedCaller(msg.sender);
        if (block.timestamp <= s.timelock) revert NotAfterExpiry();

        s.refunded = true;

        _payout(s.sender, s.token, s.amount);
        emit Refunded(swapId);
    }

/// @notice View helper
    function getSwap(bytes32 swapId) external view returns (Swap memory) {
        if (swaps[swapId].sender == address(0)) revert NotFound();
        return swaps[swapId];
    }

// ======= internal payout =======
    function _payout(address to, address token, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NothingToWithdraw();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}

