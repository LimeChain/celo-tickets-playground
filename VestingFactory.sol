pragma solidity ^0.5.3;

import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

import "../common/Initializable.sol";
import "../common/UsingRegistry.sol";
import "./VestingSchedule.sol";

// Revision 1
contract VestingFactory is ReentrancyGuard, Initializable, UsingRegistry {

    // mapping between beneficiary addresses and associated vesting contracts (schedules)
    mapping(address => VestingSchedule) private vestingSchedules;

    function initialize(address registryAddress) external initializer {
      _transferOwnership(msg.sender);
      setRegistry(registryAddress);
    }

    /**
     * @notice Factory function for creating a new vesting contract instance
     * @param beneficiary address of the beneficiary to whom vested tokens are transferred
     * @param vestingAmount the amount that is to be vested by the contract
     * @param vestingCliff duration in seconds of the cliff in which tokens will begin to vest
     * @param vestingStartTime the time (as Unix time) at which point vesting starts
     * @param vestingPeriodSec duration in seconds of the period in which the tokens will vest
     * @param revocable whether the vesting is revocable or not
     * @param revoker address of the person revoking the vesting
     * @param refundDestination address of the refund receiver after the vesting is deemed revoked
     * @dev  The function is to be called by the sponsor (the account transferring money to the newly created vesting instance)
     */
    function createVestingInstance(address beneficiary,
                          uint256 vestingAmount,
                          uint256 vestingCliff,
                          uint256 vestingStartTime,  
                          uint256 vestingPeriodSec, 
                          bool    revokable,
                          address revoker,
                          address refundDestination) public {

        // creation of a new contract
        vestingSchedules[beneficiary] = new VestingSchedule(beneficiary, vestingAmount, vestingCliff, vestingStartTime, vestingPeriodSec, revokable, revoker, refundDestination, msg.sender);

        // msg.sender to fund the vesting instance
        getGoldToken().transfer(vestingSchedules[beneficiary], vestingAmount);
    }

   /**
   * @return The vesting schedule where the address is a beneficiary
   */
    function getVestingContractForBeneficiary(address beneficiary) external view returns (VestingSchedule memory) {
        require(beneficiary != address(0), "beneficiary cannot be the zero address");
        return vestingSchedules[beneficiary];
    }
}