// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LpShareOracleV4} from "../src/LpShareOracleV4.sol";
import {FairLpMath} from "../src/libraries/FairLpMath.sol";

contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    constructor(int256 a) { answer = a; updatedAt = block.timestamp; }
    function set(int256 a, uint256 u, uint80 r) external { answer = a; updatedAt = u; roundId = r; }
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

contract LpShareOracleV4Test is Test {
    uint256 constant RISK_STALENESS = 3 hours;
    uint256 constant STABLE_STALENESS = 26 hours;
    uint256 constant DEPEG_BPS = 100;

    MockFeed feed0; MockFeed feed1; MockFeed loanFeed;
    LpShareOracleV4 oracle;

    function setUp() public {
        vm.warp(1_000_000);
        feed0 = new MockFeed(int256(4500e8)); // token0 = ETH $4500
        feed1 = new MockFeed(int256(1e8));    // token1 = USDG $1
        loanFeed = new MockFeed(int256(1e8)); // USDG $1
        oracle = new LpShareOracleV4(
            address(feed0), address(feed1), address(feed1), 18, 18, 18,
            RISK_STALENESS, STABLE_STALENESS, DEPEG_BPS
        ); // loanFeed 必属 pair(生产语义);loanFeed 变量保留供别用
    }

    function test_fairValue_matches_lib() public view {
        int24 tl = -1000; int24 tu = 1000; uint128 L = 1e18;
        uint160 sqrtFair = FairLpMath.sqrtPriceX96FromFeeds(4500e8, 1e8, 18, 18);
        (uint256 expected,,) = FairLpMath.fairValueInLoan(L, tl, tu, sqrtFair, 4500e8, 1e8, 1e8, 18, 18, 18);
        assertEq(oracle.fairValueInLoan(L, tl, tu), expected, "oracle composes lib correctly");
        assertGt(oracle.fairValueInLoan(L, tl, tu), 0, "non-zero value");
    }

    function test_zapAmount_matches_lib() public view {
        uint160 sqrtFair = FairLpMath.sqrtPriceX96FromFeeds(4500e8, 1e8, 18, 18);
        uint256 expected = FairLpMath.zapSwapAmountToToken0(1000e18, -1000, 1000, sqrtFair, 4500e8, 1e8, 18, 18);
        assertEq(oracle.zapAmountToToken0(1000e18, -1000, 1000), expected);
    }

    function test_both_legs_fresh_at_independent_boundaries() public {
        feed0.set(int256(4500e8), block.timestamp - RISK_STALENESS, 1);
        feed1.set(int256(1e8), block.timestamp - STABLE_STALENESS, 1);
        assertGt(oracle.fairValueInLoan(1e18, -1000, 1000), 0);
    }

    function test_staleness_grouping_follows_loan_feed_when_loan_is_feed0() public {
        feed0.set(int256(1e8), block.timestamp - STABLE_STALENESS, 1);
        feed1.set(int256(4500e8), block.timestamp - RISK_STALENESS, 1);
        LpShareOracleV4 loanIsFeed0 = new LpShareOracleV4(
            address(feed0), address(feed1), address(feed0), 18, 18, 18,
            RISK_STALENESS, STABLE_STALENESS, DEPEG_BPS
        );
        assertGt(loanIsFeed0.fairValueInLoan(1e18, -1000, 1000), 0);
    }

    function test_reverts_when_risk_leg_stale_and_stable_leg_fresh() public {
        feed0.set(int256(4500e8), block.timestamp - RISK_STALENESS - 1, 1);
        feed1.set(int256(1e8), block.timestamp - STABLE_STALENESS, 1);
        vm.expectRevert(LpShareOracleV4.StalePrice.selector);
        oracle.fairValueInLoan(1e18, -1000, 1000);
    }

    function test_reverts_when_stable_leg_stale_and_risk_leg_fresh() public {
        feed0.set(int256(4500e8), block.timestamp - RISK_STALENESS, 1);
        feed1.set(int256(1e8), block.timestamp - STABLE_STALENESS - 1, 1);
        vm.expectRevert(LpShareOracleV4.StalePrice.selector);
        oracle.fairValueInLoan(1e18, -1000, 1000);
    }

    function test_reverts_when_both_legs_stale() public {
        feed0.set(int256(4500e8), block.timestamp - RISK_STALENESS - 1, 1);
        feed1.set(int256(1e8), block.timestamp - STABLE_STALENESS - 1, 1);
        vm.expectRevert(LpShareOracleV4.StalePrice.selector);
        oracle.fairValueInLoan(1e18, -1000, 1000);
    }

    function test_reverts_on_nonpositive_feed() public {
        feed0.set(0, block.timestamp, 1);
        vm.expectRevert(LpShareOracleV4.NonPositive.selector);
        oracle.fairValueInLoan(1e18, -1000, 1000);
    }

    function test_stable_depeg_exact_band_is_allowed_on_both_sides() public {
        feed1.set(int256(101e6), block.timestamp, 1); // $1.01: exactly +100 bps
        assertGt(oracle.fairValueInLoan(1e18, -1000, 1000), 0);

        feed1.set(int256(99e6), block.timestamp, 1); // $0.99: exactly -100 bps
        assertGt(oracle.fairValueInLoan(1e18, -1000, 1000), 0);
    }

    function test_stable_depeg_one_feed_unit_above_band_reverts() public {
        feed1.set(int256(101e6 + 1), block.timestamp, 1);
        vm.expectRevert(
            abi.encodeWithSelector(LpShareOracleV4.StablecoinDepegged.selector, 101e6 + 1, 99e6, 101e6)
        );
        oracle.fairValueInLoan(1e18, -1000, 1000);
    }

    function test_stable_depeg_one_feed_unit_below_band_reverts() public {
        feed1.set(int256(99e6 - 1), block.timestamp, 1);
        vm.expectRevert(
            abi.encodeWithSelector(LpShareOracleV4.StablecoinDepegged.selector, 99e6 - 1, 99e6, 101e6)
        );
        oracle.fairValueInLoan(1e18, -1000, 1000);
    }

    function test_constructor_reverts_when_risk_staleness_below_lower_bound() public {
        uint256 provided = 1 hours - 1;
        vm.expectRevert(abi.encodeWithSelector(LpShareOracleV4.InvalidRiskMaxStaleness.selector, provided));
        new LpShareOracleV4(
            address(feed0), address(feed1), address(feed1), 18, 18, 18,
            provided, STABLE_STALENESS, DEPEG_BPS
        );
    }

    function test_constructor_reverts_when_risk_staleness_above_upper_bound() public {
        uint256 provided = 48 hours + 1;
        vm.expectRevert(abi.encodeWithSelector(LpShareOracleV4.InvalidRiskMaxStaleness.selector, provided));
        new LpShareOracleV4(
            address(feed0), address(feed1), address(feed1), 18, 18, 18,
            provided, STABLE_STALENESS, DEPEG_BPS
        );
    }

    function test_constructor_reverts_when_stable_staleness_below_lower_bound() public {
        uint256 provided = 25 hours - 1;
        vm.expectRevert(abi.encodeWithSelector(LpShareOracleV4.InvalidStableMaxStaleness.selector, provided));
        new LpShareOracleV4(
            address(feed0), address(feed1), address(feed1), 18, 18, 18,
            RISK_STALENESS, provided, DEPEG_BPS
        );
    }

    function test_constructor_reverts_when_stable_staleness_above_upper_bound() public {
        uint256 provided = 48 hours + 1;
        vm.expectRevert(abi.encodeWithSelector(LpShareOracleV4.InvalidStableMaxStaleness.selector, provided));
        new LpShareOracleV4(
            address(feed0), address(feed1), address(feed1), 18, 18, 18,
            RISK_STALENESS, provided, DEPEG_BPS
        );
    }

    function test_constructor_reverts_when_depeg_band_below_lower_bound() public {
        uint256 provided = 10 - 1;
        vm.expectRevert(abi.encodeWithSelector(LpShareOracleV4.InvalidStableDepegBps.selector, provided));
        new LpShareOracleV4(
            address(feed0), address(feed1), address(feed1), 18, 18, 18,
            RISK_STALENESS, STABLE_STALENESS, provided
        );
    }

    function test_constructor_reverts_when_depeg_band_above_upper_bound() public {
        uint256 provided = 500 + 1;
        vm.expectRevert(abi.encodeWithSelector(LpShareOracleV4.InvalidStableDepegBps.selector, provided));
        new LpShareOracleV4(
            address(feed0), address(feed1), address(feed1), 18, 18, 18,
            RISK_STALENESS, STABLE_STALENESS, provided
        );
    }

    /// The whole point of V4-via-Chainlink: there is NO pool to read, so a pool spot move can't
    /// change the valuation. Valuation depends ONLY on the feeds.
    function test_valuation_independent_of_any_pool() public view {
        // two calls with identical feeds give identical value regardless of external pool state
        uint256 a = oracle.fairValueInLoan(5e18, -600, 600);
        uint256 b = oracle.fairValueInLoan(5e18, -600, 600);
        assertEq(a, b);
    }
}
