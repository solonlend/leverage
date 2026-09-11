// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SettlementMath} from "../src/libraries/SettlementMath.sol";

/// Differential test: SettlementMath.sol MUST match reference/settlement_golden.py bit-for-bit.
/// Guards the money-out path (standard liquidation seize) — funds-critical.
contract SettlementMathDiffTest is Test {
    function test_liquidationSeize_vs_golden() public {
        string memory json = vm.readFile("test/vectors/settlement.json");
        uint256[] memory repay = vm.parseJsonUintArray(json, ".repay");
        uint256[] memory bonus = vm.parseJsonUintArray(json, ".bonusBps");
        uint256[] memory pfee = vm.parseJsonUintArray(json, ".protocolFeeBps");
        uint256[] memory eSeize = vm.parseJsonUintArray(json, ".expSeizeValue");
        uint256[] memory ePFee = vm.parseJsonUintArray(json, ".expProtocolFee");
        uint256[] memory eLiq = vm.parseJsonUintArray(json, ".expLiquidatorSeize");
        uint256 n = vm.parseJsonUint(json, ".nLiq");
        assertGt(n, 0);
        for (uint256 i = 0; i < n; i++) {
            SettlementMath.Seize memory s =
                SettlementMath.liquidationSeize(repay[i], bonus[i], pfee[i]);
            string memory tag = vm.toString(i);
            assertEq(s.seizeValue, eSeize[i], string.concat("seize @", tag));
            assertEq(s.protocolFee, ePFee[i], string.concat("protocolFee @", tag));
            assertEq(s.liquidatorSeize, eLiq[i], string.concat("liqSeize @", tag));
        }
    }

    /// 标准清算铁律:清算人拿走的 = 还的债 + 净奖励;协议费只从奖励里出,绝不吃到本金(repay)。
    function testFuzz_seize_invariants(uint256 repay, uint256 bonus, uint256 pfee) public pure {
        repay = bound(repay, 0, 1e30);
        bonus = bound(bonus, 0, 3000);
        pfee = bound(pfee, 0, BPS_MAX);
        SettlementMath.Seize memory s = SettlementMath.liquidationSeize(repay, bonus, pfee);
        assertGe(s.seizeValue, repay, "seize < repay (bonus can't be negative)");
        assertEq(s.liquidatorSeize + s.protocolFee, s.seizeValue, "value not conserved");
        // 协议费只吃奖励,绝不吃本金:清算人至少拿回 repay
        assertGe(s.liquidatorSeize, repay, "protocol fee ate into repaid principal");
    }

    uint256 constant BPS_MAX = 10000;
}
