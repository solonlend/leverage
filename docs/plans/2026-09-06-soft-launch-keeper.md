# Soft launch limits and keeper implementation plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Apply required reserve limits in both V3 deploy scripts and add an offline-testable liquidation keeper.
**Architecture:** Deployment inputs are checked before broadcasting and applied before seed deposits. Keeper separates configuration, scanning, and the viem transport; defaults to read-only dry runs.
**Tech Stack:** Solidity / Foundry; Node.js ESM / viem / node:test.

### Task A — deployment limits
Files: script/DeployRhDual.s.sol, script/DeploySepoliaDual.s.sol, shared script helper if useful, test/ deployment regression, DEPLOY-CHECKLIST.md.
1. Add a regression proving required capacities and credits are read and applied, and seed above capacity is rejected; run it to see failure.
2. Implement four required env inputs without numeric defaults; validate widths and capacity >= seed before broadcast; configure capacities before deposits and replace unlimited credits. Align Sepolia seed inputs.
3. Document LOAN capacity 1000000000, RISK capacity 500000000000000000; LOAN credit <=800000000, RISK credit <=400000000000000000.
4. Run bounded offline forge build --no-lint and related deployment tests serially.

### Task B — keeper
Files: keeper/package.json, keeper/config.mjs, keeper/core.mjs, keeper/index.mjs, keeper/abi.mjs, keeper/test/*.test.mjs, keeper/README.md.
1. Inspect real dual vault signatures, liquidation funding and permissions.
2. Write and run a failing node:test dry-run scan test, then implement scan behavior.
3. Add tests before config validation, retries, per-position isolation, explicit live mode, bounded transactions and shutdown behavior.
4. Implement viem adapter with explicit live key loading only; never print raw errors or credentials. Document balances/approvals and all inputs.
5. Run node --check and offline mock tests; do not install over network or contact a chain.

### Integration review
Review requirements first, then code quality; fix findings and rerun affected checks. No commits, pushes, broadcasts, fork or network checks. All long commands use explicit timeouts.
