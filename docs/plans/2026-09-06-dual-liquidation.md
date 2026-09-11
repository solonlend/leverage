# Liquidation surplus Implementation Plan

> Execute independent single-vault tasks with subagent-driven-development; root owns Dual integration.

Goal: discharge both debts before a liquidation refund; preserve 5% oracle slippage and liquidation liveness.
Architecture: shared external LiquidationSurplus library, delegatecalled by both Dual vaults to fit EIP-170. Same-token repayments first, then exact-input surplus conversion with empty executor path; refund only after both current debts reach zero.
Tech stack: Solidity 0.8.24 / Foundry, existing optimizer 80 / via_ir.

## Migration matrix (before implementation)
| Source | Existing behavior | Destination / change |
|---|---|---|
| V3/V4 `_payoutLiquidation` surplus blocks | Repay own debt, immediately refund each token | Both call shared library; settle both own-token debts before deciding refunds |
| V3/V4 `_repayLeg` | Approve lending pool, subtract actual repay | Library same-token and converted-token repay use actual returned amount |
| V4 `_settleGap` fallback | ExactInput empty path, oracle minimum at 95% fair value | Library cross-leg settlement uses identical directional quote and 500 bps constraint |
| `_approveIfNeeded` / `_safeCall` | Optional ERC20 bool, max approval if insufficient | Library retains these semantics under delegatecall |
| `_transferOrTreasury` | Borrower refund, governor on rejected transfer | Remains in both vaults, called only with debt-free refundable outputs |
| LpMathExt external linkage | External library reduces vault runtime | New dedicated settlement library avoids mixing asset movements into math library |

## Tasks and verification
1. Add `test/DualLiquidationSurplus.t.sol` harnesses invoking each real payout function. Assert 1000 RISK debt + 90 LOAN surplus consumes surplus for debt, in both directions; failed/slippage swaps retain protocol surplus, donations remain isolated.
2. Run `~/.foundry/bin/forge test --offline --match-path test/DualLiquidationSurplus.t.sol -vv` under watchdog, record assertion RED.
3. Add shared `src/libraries/LiquidationSurplus.sol`, replace only the two payout surplus blocks; repeat targeted GREEN.
4. Add public-liquidation integration and debt-free refund/capped repay/decimal boundary cases; repeat targeted run.
5. Run `~/.foundry/bin/forge build --offline --sizes --no-lint`; STOP if any vault exceeds 24576 bytes.
6. After single-vault changes land, full `~/.foundry/bin/forge test --offline --no-match-path 'test/fork/*'` with default fuzz/invariant settings. Report new/duplicated test count and excluded fork 9. No commit/push/broadcast.

## Failure policy
Swap revert leaves the surplus in the vault as protocol funds, with an event identifying debt IDs/token/amount. This keeps liquidation live while preventing borrower extraction ahead of lenders. Existing baseline-aware operations cannot refund these retained balances. No new withdrawal/rescue mechanism; later recovery is outside this patch. The same conservative treatment applies if repayment caps leave debt despite available balance.

## Verified results (2026-09-06)
- Initial Dual RED: 2 passed / 16 failed / 0 skipped, including both 1000 RISK debt + 90 LOAN surplus regressions.
- Single fee RED: 0/4; second repayment refund RED: 0/2. Target liquidation suites after fixes: 52 passed / 0 failed.
- Full non-fork final: 270 passed / 0 failed / 0 skipped; 226 baseline + 34 new Dual tests + 6 new single tests + 4 inherited repetitions. Nine fork tests explicitly excluded because sandbox has no network.
- The first full run was 269/1: existing DeepFuzz P2 assumed zero vault balance even after a swap fails. Trace proved MINOUT and matching SurplusRetained amount. P2 now verifies exact event-backed retained amounts (existing 1e3 dust tolerance), correct vault/debt IDs/token, and no borrower refunds while either debt remains. Both deep-fuzz properties passed 5000 runs in final full suite; all invariant suites passed default runs300/depth40.
- `~/.foundry/bin/forge build --offline --sizes --no-lint`: exit0. Runtime bytes / EIP-170 margin: V3Dual23680/896, V4Dual24499/77, V3Single14906/9670, V4Single19262/5314. Test-only payout harnesses carry Foundry's IS_TEST marker; production bytecode unaffected. Initial unmarked harnesses caused the size command to reject test artifacts, not production vaults.
- Read-only independent spec and code-quality review passed; git diff --check passed. No commit, push, broadcast, fork or real-chain execution.
- Final logs: `/tmp/liquidation-full-final.log`, `/tmp/liquidation-sizes-final.log`; targeted `/tmp/liquidation-target-final.log`; RED `/tmp/dual-liq-red.log`, `/tmp/single-fee-red.log`, `/tmp/single-repay-red.log`.
