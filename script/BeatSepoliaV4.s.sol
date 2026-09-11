// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  BeatSepoliaV4 — Sepolia 真链暴打 harness,V4 版(真 Uniswap v4 PoolManager/PositionManager/Permit2)。
  波次与 V3 版同构:storm/churn/drift/crash/adversarial/donate/reseed/audit(WAVE 环境变量)。
  与 V3 版的差异:
    · 价格读 StateView.getSlot0(poolId);
    · drift 用 PoolSwapTest 在 V4 池上真 swap(带目标价 sqrtPriceLimit 硬限);
    · reseed 经 Permit2 走真 PositionManager mint。
  环境变量:V4_VAULT / LENDING / ORACLE / WETH_M / USDG_M / ETH_FEED。
*/

import {Script, console2} from "forge-std/Script.sol";
import {UniV4DualVault} from "../src/UniV4DualVault.sol";
import {LpShareOracleV4} from "../src/LpShareOracleV4.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {FairLpMath} from "../src/libraries/FairLpMath.sol";
import {PoolKey, Currency, IHooks, IV4PositionManager, V4Encode} from "../src/v4/V4Periphery.sol";
import {MockERC20, MockFeedOwned} from "./testnet/TestnetMocks.sol";

interface IStateViewMin {
    function getSlot0(bytes32 poolId)
        external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

interface IPoolSwapTest {
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
    struct TestSettings { bool takeClaims; bool settleUsingBurn; }
    function swap(PoolKey memory key, SwapParams memory params, TestSettings memory testSettings, bytes memory hookData)
        external payable returns (int256);
}

interface IPermit2Min {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract BeatSepoliaV4 is Script {
    address constant STATE_VIEW = 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C;
    address constant SWAP_TEST = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe;
    address constant POSM = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint160 constant MIN_SQRT = 4295128739;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    UniV4DualVault vault;
    LendingPool lending;
    LpShareOracleV4 oracle;
    MockERC20 weth;
    MockERC20 usdg;
    MockFeedOwned ethFeed;
    bytes32 poolId;
    uint256 seed;

    function _rand(uint256 mod_) internal returns (uint256) {
        seed = uint256(keccak256(abi.encode(seed, mod_)));
        return seed % mod_;
    }

    function _key() internal view returns (PoolKey memory) {
        (address t0, address t1) = address(weth) < address(usdg)
            ? (address(weth), address(usdg)) : (address(usdg), address(weth));
        return PoolKey({
            currency0: Currency.wrap(t0), currency1: Currency.wrap(t1),
            fee: 100, tickSpacing: 1, hooks: IHooks(address(0))
        });
    }

    function _slot0() internal view returns (uint160 sp, int24 tick) {
        (sp, tick,,) = IStateViewMin(STATE_VIEW).getSlot0(poolId);
    }

    function _ethPxFromPool() internal view returns (uint256 px8) {
        (uint160 sp,) = _slot0();
        uint256 ratioX96 = FullMath.mulDiv(uint256(sp), uint256(sp), 1 << 96);
        if (vault.LOAN_IS_C0()) {
            px8 = FullMath.mulDiv(1e20, 1 << 96, ratioX96);
        } else {
            px8 = FullMath.mulDiv(ratioX96, 1e20, 1 << 96);
        }
    }

    function _syncFeedToPool() internal {
        uint256 px8 = _ethPxFromPool();
        ethFeed.setPrice(int256(px8));
        console2.log("feed synced to pool px8", px8);
    }

