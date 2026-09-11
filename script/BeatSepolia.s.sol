// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  BeatSepolia — Sepolia 真链暴打 harness。按 WAVE 环境变量分波打:

    WAVE=storm  N=6      随机参数开 N 个仓(杠杆 1.5~3.5x,宽窄带,单/双侧本金)
    WAVE=churn           对存活仓位轮流:补保证金 / 部分平仓 / 换区间
    WAVE=drift  PCT=10 DIR=down   真 swap 推池价 ±PCT% 并同步喂价(池-喂价保持一致)
    WAVE=crash  PCT=30   暴跌 PCT% 后清算所有不健康仓位(closeFactor 循环打到健康/清空)
    WAVE=adversarial     恶意路径平仓/陌生人清算/清算健康仓/预言机停摆——全部只做模拟断言(expect revert,不广播)
    WAVE=donate          真实捐赠攻击:直接打币进金库再开/平,验证不可被卷走
    WAVE=audit           全仓位体检:价值/债务/健康度 + 金库残留余额 + eToken 汇率,只读

  地址从 .testnet/sepolia.env 对应的环境变量读。真链每笔都是真 tx,gas 由部署者付。
*/

import {Script, console2} from "forge-std/Script.sol";
import {UniV3DualVault} from "../src/UniV3DualVault.sol";
import {LpShareOracleV4} from "../src/LpShareOracleV4.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {FairLpMath} from "../src/libraries/FairLpMath.sol";
import {MockERC20, MockFeedOwned} from "./testnet/TestnetMocks.sol";

