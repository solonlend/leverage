// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IRangeFactory {
    function keeper() external view returns (address);
    function treasury() external view returns (address);
    function globalPause() external view returns (bool);
    function rebalancers(address _rebalancer) external view returns (bool);
    /// @return total performance fee as a fraction of 1e18; @return call caller tip as a fraction of the total fee
    function getFees() external view returns (uint256 total, uint256 call);
}