    function run() external {
        vault = UniV4DualVault(vm.envAddress("V4_VAULT"));
        lending = LendingPool(payable(vm.envAddress("LENDING")));
        oracle = LpShareOracleV4(vm.envAddress("ORACLE"));
        weth = MockERC20(vm.envAddress("WETH_M"));
        usdg = MockERC20(vm.envAddress("USDG_M"));
        ethFeed = MockFeedOwned(vm.envAddress("ETH_FEED"));
        poolId = keccak256(abi.encode(_key()));
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

    function _storm() internal {
        uint256 n = vm.envOr("N", uint256(4));
        vm.startBroadcast();
        weth.mint(msg.sender, 1000e18);
        usdg.mint(msg.sender, 5_000_000e6);
        weth.approve(address(vault), type(uint256).max);
        usdg.approve(address(vault), type(uint256).max);
        (, int24 cur) = _slot0();
        uint256 ethPx = oracle.riskValueInLoan(1e18);
        for (uint256 i = 0; i < n; i++) {
            uint256 investU = (500 + _rand(4500)) * 1e6;
            uint256 investW = _rand(3) == 0 ? (_rand(10) + 1) * 1e17 : 0;
            uint256 equity = investU + FullMath.mulDiv(investW, ethPx, 1e18);
            uint256 levBps = 15000 + _rand(20000);
            uint256 borrowVal = FullMath.mulDiv(equity, levBps - 10000, 10000);
            int24 half = int24(int256(150 + _rand(2000)));
            try vault.open(UniV4DualVault.OpenParams({
                investRisk: investW, investLoan: investU,
                borrowRisk: FullMath.mulDiv(borrowVal / 2, 1e18, ethPx), borrowLoan: borrowVal / 2,
                tickLower: cur - half, tickUpper: cur + half,
                amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
                deadline: block.timestamp + 1800
            })) returns (uint256 id) {
                console2.log("opened", id);
                console2.log("  equityUSDG/levBps/halfWidth", equity, levBps, uint256(int256(half)));
            } catch Error(string memory reason) { console2.log("open rejected:", reason); }
            catch (bytes memory) { console2.log("open rejected (custom err)"); }
        }
        vm.stopBroadcast();
    }

    function _churn() internal {
        uint256 top = vault.nextPositionId();
        vm.startBroadcast();
        usdg.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        (, int24 cur) = _slot0();
        for (uint256 id = 1; id < top; id++) {
            if (vault.ownerOf(id) != msg.sender) continue;
            uint256 dice = _rand(3);
            if (dice == 0) {
                try vault.addMargin(id, _rand(2) == 0 ? (_rand(5) + 1) * 1e16 : 0, (50 + _rand(300)) * 1e6) {
                    console2.log("margin+", id);
                } catch { console2.log("margin rej", id); }
            } else if (dice == 1) {
                uint16 pct = uint16(2500 + _rand(5000));
                try vault.close(id, UniV4DualVault.CloseParams({
                    percent: pct, topUpRisk: 0, topUpLoan: 0,
                    maxSwapIn: type(uint256).max, minOutRisk: 0, minOutLoan: 0,
                    zapPath: "", deadline: block.timestamp + 1800
                })) { console2.log("partial close", id, uint256(pct)); }
                catch { console2.log("close rej", id); }
            } else {
                int24 half = int24(int256(150 + _rand(1500)));
                try vault.rebalance(id, UniV4DualVault.RebalanceParams({
                    newTickLower: cur - half, newTickUpper: cur + half, swapAmount: 0,
                    minSwapOut: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1800
                })) { console2.log("rebalanced", id); }
                catch { console2.log("rebalance rej", id); }
            }
        }
        vm.stopBroadcast();
    }

    function _drift() internal {
        uint256 pct = vm.envOr("PCT", uint256(10));
        bool down = keccak256(bytes(vm.envOr("DIR", string("down")))) == keccak256("down");
        uint256 px8 = _ethPxFromPool();
        uint256 target = down ? px8 * (100 - pct) / 100 : px8 * (100 + pct) / 100;
        bool c0IsLoan = vault.LOAN_IS_C0();
        uint160 sqrtTarget = c0IsLoan
            ? FairLpMath.sqrtPriceX96FromFeeds(1e8, target, 6, 18)
            : FairLpMath.sqrtPriceX96FromFeeds(target, 1e8, 18, 6);
        vm.startBroadcast();
        weth.approve(SWAP_TEST, type(uint256).max);
        usdg.approve(SWAP_TEST, type(uint256).max);
        for (uint256 i = 0; i < 8; i++) {
            uint256 nowPx = _ethPxFromPool();
            if (nowPx * 1000 <= target * 1005 && nowPx * 1005 >= target * 1000) break;
            (uint160 spNow,) = _slot0();
            // ETH 跌 = raw price(c1/c0) 涨(c0=USDG 时) → zeroForOne=false;涨反之。按 sqrt 目标定方向。
            bool zeroForOne = sqrtTarget < spNow;
            if (zeroForOne) {
                // 卖 c0:c0 是 USDG 就 mint USDG,是 WETH 就 mint WETH
                if (c0IsLoan) usdg.mint(msg.sender, 200_000e6); else weth.mint(msg.sender, 100e18);
            } else {
                if (c0IsLoan) weth.mint(msg.sender, 100e18); else usdg.mint(msg.sender, 200_000e6);
            }
            IPoolSwapTest(SWAP_TEST).swap(
                _key(),
                IPoolSwapTest.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: zeroForOne ? -int256(c0IsLoan ? uint256(200_000e6) : 100e18)
                                                : -int256(c0IsLoan ? uint256(100e18) : 200_000e6),
                    sqrtPriceLimitX96: sqrtTarget
                }),
                IPoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        _syncFeedToPool();
        vm.stopBroadcast();
    }

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
            for (uint256 round = 0; round < 6; round++) {
                if (vault.isHealthy(id)) break;
                try vault.liquidate(id, UniV4DualVault.LiquidateParams({
                    ratioBps: cf, minSeizeValue: 0, deadline: block.timestamp + 1800
                })) returns (bool fully) {
                    console2.log("liquidated", id, round, fully ? 1 : 0);
                    if (fully) break;
                } catch { console2.log("liq rej", id); break; }
            }
        }
        vm.stopBroadcast();
    }

