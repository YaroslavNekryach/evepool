// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;

import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/EnumerableSetUpgradeable.sol";
import "./interfaces/IDepositContract.sol";
import "./interfaces/IPoolToken.sol";
import "./interfaces/IPool.sol";

contract Pool is OwnableUpgradeable, IPool {
    using SafeMathUpgradeable for uint256;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    event StakeAdded(address staker, uint256 value);
    event StakeCanceled(address staker, uint256 value);
    event StakeDeposited(bytes validator);
    event TokensClaimed(address staker, uint256 value, bytes validator);
    event GovernorChanged(address oldGovernor, address newGovernor);
    event RewardsUpdated(uint256 oldRewards, uint256 newRewards);
    event FeeUpdated(uint256 oldFee, uint256 newFee);

    uint256 constant BEACON_AMOUNT = 32 ether;
    uint256 constant MIN_STAKE = 1 ether / 100;

    IPoolToken private _poolToken;
    IDepositContract private _depositContract;

    uint256 private _poolBalance;
    uint256 private _poolFeeBalance;
    uint256 private _poolRewardsBalance;
    uint256 private _pendingBalance;
    struct Staker {
        address _address;
        uint256 _amount;
    }

    mapping(uint256 => mapping(address => uint256)) private _slots;
    uint256 private _slotCurrent;
    uint256 private _slotDeposited;
    uint256 private _slotPendingBalance;
    mapping(address => uint256) private _stakerBalances;
    mapping(address => EnumerableSetUpgradeable.UintSet) private _stakerSlots;

    bytes[] private _validators;
    address private _governor;

    uint256 private _poolFee; // Pool fee in bips (1/10000)
    uint256 constant FEE_DENOMINATOR = 10000;

    function initialize(
        IPoolToken poolToken,
        IDepositContract depositContract,
        uint256 poolFee
    ) public initializer {
        OwnableUpgradeable.__Ownable_init();
        
        _poolToken = poolToken;
        _depositContract = depositContract;
        _governor = msg.sender;
        _poolFee = poolFee;

        _poolBalance = 0;
        _poolFeeBalance = 0;
        _poolRewardsBalance = 0;
        _pendingBalance = 0;

        _slotCurrent = 1;
        _slotDeposited = 0;
        _slotPendingBalance = 0;
    }

    modifier onlyGovernor() {
        require(_governor == msg.sender, "Caller is not the governor");
        _;
    }

    function pendingBalanceOf(address account) public view returns (uint256) {
        return _stakerBalances[account];
    }

    function pendingBalance() public view returns (uint256) {
        return _pendingBalance;
    }

    function balance() public view returns (uint256) {
        return _poolBalance;
    }

    function feeBalance() public view returns (uint256) {
        return _poolFeeBalance;
    }

    function rewards() public view returns (uint256) {
        return _poolRewardsBalance;
    }

    function fee() public view returns (uint256) {
        return _poolFee;
    }

    function stake() public payable {
        require(msg.value >= MIN_STAKE, "Stake too small");
        _stake(msg.sender, msg.value);
    }

    function _stake(address staker, uint256 value) private {
        if (value == 0)
            return;
        
        // Split large stakes into several slots
        if (_slotPendingBalance.add(value) > BEACON_AMOUNT) {
            uint256 step1 = BEACON_AMOUNT.sub(_slotPendingBalance);
            _stake(staker, step1);
            _stake(staker, value.sub(step1));
            return;
        }

        _pendingBalance = _pendingBalance.add(value);

        _stakerBalances[staker] = _stakerBalances[staker].add(value);

        _slots[_slotCurrent][staker] = _slots[_slotCurrent][staker].add(value);
        _stakerSlots[staker].add(_slotCurrent);

        _slotPendingBalance = _slotPendingBalance.add(value);
        if (_slotPendingBalance == BEACON_AMOUNT) {
            _slotCurrent += 1;
            _slotPendingBalance = 0;
        }

        emit StakeAdded(staker, value);
    }

    function unstakableBalance(address account) public view returns (uint256) {
        return _unstakableBalance(account);
    }

    function claimableBalance(address account) public view returns (uint256) {
        return _claimableBalance(account);
    }

    function _unstakableBalance(address account) private view returns (uint256) {
        return _slots[_slotCurrent][account];
    }

    function _claimableBalance(address account) private view returns (uint256) {
        uint256 redeemable = 0;
        uint256 index = _stakerSlots[account].length();
        while (index > 0) {
            index -= 1;
            uint256 slot = _stakerSlots[account].at(index);
            if (slot <= _slotDeposited) {
                redeemable = redeemable.add(_slots[slot][account]);
            }
        }
        return redeemable;
    }

    function unstake() public {
        uint256 pendingAmount = _unstakableBalance(msg.sender);
        require(pendingAmount > 0, "Nothing to unstake");

        _pendingBalance = _pendingBalance.sub(pendingAmount);
        _stakerBalances[msg.sender] = _stakerBalances[msg.sender].sub(pendingAmount);

        _slots[_slotCurrent][msg.sender] = 0;

        bool success = msg.sender.send(pendingAmount);
        require(success, "Transfer failed");
        emit StakeCanceled(msg.sender, pendingAmount);
    }

    function claim() public {
        uint256 index = _stakerSlots[msg.sender].length();
        uint256 mintAmount = 0;
        while (index > 0) {
            index -= 1;
            uint256 slot = _stakerSlots[msg.sender].at(index);
            if (slot <= _slotDeposited) {
                uint256 slotAmount = _slots[slot][msg.sender];
                mintAmount = mintAmount.add(slotAmount);
                _stakerBalances[msg.sender] = _stakerBalances[msg.sender].sub(slotAmount);
                _slots[slot][msg.sender] = 0;
                _stakerSlots[msg.sender].remove(slot);

                emit TokensClaimed(msg.sender, slotAmount, _validators[slot - 1]); // -1 because slots are 1-based and _validators array is 0-based
            }
        }
        if (mintAmount != 0) {
            _poolToken.mint(msg.sender, mintAmount);
        }
    }

    function deposit(
        bytes calldata pubkey,
        bytes calldata withdrawal_credentials,
        bytes calldata signature,
        bytes32 deposit_data_root
    ) public onlyOwner {
        require(_pendingBalance >= BEACON_AMOUNT, "Not enough balance");

        _pendingBalance = _pendingBalance.sub(BEACON_AMOUNT);
        _poolBalance = _poolBalance.add(BEACON_AMOUNT);

        _slotDeposited += 1;

        emit StakeDeposited(pubkey);

        _depositContract.deposit{value: BEACON_AMOUNT}(
            pubkey,
            withdrawal_credentials,
            signature,
            deposit_data_root
        );

        _validators.push(pubkey);
    }

    function getValidatorCount() public view returns (uint256) {
        return _validators.length;
    }

    function getValidator(uint256 index) public view returns (bytes memory) {
        require(index < _validators.length, "Invalid index");
        return _validators[index];
    }

    function governor() public view returns (address) {
        return _governor;
    }

    function setGovernor(address newGovernor) public virtual onlyGovernor {
        emit GovernorChanged(_governor, newGovernor);
        _governor = newGovernor;
    }

    function setRewards(uint256 rewardsValue)
        external
        override
        onlyGovernor
        returns (bool)
    {
        if (rewardsValue <= _poolRewardsBalance) {
            return false;
        }
        uint256 rewardsDiff = rewardsValue.sub(_poolRewardsBalance).sub(_poolFeeBalance);
        uint256 rewardsFee = _calculateFee(rewardsDiff);

        _poolFeeBalance = _poolFeeBalance.add(rewardsFee);

        uint256 newRewardsBalance = _poolRewardsBalance.add(rewardsDiff).sub(rewardsFee);

        emit RewardsUpdated(_poolRewardsBalance, newRewardsBalance);
        _poolRewardsBalance = newRewardsBalance;
        _updateTokenRatio();
        return true;
    }

    function updateTokenRatio() external onlyOwner {
        _updateTokenRatio();
    }

    function _updateTokenRatio() private {
        _poolToken.setRatio(_poolRewardsBalance.add(_poolBalance), _poolToken.totalSupply());
    }

    function setFee(uint256 feeValue) external override onlyGovernor returns (bool) {
        if (feeValue > FEE_DENOMINATOR) {
            return false;
        }
        emit FeeUpdated(_poolFee, feeValue);
        _poolFee = feeValue;
        return true;
    }

    function _calculateFee(uint256 amount) private view returns (uint256) {
        return (amount * _poolFee) / FEE_DENOMINATOR;
    }
}
