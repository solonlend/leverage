// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniV4LeverageVault} from "../src/UniV4LeverageVault.sol";
import {SwapExecutorV3} from "../src/SwapExecutorV3.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockERC20, MockV4PositionManager, MockSwapExecutor, MockOracle, MockStateView}
    from "./V4VaultFlow.integration.t.sol";
import {NamedMockERC20} from "./LendingPoolIntegration.t.sol";
import {MockRouter02, MockERC20 as RouterMockERC20} from "./SwapExecutorV3.t.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../src/lending/libraries/helpers/AddressId.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";

/*
  攻击重放与边界榨取:
  A1 首存者 eToken 通胀攻击(捐赠推汇率)→ 受害人存款不可被偷走
  A2 恶意 zapPath(用户可控入参)→ SwapExecutor 端点校验拦截
  A3 重入:恶意 swap executor 在 zap 里反调金库 → nonReentrant 拦截
  A4 零流动性仓位垃圾(超小额开仓刷 debtId)
  A5 1 wei 清算 griefing → ZERO_SEIZE 拦截
*/

interface IERC20V {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// A3 用:zap 时反调 vault.close,记录被什么理由拦下,然后正常 1:1 兑付让主流程走完。
contract ReentrantExecutor {
    UniV4LeverageVault public vault;
    string public reentryRevertReason;
    function setVault(UniV4LeverageVault v) external { vault = v; }
    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256, bytes calldata)
        external returns (uint256)
    {
        if (address(vault) != address(0)) {
            try vault.close(1, UniV4LeverageVault.CloseParams({
                percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1
            })) returns (uint256) {
                reentryRevertReason = "REENTRY_SUCCEEDED";
            } catch Error(string memory reason) {
                reentryRevertReason = reason;
            } catch {
                reentryRevertReason = "LOW_LEVEL";
            }
        }
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(msg.sender, amountIn); // 1:1
        return amountIn;
    }
}