    function _adversarial() internal {
        uint256 top = vault.nextPositionId();
        uint256 victim = 0;
        for (uint256 id = 1; id < top; id++) {
            if (vault.ownerOf(id) == msg.sender) { victim = id; break; }
        }
        require(victim != 0, "need a live position (run storm first)");

        vm.startPrank(msg.sender);
        bytes memory evilPath = abi.encodePacked(address(usdg), uint24(500), address(0xDEAD), uint24(500), address(weth));
        (,,,, uint256 vDR, uint256 vDL) = vault.positions(victim);
        try vault.close(victim, UniV4DualVault.CloseParams({
            percent: 10000, topUpRisk: 0, topUpLoan: 0,
            maxSwapIn: type(uint256).max, minOutRisk: 0, minOutLoan: 0,
            zapPath: evilPath, deadline: block.timestamp + 1800
        })) {
            (uint256 rR,) = lending.getCurrentDebt(vDR);
            (uint256 rL,) = lending.getCurrentDebt(vDL);
            require(rR <= 1e4 && rL <= 1e4, "ADV-A FAIL: evil path left lender loss");
            console2.log("ADV-A ok: evil path unused/neutralized, lenders whole");
        } catch { console2.log("ADV-A ok: evil zapPath rejected"); }
        vm.stopPrank();

        vm.startPrank(address(0xBEEF));
        try vault.liquidate(victim, UniV4DualVault.LiquidateParams({ratioBps: 1000, minSeizeValue: 0, deadline: block.timestamp + 1800})) {
            revert("ADV-B FAIL: stranger liquidated");
        } catch { console2.log("ADV-B ok: stranger liquidation rejected"); }
        try vault.close(victim, UniV4DualVault.CloseParams({
            percent: 10000, topUpRisk: 0, topUpLoan: 0,
            maxSwapIn: type(uint256).max, minOutRisk: 0, minOutLoan: 0,
            zapPath: "", deadline: block.timestamp + 1800
        })) { revert("ADV-D FAIL: stranger closed others position"); }
        catch { console2.log("ADV-D ok: stranger close rejected"); }
        vm.stopPrank();

        if (vault.isHealthy(victim)) {
            vm.startPrank(msg.sender);
            try vault.liquidate(victim, UniV4DualVault.LiquidateParams({ratioBps: 1000, minSeizeValue: 0, deadline: block.timestamp + 1800})) {
                revert("ADV-C FAIL: liquidated a healthy position");
            } catch { console2.log("ADV-C ok: healthy position not liquidatable"); }
            vm.stopPrank();
        }
        console2.log("adversarial simulation assertions all passed");
    }

