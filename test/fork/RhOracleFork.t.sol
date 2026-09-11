// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LpShareOracleV4, IAggregatorV3} from "../../src/LpShareOracleV4.sol";

/// FORK e2e (Robinhood Chain mainnet): our V4 oracle must read the REAL on-chain Chainlink feeds
/// (NVDA/USD, USDG/USD) and produce a sane fair value. Run: forge test --match-contract RhOracleFork
/// (needs network; set REQUIRE_RH_FORK=true to make an unavailable fork fail the run).
/// TODO: 股票类资产周末存在 60+ 小时喂价空窗；时效策略是 Solon 股票借贷的待设计项。
/// For NVDA/USDG: USDG 0x5fc5.. < NVDA 0xd060.. → currency0 = USDG (6dec), currency1 = NVDA (18dec).
contract RhOracleForkTest is Test {
    string RPC = "https://rpc.mainnet.chain.robinhood.com/rpc";
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    LpShareOracleV4 oracle;
    bool forked;

    function setUp() public {
        try vm.createSelectFork(RPC) {
            forked = true;
            // currency0 = USDG (feed0, 6 dec), currency1 = NVDA (feed1, 18 dec), loan = USDG
            oracle = new LpShareOracleV4(
                USDG_FEED, NVDA_FEED, USDG_FEED, /*dec0*/ 6, /*dec1*/ 18, /*loanDec*/ 6,
                /*riskStaleness*/ 26 hours, /*stableStaleness*/ 26 hours, /*depegBps*/ 100
            );
        } catch {
            if (vm.envOr("REQUIRE_RH_FORK", false)) revert("required RH fork unavailable");
            forked = false;
        }
    }

    function test_oracle_reads_real_feeds_and_values_position() public {
        vm.skip(!forked, "RH fork unavailable");
        int24 lower = -887220; int24 upper = 887220; // wide straddle so any real price is inside
        (,,, uint256 updatedAt,) = IAggregatorV3(NVDA_FEED).latestRoundData();
        assertGt(updatedAt, 0, "NVDA feed must have an update");
        assertLe(updatedAt, block.timestamp, "NVDA update cannot be in the future");
        if (block.timestamp - updatedAt > oracle.RISK_MAX_STALENESS()) {
            emit log("NVDA feed is stale (market closure/weekend possible): asserting fail-closed StalePrice");
            emit log_named_uint("NVDA updatedAt", updatedAt);
            vm.expectRevert(LpShareOracleV4.StalePrice.selector);
            oracle.riskValueInLoan(1e18); // Reads NVDA first, so another feed cannot mask its staleness.
            vm.expectRevert(LpShareOracleV4.StalePrice.selector);
            oracle.fairValueInLoan(1e18, lower, upper);
            vm.expectRevert(LpShareOracleV4.StalePrice.selector);
            oracle.zapAmountToToken0(1_000e6, lower, upper);
            return;
        }
        uint256 v = oracle.fairValueInLoan(1e18, lower, upper);
        emit log_named_uint("fairValueInLoan(1e18 liq) in USDG(6dec)", v);
        assertGt(v, 0, "real-feed valuation must be positive");

        uint256 zap = oracle.zapAmountToToken0(1_000e6, lower, upper); // 1000 USDG (6dec)
        emit log_named_uint("zapAmountToToken0 of 1000 USDG", zap);
        assertLe(zap, 1_000e6, "zap split cannot exceed input");
    }
}
