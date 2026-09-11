# Solon Leveraged LP — Robinhood Chain mainnet deployment (2026-09-07)

**Chain:** Robinhood Chain (chainId 4663) · **Pool:** Uniswap V3 WETH/USDG fee 0.01% `0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca`
**Scope:** first wave — dual-borrow + single-borrow V3 vaults sharing one lending pool. Scaled soft launch.
**Deployer / governor / keeper:** `0xD0340F008bee8F6101cD609E0447cd3d44f8cC84` (single-key; no multisig; no external audit — accepted for a capped soft launch).

## Deployed addresses

| Contract | Address |
|---|---|
| UniV3DualVault (vaultId 1) | `0x9Db7aDa64D1E8b856E15D916d886797501F28ce0` |
| UniV3LeverageVault (vaultId 2, single-borrow) | `0x9e100d524DFEa1Aa76286A7F00682e72F79aC3aE` |
| LendingPool | `0xA4af5515A7DE8E1661C92d3246296Ff3a48791Dd` |
| LpShareOracleV4 | `0x52b5728D1086b0B68d98DD51ee6544d87062Ef0f` |
| SwapExecutorV3 | `0xe05d1c6AcbECe311c3A68D372F5f8A8FaCf8C6b2` |
| AddressRegistry | `0xf5e6DC8412aBFc9BcF41F86aABfEDf0a16163CB4` |
| SolonVaultRegistry | `0xe8Eb1EFb1EF33c4D55BA33701A9a234aD66ea065` |
| eToken USDG (reserve 1) | `0x59286206faCD48E002a4e0EaC106998567071Ef3` |
| eToken WETH (reserve 2) | `0x2e3409b1d8068eB330437d89048b3d96D6379dac` |

**External (verified on-chain):** NFPM `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` · ROUTER `0xCaf681a66D020601342297493863E78c959E5cb2` · WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` · USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` · ETH/USD feed `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` · USDG/USD feed `0x61B7e5650328764B076A108EFF5fa7282a1B9aD2`

## Parameters (as deployed, VerifyDeployment PASS)

- LLTV 77% · liq bonus 700 bps · protocol fee 0 (soft launch) · harvest fee 10% · close factor 50% · min width 10 ticks
- Rate curve: (0,0) → (90%, 4% APR) → (100%, 204% APR)
- Oracle: risk staleness 93600s (26h) · stable staleness 93600s (26h) · USDG depeg 50 bps · dec0/dec1/loanDec 18/6/6
- Reserves: USDG (id 1) capacity 200e6, seed 200e6; WETH (id 2) capacity 5e16 (0.05), seed 5e16
- Credits: dual-borrow — USDG 100e6, WETH 4e16 (0.04); single-borrow — USDG 60e6 (borrows loan only). Reserve-1 total credit 160e6 ≤ capacity 200e6.

## Build provenance

- Repo `solonlend/leverage` at deploy commit `c12cfbe` (single-attach) on top of `d9b9cb2` (scaled seed floor) / `d35363e` (fork-rehearsal fixes).
- Offline suite 325/325; RH mainnet fork suite 9/9; scaled + combined deploy rehearsed on an RH mainnet fork before broadcast.

## Funding trail (all from existing Solon funds, no new deposit)

- Withdrew 393.75 USDG from the Solon usdgVault (`0xCBB6…6d99`) in chunks (Vault V2 allocation-cap caps single withdraws; ~101 USDG left, recoverable).
- Swapped 250 USDG → 0.100068 WETH via SwapRouter02 (tx `0x519e1f7a…`, ~0.3% vs feed, 0.5% slippage guard).

## Smoke (mainnet, real funds)

- Dual: open position 1 (V 150.1 / D 49.98 USDG, healthy) → full close → residual debt 0. ✓
- Single: open position 1 (V 48.4 USDG, invest 30 + borrow 20) → full close → receipt burned. ✓
- Liquidation: NOT drilled live on mainnet (cannot move real feeds / open a deliberately-unhealthy position). Path verified on Sepolia (real forced liquidation) + fork suite; keeper liquidator whitelist confirmed on mainnet.

## Known residual risks (accepted)

Single deployer key = governor + keeper + SwapExecutor revoke-brake holder. No multisig. No external audit. Single keeper (no redundancy). Capped by tiny reserve size (200 USDG / 0.05 WETH). Scale-up should revisit multisig + audit + keeper redundancy first.

## Post-deploy TODO

- [ ] Sync mainnet addresses to `solonlend/skill` (addresses.json leveragedFarms.robinhoodMainnet, status live), FARM-GUIDE / SKILL wording, and the three tools (read/sim/market) — test each against a live vault.
- [ ] Docs update (product surfaces) with mainnet addresses + single & dual coverage.
- [ ] Farm UI `solon-farms.ts` mainnet addresses (both vaults) → e2e → publish.
- [ ] Website hero + status: testnet → mainnet live, dated, soft-launch framing.
- [ ] keeper DRY_RUN daemon + monitoring daemon up; alert route tested.
- [ ] Announcement (house-standard card + @Solonlend tweet) — after ops are live.
- [ ] Top up keeper buffer (pull remaining vault USDG) once external positions appear.

## 2026-09-11 护栏放宽(B 档,KousanS 拍板;fork 演练后广播,全部 status 1)

| 参数 | 旧 | 新 | tx |
|---|---|---|---|
| USDG 储备容量 | 200 | **10,000** | 0xb09f25bc…c95e |
| WETH 储备容量 | 0.05 | **2.5** | 0xbffe1a07…9363 |
| dual 金库 USDG 额度 | 100 | **5,000** | 0x80279176…ab23 |
| dual 金库 WETH 额度 | 0.04 | **1.25** | 0x05f3907a…4603 |

主网回读逐位一致。单借金库额度未动(60 USDG,维持)。总容量 ≈ $16k(ETH@$2,471);
上限=pre-audit 最坏敞口,审计落地前不再上调至 C 档。
