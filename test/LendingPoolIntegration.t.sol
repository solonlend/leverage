// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniV4LeverageVault} from "../src/UniV4LeverageVault.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockERC20, MockV4PositionManager, MockSwapExecutor, MockOracle, MockStateView}
    from "./V4VaultFlow.integration.t.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../src/lending/libraries/helpers/AddressId.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";

/// 集成测试:V4 金库 × 真 LendingPool(ExtraFi fork,原样复用)。
/// DEX 侧仍用 V4VaultFlow 的 mock(PM/swap/oracle),借贷侧全真:
/// initReserve → 出借人 deposit 吃息 → 金库白名单+授信 → open 真借款 → 计息 → close 真还款 → 出借人 redeem 赚息。

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// LendingPool.initReserve 需要 name/symbol/decimals(给 eToken 起名),V4VaultFlow 的裸 mock 没有,补上。
contract NamedMockERC20 is MockERC20 {
    string public name; string public symbol; uint8 public decimals = 18;
    constructor(string memory n, string memory s) { name = n; symbol = s; }
}

abstract contract LendingPoolIntegrationFixture is Test {
    NamedMockERC20 t0; NamedMockERC20 usdg;
    LendingPool lending;
    AddressRegistry registry;
    SolonVaultRegistry vaultReg;
    MockV4PositionManager pm; MockSwapExecutor swap; MockOracle oracle; MockStateView sv;
    UniV4LeverageVault vault;

    address user = makeAddr("user");
    address lender = makeAddr("lender");
    address treasury = makeAddr("treasury");
    address gov = makeAddr("gov");
    uint256 constant RESERVE_ID = 1;
    uint256 constant VAULT_ID = 1;
    uint256 constant LENDER_DEPOSIT = 100_000e18;

    function setUp() public {
        // 排序保证 risk=currency0 < loan=currency1(loanIsC0=false),币名只是外观
        NamedMockERC20 a = new NamedMockERC20("Risk", "RISK");
        NamedMockERC20 b = new NamedMockERC20("USD Global", "USDG");
        (t0, usdg) = address(a) < address(b) ? (a, b) : (b, a);

        // ── 真借贷侧:registry + pool + reserve + 我们的 vault 注册表(实现 IVaultFactory.vaults)──
        registry = new AddressRegistry(address(new NamedMockERC20("WETH", "WETH")));
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, treasury);
        lending = new LendingPool(address(registry), registry.getAddress(AddressId.ADDRESS_ID_WETH9));
        lending.initReserve(address(usdg));
        vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));

        // ── DEX mock 侧(与 V4VaultFlow 相同)──
        uint160 sqrtP0 = TickMath.getSqrtRatioAtTick(0);
        pm = new MockV4PositionManager(MockERC20(address(t0)), MockERC20(address(usdg)), sqrtP0);
        swap = new MockSwapExecutor(MockERC20(address(t0)), MockERC20(address(usdg)), 1e18);
        oracle = new MockOracle();
        sv = new MockStateView(sqrtP0, 0);

        vault = new UniV4LeverageVault(UniV4LeverageVault.InitParams({
            governor: gov, positionManager: address(pm), stateView: address(sv),
            lendingPool: address(lending), reserveId: RESERVE_ID, oracle: address(oracle), swapExecutor: address(swap),
            token0: address(t0), token1: address(usdg), loanIsC0: false, fee: 3000, tickSpacing: 60, hooks: address(0),
            minWidthTicks: 100, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            borrowFeeBps: 0, closeFactorBps: 5000, lltv: 0.8e18
        }));

        // 金库进白名单 + 授信(Extra 的 credit 机制:owner 给每个 vault 划借款额度)
        vaultReg.setVault(VAULT_ID, address(vault));
        lending.enableVaultToBorrow(VAULT_ID);
        lending.setCreditsOfVault(VAULT_ID, RESERVE_ID, type(uint128).max);

        // 出借人入金
        usdg.mint(lender, LENDER_DEPOSIT);
        vm.startPrank(lender);
        usdg.approve(address(lending), type(uint256).max);
        lending.deposit(RESERVE_ID, LENDER_DEPOSIT, lender, 0);
        vm.stopPrank();

        // swap mock 两边备货
        usdg.mint(address(swap), 1_000_000e18);
        t0.mint(address(swap), 1_000_000e18);
        usdg.mint(user, 10_000e18);
    }

    function _open(uint256 invest, uint256 borrow) internal returns (uint256 id) {
        vm.startPrank(user);
        usdg.approve(address(vault), type(uint256).max);
        id = vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: invest, amountBorrow: borrow, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }
}

