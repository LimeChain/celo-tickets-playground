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

    event VestingWithdrawn(address beneficiary, uint256 amount, uint256 timestamp);
    event VestingRevoked(address revoker, address refundDestination, uint256 refundDestinationAmount, uint256 timestamp);

    // amount that is to be vested
    uint256 private _vestingAmount;

    // beneficiary of the amount
    address private _beneficiary;

    // durations in secs. of the entire vesting
    uint256 private _duration;

    // timestamps for start and cliff starting points. Timestamps are expressed in UNIX time, the same units as block.timestamp.
    uint256 private _cliff;
    uint256 private _start;

    // indicates if the contract is revokable
    bool private _revocable;

    // revoking address and destination
    address private _refundDestination;
    address private _revoker;

    // indicates how much of the vested amount has been released for withdrawal
    uint256 private _released;

    // indicates if the vesting has been revoked. false by default
    bool _revoked;

    // the time at which the revocation has taken place
    uint256 _revokeTime;

    /**
     * @notice A constructor for initialising a new instance of a Vesting Schedule contract
     * @param beneficiary address of the beneficiary to whom vested tokens are transferred
     * @param vestingAmount the amount that is to be vested by the contract
     * @param vestingCliff duration in seconds of the cliff in which tokens will begin to vest
     * @param vestingStartTime the time (as Unix time) at which point vesting starts
     * @param vestingPeriodSec duration in seconds of the period in which the tokens will vest
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
                bool    revocable,
                address revoker,
                address refundDestination,               
                address vestingContractOwner) public {

        // do some basic checks
        require(vestingAmount > 0, "Amount must be positive");
        require(beneficiary != address(0), "Beneficiary is the zero address");
        require(revoker != address(0), "Revoker is the zero address");
        require(refundDestination != address(0), "Refund destination is the zero address");
        // solhint-disable-next-line max-line-length
        require(vestingCliff <= vestingPeriodSec, "Vesting Cliff is longer than duration");
        // solhint-disable-next-line max-line-length
        require(vestingPeriodSec > 0, "Vesting duration is 0");
        // solhint-disable-next-line max-line-length
         require(vestingStartTime.add(vestingCliff) > block.timestamp, "Final time is before current time");

        _transferOwnership(vestingContractOwner);

        _beneficiary = beneficiary;
        _vestingAmount = vestingAmount;
        _revocable = revocable;
        _duration = vestingPeriodSec;
        _cliff = vestingStartTime.add(vestingCliff);
        _start = vestingStartTime;
        _refundDestination = refundDestination;
        _revoker = revoker;
    }

    /**
     * @return the beneficiary of the tokens.
     */
    function beneficiary() external view returns (address) {
        return _beneficiary;
    }

    /**
     * @return the amount to be vested.
     */
    function vestingAmount() external view returns (uint256) {
        return _vestingAmount;
    }

    /**
     * @return the cliff time of the token vesting.
     */
    function cliff() external view returns (uint256) {
        return _cliff;
    }

    /**
     * @return the start time of the token vesting.
     */
    function start() external view returns (uint256) {
        return _start;
    }

    /**
     * @return the duration of the token vesting.
     */
    function duration() external view returns (uint256) {
        return _duration;
    }

    /**
     * @return true if the vesting is revocable.
     */
    function revocable() external view returns (bool) {
        return _revocable;
    }

    /**
     * @return the cummulative amount of tokens released.
     */
    function released() external view returns (uint256) {
        return _released;
    }

    /**
     * @return true if the vesting is revoked.
     */
    function revoked(address token) external view returns (bool) {
        return _revoked;
    }

    /**
     * @return the timestamp of the revocation.
     */
    function revokeTime(address token) external view returns (bool) {
        return _revokeTime;
    }

    /**
     * @notice Transfers available released tokens from the vesting back to beneficiary.
     */
    function withdraw() external onlyBeneficiary {
        uint256 unreleased = _releasableAmount(block.timestamp);

        require(unreleased > 0, "No unreleased tokens are due for withdraw");

        _released = _released.add(unreleased);

        token.safeTransfer(_beneficiary, unreleased);

        emit VestingWithdrawn(msg.sender, unreleased, block.timestamp);
    }

    /**
     * @notice Allows only the revoker to revoke the vesting. Tokens already vested
     * remain in the contract, the rest are returned to the _refundDestination.
     * @param revokeTime the revocation timestamp
     * @dev revokeTime the revocation timestamp. If is less than the current block timestamp, it is set equal
     */
    function revoke(revokeTime) external onlyRevoker {
        require(_revocable, "Revoking is not allowed");
        require(!_revoked, "Vesting already revoked");

        uint256 revokeTimestamp = revokeTime > block.timestamp ? revokeTime : block.timestamp;

        uint256 balance = getGoldToken().balanceOf(address(this));
        uint256 unreleased = _releasableAmount(revokeTimestamp);
        uint256 refund = balance.sub(unreleased);

        _revoked = true;
        _revokeTime = revokeTimestamp;

        getGoldToken().transfer(_refundDestination, refund);

        emit VestingRevoked(msg.sender, _refundDestination, refund, _revokeTime);
    }

    /**
     * @dev Calculates the amount that has already vested but hasn't been withdrawn (released) yet.
     * @param timestamp the timestamp at which the calculate the releasable amount
     */
    function _releasableAmount(uint256 timestamp) private view returns (uint256) {
        return _vestedAmount(timestamp).sub(_released);
    }

    /**
     * @dev Calculates the amount that has already vested.
     * @param timestamp the timestamp at which the calculate the already vested amount
     */
    function _vestedAmount(uint256 timestamp) private view returns (uint256) {
        uint256 currentBalance = getGoldToken().balanceOf(address(this));
        uint256 totalBalance = currentBalance.add(_released);

        if (timestamp < _cliff) {
            return 0;
        } else if (timestamp >= _start.add(_duration) || _revoked) {
            return totalBalance;
        } else {
            return totalBalance.mul(timestamp.sub(_start)).div(_duration);
        }
    }
}