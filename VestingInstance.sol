pragma solidity ^0.5.3;

import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "../common/UsingRegistry.sol";

contract VestingSchedule is Ownable, UsingRegistry {
    // solhint-disable not-rely-on-time

    modifier onlyRevoker() {
      require(msg.sender == _revoker, "sender must be the vesting revoker");
      _;
    }

    modifier onlyBeneficiary() {
      require(msg.sender == _revoker, "sender must be the vesting beneficiary");
      _;
    }

    using SafeMath for uint256;

    event VestingGoldLocked(uint256 amount, uint256 timestamp);
    event VestingGoldUnlocked(uint256 amount, uint256 timestamp);
    event VestingGoldRelocked(uint256 index, uint256 timestamp);
    event VestingGoldWithdrawn(uint256 index, uint256 timestamp);
    event VestingAccountVoterAuthorized(address authorizer, address voter, uint256 timestamp);
    event VestingAccountValidatorAuthorized(address authorizer, address validator, uint256 timestamp);
    event VestingWithdrawn(address beneficiary, uint256 amount, uint256 timestamp);
    event VestingRevoked(address revoker, address refundDestination, uint256 refundDestinationAmount, uint256 timestamp);

    // total that is to be vested
    uint256 public _vestingAmount;

    // amount that is to be vested per period
    uint256 public __vestAmountPerPeriod;

    // number of vesting periods
    uint256 public __vestingPeriods;

    // beneficiary of the amount
    address public _beneficiary;

    // durations in secs. of one period
    uint256 public _vestingPeriodSec;

    // timestamps for start and cliff starting points. Timestamps are expressed in UNIX time, the same units as block.timestamp.
    uint256 public _cliffStartTime;
    uint256 public _vestingStartTime;

    // indicates if the contract is revokable
    bool public _revocable;

    // revoking address and refund destination
    address public _refundDestination;
    address public _revoker;

    // indicates how much of the vested amount has been released for withdrawal (i.e. withdrawn)
    uint256 public _currentlyReleased;

    // indicates if the vesting has been revoked. false by default
    bool public _revoked;

    // the time at which the revocation has taken place
    uint256 public _revokeTime;

    /**
     * @notice A constructor for initialising a new instance of a Vesting Schedule contract
     * @param beneficiary address of the beneficiary to whom vested tokens are transferred
     * @param vestingAmount the amount that is to be vested by the contract
     * @param vestingCliff duration in seconds of the cliff in which tokens will begin to vest
     * @param vestingStartTime the time (as Unix time) at which point vesting starts
     * @param vestingPeriodSec duration in seconds of the period in which the tokens will vest
     * @param vestAmountPerPeriod the vesting amound per period where period is the vestingAmount distributed over the vestingPeriodSec
     * @param revocable whether the vesting is revocable or not
     * @param revoker address of the person revoking the vesting
     * @param refundDestination address of the refund receiver after the vesting is deemed revoked
     * @param vestingContractOwner the owner that of the vesting contract
     */
    constructor (address beneficiary,
                uint256 vestingAmount,
                uint256 vestingCliff,
                uint256 vestingStartTime,
                uint256 vestingPeriodSec,
                uint256 vestAmountPerPeriod,
                bool    revocable,
                address revoker,
                address refundDestination,               
                address vestingContractOwner) public {

        // do some basic checks
        require(vestingAmount > 0, "Amount must be positive");
        require(beneficiary != address(0), "Beneficiary is the zero address");
        require(refundDestination != address(0), "Refund destination is the zero address");
        // solhint-disable-next-line max-line-length
        require(vestingCliff <= vestingPeriodSec, "Vesting cliff is longer than duration");
        // solhint-disable-next-line max-line-length
        require(vestingPeriodSec > 0, "Vesting period is 0 s.");
        // solhint-disable-next-line max-line-length
        require(vestAmountPerPeriod <= vestingAmount, "Vesting amount per period is greater than the total vesting amount");
        // solhint-disable-next-line max-line-length
         require(vestingStartTime.add(vestingCliff) > block.timestamp, "Final time is before current time");

        // transfer the ownership from the factory to the vesting owner
        _transferOwnership(vestingContractOwner);

        //make the vesting instance an account
        getAccounts().setAccount("unique account name", 0x0, getAccounts().getWalletAddress(beneficiary)); // TODO: check unique account name, key and wallet address(that of the beneficiary ???)

        _vestingPeriods =  vestingAmount.div(vestAmountPerPeriod);
        _beneficiary = beneficiary;
        _vestingAmount = vestingAmount;
        _vestAmountPerPeriod = vestAmountPerPeriod;
        _revocable = revocable;
        _vestingPeriodSec = vestingPeriodSec;
        _cliffStartTime = vestingStartTime.add(vestingCliff);
        _vestingStartTime = vestingStartTime;
        _refundDestination = refundDestination;
        _revoker = revoker;
    }

    /**
     * @notice Transfers available released tokens from the vesting back to beneficiary.
     */
    function withdraw() external onlyBeneficiary {
        uint256 releasableAmount = _getReleasableAmount(block.timestamp);

        require(releasableAmount > 0, "No unreleased tokens are due for withdraw");

        _currentlyReleased = _currentlyReleased.add(releasableAmount);

        getGoldToken().safeTransfer(_beneficiary, releasableAmount);

        emit VestingWithdrawn(msg.sender, releasableAmount, block.timestamp);
    }

    /**
     * @notice Allows only the revoker to revoke the vesting. Gold already vested
     * remains in the contract, the rest is returned to the _refundDestination.
     * @param revokeTime the revocation timestamp
     * @dev revokeTime the revocation timestamp. If is less than the current block timestamp, it is set equal
     */
    function revoke(revokeTime) external onlyRevoker {
        require(_revocable, "Revoking is not allowed");
        require(!_revoked, "Vesting already revoked");

        uint256 revokeTimestamp = revokeTime > block.timestamp ? revokeTime : block.timestamp;

        uint256 balance = getGoldToken().balanceOf(address(this));
        uint256 releasableAmount = _getReleasableAmount(revokeTimestamp);
        uint256 refund = balance.sub(releasableAmount);

        _revoked = true;
        _revokeTime = revokeTimestamp;

        getGoldToken().transfer(_refundDestination, refund);

        emit VestingRevoked(msg.sender, _refundDestination, refund, _revokeTime);
    }

    /**
     * @dev Calculates the amount that has already vested but hasn't been withdrawn (released) yet.
     * @param timestamp the timestamp at which the calculate the releasable amount
     */
    function _getReleasableAmount(uint256 timestamp) private view returns (uint256) {
        return _calculateFreeAmount(timestamp).sub(_currentlyReleased);
    }

    /**
     * @dev Calculates the amount that has already vested.
     * @param timestamp the timestamp at which the calculate the already vested amount
     */
    function _calculateFreeAmount(uint256 timestamp) private view returns (uint256) {
        uint256 currentBalance = getGoldToken().balanceOf(address(this));
        uint256 totalBalance = currentBalance.add(_currentlyReleased);

        if (timestamp < _cliffStartTime) {
            return 0;
        } else if (timestamp >= _vestingStartTime.add( _vestingPeriods.mul(_vestingPeriodSec) ) || _revoked) {
            return totalBalance;
        } else {
            uint256 gradient = (timestamp.sub(_vestingStartTime)).div(_vestingPeriodSec);
            return  ( (currentBalance.mul(gradient)).mul(vestAmountPerPeriod) ).div(totalBalance);
        }
    }

    /**
     * @notice A wrapper func for the lock gold method
     * @param value the value to gold to be locked
     * @return True if the transaction succeeds.
     * @dev To be called only by the beneficiary of the vesting
     */
    function lockGold(uint256 value) external onlyBeneficiary returns (bool) {

      // the beneficiary may not lock more than the vesting has currently released
      uint256 unreleasedAmount = _getReleasableAmount(block.timestamp);
      require(unreleasedAmount >= value, "Gold Amount to lock must not be less that the currently releasable amount");

      bool success;
      (success,) = address(getLockedGold()).lock.gas(gasleft()).value(msg.value)();
      emit VestingGoldLocked(msg.value, block.timestamp);
      return success;
    }

    /**
     * @notice A wrapper func for the unlock gold method function
     * @param value the value to gold to be unlocked for the vesting instance
     * @return True if the transaction succeeds.
     * @dev To be called only by the beneficiary of the vesting
     */
    function unlockGold(uint256 value) external onlyBeneficiary returns (bool) {
      bool success;
      (success,) = address(getLockedGold()).unlock.gas(gasleft()).value(msg.value)(value);
      emit VestingGoldUnlocked(msg.value, block.timestamp);
      return success;
    }

    /**
     * @notice A wrapper func for the relock locked gold method function
     * @param index the index of the pending locked gold withdrawal
     * @return True if the transaction succeeds.
     * @dev To be called only by the beneficiary of the vesting.
     */
    function relockLockedGold(uint256 index) external onlyBeneficiary returns (bool) {
      bool success;
      (success,) = address(getLockedGold()).relock.gas(gasleft())(index);
      emit VestingGoldRelocked(index, block.timestamp);
      return success;
    }

    /**
     * @notice A wrapper func for the withdraw locked gold method function
     * @param index the index of the pending locked gold withdrawal
     * @return True if the transaction succeeds.
     * @dev To be called only by the beneficiary of the vesting. The amount shall be withdrawn back by the vesting instance
     */
    function withdrawLockedGold(uint256 index) external onlyBeneficiary returns (bool) {
      bool success;
      (success,) = address(getLockedGold()).withdraw.gas(gasleft())(index);
      emit VestingGoldWithdrawn(index, block.timestamp);
      return success;
    }

    /**
     * @notice A wrapper func for the authorize vote signer account method
     * @param v The recovery id of the incoming ECDSA signature.
     * @param r Output value r of the ECDSA signature.
     * @param s Output value s of the ECDSA signature.
     * @return True if the transaction succeeds.
     * @dev To be called only by the beneficiary of the vesting. The v,r and s signature should be a signed message by the beneficiary being the vesting contract instance address
     */
    function authorizeVoteSigner(uint8 v, bytes32 r, bytes32 s) external onlyBeneficiary returns (bool) {
      bool success;
      (success,) = address(getAccounts()).authorizeVoteSigner.gas(gasleft())(beneficiary, v, r, s);
      emit VestingAccountVoterAuthorized(address(this), beneficiary, block.timestamp);
      return success;
    }

    /**
     * @notice A wrapper func for the authorize validation signer account method
     * @param v The recovery id of the incoming ECDSA signature.
     * @param r Output value r of the ECDSA signature.
     * @param s Output value s of the ECDSA signature.
     * @return True if the transaction succeeds.
     * @dev To be called only by the beneficiary of the vesting. The v,r and s signature should be a signed message by the beneficiary being the vesting contract instance address
     */
    function authorizeValidationSigner(uint8 v, bytes32 r, bytes32 s) external onlyBeneficiary returns (bool) {
      bool success;
      (success,) = address(getAccounts()).authorizeValidationSigner.gas(gasleft())(beneficiary, v, r, s);
      emit VestingAccountValidatorAuthorized(address(this), beneficiary, block.timestamp);
      return success;
    }

}