contract LendingPoolIntegrationTest is LendingPoolIntegrationFixture {
    /// 开仓从真池借款:债务上账、储备可用流动性下降、LP 铸出。
    function test_open_borrowsFromRealPool() public {
        uint256 id = _open(1000e18, 2000e18);
        (, uint128 liq,,, uint256 debtId) = vault.positions(id);
        assertGt(liq, 0, "liquidity minted");
        (uint256 debt,) = lending.getCurrentDebt(debtId);
        assertEq(debt, 2000e18, "debt == borrowed");
        // 借走的 USDG 离开 eToken 金库
        address eToken = lending.getETokenAddress(RESERVE_ID);
        assertEq(usdg.balanceOf(eToken), LENDER_DEPOSIT - 2000e18, "reserve liquidity reduced");
    }

    /// 时间流逝 → 债务按借款利率指数增长。
    function test_debt_accruesInterest() public {
        uint256 id = _open(1000e18, 2000e18);
        (,,,, uint256 debtId) = vault.positions(id);
        vm.warp(block.timestamp + 365 days);
        (uint256 debt,) = lending.getCurrentDebt(debtId);
        assertGt(debt, 2000e18, "interest accrued");
        assertLt(debt, 2100e18, "low utilization => low rate");
    }

    /// 全平:连本带息还给真池,债务清零,出借人 redeem 拿回本金+利息。
    function test_close_repaysWithInterest_lenderEarns() public {
        uint256 id = _open(1000e18, 2000e18);
        (,,,, uint256 debtId) = vault.positions(id);
        vm.warp(block.timestamp + 365 days);

        vm.prank(user);
        uint256 out = vault.close(id, UniV4LeverageVault.CloseParams({
            percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        (uint256 debt,) = lending.getCurrentDebt(debtId);
        assertEq(debt, 0, "debt cleared");
        assertGt(out, 0, "user residual after repay");
        assertLt(out, 1000e18, "residual < principal (paid interest)");

        // 出借人退出:eToken 全额赎回 > 本金(利息落袋,扣掉 15% reserveFee 后仍为正)
        address eToken = lending.getETokenAddress(RESERVE_ID);
        vm.startPrank(lender);
        IERC20View(eToken).approve(address(lending), type(uint256).max);
        uint256 got = lending.redeem(RESERVE_ID, type(uint256).max, lender, false);
        vm.stopPrank();
        assertGt(got, LENDER_DEPOSIT, "lender earned interest");
    }

    function test_pause_blocks_new_borrow_and_open() public {
        uint256 id = _open(1000e18, 2000e18);
        (,,,, uint256 debtId) = vault.positions(id);

        usdg.mint(user, 1000e18);
        vm.prank(user);
        usdg.approve(address(vault), type(uint256).max);
        lending.emergencyPauseAll();

        vm.startPrank(address(vault));
        vm.expectRevert(bytes("83"));
        lending.borrow(address(vault), debtId, 1e18);
        vm.stopPrank();

        vm.startPrank(user);
        vm.expectRevert(bytes("83"));
        vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: 1000e18, amountBorrow: 2000e18, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
    }

    function test_pause_allows_close_after_vault_is_disabled() public {
        uint256 id = _open(1000e18, 2000e18);
        (,,,, uint256 debtId) = vault.positions(id);
        lending.emergencyPauseAll();
        lending.disableVaultToBorrow(VAULT_ID);

        vm.prank(user);
        vault.close(id, UniV4LeverageVault.CloseParams({
            percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1
        }));

        (uint256 debt,) = lending.getCurrentDebt(debtId);
        assertEq(debt, 0, "paused close repaid debt");
    }

    function test_pause_blocks_redeem() public {
        lending.emergencyPauseAll();
        address eToken = lending.getETokenAddress(RESERVE_ID);
        vm.startPrank(lender);
        IERC20View(eToken).approve(address(lending), type(uint256).max);
        vm.expectRevert(bytes("83"));
        lending.redeem(RESERVE_ID, type(uint256).max, lender, false);
        vm.stopPrank();
    }

    function test_pause_allows_risk_reducing_admin_actions_only() public {
        lending.emergencyPauseAll();

        lending.disableVaultToBorrow(VAULT_ID);
        assertFalse(lending.borrowingWhiteList(address(vault)), "vault disabled");
        vm.expectRevert(bytes("83"));
        lending.enableVaultToBorrow(VAULT_ID);

        lending.setCreditsOfVault(VAULT_ID, RESERVE_ID, 1e18);
        assertEq(lending.credits(RESERVE_ID, address(vault)), 1e18, "credit lowered");
        vm.expectRevert(bytes("83"));
        lending.setCreditsOfVault(VAULT_ID, RESERVE_ID, 2e18);

        lending.freezeReserve(RESERVE_ID);
        vm.expectRevert(bytes("83"));
        lending.unFreezeReserve(RESERVE_ID);

        lending.disableBorrowing(RESERVE_ID);
        vm.expectRevert(bytes("83"));
        lending.enableBorrowing(RESERVE_ID);

        lending.setReserveCapacity(RESERVE_ID, LENDER_DEPOSIT);
        vm.expectRevert(bytes("83"));
        lending.setReserveCapacity(RESERVE_ID, LENDER_DEPOSIT + 1);

        vm.expectRevert(bytes("83"));
        lending.deActivateReserve(RESERVE_ID);
    }
}
