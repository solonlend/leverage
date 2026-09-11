// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LpShareOracleV4} from "../src/LpShareOracleV4.sol";

/*
  riskValueInLoan(TDD):把 RISK 数量按 Chainlink 折成 LOAN(USDG)本位。
  RISK feed = 与 LOAN_FEED 不同的那个(构造时判定);fail-closed 同其余读数。
  场景:ETH $2000 / USDG $1,18dp→6dp:1 ETH = 2000e6 USDG。
*/

contract FixedFeed {
    int256 public answer; uint8 public decimals = 8;
    constructor(int256 a) { answer = a; }
    function set(int256 a) external { answer = a; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, 0, block.timestamp, 1);
    }
}

contract OracleRiskValueTest is Test {
    FixedFeed ethFeed; FixedFeed usdgFeed;
    LpShareOracleV4 oracle;

    function setUp() public {
        vm.warp(1_000_000);
        ethFeed = new FixedFeed(2000e8);
        usdgFeed = new FixedFeed(1e8);
        // (feed0=ETH, feed1=USDG, loanFeed=USDG, dec0=18, dec1=6, loanDec=6)
        oracle = new LpShareOracleV4(
            address(ethFeed), address(usdgFeed), address(usdgFeed), 18, 6, 6, 3 hours, 26 hours, 100
        );
    }

    function test_riskValueInLoan_basic() public view {
        // 1 ETH @ $2000, USDG @ $1 → 2000 USDG (6dp)
        assertEq(oracle.riskValueInLoan(1e18), 2000e6, "1 ETH = 2000 USDG");
        // 0.5 ETH → 1000 USDG
        assertEq(oracle.riskValueInLoan(0.5e18), 1000e6);
        assertEq(oracle.riskValueInLoan(0), 0);
    }

    function test_riskValueInLoan_risk_move_within_stable_band() public {
        ethFeed.set(1500e8);
        usdgFeed.set(995e5); // USDG $0.995, still inside the configured 1% band
        assertEq(oracle.riskValueInLoan(1e18), 1507537688, "in-band price still denominates risk value");
    }

    function test_riskValueInLoan_reverts_when_stablecoin_depegs() public {
        usdgFeed.set(98e6);
        vm.expectRevert(
            abi.encodeWithSelector(LpShareOracleV4.StablecoinDepegged.selector, 98e6, 99e6, 101e6)
        );
        oracle.riskValueInLoan(1e18);
    }

    function test_riskValueInLoan_failClosed() public {
        usdgFeed.set(0);
        vm.expectRevert(LpShareOracleV4.NonPositive.selector);
        oracle.riskValueInLoan(1e18);
        usdgFeed.set(1e8);
        ethFeed.set(-1);
        vm.expectRevert(LpShareOracleV4.NonPositive.selector);
        oracle.riskValueInLoan(1e18);
    }
}
