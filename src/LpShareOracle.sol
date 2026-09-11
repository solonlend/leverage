// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

// ██ DEPRECATED — 禁止部署 ██
// 本 TWAP 版预言机:feed 交叉校验为空实现(仅注释承诺)、无 riskValueInLoan(接 DualVault 即全砖)。
// 一切部署一律使用 LpShareOracleV4(纯 Chainlink,含 riskValueInLoan 与构造期校验)。安全审计 M6。

/*
  LpShareOracle — the ONE custom, funds-critical contract of the leveraged-LP product.
  Prices one share of a Charm-style two-sided Uniswap V3 LP vault (an ERC20) in loan-token
  units, in Morpho's IOracle scale (1e36 + loanDec - collDec). Morpho Blue uses this to
  value the wrapped-LP collateral and to run its NATIVE liquidation — we write no liquidation
  logic ourselves.

  SECURITY — the whole ballgame is here (Alpha Homora / Warp-oracle class of bug):
    * NEVER value the position from spot reserves (vault.getTotalAmounts() at spot). An attacker
      can skew the token0/token1 split by moving the pool within one tx and mint/liquidate at a
      fabricated share value. getTotalAmounts() is provided by Charm but is SPOT — do not price on it.
    * Instead compute FAIR token amounts from the position's liquidity L and range at a
      MANIPULATION-RESISTANT price:
         - sqrtPriceFair from the pool's TWAP over `twapWindow` (Uniswap V3 observe()),
           bounded against the two external Chainlink feeds so a stale/poisoned TWAP can't pass.
         - fair amounts (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
              sqrtPriceFair, sqrtRatioLower, sqrtRatioUpper, L)  summed across the vault's
           active range(s) plus idle balances the vault holds.
      Then value each leg with its Chainlink feed and divide by totalSupply().
    * Fail-closed: revert on stale feed, zero supply, TWAP deviation vs feeds beyond `maxDeviationBps`,
      or any zero/again check — same discipline as StockOracleAdapter.
    * Two-sided-only invariant is enforced upstream (position always straddles price), which keeps
      this valuation bounded and well-behaved; single-sided ranges are rejected at open time.

  This skeleton fixes the INTERFACE and the SAFE DESIGN. The tick/liquidity math bodies are marked
  TODO and must be implemented against Uniswap's LiquidityAmounts/TickMath and red-teamed + audited
  (differential test vs a Python golden model, fuzz, and replay of the Alpha Homora attack) BEFORE
  any mainnet market uses it — funds depend on it.
*/

import {TickMath} from "./libraries/TickMath.sol";
import {FairLpMath} from "./libraries/FairLpMath.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface ICharmVault {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function pool() external view returns (address);
    function totalSupply() external view returns (uint256);
    function getTotalAmounts() external view returns (uint256 total0, uint256 total1); // SPOT — reference only, not for pricing
    // Charm exposes its active range(s); the concrete getter set is wired when we pin the fork.
}

interface IUniV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128);
    function slot0()
        external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

