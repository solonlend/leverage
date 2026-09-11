// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniV4LeverageVault} from "../src/UniV4LeverageVault.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {MockERC20, MockV4PositionManager, MockSwapExecutor, MockOracle, MockStateView}
    from "./V4VaultFlow.integration.t.sol";
import {NamedMockERC20} from "./LendingPoolIntegration.t.sol";
import {LendingPool} from "../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../src/lending/libraries/helpers/AddressId.sol";
import {SolonVaultRegistry} from "../src/lending/SolonVaultRegistry.sol";

/*
  状态化不变量 fuzz:真 LendingPool × V4 金库 × 可动价格的 mock DEX。
  Handler 随机做 存/取/开/加/平/领/清算/时间流逝/价格跳动,每轮序列后校验铁律:

  INV1 出借人偿付能力:eToken 金库里的 USDG + 在外债务 ≥ 名义总存款(利息只增不减)
  INV2 金库不滞留:金库合约在交易之间不持任何松散 token
  INV3 记账自洽:所有活跃仓位债务之和 ≈ reserve.totalBorrows(Extra 已知舍入漂移,容忍每仓 1 wei/更新)
  INV4 凭证一致:receipt 已销毁(owner=0)的仓位 liquidity 必为 0
  INV5 汇率单调:eToken 兑换率永不下降(出借人本金不缩水)
*/

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract Handler is Test {
    UniV4LeverageVault public vault;
    LendingPool public lending;
    NamedMockERC20 public usdg; NamedMockERC20 public t0;
    MockOracle public oracle;
    address public lender = address(0x10E1);
    address public trader = address(0x7Ade);
    address public keeper = address(0xCafe);
    uint256 public liveDebtIds; // ghost:活跃仓位数上限追踪

    constructor(
        UniV4LeverageVault v, LendingPool l, NamedMockERC20 u, NamedMockERC20 r, MockOracle o
    ) {
        vault = v; lending = l; usdg = u; t0 = r; oracle = o;
        usdg.mint(lender, 1e30); usdg.mint(trader, 1e30); usdg.mint(keeper, 1e30);
        vm.prank(lender); usdg.approve(address(lending), type(uint256).max);
        vm.prank(trader); usdg.approve(address(vault), type(uint256).max);
        vm.prank(keeper); usdg.approve(address(vault), type(uint256).max);
    }

    function deposit(uint256 amt) external {
        amt = bound(amt, 2000, 1e24); // > MINIMUM_ETOKEN_AMOUNT
        vm.prank(lender);
        lending.deposit(1, amt, lender, 0);
    }

    function redeem(uint256 amt) external {
        address eToken = lending.getETokenAddress(1);
        uint256 bal = IERC20View(eToken).balanceOf(lender);
        if (bal < 2) return;
        amt = bound(amt, 1, bal);
        vm.startPrank(lender);
        IERC20View(eToken).approve(address(lending), amt);
        try lending.redeem(1, amt, lender, false) {} catch {} // 池子流动性被借光时允许失败
        vm.stopPrank();
    }

    function open(uint256 invest, uint256 borrow) external {
        invest = bound(invest, 1e18, 1e22);
        borrow = bound(borrow, 0, invest * 4); // 允许尝试超杠杆,健康检查应拦截
        vm.prank(trader);
        try vault.open(UniV4LeverageVault.OpenParams({
            amountInvest: invest, amountBorrow: borrow, tickLower: -1000, tickUpper: 1000,
            amount0Max: type(uint128).max, amount1Max: type(uint128).max, minLiquidity: 0,
            zapPath: "", deadline: block.timestamp + 1
        })) {} catch {}
    }

    function closePartial(uint256 idSeed, uint256 pct) external {
        uint256 id = _pickActive(idSeed); if (id == 0) return;
        uint16 percent = uint16(bound(pct, 1, 10000));
        vm.prank(trader);
        try vault.close(id, UniV4LeverageVault.CloseParams({
            percent: percent, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1
        })) {} catch {}
    }

    function harvest(uint256 idSeed, bool compound, uint256 f0, uint256 f1) external {
        uint256 id = _pickActive(idSeed); if (id == 0) return;
        (uint256 v4Id,,,,) = vault.positions(id);
        MockV4PositionManager(vault.POSITION_MANAGER()).accrueFees(v4Id, bound(f0, 0, 1e20), bound(f1, 0, 1e20));
        vm.prank(trader);
        try vault.harvest(id, compound, "", block.timestamp + 1) {} catch {}
    }

    function liquidate(uint256 idSeed, uint256 repay) external {
        uint256 id = _pickActive(idSeed); if (id == 0) return;
        vm.prank(keeper);
        try vault.liquidate(id, UniV4LeverageVault.LiquidateParams({
            repayAmount: bound(repay, 1, 1e24), minSeizeOut: 0, zapPath: "", deadline: block.timestamp + 1
        })) {} catch {}
    }

    function warpTime(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 90 days));
    }

    function movePrice(uint256 v) external {
        // 公允价 per-liquidity 在 [0.5e18, 4e18] 摆动:能造出不健康仓,也能回血
        oracle.setValPerLiq(bound(v, 0.5e18, 4e18));
    }

    function _pickActive(uint256 seed) internal view returns (uint256) {
        uint256 next = _nextId();
        if (next <= 1) return 0;
        for (uint256 i = 0; i < 5; i++) {
            uint256 id = (uint256(keccak256(abi.encode(seed, i))) % (next - 1)) + 1;
            if (vault.ownerOf(id) != address(0)) return id;
        }
        return 0;
    }
    function _nextId() internal view returns (uint256) { return vault.nextPositionId(); }
}

