# Five contract fixes implementation plan

**Goal:** Close all five accepted low-risk findings with observed RED → GREEN tests.
**Architecture:** Exact incoming balance checks and operation-scoped ETH settlement; delayed registry corrections; bounded router allowances; precision-aware zap reference selection.
**Tech Stack:** Solidity 0.8.24, Foundry, existing optimizer/via-IR configuration.

Each numbered task runs its regression tests before production edits, records failures under /tmp/leverage-*, implements the minimal fix, then reruns those tests. No commit, push, broadcast, network access, dependency edits or optimizer changes.

1. Payments and LendingPool: replace unsafe FoT assertions in test/LendingPoolPayments.t.sol with custom-error rejection and atomic accounting assertions; check recipient balances around incoming transfers. Cover deposit, staking and repay.
2. Payments and LendingPool: change donation-sweeping assertions to preservation; cover exact native redemption, excess ETH refund, forced ETH with insufficient or zero msg.value and staking. Wrap/refund only current-call ETH and unwrap only accounted redemption.
3. SolonVaultRegistry: add test/SolonVaultRegistry.t.sol, demonstrate missing delayed correction API via low-level calls; implement owner-only scheduling, delayed execution, cancellation and explicit events. Preserve existing registration and address-based lending authorization.
4. SwapExecutorV3 and test/SwapExecutorV3.t.sol: assert exact router allowance during calls and zero after input/output swaps, strict zero-first token support, owner-only revocation. Replace unlimited approvals with exact zero-first approvals and cleanup.
5. FairLpMath and test/FairLpMath.diff.t.sol: reproduce nonzero rounded-leg ratio distortion; preserve golden outputs; detect material continuous-ratio rounding error and raise reference liquidity or fail closed.

Validation: baseline `forge test --no-match-path 'test/fork/**' --offline`; targeted `--match-path` and `--match-test` for each RED/GREEN; final full non-fork suite with configured fuzz/invariants, plus `forge build --sizes --no-lint --offline`. Commands use ~/.foundry/bin/forge with subprocess timeouts. Inspect all four vaults, LendingPool and SwapExecutorV3; halt/report any size overflow without removing functionality. Fork execution skipped offline and marked 待带网重验; retain/extend fork logic coverage where applicable. Review specification compliance, then code quality, before final integration validation.

## Operational details

- Registry correction: while the id still resolves to the old address, revoke its LendingPool borrowing whitelist and zero its reserve credits. Then propose the replacement, inspect the emitted old/new addresses, wait two days, and execute as owner. Correction does not migrate or revoke address-keyed permissions or debt. Rescheduling restarts the delay; cancellation and an accepted ownership transfer invalidate the pending action.
- SwapExecutorV3's immutable deployer owner may only revoke a token's ROUTER allowance; this role cannot move funds or change ROUTER. Each successful swap already clears its exact allowance before returning/refunding.
- Zap uses a conservative continuous-value rounding certificate. Both normalized shares are certified within 1 bp relative error before final output-unit flooring. An uncertified base reference escalates to uint128 maximum; an uncertified two-sided maximum reference reverts. This can escalate earlier than an exact deviation comparison. For a $10,000 swap allocation, 1 bp is $1 of relative allocation error. Historical 201 golden vectors and the fixed WETH/USDG amount remain unchanged.

## TDD evidence

All logs below are local `/tmp/leverage-*` files; no network or chain actions were used.

- FoT: `payments-fot-red.log` 0 passed / 3 failed, then 3 passed.
- Native settlement: `payments-native-red.log` 0 passed / 7 failed, then 7 passed; combined final Payments suite 13 passed (was 4).
- Registry: `registry-red.log` 0 passed / 1 failed, `registry-red2.log` 1 passed / 2 failed; final 6 passed (new suite).
- Swap: `swap-red1.log` 12 passed / 1 failed, `swap-red2.log` 13 passed / 1 failed, `swap-red3.log` 14 passed / 2 failed; final 18 passed (was 12).
- Zap: `zap-red.log` 0 passed / 3 failed; math suites 12 passed (was 9). Python reference separately reproduced 3 failures in `zap-reference-red.log`, then passed all 3 independent rational tests and all 201 historical zap vectors.
- Independent specification and subsequent code-quality reviews both passed without blocking findings.

## Final verification

- Non-fork baseline: 296 passed / 0 failed. Final: 320 passed / 0 failed across 38 suites (`/tmp/leverage-final-tests.log`). Net +24 = Payments +9, Registry +6, Swap +6, zap +3. Existing unsafe-behavior tests were rewritten into safety assertions rather than removed.
- Both invariant suites ran 300 runs / 12,000 calls each; deep fuzz ran 5,000 cases per property, without failures.
- `forge build --sizes --no-lint --offline` exited 0 (`/tmp/leverage-sizes-after.log`), including fork-test compilation. Runtime size / EIP-170 margin in bytes: V3 single 14,906 / 9,670; V3 dual 23,680 / 896; V4 single 19,262 / 5,314; V4 dual 24,499 / 77; LendingPool 15,779 / 8,797; SwapExecutorV3 3,200 / 21,376. Four vault sizes are unchanged; baseline V4 dual margin was already 77 B.
- All 9 real-network fork tests were excluded from execution under the offline instruction: **待带网重验**. No fork pass is claimed.
- `git diff --check` passed. No modifications to `lib/**`, `src/lending/external/**` or historical vectors; no commit, push or broadcast.
