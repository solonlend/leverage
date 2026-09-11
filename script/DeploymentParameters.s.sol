// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";

/// Required deployment inputs. Rates are APR endpoints in bps, never slopes.
abstract contract DeploymentParameters is Script {
    struct Parameters {
        uint256 lltv;
        uint16 liqBonusBps;
        uint16 protocolFeeBps;
        uint16 utilizationA;
        uint16 borrowingRateA;
        uint16 utilizationB;
        uint16 borrowingRateB;
        uint16 maxBorrowingRate;
    }

    function _readParameters() internal view returns (Parameters memory p) {
        p.lltv = vm.envUint("LLTV"); // WAD: 77% = 770000000000000000
        p.liqBonusBps = _requiredUint16("LIQ_BONUS_BPS");
        p.protocolFeeBps = _requiredUint16("PROTOCOL_FEE_BPS");
        p.utilizationA = _requiredUint16("UTILIZATION_A_BPS");
        p.borrowingRateA = _requiredUint16("BORROWING_RATE_A_BPS");
        p.utilizationB = _requiredUint16("UTILIZATION_B_BPS");
        p.borrowingRateB = _requiredUint16("BORROWING_RATE_B_BPS");
        p.maxBorrowingRate = _requiredUint16("MAX_BORROWING_RATE_BPS");
        require(p.lltv > 0 && p.lltv <= 1e18, "BAD_LLTV");
        require(p.liqBonusBps <= 2000 && p.protocolFeeBps <= 5000, "BAD_FEES");
        require(p.utilizationA < p.utilizationB && p.utilizationB < 10000, "BAD_UTILIZATION");
        require(p.borrowingRateA <= p.borrowingRateB && p.borrowingRateB <= p.maxBorrowingRate, "BAD_RATE_ENDPOINTS");
    }

    function _requiredUint16(string memory name) private view returns (uint16) {
        uint256 value = vm.envUint(name);
        require(value <= type(uint16).max, string.concat(name, " exceeds uint16"));
        return uint16(value);
    }

    function _configureRate(LendingPool lending, uint256 reserveId, Parameters memory p) internal {
        lending.setBorrowingRateConfig(
            reserveId, p.utilizationA, p.borrowingRateA, p.utilizationB, p.borrowingRateB, p.maxBorrowingRate
        );
    }
}
