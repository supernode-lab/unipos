// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStakeCore} from "./StakeCore.sol";

/**
 * @title POS Stake Core Contract
 * @notice
 */
contract BeneficiaryCore {
    using SafeERC20 for IERC20;

    struct ShareholderInfo {
        address owner;
        uint256 allowance;
        uint256 grantedAmount;
        uint256 claimedAmount;
        uint256 share;
    }

    IERC20 public immutable token;

    // total user staked amount
    uint256 public totalCollateral;
    // total security deposit amount
    uint256 public totalSecurityDeposit;
    // total required stake amount
    uint256 public requiredCollateral;

    address[] public shareholders;
    mapping(address => ShareholderInfo) public shareholdersInfo;

    address public admin;
    IStakeCore public stakeCore;

    // Events
    event ShareholderAdded(address indexed shareholder, uint256 allowance);
    event SharesSet(address indexed shareholder, uint256 shares);
    event AllowanceSet(address indexed shareholder, uint256 allowance);
    event RewardsWithdrawn(address indexed shareholder, uint256 amount);
    event RewardsCollected(uint256 amount);
    event RewardsDistributed(uint256 totalRewards);

    constructor(IERC20 _token, address _admin, address _stakeCore) {
        require(_admin != address(0), "Admin address can't be zero");
        require(_stakeCore != address(0), "StakeCore address can't be zero");

        token = _token;
        admin = _admin;
        stakeCore = IStakeCore(_stakeCore);
        shareholders.push(_admin);
        shareholdersInfo[_admin] = ShareholderInfo({owner: _admin, allowance: type(uint256).max, grantedAmount: 0, claimedAmount: 0, share: 100});
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    function addShareholder(address _owner, uint256 _allowance) external onlyAdmin {
        require(shareholdersInfo[_owner].owner == address(0), "Shareholder already exists");
        shareholders.push(_owner);
        shareholdersInfo[_owner] = ShareholderInfo({owner: _owner, allowance: _allowance, grantedAmount: 0, claimedAmount: 0, share: 0});
        emit ShareholderAdded(_owner, _allowance);
    }

    function setShares(address[] calldata _owners, uint256[] calldata _shares) external onlyAdmin {
        require(_owners.length == _shares.length, "Owners and shares length must be equal");
        uint256 totalShares;
        for (uint256 i = 0; i < _owners.length; i++) {
            totalShares += _shares[i];
        }
        require(totalShares <= 100, "Total shares must be 100");
        for (uint256 i = 0; i < _owners.length; i++) {
            require(shareholdersInfo[_owners[i]].owner != address(0), "Not a shareholder");
            shareholdersInfo[_owners[i]].share = _shares[i];
            emit SharesSet(_owners[i], _shares[i]);
        }
    }

    function setAllowance(address _shareHolder, uint256 _allowance) external onlyAdmin {
        require(shareholdersInfo[_shareHolder].owner != address(0), "Not a shareholder");
        require(_allowance >= shareholdersInfo[_shareHolder].claimedAmount, "Allowance must be greater than claimed amount");
        shareholdersInfo[_shareHolder].allowance = _allowance;
        emit AllowanceSet(_shareHolder, _allowance);
    }

    /// distrubute rewards to shareholders based on their shares
    function withdrawRewards() external returns(uint256) {
        uint256 claimed = stakeCore.claimBeneficiaryRewards();
        distributeRewards(claimed);
        emit RewardsWithdrawn(msg.sender, claimed);
        return claimed;
    }

    function claimRewards() external {
        ShareholderInfo storage info = shareholdersInfo[msg.sender];
        require(info.owner == msg.sender, "Not a shareholder");
        require(info.grantedAmount > info.claimedAmount, "No rewards");
        token.safeTransfer(msg.sender, info.grantedAmount - info.claimedAmount);
        info.claimedAmount = info.grantedAmount;
        emit RewardsWithdrawn(msg.sender, info.grantedAmount - info.claimedAmount);
    }

    function collect() external onlyAdmin returns(uint256) {
        //  withdraw extra token from this contract
        uint256 balance = token.balanceOf(address(this));
        uint256 unclaimed = 0;
        for (uint256 i = 0; i < shareholders.length; i++) {
            address shareholder = shareholders[i];
            ShareholderInfo storage info = shareholdersInfo[shareholder];
            if (info.grantedAmount > info.claimedAmount) {
                unclaimed += info.grantedAmount - info.claimedAmount;
            }
        }
        require(balance >= unclaimed, "Not enough token");
        token.safeTransfer(admin, balance - unclaimed);
        emit RewardsCollected(balance - unclaimed);
        return balance - unclaimed;
    }

    function getShareholderInfo(address _shareholder) external view returns (ShareholderInfo memory) {
        return shareholdersInfo[_shareholder];
    }

    function getTotalShares() public view returns (uint256 totalShares) {
        for (uint256 i = 0; i < shareholders.length; i++) {
            totalShares += shareholdersInfo[shareholders[i]].share;
        }
    }

    function distributeRewards(uint256 totalRewards) internal {
        for (uint256 i = 0; i < shareholders.length; i++) {
            address shareholder = shareholders[i];
            ShareholderInfo storage info = shareholdersInfo[shareholder];
            if (info.allowance <= info.grantedAmount) continue;

            uint256 maxAllowed = info.allowance - info.grantedAmount;
            uint256 amount = (totalRewards * info.share) / 100 > maxAllowed ? maxAllowed : (totalRewards * info.share) / 100;

            info.grantedAmount += amount;
        }
        emit RewardsDistributed(totalRewards);
    }
}