interface IV3PoolLike {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

interface INfpmMint {
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    function mint(MintParams calldata) external payable
        returns (uint256, uint128, uint256, uint256);
}

interface IRouter02 {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

contract BeatSepolia is Script {
    UniV3DualVault vault;
    LendingPool lending;
    LpShareOracleV4 oracle;
    MockERC20 weth;
    MockERC20 usdg;
    MockFeedOwned ethFeed;
    address pool;
    address router;
    uint256 seed;

    function _rand(uint256 mod_) internal returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed, mod_)));
        return seed % mod_;
    }

    function _ethPxFromPool() internal view returns (uint256 px8) {
        (uint160 sp,,,,,,) = IV3PoolLike(pool).slot0();
        // 两步 mulDiv 防 sp^2 溢出(极端 tick 下 sp 接近 2^160,平方会爆 uint256)
        uint256 ratioX96 = FullMath.mulDiv(uint256(sp), uint256(sp), 1 << 96);
        // 8 位小数 USD 价:USDG=1$。两种排序分别换算
        if (vault.LOAN_IS_C0()) {
            px8 = FullMath.mulDiv(1e20, 1 << 96, ratioX96); // t0=USDG(6),t1=WETH(18)
        } else {
            px8 = FullMath.mulDiv(ratioX96, 1e20, 1 << 96); // t0=WETH(18),t1=USDG(6)
        }
    }

    function _syncFeedToPool() internal {
        uint256 px8 = _ethPxFromPool();
        ethFeed.setPrice(int256(px8));
        console2.log("feed synced to pool px8", px8);
    }

    function run() external {
        vault = UniV3DualVault(vm.envAddress("VAULT"));
        lending = LendingPool(payable(vm.envAddress("LENDING")));
        oracle = LpShareOracleV4(vm.envAddress("ORACLE"));
        weth = MockERC20(vm.envAddress("WETH_M"));
        usdg = MockERC20(vm.envAddress("USDG_M"));
        ethFeed = MockFeedOwned(vm.envAddress("ETH_FEED"));
        pool = vm.envAddress("POOL_M");
        router = vm.envAddress("ROUTER_M");
        seed = vm.envOr("SEED", uint256(blockhash(block.number - 1) != bytes32(0) ? uint256(blockhash(block.number - 1)) : 42));

        string memory wave = vm.envString("WAVE");
        bytes32 w = keccak256(bytes(wave));
        if (w == keccak256("storm")) _storm();
        else if (w == keccak256("churn")) _churn();
        else if (w == keccak256("drift")) _drift();
        else if (w == keccak256("crash")) _crash();
        else if (w == keccak256("adversarial")) _adversarial();
        else if (w == keccak256("donate")) _donate();
        else if (w == keccak256("reseed")) _reseed();
        else if (w == keccak256("audit")) _audit();
        else revert("UNKNOWN_WAVE");
    }

    // ── W1 随机开仓风暴 ──────────────────────────────────────────────
    function _storm() internal {
        uint256 n = vm.envOr("N", uint256(6));
        vm.startBroadcast();
        weth.mint(msg.sender, 1000e18);
        usdg.mint(msg.sender, 5_000_000e6);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        (, int24 cur,,,,,) = IV3PoolLike(pool).slot0();
        uint256 ethPx = oracle.riskValueInLoan(1e18);

        for (uint256 i = 0; i < n; i++) {
            uint256 investU = (500 + _rand(4500)) * 1e6;          // 500~5000 USDG
            uint256 investW = _rand(3) == 0 ? (_rand(10) + 1) * 1e17 : 0; // 1/3 概率带 0.1~1 WETH
            uint256 equity = investU + FullMath.mulDiv(investW, ethPx, 1e18);
            uint256 levBps = 15000 + _rand(20000);                // 1.5x~3.5x
            uint256 borrowVal = FullMath.mulDiv(equity, levBps - 10000, 10000);
            uint256 borrowW = FullMath.mulDiv(borrowVal / 2, 1e18, ethPx);
            uint256 borrowU = borrowVal / 2;
            int24 half = int24(int256(150 + _rand(2000)));        // 半宽 150~2150 tick
            try vault.open(UniV3DualVault.OpenParams({
                investRisk: investW, investLoan: investU, borrowRisk: borrowW, borrowLoan: borrowU,
                tickLower: cur - half, tickUpper: cur + half,
                amount0Min: 0, amount1Min: 0, minLiquidity: 0, deadline: block.timestamp + 1800
            })) returns (uint256 id) {
                console2.log("opened", id);
                console2.log("  equityUSDG/levBps/halfWidth", equity, levBps, uint256(int256(half)));
            } catch Error(string memory reason) {
                console2.log("open rejected:", reason); // 过高杠杆被 UNHEALTHY_OPEN 拒是预期行为
            } catch (bytes memory) {
                console2.log("open rejected (custom err)");
            }
        }
        vm.stopBroadcast();
    }

    // ── W2 存量仓位搅拌 ──────────────────────────────────────────────
    function _churn() internal {
        uint256 top = vault.nextPositionId();
        vm.startBroadcast();
        usdg.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        (, int24 cur,,,,,) = IV3PoolLike(pool).slot0();
        for (uint256 id = 1; id < top; id++) {
            if (vault.ownerOf(id) != msg.sender) continue;
            uint256 dice = _rand(3);
            if (dice == 0) {
                uint256 aU = (50 + _rand(300)) * 1e6;
                uint256 aW = _rand(2) == 0 ? (_rand(5) + 1) * 1e16 : 0;
                try vault.addMargin(id, aW, aU) { console2.log("margin+", id); }
                catch Error(string memory r) { console2.log("margin rej", id, r); }
                catch (bytes memory) { console2.log("margin rej (custom)", id); }
            } else if (dice == 1) {
                uint16 pct = uint16(2500 + _rand(5000)); // 25%~75%
                try vault.close(id, UniV3DualVault.CloseParams({
                    percent: pct, topUpRisk: 0, topUpLoan: 0,
                    maxSwapIn: type(uint256).max, minOutRisk: 0, minOutLoan: 0,
                    zapPath: "", deadline: block.timestamp + 1800
                })) { console2.log("partial close", id, uint256(pct)); }
                catch Error(string memory r) { console2.log("close rej", id, r); }
                catch (bytes memory) { console2.log("close rej (custom)", id); }
            } else {
                int24 half = int24(int256(150 + _rand(1500)));
                try vault.rebalance(id, UniV3DualVault.RebalanceParams({
                    newTickLower: cur - half, newTickUpper: cur + half, swapAmount: 0,
                    minSwapOut: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1800
                })) { console2.log("rebalanced", id); }
                catch Error(string memory r) { console2.log("rebalance rej", id, r); }
                catch (bytes memory) { console2.log("rebalance rej (custom)", id); }
            }
        }
        vm.stopBroadcast();
    }

    // ── W3 推价 + 喂价同步 ───────────────────────────────────────────
    function _drift() internal {
        uint256 pct = vm.envOr("PCT", uint256(10));
        bool down = keccak256(bytes(vm.envOr("DIR", string("down")))) == keccak256("down");
        uint256 px8 = _ethPxFromPool();
        vm.startBroadcast();
        // 二分逼近:用真 swap 把池价推到目标 ±0.5% 内(最多 12 步)
        uint256 target = down ? px8 * (100 - pct) / 100 : px8 * (100 + pct) / 100;
        // 目标 sqrtPrice 当硬限:swap 到线即停,永不打穿流动性带(上次真打穿过——MAX_TICK 教训)
        bool c0IsLoan = vault.LOAN_IS_C0();
        uint160 sqrtTarget = c0IsLoan
            ? FairLpMath.sqrtPriceX96FromFeeds(1e8, target, 6, 18)
            : FairLpMath.sqrtPriceX96FromFeeds(target, 1e8, 18, 6);
        for (uint256 i = 0; i < 12; i++) {
            uint256 nowPx = _ethPxFromPool();
            if (nowPx * 1000 <= target * 1005 && nowPx * 1005 >= target * 1000) break;
            bool pushDown = nowPx > target;
            if (pushDown) {
                uint256 amt = 40e18 + _rand(60e18);
                weth.mint(msg.sender, amt);
                weth.approve(router, amt);
                IRouter02(router).exactInputSingle(IRouter02.ExactInputSingleParams({
                    tokenIn: address(weth), tokenOut: address(usdg), fee: 100,
                    recipient: msg.sender, amountIn: amt, amountOutMinimum: 0, sqrtPriceLimitX96: sqrtTarget
                }));
            } else {
                uint256 amt = (80_000e6 + _rand(120_000e6));
                usdg.mint(msg.sender, amt);
                usdg.approve(router, amt);
                IRouter02(router).exactInputSingle(IRouter02.ExactInputSingleParams({
                    tokenIn: address(usdg), tokenOut: address(weth), fee: 100,
                    recipient: msg.sender, amountIn: amt, amountOutMinimum: 0, sqrtPriceLimitX96: sqrtTarget
                }));
            }
        }
        _syncFeedToPool();
        vm.stopBroadcast();
    }

    // ── W4 清算风暴 ─────────────────────────────────────────────────
    function _crash() internal {
        uint256 top = vault.nextPositionId();
        vm.startBroadcast();
        weth.mint(msg.sender, 500e18);
        usdg.mint(msg.sender, 2_000_000e6);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        uint256 cf = vault.CLOSE_FACTOR_BPS();
        for (uint256 id = 1; id < top; id++) {
            if (vault.ownerOf(id) == address(0)) continue;
            for (uint256 round = 0; round < 4; round++) {
                if (vault.isHealthy(id)) break;
                try vault.liquidate(id, UniV3DualVault.LiquidateParams({
                    ratioBps: cf, minSeizeValue: 0, deadline: block.timestamp + 1800
                })) returns (bool fully) {
                    console2.log("liquidated", id, round, fully ? 1 : 0);
                    if (fully) break;
                } catch Error(string memory r) { console2.log("liq rej", id, r); break; }
                catch (bytes memory) { console2.log("liq rej (custom)", id); break; }
            }
        }
        vm.stopBroadcast();
    }

    // ── W5 敌意断言(只模拟,不广播;真链状态上验证拒绝路径)────────────
    function _adversarial() internal {
        uint256 top = vault.nextPositionId();
        uint256 victim = 0;
        for (uint256 id = 1; id < top; id++) {
            if (vault.ownerOf(id) == msg.sender) { victim = id; break; }
        }
        require(victim != 0, "need a live position (run storm first)");

        // A. 恶意 zapPath 全平:E-1 修复后的正确断言是"要么拒绝,要么对出借人无损"
        //    (无缺口时 path 根本不被使用,平仓照常成功也是合法结果)
        vm.startPrank(msg.sender);
        bytes memory evilPath = abi.encodePacked(address(usdg), uint24(500), address(0xDEAD), uint24(500), address(weth));
        (,,,, uint256 vDR, uint256 vDL) = vault.positions(victim);
        try vault.close(victim, UniV3DualVault.CloseParams({
            percent: 10000, topUpRisk: 0, topUpLoan: 0,
            maxSwapIn: type(uint256).max, minOutRisk: 0, minOutLoan: 0,
            zapPath: evilPath, deadline: block.timestamp + 1800
        })) {
            (uint256 rR,) = lending.getCurrentDebt(vDR);
            (uint256 rL,) = lending.getCurrentDebt(vDL);
            require(rR <= 1e4 && rL <= 1e4, "ADV-A FAIL: evil path left lender loss");
            console2.log("ADV-A ok: evil path unused/neutralized, lenders whole");
        }
        catch { console2.log("ADV-A ok: evil zapPath rejected"); }
        vm.stopPrank();

        // B. 陌生人清算 → NotLiquidator
        address stranger = address(0xBEEF);
        vm.startPrank(stranger);
        try vault.liquidate(victim, UniV3DualVault.LiquidateParams({ratioBps: 1000, minSeizeValue: 0, deadline: block.timestamp + 1800})) {
            revert("ADV-B FAIL: stranger liquidated");
        } catch { console2.log("ADV-B ok: stranger liquidation rejected"); }
        vm.stopPrank();

        // C. 清算健康仓 → Healthy(用真 liquidator 身份)
        if (vault.isHealthy(victim)) {
            vm.startPrank(msg.sender);
            try vault.liquidate(victim, UniV3DualVault.LiquidateParams({ratioBps: 1000, minSeizeValue: 0, deadline: block.timestamp + 1800})) {
                revert("ADV-C FAIL: liquidated a healthy position");
            } catch { console2.log("ADV-C ok: healthy position not liquidatable"); }
            vm.stopPrank();
        }

        // D. 陌生人动别人的仓位 → NotHolder
        vm.startPrank(stranger);
        try vault.close(victim, UniV3DualVault.CloseParams({
            percent: 10000, topUpRisk: 0, topUpLoan: 0,
            maxSwapIn: type(uint256).max, minOutRisk: 0, minOutLoan: 0,
            zapPath: "", deadline: block.timestamp + 1800
        })) { revert("ADV-D FAIL: stranger closed others position"); }
        catch { console2.log("ADV-D ok: stranger close rejected"); }
        vm.stopPrank();
        console2.log("adversarial simulation assertions all passed");
    }

    // ── W6 捐赠攻击(真广播)──────────────────────────────────────────
    function _donate() internal {
        vm.startBroadcast();
        usdg.mint(msg.sender, 10_000e6);
        weth.mint(msg.sender, 10e18);
        uint256 vaultU0 = usdg.balanceOf(address(vault));
        uint256 vaultW0 = weth.balanceOf(address(vault));
        usdg.transfer(address(vault), 5_000e6); // 捐赠
        weth.transfer(address(vault), 1e18);
        // 捐赠后做一轮开+全平,退款不得多于本人应得(E6 基线快照防卷赠)
        usdg.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        (, int24 cur,,,,,) = IV3PoolLike(pool).slot0();
        uint256 ethPx = oracle.riskValueInLoan(1e18);
        uint256 myU0 = usdg.balanceOf(msg.sender);
        uint256 id = vault.open(UniV3DualVault.OpenParams({
            investRisk: 0, investLoan: 1_000e6, borrowRisk: (1_000e6 * 1e18) / ethPx, borrowLoan: 0,
            tickLower: cur - 1000, tickUpper: cur + 1000,
            amount0Min: 0, amount1Min: 0, minLiquidity: 0, deadline: block.timestamp + 1800
        }));
        vault.close(id, UniV3DualVault.CloseParams({
            percent: 10000, topUpRisk: 0, topUpLoan: 0,
            maxSwapIn: type(uint256).max, minOutRisk: 0, minOutLoan: 0,
            zapPath: "", deadline: block.timestamp + 1800
        }));
        uint256 myGain = usdg.balanceOf(msg.sender) + 1_000e6 - myU0; // 开仓投入退回后的净变化
        require(myGain <= 1_000e6 + 1e6, "DONATE FAIL: swept donated funds");
        uint256 vaultU1 = usdg.balanceOf(address(vault));
        console2.log("donation stays in vault (USDG before/after)", vaultU0, vaultU1);
        require(vaultU1 >= vaultU0 + 5_000e6 - 1e6, "DONATE FAIL: vault lost donated USDG");
        require(weth.balanceOf(address(vault)) >= vaultW0 + 1e18 - 1e12, "DONATE FAIL: vault lost donated WETH");
        vm.stopBroadcast();
    }

    // ── 补流动性:围绕当前 tick ±15000 灌宽带深度(砸价打穿后必跑)──────
    function _reseed() internal {
        vm.startBroadcast();
        weth.mint(msg.sender, 500e18);
        usdg.mint(msg.sender, 1_500_000e6);
        weth.approve(vm.envAddress("NFPM"), type(uint256).max);
        usdg.approve(vm.envAddress("NFPM"), type(uint256).max);
        (, int24 cur,,,,,) = IV3PoolLike(pool).slot0();
        (address t0, address t1) = address(weth) < address(usdg)
            ? (address(weth), address(usdg)) : (address(usdg), address(weth));
        INfpmMint(vm.envAddress("NFPM")).mint(INfpmMint.MintParams({
            token0: t0, token1: t1, fee: 100,
            tickLower: cur - 15000, tickUpper: cur + 15000,
            amount0Desired: t0 == address(weth) ? uint256(500e18) : 1_500_000e6,
            amount1Desired: t0 == address(weth) ? 1_500_000e6 : uint256(500e18),
            amount0Min: 0, amount1Min: 0,
            recipient: msg.sender, deadline: block.timestamp + 1800
        }));
        console2.log("reseeded liquidity around tick", cur);
        vm.stopBroadcast();
    }

    // ── W7 全面体检(只读)────────────────────────────────────────────
    function _audit() internal view {
        uint256 top = vault.nextPositionId();
        uint256 live; uint256 unhealthy; uint256 totalVal; uint256 totalDebt;
        for (uint256 id = 1; id < top; id++) {
            if (vault.ownerOf(id) == address(0)) {
                (,,,, uint256 dR, uint256 dL) = vault.positions(id);
                if (dR != 0 || dL != 0) {
                    (uint256 orphanR,) = lending.getCurrentDebt(dR);
                    (uint256 orphanL,) = lending.getCurrentDebt(dL);
                    if (orphanR > 1e4 || orphanL > 1e4) {
                        console2.log("!! ORPHAN BAD DEBT id", id, orphanR, orphanL);
                    }
                }
                continue;
            }
            live++;
            uint256 v = vault.positionValue(id);
            uint256 d = vault.totalDebtInLoan(id);
            totalVal += v; totalDebt += d;
            bool h = vault.isHealthy(id);
            if (!h) unhealthy++;
            console2.log("pos", id, v, d);
            console2.log("  healthy", h);
        }
        console2.log("live/unhealthy", live, unhealthy);
        console2.log("sum value/debt (USDG 6dp)", totalVal, totalDebt);
        console2.log("vault residual WETH", weth.balanceOf(address(vault)));
        console2.log("vault residual USDG", usdg.balanceOf(address(vault)));
        console2.log("reserve USDG availLiq", usdg.balanceOf(lending.getETokenAddress(1)));
        console2.log("reserve WETH availLiq", weth.balanceOf(lending.getETokenAddress(2)));
    }
}
