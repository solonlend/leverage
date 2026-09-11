// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployRhDual} from "../script/DeployRhDual.s.sol";

import {DeployRhV3} from "../script/DeployRhV3.s.sol";
import {DeploySepoliaDual} from "../script/DeploySepoliaDual.s.sol";
import {DeploymentParameters} from "../script/DeploymentParameters.s.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {AddressId} from "../src/lending/libraries/helpers/AddressId.sol";
import {AddressRegistry} from "../src/lending/address-registry/AddressRegistry.sol";
import {MockERC20} from "../script/testnet/TestnetMocks.sol";
import {DataTypes} from "../src/lending/libraries/types/DataTypes.sol";

contract DeploymentParametersHarness is DeploymentParameters {
    function read() external view returns (Parameters memory) { return _readParameters(); }
    function configure(LendingPool lending, uint256 id) external { _configureRate(lending, id, _readParameters()); }
}

contract VerifyDeploymentParametersTest is Test {
    DeploymentParametersHarness private harness;
    string[8] private keys = ["LLTV", "LIQ_BONUS_BPS", "PROTOCOL_FEE_BPS", "UTILIZATION_A_BPS",
        "BORROWING_RATE_A_BPS", "UTILIZATION_B_BPS", "BORROWING_RATE_B_BPS", "MAX_BORROWING_RATE_BPS"];

    function setUp() public {
        harness = new DeploymentParametersHarness();
        _setParameters();
        vm.setEnv("RISK_MAX_STALENESS_SECONDS", "10800");
        vm.setEnv("STABLE_MAX_STALENESS_SECONDS", "93600");
        vm.setEnv("STABLE_DEPEG_BPS", "100");
    }

    function _setParameters() private {
        string[8] memory values = ["770000000000000000", "700", "900", "8000", "300", "9000", "400", "20400"];
        for (uint256 i; i < keys.length; ++i) vm.setEnv(keys[i], values[i]);
    }

    function testMissingLltvFailsBeforeSeedPreflight() public {
        _setParameters();
        vm.setEnv("RISK_MAX_STALENESS_SECONDS", "10800");
        vm.setEnv("STABLE_MAX_STALENESS_SECONDS", "93600");
        vm.setEnv("STABLE_DEPEG_BPS", "100");
        vm.setEnv("SEED_USDG", "0");
        vm.setEnv("LLTV", "");
        (bool readOk, bytes memory missingError) = address(vm).call(abi.encodeWithSignature("envUint(string)", "LLTV"));
        assertFalse(readOk);
        DeployRhDual script = new DeployRhDual();
        vm.expectRevert(missingError);
        script.run();
    }

    function testEachRequiredInputRejectsMissingOrEmptyValue() public {
        _setParameters();
        for (uint256 i; i < keys.length; ++i) {
            _setParameters();
            vm.setEnv(keys[i], "");
            vm.expectRevert();
            harness.read();
        }
    }

    function testRequiredValuesArePreserved() public {
        _setParameters();
        DeploymentParameters.Parameters memory p = harness.read();
        assertEq(p.lltv, 0.77e18);
        assertEq(p.liqBonusBps, 700);
        assertEq(p.protocolFeeBps, 900);
        assertEq(p.utilizationA, 8000);
        assertEq(p.borrowingRateA, 300);
        assertEq(p.utilizationB, 9000);
        assertEq(p.borrowingRateB, 400);
        assertEq(p.maxBorrowingRate, 20400);
    }

    function testUint16OverflowCannotSilentlyTruncate() public {
        _setParameters();
        for (uint256 i = 1; i < keys.length; ++i) {
            _setParameters();
            vm.setEnv(keys[i], "65536");
            vm.expectRevert(bytes(string.concat(keys[i], " exceeds uint16")));
            harness.read();
        }
    }

    function testZeroFeesAndFlatZeroRatesAreAllowed() public {
        _setParameters();
        vm.setEnv("LIQ_BONUS_BPS", "0");
        vm.setEnv("PROTOCOL_FEE_BPS", "0");
        vm.setEnv("BORROWING_RATE_A_BPS", "0");
        vm.setEnv("BORROWING_RATE_B_BPS", "0");
        vm.setEnv("MAX_BORROWING_RATE_BPS", "0");
        DeploymentParameters.Parameters memory p = harness.read();
        assertEq(p.liqBonusBps + p.protocolFeeBps + p.borrowingRateA + p.borrowingRateB + p.maxBorrowingRate, 0);
    }

    function testRejectInvalidLltv() public {
        _setParameters();
        vm.setEnv("LLTV", "0");
        vm.expectRevert("BAD_LLTV"); harness.read();
        vm.setEnv("LLTV", "1000000000000000001");
        vm.expectRevert("BAD_LLTV"); harness.read();
    }

    function testRejectInvalidFees() public {
        _setParameters();
        vm.setEnv("LIQ_BONUS_BPS", "2001");
        vm.expectRevert("BAD_FEES"); harness.read();
        _setParameters();
        vm.setEnv("PROTOCOL_FEE_BPS", "5001");
        vm.expectRevert("BAD_FEES"); harness.read();
    }

    function testRejectUnorderedOrFullUtilizationKinks() public {
        _setParameters();
        vm.setEnv("UTILIZATION_A_BPS", "9000");
        vm.expectRevert("BAD_UTILIZATION"); harness.read();
        _setParameters();
        vm.setEnv("UTILIZATION_B_BPS", "10000");
        vm.expectRevert("BAD_UTILIZATION"); harness.read();
    }

    function testRejectDescendingRateEndpoints() public {
        _setParameters();
        vm.setEnv("BORROWING_RATE_A_BPS", "401");
        vm.expectRevert("BAD_RATE_ENDPOINTS"); harness.read();
        _setParameters();
        vm.setEnv("MAX_BORROWING_RATE_BPS", "399");
        vm.expectRevert("BAD_RATE_ENDPOINTS"); harness.read();
    }

    function testAllEntrypointsRequireFinalRateBeforeBroadcast() public {
        _setParameters();
        vm.setEnv("MAX_BORROWING_RATE_BPS", "");
        (, bytes memory missingError) = address(vm).call(abi.encodeWithSignature("envUint(string)", "MAX_BORROWING_RATE_BPS"));
        DeployRhDual dual = new DeployRhDual();
        DeployRhV3 single = new DeployRhV3();
        DeploySepoliaDual sepolia = new DeploySepoliaDual();
        vm.expectRevert(missingError); dual.run();
        vm.expectRevert(missingError); single.run();
        vm.expectRevert(missingError); sepolia.run();
    }

    function testDualEntrypointsRequireEverySoftLaunchLimitBeforeBroadcast() public {
        _setParameters();
        string[4] memory limitKeys = ["RISK_RESERVE_CAPACITY", "LOAN_RESERVE_CAPACITY", "RISK_CREDIT", "LOAN_CREDIT"];
        DeployRhDual dual = new DeployRhDual();
        DeploySepoliaDual sepolia = new DeploySepoliaDual();
        for (uint256 i; i < limitKeys.length; ++i) {
            vm.setEnv("RISK_RESERVE_CAPACITY", "500000000000000000");
            vm.setEnv("LOAN_RESERVE_CAPACITY", "1000000000");
            vm.setEnv("RISK_CREDIT", "400000000000000000");
            vm.setEnv("LOAN_CREDIT", "800000000");
            vm.setEnv(limitKeys[i], "");
            (, bytes memory missingError) = address(vm).call(abi.encodeWithSignature("envUint(string)", limitKeys[i]));
            vm.expectRevert(missingError); dual.run();
            vm.expectRevert(missingError); sepolia.run();
        }
    }

    function testDualCapacityBelowSeedFailsBeforeBroadcast() public {
        _setParameters();
        vm.setEnv("RISK_RESERVE_CAPACITY", "500000000000000000");
        vm.setEnv("LOAN_RESERVE_CAPACITY", "999999999");
        vm.setEnv("RISK_CREDIT", "400000000000000000");
        vm.setEnv("LOAN_CREDIT", "800000000");
        vm.setEnv("SEED_USDG", "1000000000");
        vm.setEnv("SEED_WETH", "500000000000000000");
        DeployRhDual dual = new DeployRhDual();
        DeploySepoliaDual sepolia = new DeploySepoliaDual();
        vm.expectRevert("LOAN_RESERVE_CAPACITY below seed"); dual.run();
        vm.expectRevert("LOAN_RESERVE_CAPACITY below seed"); sepolia.run();
        vm.setEnv("LOAN_RESERVE_CAPACITY", "1000000000");
        vm.setEnv("RISK_RESERVE_CAPACITY", "499999999999999999");
        vm.expectRevert("RISK_RESERVE_CAPACITY below seed"); dual.run();
        vm.expectRevert("RISK_RESERVE_CAPACITY below seed"); sepolia.run();
    }

    function testDualSeedMinimumFailsBelowFloor() public {
        _setParameters();
        // Below the 2026-09-07 lowered dual floor (200 USDG / 0.05 WETH).
        vm.setEnv("RISK_RESERVE_CAPACITY", "50000000000000000");
        vm.setEnv("LOAN_RESERVE_CAPACITY", "200000000");
        vm.setEnv("RISK_CREDIT", "40000000000000000");
        vm.setEnv("LOAN_CREDIT", "160000000");
        DeployRhDual dual = new DeployRhDual();
        vm.setEnv("SEED_USDG", "199999999");
        vm.setEnv("SEED_WETH", "50000000000000000");
        vm.expectRevert("SEED_USDG below deployment minimum"); dual.run();
        vm.setEnv("SEED_USDG", "200000000");
        vm.setEnv("SEED_WETH", "49999999999999999");
        vm.expectRevert("SEED_WETH below deployment minimum"); dual.run();
    }

    function testDualScaledSeedAtFloorPassesValidation() public {
        _setParameters();
        // The scaled first-wave sizing: seed == capacity == 200 USDG / 0.05 WETH, credit 80%.
        vm.setEnv("RISK_RESERVE_CAPACITY", "50000000000000000");
        vm.setEnv("LOAN_RESERVE_CAPACITY", "200000000");
        vm.setEnv("RISK_CREDIT", "40000000000000000");
        vm.setEnv("LOAN_CREDIT", "160000000");
        vm.setEnv("SEED_USDG", "200000000");
        vm.setEnv("SEED_WETH", "50000000000000000");
        DeployRhDual dual = new DeployRhDual();
        // Balance guard, not the seed floor, is the next gate — prove the floor no longer reverts.
        address usdg = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
        vm.mockCall(usdg, abi.encodeWithSignature("balanceOf(address)", address(this)), abi.encode(uint256(0)));
        vm.expectRevert("insufficient USDG for mandatory seed"); dual.run();
    }

    function testSingleSeedMinimumFailsBeforeBroadcast() public {
        _setParameters();
        DeployRhV3 single = new DeployRhV3();
        vm.setEnv("SEED_USDG", "999999999");
        vm.expectRevert("SEED_USDG below deployment minimum"); single.run();
    }

    function testSingleInsufficientSeedBalanceFailsBeforeBroadcast() public {
        _setParameters();
        DeployRhV3 single = new DeployRhV3();
        vm.setEnv("SEED_USDG", "1000000000");
        address usdg = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
        vm.mockCall(usdg, abi.encodeWithSignature("balanceOf(address)", address(this)), abi.encode(uint256(999999999)));
        vm.expectRevert("insufficient USDG for mandatory seed"); single.run();
    }

    function testExplicitRateConfigurationOverridesBothReserveDefaults() public {
        _setParameters();
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        MockERC20 usdg = new MockERC20("USDG", "USDG", 6);
        AddressRegistry registry = new AddressRegistry(address(weth));
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, address(this));
        LendingPool lending = new LendingPool(address(registry), address(weth));
        lending.initReserve(address(usdg));
        lending.initReserve(address(weth));
        lending.transferOwnership(address(harness));
        for (uint256 id = 1; id <= 2; ++id) {
            harness.configure(lending, id);
            (,,,,,,, DataTypes.InterestRateConfig memory r,,,,) = lending.reserves(id);
            assertEq(r.utilizationA, 0.8e18);
            assertEq(r.borrowingRateA, 0.03e18);
            assertEq(r.utilizationB, 0.9e18);
            assertEq(r.borrowingRateB, 0.04e18);
            assertEq(r.maxBorrowingRate, 2.04e18);
        }
    }
}
