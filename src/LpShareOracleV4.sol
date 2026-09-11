// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {FairLpMath} from "./libraries/FairLpMath.sol";
import {FullMath} from "./libraries/FullMath.sol";

/*
  LpShareOracleV4 — funds-critical fair valuation for the V4 leveraged-LP vault.
  Uniswap V4 core pools have NO built-in observe()/TWAP (it moved to optional hooks), so the
  manipulation-resistant fair price is derived entirely from Chainlink feeds — fully external,
  so a flash move of the pool's spot price CANNOT skew our valuation/liquidation.

  Same interface the vault calls as the V3 oracle (fairValueInLoan / zapAmountToToken0), so the
  vault code is unchanged; only the fair-price SOURCE differs (feeds instead of pool TWAP).

  Fail-closed on stale / bad / non-positive feeds (same discipline as the stock oracle adapter).
  The tick/liquidity math is the same audited FairLpMath used by the V3 path (differential-tested
  vs the Python golden), so no new funds-critical math is introduced here.
*/

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract LpShareOracleV4 {
    address public immutable FEED0;      // Chainlink token0/USD
    address public immutable FEED1;      // Chainlink token1/USD
    address public immutable LOAN_FEED;  // Chainlink loanToken/USD (USDG/USD)
    uint8 public immutable DEC0;         // token0 decimals
    uint8 public immutable DEC1;         // token1 decimals
    uint8 public immutable LOAN_DEC;     // loan token (USDG) decimals
    uint256 public immutable RISK_MAX_STALENESS;
    uint256 public immutable STABLE_MAX_STALENESS;
    uint256 public immutable STABLE_DEPEG_BPS;
    uint256 private immutable STABLE_MIN_PRICE;
    uint256 private immutable STABLE_MAX_PRICE;
    // all three USD feeds share the same feed decimals (cancels in the USD→loan division)

    uint256 internal constant MIN_RISK_MAX_STALENESS = 1 hours;
    uint256 internal constant MAX_RISK_MAX_STALENESS = 48 hours; // RH ETH feed 偏差触发+长心跳(实测平静期 gap 达24h),放宽至覆盖心跳;波动期由 ±0.5% 偏差触发保新鲜。见 docs/FINDING-rh-eth-feed-staleness-2026-09-06.md
    uint256 internal constant MIN_STABLE_MAX_STALENESS = 25 hours;
    uint256 internal constant MAX_STABLE_MAX_STALENESS = 48 hours;
    uint256 internal constant MIN_STABLE_DEPEG_BPS = 10;
    uint256 internal constant MAX_STABLE_DEPEG_BPS = 500;
    uint256 internal constant BPS = 10_000;

    // dual-borrow 扩展:RISK = 与 LOAN_FEED 不同的那个 token(feed 相同视为 loan 腿)。
    // 构造期一次判定,供 riskValueInLoan 使用;不影响任何既有方法。
    address public immutable RISK_FEED;
    uint8 public immutable RISK_DEC;

    error StalePrice();
    error BadRound();
    error NonPositive();
    error InvalidRiskMaxStaleness(uint256 provided);
    error InvalidStableMaxStaleness(uint256 provided);
    error InvalidStableDepegBps(uint256 provided);
    error StablecoinDepegged(uint256 observed, uint256 lowerBound, uint256 upperBound);

    constructor(
        address feed0, address feed1, address loanFeed,
        uint8 dec0, uint8 dec1, uint8 loanDec,
        uint256 riskMaxStaleness, uint256 stableMaxStaleness, uint256 stableDepegBps
    ) {
        if (riskMaxStaleness < MIN_RISK_MAX_STALENESS || riskMaxStaleness > MAX_RISK_MAX_STALENESS) {
            revert InvalidRiskMaxStaleness(riskMaxStaleness);
        }
        if (stableMaxStaleness < MIN_STABLE_MAX_STALENESS || stableMaxStaleness > MAX_STABLE_MAX_STALENESS) {
            revert InvalidStableMaxStaleness(stableMaxStaleness);
        }
        if (stableDepegBps < MIN_STABLE_DEPEG_BPS || stableDepegBps > MAX_STABLE_DEPEG_BPS) {
            revert InvalidStableDepegBps(stableDepegBps);
        }
        require(feed0 != address(0) && feed1 != address(0) && loanFeed != address(0), "ZERO_ADDR");
        require(loanFeed == feed0 || loanFeed == feed1, "LOAN_FEED_NOT_IN_PAIR"); // 错配会静默指错 RISK_FEED(一致性审计④)
        // code-review:三 feed 小数位必须一致("相除相消"的前提),不一致=价差 1e10 级灾难
        uint8 feedDecimals = IAggregatorV3(loanFeed).decimals();
        require(
            IAggregatorV3(feed0).decimals() == feedDecimals
                && IAggregatorV3(feed1).decimals() == feedDecimals,
            "FEED_DECIMALS_MISMATCH"
        );
        FEED0 = feed0; FEED1 = feed1; LOAN_FEED = loanFeed;
        DEC0 = dec0; DEC1 = dec1; LOAN_DEC = loanDec;
        RISK_MAX_STALENESS = riskMaxStaleness;
        STABLE_MAX_STALENESS = stableMaxStaleness;
        STABLE_DEPEG_BPS = stableDepegBps;
        uint256 stablePegPrice = 10 ** feedDecimals;
        STABLE_MIN_PRICE = FullMath.mulDiv(stablePegPrice, BPS - stableDepegBps, BPS);
        STABLE_MAX_PRICE = FullMath.mulDiv(stablePegPrice, BPS + stableDepegBps, BPS);
        (RISK_FEED, RISK_DEC) = loanFeed == feed1 ? (feed0, dec0) : (feed1, dec1);
    }

    function _readFeed(address feed) internal view returns (uint256) {
        (uint80 roundId, int256 ans,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(feed).latestRoundData();
        if (updatedAt == 0 || roundId == 0) revert BadRound();
        if (answeredInRound < roundId) revert BadRound();
        uint256 maxStaleness = feed == LOAN_FEED ? STABLE_MAX_STALENESS : RISK_MAX_STALENESS;
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice();
        if (ans <= 0) revert NonPositive();
        uint256 price = uint256(ans);
        if (feed == LOAN_FEED && (price < STABLE_MIN_PRICE || price > STABLE_MAX_PRICE)) {
            revert StablecoinDepegged(price, STABLE_MIN_PRICE, STABLE_MAX_PRICE);
        }
        return price;
    }

    /// Manipulation-resistant fair sqrtPrice from the two Chainlink feeds (no pool TWAP on V4).
    function _fairSqrtPriceX96(uint256 p0, uint256 p1) internal view returns (uint160) {
        return FairLpMath.sqrtPriceX96FromFeeds(p0, p1, DEC0, DEC1);
    }

    /// Fair value, in loan-token (USDG) units, of a concrete LP position. Same math as the V3 path.
    function fairValueInLoan(uint128 liquidity, int24 tickLower, int24 tickUpper)
        public view returns (uint256 valueInLoan)
    {
        uint256 p0 = _readFeed(FEED0);
        uint256 p1 = _readFeed(FEED1);
        uint256 pLoan = _readFeed(LOAN_FEED);
        uint160 sqrtFair = _fairSqrtPriceX96(p0, p1);
        (valueInLoan,,) = FairLpMath.fairValueInLoan(
            liquidity, tickLower, tickUpper, sqrtFair, p0, p1, pLoan, DEC0, DEC1, LOAN_DEC
        );
    }

    /// dual-borrow:把 RISK 数量按 Chainlink 折成 LOAN(USDG)本位,用于双债合并健康度。
    /// fail-closed 同其余读数;USD feed 同 decimals,分子分母相消。
    function riskValueInLoan(uint256 riskAmount) external view returns (uint256) {
        if (riskAmount == 0) return 0;
        uint256 pRisk = _readFeed(RISK_FEED);
        uint256 pLoan = _readFeed(LOAN_FEED);
        // value = amount × pRisk/pLoan × 10^LOAN_DEC / 10^RISK_DEC
        return FullMath.mulDiv(riskAmount, pRisk * (10 ** LOAN_DEC), pLoan * (10 ** RISK_DEC));
    }

    /// Open-time zap target: how much of totalLoan USDG to swap into token0 for a balanced position.
    function zapAmountToToken0(uint256 totalLoan, int24 tickLower, int24 tickUpper)
        external view returns (uint256)
    {
        uint256 p0 = _readFeed(FEED0);
        uint256 p1 = _readFeed(FEED1);
        uint160 sqrtFair = _fairSqrtPriceX96(p0, p1);
        return FairLpMath.zapSwapAmountToToken0(totalLoan, tickLower, tickUpper, sqrtFair, p0, p1, DEC0, DEC1);
    }
}
