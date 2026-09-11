// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LpShareOracleV4} from "../../src/LpShareOracleV4.sol";
import {SwapExecutorV3} from "../../src/SwapExecutorV3.sol";
import {LendingPool} from "../../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../../src/lending/libraries/helpers/AddressId.sol";
import {SolonVaultRegistry} from "../../src/lending/SolonVaultRegistry.sol";
import {UniV3DualVault} from "../../src/UniV3DualVault.sol";

/*
  RH 主网 fork:dual-borrow 三块真链验证(合约不上链,全在本地 fork):
  F-A 真 Chainlink 折算:oracle.riskValueInLoan(1 ETH) ≈ ETH 价(USDG 6dp)
  F-B 真 router exactOutput:买恰好 0.01 WETH,多给的 USDG 退回,不滞留
  F-C 真链双储备:initReserve(WETH) + 双边出借人 + 双授信 → 借 WETH/借 USDG → 还清
  Run: REQUIRE_RH_FORK=true forge test --match-contract RhDualFork(需要网络)
*/

interface IV3PoolLike { function slot0() external view returns (uint160,int24,uint16,uint16,uint16,uint8,bool); }

interface IERC20f {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract RhDualForkTest is Test {
    string RPC = "https://rpc.mainnet.chain.robinhood.com/rpc";
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH   = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH_FEED  = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    bool forked;

    function setUp() public {
        try vm.createSelectFork(RPC) { forked = true; } catch {
            if (vm.envOr("REQUIRE_RH_FORK", false)) revert("required RH fork unavailable");
            forked = false;
        }
    }

    // ── F-A 真喂价折算 ──
    function test_FA_riskValueInLoan_real_feeds() public {
        vm.skip(!forked, "RH fork unavailable");
        LpShareOracleV4 oracle =
            new LpShareOracleV4(ETH_FEED, USDG_FEED, USDG_FEED, 18, 6, 6, 26 hours, 26 hours, 100);
        uint256 v = oracle.riskValueInLoan(1e18);
        emit log_named_uint("1 ETH in USDG (6dp)", v);
        // 合理区间:ETH 价 $500–$20000
        assertGt(v, 500e6, "sane lower bound");
        assertLt(v, 20_000e6, "sane upper bound");
        // 线性
        assertApproxEqAbs(oracle.riskValueInLoan(2e18), v * 2, 1, "linear in amount (floor rounding 1 wei)");
    }

    // ── F-B 真 router exactOutput ──
    function test_FB_exactOutput_real_router() public {
        vm.skip(!forked, "RH fork unavailable");
        SwapExecutorV3 exec = new SwapExecutorV3(ROUTER, 100);
        deal(USDG, address(this), 1_000e6);
        IERC20f(USDG).approve(address(exec), type(uint256).max);

        uint256 wBefore = IERC20f(WETH).balanceOf(address(this));
        uint256 uBefore = IERC20f(USDG).balanceOf(address(this));
        uint256 spent = exec.swapExactOutput(USDG, WETH, 0.01e18, 1_000e6, "");

        assertEq(IERC20f(WETH).balanceOf(address(this)) - wBefore, 0.01e18, "exact 0.01 WETH delivered");
        assertEq(uBefore - IERC20f(USDG).balanceOf(address(this)), spent, "only actual spent deducted (refund worked)");
        assertLt(spent, 1_000e6, "spent below maxIn");
        assertGt(spent, 1e6, "sane price paid");
        assertEq(IERC20f(USDG).balanceOf(address(exec)), 0, "no USDG stranded in executor");
        assertEq(IERC20f(WETH).balanceOf(address(exec)), 0, "no WETH stranded in executor");
        emit log_named_uint("spent USDG for 0.01 WETH", spent);
    }