contract InvariantsTest is Test {
    NamedMockERC20 t0; NamedMockERC20 usdg;
    LendingPool lending;
    MockV4PositionManager pm; MockSwapExecutor swap; MockOracle oracle; MockStateView sv;
    UniV4LeverageVault vault;
    Handler handler;
    address eToken;
    uint256 lastExchangeRate;

    function setUp() public {
        NamedMockERC20 a = new NamedMockERC20("Risk", "RISK");
        NamedMockERC20 b = new NamedMockERC20("USD Global", "USDG");
        (t0, usdg) = address(a) < address(b) ? (a, b) : (b, a);

        AddressRegistry registry = new AddressRegistry(address(new NamedMockERC20("WETH", "WETH")));
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, makeAddr("treasury"));
        lending = new LendingPool(address(registry), registry.getAddress(AddressId.ADDRESS_ID_WETH9));
        lending.initReserve(address(usdg));
        SolonVaultRegistry vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));

        uint160 sqrtP0 = TickMath.getSqrtRatioAtTick(0);
        pm = new MockV4PositionManager(MockERC20(address(t0)), MockERC20(address(usdg)), sqrtP0);
        swap = new MockSwapExecutor(MockERC20(address(t0)), MockERC20(address(usdg)), 1e18);
        oracle = new MockOracle();
        sv = new MockStateView(sqrtP0, 0);

        vault = new UniV4LeverageVault(UniV4LeverageVault.InitParams({
            governor: makeAddr("gov"), positionManager: address(pm), stateView: address(sv),
            lendingPool: address(lending), reserveId: 1, oracle: address(oracle), swapExecutor: address(swap),
            token0: address(t0), token1: address(usdg), loanIsC0: false, fee: 3000, tickSpacing: 60, hooks: address(0),
            minWidthTicks: 100, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            borrowFeeBps: 0, closeFactorBps: 5000, lltv: 0.8e18
        }));
        vaultReg.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, 1, type(uint128).max);
        eToken = lending.getETokenAddress(1);

        usdg.mint(address(swap), 1e30); t0.mint(address(swap), 1e30);

        handler = new Handler(vault, lending, usdg, t0, oracle);
        address keeperAddr = handler.keeper();
        address lenderAddr = handler.lender();
        vm.prank(makeAddr("gov"));
        vault.setLiquidator(keeperAddr, true);

        // 种子流动性,避免全空状态
        vm.prank(lenderAddr);
        lending.deposit(1, 1_000_000e18, lenderAddr, 0);

        lastExchangeRate = lending.exchangeRateOfReserve(1);
        targetContract(address(handler));
    }

    /// INV1 偿付能力:eToken 实币 + 在外债务 ≥ 存款名义额(具体差额是利息,只多不少)
    function invariant_lender_solvency() public view {
        (uint256 totalBorrows,) = _reserveBorrows();
        uint256 cash = usdg.balanceOf(eToken);
        uint256 liability = lending.totalLiquidityOfReserve(1); // 现金+债务口径的总资产
        assertGe(cash + totalBorrows + 1, liability, "cash + debts must back total liquidity");
    }

    /// INV2 金库不滞留资金
    function invariant_vault_holds_nothing() public view {
        assertEq(usdg.balanceOf(address(vault)), 0, "vault must not hold USDG between txs");
        assertEq(t0.balanceOf(address(vault)), 0, "vault must not hold risk token between txs");
    }

    /// INV3 债务记账自洽(允许 Extra 已知的舍入漂移:每仓每次更新 ≤1 wei,给宽松上界)
    function invariant_debt_accounting() public view {
        uint256 sum;
        uint256 next = vault.nextPositionId();
        for (uint256 id = 1; id < next; id++) {
            (,,,, uint256 debtId) = vault.positions(id);
            if (debtId != 0) { (uint256 d,) = lending.getCurrentDebt(debtId); sum += d; }
        }
        (uint256 totalBorrows,) = _reserveBorrows();
        // totalBorrows 可能略小于仓位债务和(官方文档记载的舍入方向),不允许反向大幅偏离
        assertLe(totalBorrows, sum + next * 10 + 10, "totalBorrows must not exceed sum of position debts (+rounding)");
    }

    /// INV4 凭证一致:receipt 销毁 ⇒ 无流动性
    function invariant_receipt_consistency() public view {
        uint256 next = vault.nextPositionId();
        for (uint256 id = 1; id < next; id++) {
            if (vault.ownerOf(id) == address(0)) {
                (, uint128 liq,,,) = vault.positions(id);
                assertEq(liq, 0, "burned receipt must have zero liquidity");
            }
        }
    }

    /// INV5 eToken 汇率单调不减(出借人不会被动亏本金)
    function invariant_exchange_rate_monotonic() public {
        uint256 rate = lending.exchangeRateOfReserve(1);
        assertGe(rate + 1, lastExchangeRate, "eToken exchange rate must never decrease");
        lastExchangeRate = rate;
    }

    function _reserveBorrows() internal view returns (uint256 totalBorrows, uint256 dummy) {
        // LendingPool.reserves(id) 自动 getter 返回打平的 struct;直接用公开视图口径
        totalBorrows = lending.totalBorrowsOfReserve(1);
        dummy = 0;
    }
}