contract LpShareOracle {
    address public immutable VAULT;      // Charm two-sided LP vault (the ERC20 collateral)
    address public immutable POOL;       // underlying Uniswap V3 pool
    address public immutable FEED0;      // Chainlink feed token0/USD (or /loan)
    address public immutable FEED1;      // Chainlink feed token1/USD (or /loan)
    address public immutable LOAN_FEED;  // Chainlink feed loanToken/USD (USDG/USD)

    uint32  public immutable TWAP_WINDOW;      // e.g. 1800s
    uint256 public immutable MAX_DEVIATION_BPS; // TWAP vs feed cross-check bound
    uint256 public immutable MAX_STALENESS;     // feed staleness bound
    uint256 public immutable SCALE;             // 10^(36 + loanDec - collDec); collDec = 18 (vault shares)

    uint8 public immutable DEC0;      // token0 decimals
    uint8 public immutable DEC1;      // token1 decimals
    uint8 public immutable LOAN_DEC;  // loan token (USDG) decimals
    // NOTE: all three USD feeds MUST share the same decimals (RH Chainlink USD feeds = 8); the
    //       feed-decimal cancels in the USD→loan division. Enforced by the deploy script's feed pin.

    error StalePrice();
    error BadRound();
    error NonPositive();
    error TwapDeviation();
    error LegacyOracleDeprecatedUseLpShareOracleV4();

    constructor(
        address vault, address feed0, address feed1, address loanFeed,
        uint32 twapWindow, uint256 maxDeviationBps, uint256 maxStaleness, uint256 scale,
        uint8 dec0, uint8 dec1, uint8 loanDec
    ) {
        // EVM contract code is installed only after initcode returns, so this is unconditionally true
        // during every creation attempt. Keeping the original body below preserves the source as a
        // reference while ensuring even zero/code-less inputs hit the explicit migration error first.
        if (address(this).code.length == 0) revert LegacyOracleDeprecatedUseLpShareOracleV4();
        require(
            vault != address(0) && feed0 != address(0) && feed1 != address(0) && loanFeed != address(0),
            "ZERO_ADDR"
        );
        VAULT = vault;
        POOL = ICharmVault(vault).pool();
        FEED0 = feed0; FEED1 = feed1; LOAN_FEED = loanFeed;
        TWAP_WINDOW = twapWindow; MAX_DEVIATION_BPS = maxDeviationBps;
        MAX_STALENESS = maxStaleness; SCALE = scale;
        DEC0 = dec0; DEC1 = dec1; LOAN_DEC = loanDec;
    }

    function _readFeed(address feed) internal view returns (uint256) {
        (uint80 roundId, int256 ans,, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(feed).latestRoundData();
        if (updatedAt == 0 || roundId == 0) revert BadRound();
        if (answeredInRound < roundId) revert BadRound();
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();
        if (ans <= 0) revert NonPositive();
        return uint256(ans);
    }

    /// @notice Time-weighted arithmetic-mean tick over TWAP_WINDOW. This is the manipulation
    ///         resistance: an attacker moving spot (slot0) within one tx barely moves a
    ///         window-averaged tick, so a fabricated price cannot pass. (Uniswap OracleLibrary.consult)
    function _meanTick() internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW; // window ago
        secondsAgos[1] = 0;           // now
        (int56[] memory tickCumulatives,) = IUniV3Pool(POOL).observe(secondsAgos);

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int24 meanTick = int24(delta / int56(uint56(TWAP_WINDOW)));
        // round toward negative infinity (Uniswap convention) so the tick is not biased up
        if (delta < 0 && (delta % int56(uint56(TWAP_WINDOW)) != 0)) meanTick--;
        return meanTick;
    }

    /// Manipulation-resistant fair sqrtPrice from TWAP, cross-checked against the feeds.
    function _fairSqrtPriceX96() internal view returns (uint160) {
        uint160 sqrtTwap = TickMath.getSqrtRatioAtTick(_meanTick());
        // Cross-check TWAP against the two Chainlink feeds (decimal-aware ratio bound). The exact
        // decimal wiring is pinned when the Charm fork/token decimals are fixed; the deviation gate
        // below is the invariant it must enforce: |twapPrice - feedPrice| / feedPrice <= MAX_DEVIATION_BPS.
        // Until pinned, callers MUST NOT rely on price() on mainnet (still reverts in price()).
        return sqrtTwap;
    }

    /// @notice Fair value, in loan-token (USDG) units, of a concrete LP position (liquidity over a
    ///         range) — the number the leverage vault feeds into health & liquidation checks.
    ///         Anti-manipulation: uses TWAP fair sqrtPrice + Chainlink feeds, never spot.
    ///         Bit-exact twin of golden fair_value_in_loan (differential-tested).
    function fairValueInLoan(uint128 liquidity, int24 tickLower, int24 tickUpper)
        public view returns (uint256 valueInLoan)
    {
        uint160 sqrtFair = _fairSqrtPriceX96();
        uint256 p0 = _readFeed(FEED0);
        uint256 p1 = _readFeed(FEED1);
        uint256 pLoan = _readFeed(LOAN_FEED);
        (valueInLoan,,) = FairLpMath.fairValueInLoan(
            liquidity, tickLower, tickUpper, sqrtFair, p0, p1, pLoan, DEC0, DEC1, LOAN_DEC
        );
    }

    /// @notice Open-time zap target: how much of `totalLoan` USDG to swap into token0 for a balanced
    ///         two-sided position over [tickLower,tickUpper]. Uses the TWAP fair price (not spot), so
    ///         the target ratio can't be skewed by a flash price move. The vault swaps this much via its
    ///         executor with a slippage bound, then mints (amountMin protects the rest).
    function zapAmountToToken0(uint256 totalLoan, int24 tickLower, int24 tickUpper)
        external view returns (uint256)
    {
        uint160 sqrtFair = _fairSqrtPriceX96();
        uint256 p0 = _readFeed(FEED0);
        uint256 p1 = _readFeed(FEED1);
        return FairLpMath.zapSwapAmountToToken0(totalLoan, tickLower, tickUpper, sqrtFair, p0, p1, DEC0, DEC1);
    }

    // NOTE: the Morpho-IOracle per-share price() + _fairAmounts() (wrapped-LP-as-Morpho-collateral path)
    // were removed — we settled on the Extra per-user model (UniV3/V4LeverageVault), which values a
    // position via fairValueInLoan() above, not a Morpho per-share price. Re-add only if a wrapped-LP
    // Morpho market is ever introduced (v2+).
}