    // ── F-C 真链双储备借贷 ──
    function test_FC_dual_reserve_borrow_repay_real_tokens() public {
        vm.skip(!forked, "RH fork unavailable");
        AddressRegistry registry = new AddressRegistry(WETH);
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, makeAddr("treasury"));
        LendingPool lending = new LendingPool(address(registry), WETH);
        lending.initReserve(USDG); // 1
        lending.initReserve(WETH); // 2
        SolonVaultRegistry vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));
        // 本测试合约充当"金库"进白名单+双授信
        vaultReg.setVault(1, address(this));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, 1, type(uint128).max);
        lending.setCreditsOfVault(1, 2, type(uint128).max);

        // 双边出借人(真币 deal)
        address lu = makeAddr("lenderU"); address lw = makeAddr("lenderW");
        deal(USDG, lu, 100_000e6); deal(WETH, lw, 100e18);
        vm.startPrank(lu); IERC20f(USDG).approve(address(lending), type(uint256).max);
        lending.deposit(1, 100_000e6, lu, 0); vm.stopPrank();
        vm.startPrank(lw); IERC20f(WETH).approve(address(lending), type(uint256).max);
        lending.deposit(2, 100e18, lw, 0); vm.stopPrank();

        // 借两腿
        uint256 dU = lending.newDebtPosition(1);
        uint256 dW = lending.newDebtPosition(2);
        lending.borrow(address(this), dU, 5_000e6);
        lending.borrow(address(this), dW, 2e18);
        assertEq(IERC20f(USDG).balanceOf(address(this)), 5_000e6, "USDG borrowed");
        assertEq(IERC20f(WETH).balanceOf(address(this)), 2e18, "WETH borrowed");

        // 还清两腿
        IERC20f(USDG).approve(address(lending), type(uint256).max);
        IERC20f(WETH).approve(address(lending), type(uint256).max);
        lending.repay(address(this), dU, 5_000e6);
        lending.repay(address(this), dW, 2e18);
        (uint256 ru,) = lending.getCurrentDebt(dU);
        (uint256 rw,) = lending.getCurrentDebt(dW);
        assertEq(ru, 0, "USDG debt cleared");
        assertEq(rw, 0, "WETH debt cleared");
        emit log("dual-reserve borrow/repay works on real RH tokens");
    }

    

    // ── F-D 全真 dual e2e:真 V3 池 + 真喂价 + 真 executor + 真双储备,开→补→换区间→平 ──
    address constant NFPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG fee100

    function test_FD_dual_vault_full_e2e_real_pool() public {
        vm.skip(!forked, "RH fork unavailable");
        // 借贷侧
        AddressRegistry registry = new AddressRegistry(WETH);
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, makeAddr("treasury"));
        LendingPool lending = new LendingPool(address(registry), WETH);
        lending.initReserve(USDG); // 1
        lending.initReserve(WETH); // 2
        SolonVaultRegistry vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));

        LpShareOracleV4 oracle =
            new LpShareOracleV4(ETH_FEED, USDG_FEED, USDG_FEED, 18, 6, 6, 26 hours, 26 hours, 100);
        SwapExecutorV3 exec = new SwapExecutorV3(ROUTER, 100);

        UniV3DualVault vault = new UniV3DualVault(UniV3DualVault.InitParams({
            governor: makeAddr("gov"), positionManager: NFPM, pool: POOL,
            lendingPool: address(lending), reserveRisk: 2, reserveLoan: 1,
            oracle: address(oracle), swapExecutor: address(exec),
            token0: WETH, token1: USDG, loanIsC0: false, fee: 100,
            minWidthTicks: 10, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            closeFactorBps: 5000, lltv: 0.8e18
        }));
        vaultReg.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, 1, type(uint128).max);
        lending.setCreditsOfVault(1, 2, type(uint128).max);

        // 双边出借人
        address lu = makeAddr("lu"); address lw = makeAddr("lw");
        deal(USDG, lu, 500_000e6); deal(WETH, lw, 200e18);
        vm.startPrank(lu); IERC20f(USDG).approve(address(lending), type(uint256).max);
        lending.deposit(1, 500_000e6, lu, 0); vm.stopPrank();
        vm.startPrank(lw); IERC20f(WETH).approve(address(lending), type(uint256).max);
        lending.deposit(2, 200e18, lw, 0); vm.stopPrank();

        // 借款人:自带 2000 USDG;按当前价借两腿(比例由链下/此处按预言机价粗算)
        address user = makeAddr("dualUser");
        deal(USDG, user, 3_000e6);
        (, int24 cur,,,,,) = IV3PoolLike(POOL).slot0();
        uint256 ethPx = oracle.riskValueInLoan(1e18); // USDG(6dp)/ETH
        // 借 2000 价值的 WETH + 500 USDG;用户自带 2000 USDG → LP≈4000,债≈2500,健康(≤3200)
        uint256 borrowWeth = (2_000e6 * 1e18) / ethPx;
        vm.startPrank(user);
        IERC20f(USDG).approve(address(vault), type(uint256).max);
        IERC20f(WETH).approve(address(vault), type(uint256).max);
        uint256 id = vault.open(UniV3DualVault.OpenParams({
            investRisk: 0, investLoan: 2_000e6, borrowRisk: borrowWeth, borrowLoan: 500e6,
            tickLower: cur - 2000, tickUpper: cur + 2000,
            amount0Min: 0, amount1Min: 0, minLiquidity: 0, deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        (, uint128 liq,,, uint256 dW, uint256 dU) = vault.positions(id);
        assertGt(liq, 0, "real V3 dual position minted");
        (uint256 wDebt,) = lending.getCurrentDebt(dW);
        (uint256 uDebt,) = lending.getCurrentDebt(dU);
        assertApproxEqAbs(wDebt, borrowWeth, 1e6, "WETH debt (open dust auto-repays)");
        assertLe(uDebt, 500e6, "USDG debt <= borrowed (unused auto-repaid, E-2)");
        emit log_named_uint("opened liq", liq);

        // 补保证金(单侧 USDG)
        deal(USDG, user, 200e6);
        vm.startPrank(user);
        vault.addMargin(id, 0, 200e6);
        vm.stopPrank();
        (uint256 uDebt2,) = lending.getCurrentDebt(dU);
        assertEq(uDebt2, uDebt > 200e6 ? uDebt - 200e6 : 0, "margin repaid USDG leg (capped at cur)");

        // 原地换区间(收窄,delta=0,零头退还)
        vm.prank(user);
        vault.rebalance(id, UniV3DualVault.RebalanceParams({
            newTickLower: cur - 1000, newTickUpper: cur + 1000, swapAmount: 0,
            minSwapOut: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        (, uint128 liq2, int24 tl2,,,) = vault.positions(id);
        assertGt(liq2, 0, "re-ranged");
        assertEq(tl2, cur - 1000, "new range");
        (uint256 wDebt3,) = lending.getCurrentDebt(dW);
        assertEq(wDebt3, wDebt, "debt untouched by rebalance");

        // increase:追加 500 USDG 保证金 + 2x(真池上验证加仓路径,v1.2 新功能)
        deal(USDG, user, 500e6);
        vm.startPrank(user);
        (, uint128 liqBeforeInc,,,,) = vault.positions(id);
        vault.increase(id, UniV3DualVault.IncreaseParams({
            investRisk: 0, investLoan: 500e6,
            borrowRisk: (250e6 * 1e18) / ethPx, borrowLoan: 250e6,
            amount0Min: 0, amount1Min: 0, minLiquidity: 1, deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        (, uint128 liqAfterInc,,,,) = vault.positions(id);
        assertGt(liqAfterInc, liqBeforeInc, "increase grew liquidity on real pool");

        // harvest 双模式(真池上刚换过区间,fee 可能为 0——验证两模式都不 revert 且记账一致)
        vm.startPrank(user);
        (uint256 hc0, uint256 hc1) = vault.harvest(id, false, block.timestamp + 1);
        emit log_named_uint("harvest claim fee0", hc0);
        emit log_named_uint("harvest claim fee1", hc1);
        vault.harvest(id, true, block.timestamp + 1); // compound(fee=0 时为 no-op,但健康检查照跑)
        vm.stopPrank();
        (, uint128 liqH,,,,) = vault.positions(id);
        assertGt(liqH, 0, "position intact after harvest");

        // 全平:preview 缺口 → 真 exactOutput 补(或 topUp=0 走盈余互补)
        vm.startPrank(user);
        (,,,, uint256 shortR, uint256 shortL) = vault.previewClose(id, 10000);
        emit log_named_uint("preview shortRisk", shortR);
        emit log_named_uint("preview shortLoan", shortL);
        vault.close(id, UniV3DualVault.CloseParams({
            percent: 10000, topUpRisk: 0, topUpLoan: 0, maxSwapIn: type(uint256).max,
            minOutRisk: 0, minOutLoan: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        (uint256 wEnd,) = lending.getCurrentDebt(dW);
        (uint256 uEnd,) = lending.getCurrentDebt(dU);
        assertLe(oracle.riskValueInLoan(wEnd), 1e3, "WETH debt cleared (value dust ok)");
        assertLe(uEnd, 1_000, "USDG debt cleared (dust ok)");
        assertEq(vault.ownerOf(id), address(0), "receipt burned");
        assertEq(IERC20f(WETH).balanceOf(address(vault)), 0, "vault clean WETH");
        assertEq(IERC20f(USDG).balanceOf(address(vault)), 0, "vault clean USDG");
        emit log("FULL dual e2e on real RH V3 pool: open->margin->rebalance->close");
    }

}
