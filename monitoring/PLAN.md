# Monitoring Implementation Plan

Goal: read-only offline-testable viem daemon following docs/OPS-RUNBOOK.md §2.
Architecture: pure threshold decisions, injected RPC polling, durable BadDebt cursor,
isolated notification and heartbeat adapters. Node >=22; reuse keeper viem 2.56.3.

1. TDD threshold rules in rules.mjs and test/rules.test.mjs: strict feed ages,
   inclusive peg/heartbeat limits, invalid data, optional debt/LLTV utilization.
2. Independently delegate notify.mjs and heartbeat.mjs with their own failing tests.
3. TDD monitor.mjs polling: retry reads, isolate failures, persistent event progress,
   bounded ranges, unique event alert keys; mock RPC only.
4. Wire config.mjs/index.mjs/abi.mjs with createRequire anchored in keeper;
   document environment, heartbeat pipeline, limitations and offline commands.
5. Run node --check for every module and node --test monitoring/test/*.test.mjs;
   review diff scope and report exact results. No commit/push/network.