    function _donate() internal {
        vm.startBroadcast();
        usdg.mint(msg.sender, 10_000e6);
        weth.mint(msg.sender, 10e18);
        uint256 vaultU0 = usdg.balanceOf(address(vault));
        usdg.transfer(address(vault), 5_000e6);
        weth.transfer(address(vault), 1e18);
        usdg.approve(address(vault), type(uint256).max);
        weth.approve(address(vault), type(uint256).max);
        (, int24 cur) = _slot0();
        uint256 ethPx = oracle.riskValueInLoan(1e18);
        uint256 id = vault.open(UniV4DualVault.OpenParams({
            investRisk: 0, investLoan: 1_000e6, borrowRisk: (1_000e6 * 1e18) / ethPx, borrowLoan: 0,
            tickLower: cur - 1000, tickUpper: cur + 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            deadline: block.timestamp + 1800
        }));
        vault.close(id, UniV4DualVault.CloseParams({
            percent: 10000, topUpRisk: 0, topUpLoan: 0,
            maxSwapIn: type(uint256).max, minOutRisk: 0, minOutLoan: 0,
            zapPath: "", deadline: block.timestamp + 1800
        }));
        uint256 vaultU1 = usdg.balanceOf(address(vault));
        console2.log("donation stays in vault (USDG before/after)", vaultU0, vaultU1);
        require(vaultU1 >= vaultU0 + 5_000e6 - 1e6, "DONATE FAIL: vault lost donated USDG");
        vm.stopBroadcast();
    }

    function _reseed() internal {
        vm.startBroadcast();
        weth.mint(msg.sender, 500e18);
        usdg.mint(msg.sender, 1_500_000e6);
        weth.approve(PERMIT2, type(uint256).max);
        usdg.approve(PERMIT2, type(uint256).max);
        IPermit2Min(PERMIT2).approve(address(weth), POSM, type(uint160).max, type(uint48).max);
        IPermit2Min(PERMIT2).approve(address(usdg), POSM, type(uint160).max, type(uint48).max);
        (, int24 tick) = _slot0();
        IV4PositionManager(POSM).modifyLiquidities(
            V4Encode.mint(_key(), tick - 15000, tick + 15000, 5e15, type(uint128).max, type(uint128).max, msg.sender),
            block.timestamp + 1800
        );
        console2.log("reseeded v4 liquidity around tick", tick);
        vm.stopBroadcast();
    }

    function _audit() internal view {
        uint256 top = vault.nextPositionId();
        uint256 live; uint256 unhealthy;
        for (uint256 id = 1; id < top; id++) {
            if (vault.ownerOf(id) == address(0)) {
                (,,,, uint256 dR, uint256 dL) = vault.positions(id);
                if (dR != 0 || dL != 0) {
                    (uint256 oR,) = lending.getCurrentDebt(dR);
                    (uint256 oL,) = lending.getCurrentDebt(dL);
                    if (oR > 1e4 || oL > 1e4) console2.log("!! ORPHAN BAD DEBT id", id, oR, oL);
                }
                continue;
            }
            live++;
            bool h = vault.isHealthy(id);
            if (!h) unhealthy++;
            console2.log("pos", id, vault.positionValue(id), vault.totalDebtInLoan(id));
            console2.log("  healthy", h);
        }
        console2.log("live/unhealthy", live, unhealthy);
        console2.log("vault residual WETH", weth.balanceOf(address(vault)));
        console2.log("vault residual USDG", usdg.balanceOf(address(vault)));
        console2.log("reserve USDG availLiq", usdg.balanceOf(lending.getETokenAddress(1)));
        console2.log("reserve WETH availLiq", weth.balanceOf(lending.getETokenAddress(2)));
    }
}