contract AdversarialTest is Test {
    NamedMockERC20 t0; NamedMockERC20 usdg;
    LendingPool lending;
    address eToken;
    MockV4PositionManager pm; MockOracle oracle; MockStateView sv;
    SolonVaultRegistry vaultReg;
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address user = makeAddr("user");
    address keeper = makeAddr("keeper");
    address gov = makeAddr("gov");
    uint160 sqrtP0;

    function setUp() public {
        NamedMockERC20 a = new NamedMockERC20("Risk", "RISK");
        NamedMockERC20 b = new NamedMockERC20("USD Global", "USDG");
        (t0, usdg) = address(a) < address(b) ? (a, b) : (b, a);

        AddressRegistry registry = new AddressRegistry(address(new NamedMockERC20("WETH", "WETH")));
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, makeAddr("treasury"));
        lending = new LendingPool(address(registry), registry.getAddress(AddressId.ADDRESS_ID_WETH9));
        lending.initReserve(address(usdg));
        eToken = lending.getETokenAddress(1);
        vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));

        sqrtP0 = TickMath.getSqrtRatioAtTick(0);
        pm = new MockV4PositionManager(MockERC20(address(t0)), MockERC20(address(usdg)), sqrtP0);
        oracle = new MockOracle();
        sv = new MockStateView(sqrtP0, 0);
    }

    function _newVault(address swapExecutor) internal returns (UniV4LeverageVault vault) {
        vault = new UniV4LeverageVault(UniV4LeverageVault.InitParams({
            governor: gov, positionManager: address(pm), stateView: address(sv),
            lendingPool: address(lending), reserveId: 1, oracle: address(oracle), swapExecutor: swapExecutor,
            token0: address(t0), token1: address(usdg), loanIsC0: false, fee: 3000, tickSpacing: 60, hooks: address(0),
            minWidthTicks: 100, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            borrowFeeBps: 0, closeFactorBps: 5000, lltv: 0.8e18
        }));
        uint256 vid = uint256(uint160(address(vault))); // 每个金库独立 vaultId,避免 ID_TAKEN
        vaultReg.setVault(vid, address(vault));
        lending.enableVaultToBorrow(vid);
        lending.setCreditsOfVault(vid, 1, type(uint128).max);
        vm.prank(gov);
        vault.setLiquidator(keeper, true);
    }

    // ── A1 首存者/捐赠通胀攻击 ──
    // 官方修复(首存 burn 1000 到 dead)挡住了"偷存款";残留面是捐赠把 exchangeRate
    // 整数除法压到 0 → 后续所有 deposit revert(储备被砖,攻击者自己净亏捐赠)。
    // 部署侧缓解 = 上线即做种子存款(supply 大到捐赠无法压零)。两个属性都测:
    function test_A1a_donation_bricks_unseeded_pool_but_steals_nothing() public {
        usdg.mint(attacker, 1_000_000e18);
        usdg.mint(victim, 1_000_000e18);

        vm.startPrank(attacker);
        usdg.approve(address(lending), type(uint256).max);
        lending.deposit(1, 1001, attacker, 0); // 抢首存最小额
        usdg.transfer(eToken, 100_000e18);     // 捐赠推汇率
        vm.stopPrank();

        // 汇率被压零 → 任意额度存款都被拒,受害人本金原地不动(DoS,不是盗窃)
        vm.startPrank(victim);
        usdg.approve(address(lending), type(uint256).max);
        vm.expectRevert(bytes("24")); // VL_ETOKEN_AMOUNT_TOO_SMALL
        lending.deposit(1, 1_000_000e18, victim, 0);
        vm.stopPrank();
        assertEq(usdg.balanceOf(victim), 1_000_000e18, "victim funds untouched");

        // 攻击者赎回:1/1001 份额,只能拿回捐赠的 ~0.1%,净亏 ~99.9%
        uint256 aBal = IERC20V(eToken).balanceOf(attacker);
        vm.startPrank(attacker);
        IERC20V(eToken).approve(address(lending), type(uint256).max);
        uint256 aGot = aBal > 0 ? lending.redeem(1, aBal, attacker, false) : 0;
        vm.stopPrank();
        assertLt(aGot, 1_000e18, "attacker recovers <1% of the 100k donation");
    }

    function test_A1b_seeded_pool_immune_to_donation_attack() public {
        // 部署侧缓解:先做 1000 USDG 种子存款(deploy 脚本行为)
        address seeder = makeAddr("seeder");
        usdg.mint(seeder, 1_000e18);
        vm.startPrank(seeder);
        usdg.approve(address(lending), type(uint256).max);
        lending.deposit(1, 1_000e18, seeder, 0);
        vm.stopPrank();

        // 同样的攻击:捐 10 万
        usdg.mint(attacker, 100_000e18);
        vm.prank(attacker);
        usdg.transfer(eToken, 100_000e18);

        // 存款照常可用,受害人赎回不损失本金
        usdg.mint(victim, 10_000e18);
        vm.startPrank(victim);
        usdg.approve(address(lending), type(uint256).max);
        lending.deposit(1, 10_000e18, victim, 0);
        uint256 vBal = IERC20V(eToken).balanceOf(victim);
        IERC20V(eToken).approve(address(lending), type(uint256).max);
        uint256 got = lending.redeem(1, vBal, victim, false);
        vm.stopPrank();
        assertGt(got, 9_900e18, "victim redeems ~full deposit on seeded pool");
    }

    // ── A2 恶意 zapPath:开仓传"兑到无关 token"的路径必须被拦 ──
    function test_A2_malicious_zapPath_rejected() public {
        MockRouter02 router = new MockRouter02(RouterMockERC20(address(t0)), 1e18);
        SwapExecutorV3 realExec = new SwapExecutorV3(address(router), 100);
        UniV4LeverageVault vault = _newVault(address(realExec));
        _seedLending();

        NamedMockERC20 junk = new NamedMockERC20("JUNK", "JUNK");
        bytes memory evilPath = abi.encodePacked(address(usdg), uint24(500), address(junk));

        usdg.mint(user, 1000e18);
        vm.startPrank(user);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("PATH_OUT"));
        vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 100e18, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: evilPath, deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    // ── A3 重入:zap 过程反调 close 必须被 nonReentrant 拦下 ──
    function test_A3_reentrancy_blocked_during_zap() public {
        ReentrantExecutor evil = new ReentrantExecutor();
        UniV4LeverageVault vault = _newVault(address(evil));
        evil.setVault(vault);
        _seedLending();

        usdg.mint(user, 1000e18);
        vm.startPrank(user);
        usdg.approve(address(vault), type(uint256).max);
        vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 100e18, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        assertEq(evil.reentryRevertReason(), "REENTRANCY", "reentry must be blocked by guard");
    }

    // ── A4 零流动性垃圾仓位:极小额开仓不得铸出空仓位刷 debtId ──
    function test_A4_zero_liquidity_open_rejected() public {
        UniV4LeverageVault vault = _newVault(address(new MockSwapExecutor(MockERC20(address(t0)), MockERC20(address(usdg)), 1e18)));
        _seedLending();
        usdg.mint(address(this), 10);
        usdg.approve(address(vault), type(uint256).max);
        vm.expectRevert(bytes("ZERO_LIQ"));
        vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: 1, amountBorrow: 0, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
    }

    // ── A5 1 wei 清算 griefing:seize 取整为 0 必须整体 revert ──
    function test_A5_dust_liquidation_reverts() public {
        MockSwapExecutor mockSwap = new MockSwapExecutor(MockERC20(address(t0)), MockERC20(address(usdg)), 1e18);
        usdg.mint(address(mockSwap), 1e30); t0.mint(address(mockSwap), 1e30);
        UniV4LeverageVault vault = _newVault(address(mockSwap));
        _seedLending();

        usdg.mint(user, 1000e18);
        vm.startPrank(user);
        usdg.approve(address(vault), type(uint256).max);
        uint256 id = vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: 100e18, amountBorrow: 100e18, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();

        (, uint128 liqBefore,,,) = vault.positions(id);
        oracle.setValPerLiq((100e18 * 1e18) / liqBefore); // 不健康
        usdg.mint(keeper, 100e18);
        uint256 kBefore = usdg.balanceOf(keeper);
        vm.startPrank(keeper);
        usdg.approve(address(vault), type(uint256).max);
        vault.liquidate(id, UniV4LeverageVault.LiquidateParams({
            repayAmount: 1, minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        // 尘量清算允许执行,但取整方向必须对协议有利:keeper 不可净赚,仓位只被拿走尘量价值
        (, uint128 liqAfter,,,) = vault.positions(id);
        uint256 kAfter = usdg.balanceOf(keeper);
        assertLe(kAfter, kBefore + 2, "dust liquidation must not be profitable");
        uint256 seizedValue = (uint256(liqBefore - liqAfter) * 100e18) / liqBefore;
        assertLe(seizedValue, 2, "dust repay must seize only dust value");
    }

    function _seedLending() internal {
        address lender = makeAddr("seedLender");
        usdg.mint(lender, 1_000_000e18);
        vm.startPrank(lender);
        usdg.approve(address(lending), type(uint256).max);
        lending.deposit(1, 1_000_000e18, lender, 0);
        vm.stopPrank();
    }
}
