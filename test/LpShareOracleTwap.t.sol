// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LpShareOracle} from "../src/LpShareOracle.sol";

contract LpShareOracleTwapTest is Test {
    function test_constructor_alwaysRevertsWithMigrationError() public {
        vm.expectRevert(LpShareOracle.LegacyOracleDeprecatedUseLpShareOracleV4.selector);
        new LpShareOracle(address(0), address(0), address(0), address(0), 0, 0, 0, 0, 0, 0, 0);
    }
}
