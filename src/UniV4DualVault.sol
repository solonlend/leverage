// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  UniV4DualVault — Dual-Borrow 杠杆 LP 金库(Uniswap V4),对大仓位友好版。
  设计:docs/DESIGN-dual-borrow-v1.md(KousanS 2026-09-04 拍板)。

  与单币版 UniV4LeverageVault 的根本差异:
    · 两条腿各借各的资产:RISK(WETH) 从 reserveRisk 借、LOAN(USDG) 从 reserveLoan 借,
      按区间比例直接铸 LP —— 开仓零 swap。
    · 每仓两笔债(debtRisk/debtLoan);健康度按双债合并计价(USDG 本位):
      fairValueInLoan(LP) × LLTV ≥ riskValueInLoan(debtRisk) + debtLoan。
    · 平仓匹配还债 + 缺口 exactOutput 互补(swap ∝ 价格漂移,非半仓)。
    · rebalance 只换链下算好的 delta,债务全程不动。
  单币版保持原样不动(已红队);本合约独立成长,红队全套按双资产重跑后才可部署。

  Permit2 结算(2026-09-04 落地,原部署闸):真 v4-periphery PositionManager 的 SETTLE_PAIR
  经 Permit2 拉款。_v4Mint 前 _armPermit2:token→Permit2 万能授权 + Permit2.approve(token,PM,max160,max48)。
  canonical Permit2 无代码的环境(单元测试 mock 链)自动跳过,mock PM 仍走直接 transferFrom。
  ██部署前置██:目标链必须已部署 canonical Permit2(0x000000000022D4...),部署清单需 cast codesize 验证。
  v1 部署目标 = UniV3DualVault(不受影响)。

  TDD 进度:open/isHealthy(tracer)已实现;close/addMargin/rebalance/liquidate 按测试推进逐环补齐。
*/

import {SettlementMath} from "./libraries/SettlementMath.sol";
import {LiquidationSurplus} from "./libraries/LiquidationSurplus.sol";
import {LpMathExt} from "./libraries/LpMathExt.sol";
import {
    Currency, IHooks, PoolKey, IV4PositionManager, V4Encode, PositionInfoLib
} from "./v4/V4Periphery.sol";

interface ILendingPool {
    function newDebtPosition(uint256 reserveId) external returns (uint256 debtId);
    function getUnderlyingTokenAddress(uint256 reserveId) external view returns (address);
    function borrow(address onBehalfOf, uint256 debtId, uint256 amount) external;
    function repay(address onBehalfOf, uint256 debtId, uint256 amount) external returns (uint256 repaid);
    function getCurrentDebt(uint256 debtId) external view returns (uint256 currentDebt, uint256 latestBorrowingIndex);
}

/// dual 版预言机面:LP 公允价 + RISK 折 LOAN(均 fail-closed,USDG 本位)。
interface IDualLpOracle {
    function fairValueInLoan(uint128 liquidity, int24 tickLower, int24 tickUpper) external view returns (uint256);
    function riskValueInLoan(uint256 riskAmount) external view returns (uint256);
}

interface ISwapExecutor {
    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata path)
        external returns (uint256 amountOut);
    function swapExactOutput(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxIn, bytes calldata path)
        external returns (uint256 amountIn);
}

interface IStateView {
    function getSlot0(bytes32 poolId)
        external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC20 {
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

abstract contract PositionReceipt721 {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    mapping(uint256 => address) public ownerOf;
    uint256 internal _nextId = 1;
    function nextPositionId() external view returns (uint256) { return _nextId; }
    function _mint(address to) internal returns (uint256 id) { id = _nextId++; ownerOf[id] = to; emit Transfer(address(0), to, id); }
    function _burn(uint256 id) internal { emit Transfer(ownerOf[id], address(0), id); delete ownerOf[id]; }
}

abstract contract ReentrancyGuard {
    error Reentrancy();
    uint256 private _lock = 1;
    modifier nonReentrant() { if (!(_lock == 1)) revert Reentrancy(); _lock = 2; _; _lock = 1; }
}

contract UniV4DualVault is PositionReceipt721, ReentrancyGuard {
    struct Position {
        uint256 dexTokenId;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 debtRisk;    // WETH 债务仓(reserveRisk)
        uint256 debtLoan;    // USDG 债务仓(reserveLoan)
    }

    mapping(uint256 => Position) public positions;
    mapping(address => bool) public liquidators;

    address public immutable GOVERNOR;
    address public immutable POSITION_MANAGER;
    /// canonical Permit2(全链同址);真 PM 的 SETTLE_PAIR 只认 Permit2 额度
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    mapping(address => bool) internal permit2Armed;
    address public immutable STATE_VIEW;
    address public immutable LENDING_POOL;
    uint256 public immutable RESERVE_RISK;
    uint256 public immutable RESERVE_LOAN;
    address public immutable ORACLE;
    address public immutable SWAP_EXECUTOR;
    address public immutable TOKEN0;
    address public immutable TOKEN1;
    bool    public immutable LOAN_IS_C0;
    address public immutable LOAN;
    address public immutable RISK;
    uint24  public immutable FEE;
    int24   public immutable TICK_SPACING;
    address public immutable HOOKS;
    bytes32 public immutable POOL_ID;

    int24   public immutable MIN_WIDTH_TICKS;
    uint256 public immutable LIQ_BONUS_BPS;
    uint256 public immutable PROTOCOL_FEE_BPS;
    uint256 public immutable HARVEST_FEE_BPS;
    uint256 public immutable CLOSE_FACTOR_BPS;
    uint256 public immutable LLTV;

    /// liquidity 数学的向下取整会造出 wei 级"假缺口";低于此阈值不触发缺口 swap、不计坏账事件。
    /// (18dp 代币≈尘埃;6dp 代币=0.001。与 Extra 已知的记账取整漂移同性质,社会化为尘。设计 §3)
    uint256 internal constant GAP_EPS = 1e3;
    /// 降级 swap(盈余全换)的最大容忍滑点:minOut 由预言机公允价反推。
    /// 经济审计 E-1:此前 minOut=0 + 用户可控 zapPath 可把整条盈余腿洗进攻击者池子、坏账甩给出借人。
    uint256 internal constant MAX_GAP_SLIPPAGE_BPS = 500;
    /// 单笔清算最小价值(LOAN 单位),防粉尘清算骚扰(经济审计 E-3)。
    uint256 internal constant MIN_LIQ_VALUE = 1e4;

    error NotHolder();
    error NotGovernor();
    error ZeroLiq();
    error SlippageLiq();
    error UnhealthyOpen();
    error SlippageGap();
    error Slippage();
    error UnhealthyAfterClose();
    error SolventBadDebt();
    error DustLiq();
    error ZeroSeize();
    error SeizeValueLow();
    error UnhealthyAfterRebalance();
    error UnhealthyAfterHarvest();
    error NotTwoSided();
    error TokenCallFailed();
    error NotLiquidator();
    error RangeTooNarrow();
    error Healthy();

    event LiquidatorSet(address indexed keeper, bool allowed);
    event PositionOpened(
        uint256 indexed id, address indexed owner,
        uint256 investRisk, uint256 investLoan, uint256 borrowRisk, uint256 borrowLoan,
        uint256 debtRisk, uint256 debtLoan, uint128 liquidity, int24 tickLower, int24 tickUpper
    );
    event BadDebt(uint256 indexed id, uint256 indexed debtId, uint256 residualDebt);
    event PositionClosed(
        uint256 indexed id, uint16 percentBps,
        uint256 repaidRisk, uint256 repaidLoan, uint256 outRisk, uint256 outLoan, bool full
    );

    modifier onlyHolder(uint256 id) { if (ownerOf[id] != msg.sender) revert NotHolder(); _; }

    struct InitParams {
        address governor; address positionManager; address stateView;
        address lendingPool; uint256 reserveRisk; uint256 reserveLoan;
        address oracle; address swapExecutor;
        address token0; address token1; bool loanIsC0; uint24 fee; int24 tickSpacing; address hooks;
        int24 minWidthTicks; uint256 liqBonusBps; uint256 protocolFeeBps; uint256 harvestFeeBps;
        uint256 closeFactorBps; uint256 lltv;
    }

    constructor(InitParams memory p) {
        require(
            p.governor != address(0) && p.positionManager != address(0) && p.stateView != address(0)
            && p.lendingPool != address(0) && p.oracle != address(0) && p.swapExecutor != address(0)
            && p.token0 != address(0) && p.token1 != address(0),
            "ZERO_ADDR"
        );
        require(p.token0 < p.token1, "UNSORTED");
        require(p.reserveRisk != p.reserveLoan, "SAME_RESERVE");
        // L5:immutable 参数越界=永久 DoS/费率下溢,部署期一次性卡死
        require(p.lltv > 0 && p.lltv <= 1e18, "BAD_LLTV");
        require(p.closeFactorBps > 0 && p.closeFactorBps <= 10000, "BAD_CLOSE_FACTOR");
        require(p.liqBonusBps <= 2000 && p.protocolFeeBps <= 5000 && p.harvestFeeBps <= 3000, "BAD_FEES");
        require(p.minWidthTicks > 0, "BAD_MIN_WIDTH");
        GOVERNOR = p.governor; POSITION_MANAGER = p.positionManager; STATE_VIEW = p.stateView;
        LENDING_POOL = p.lendingPool; RESERVE_RISK = p.reserveRisk; RESERVE_LOAN = p.reserveLoan;
        ORACLE = p.oracle; SWAP_EXECUTOR = p.swapExecutor;
        TOKEN0 = p.token0; TOKEN1 = p.token1; FEE = p.fee; TICK_SPACING = p.tickSpacing; HOOKS = p.hooks;
        LOAN_IS_C0 = p.loanIsC0;
        LOAN = p.loanIsC0 ? p.token0 : p.token1;
        RISK = p.loanIsC0 ? p.token1 : p.token0;
        // code-review:储备 id 与两腿代币必须绑定一致,id 写反=记账灾难(借 USDG 记成 wei 级 WETH 债)
        require(ILendingPool(p.lendingPool).getUnderlyingTokenAddress(p.reserveRisk) == (p.loanIsC0 ? p.token1 : p.token0), "RESERVE_RISK_MISMATCH");
        require(ILendingPool(p.lendingPool).getUnderlyingTokenAddress(p.reserveLoan) == (p.loanIsC0 ? p.token0 : p.token1), "RESERVE_LOAN_MISMATCH");
        MIN_WIDTH_TICKS = p.minWidthTicks; LIQ_BONUS_BPS = p.liqBonusBps; PROTOCOL_FEE_BPS = p.protocolFeeBps;
        HARVEST_FEE_BPS = p.harvestFeeBps; CLOSE_FACTOR_BPS = p.closeFactorBps; LLTV = p.lltv;
        POOL_ID = keccak256(abi.encode(_key()));
    }

    function setLiquidator(address keeper, bool allowed) external {
        if (msg.sender != GOVERNOR) revert NotGovernor();
        liquidators[keeper] = allowed;
        emit LiquidatorSet(keeper, allowed);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(TOKEN0), currency1: Currency.wrap(TOKEN1),
            fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(HOOKS)
        });
    }

    // ─────────────────────────────── OPEN(双币借款,零 swap)───────────────────────────────
    struct OpenParams {
        uint256 investRisk; uint256 investLoan;   // 用户自带两腿(可各为 0)
        uint256 borrowRisk; uint256 borrowLoan;   // 各储备借入量(前端按区间比例算)
        int24 tickLower; int24 tickUpper;
        uint128 amount0Max; uint128 amount1Max; uint128 minLiquidity;
        uint256 deadline;
    }

    function open(OpenParams calldata p) external nonReentrant returns (uint256 positionNftId) {
        _requireTwoSidedRange(p.tickLower, p.tickUpper);
        (uint256 base0, uint256 base1) = _snap();

        // 拉自带两腿 + 各储备借款(债务仓恒建,便于后续 increase/addMargin 复用)
        _pull(RISK, msg.sender, p.investRisk);
        _pull(LOAN, msg.sender, p.investLoan);
        uint256 debtRisk = ILendingPool(LENDING_POOL).newDebtPosition(RESERVE_RISK);
        uint256 debtLoan = ILendingPool(LENDING_POOL).newDebtPosition(RESERVE_LOAN);
        if (p.borrowRisk > 0) ILendingPool(LENDING_POOL).borrow(address(this), debtRisk, p.borrowRisk);
        if (p.borrowLoan > 0) ILendingPool(LENDING_POOL).borrow(address(this), debtLoan, p.borrowLoan);

        uint256 totalRisk = p.investRisk + p.borrowRisk;
        uint256 totalLoan = p.investLoan + p.borrowLoan;
        (uint256 amt0, uint256 amt1) = LOAN_IS_C0 ? (totalLoan, totalRisk) : (totalRisk, totalLoan);

        uint128 liq = _liquidityFor(p.tickLower, p.tickUpper, amt0, amt1);
        if (!(liq > 0)) revert ZeroLiq();
        if (!(liq >= p.minLiquidity)) revert SlippageLiq(); // 比例过期/被夹的保险丝
        uint256 tokenId = _v4Mint(p.tickLower, p.tickUpper, liq, p.amount0Max, p.amount1Max, amt0, amt1, p.deadline);

        positionNftId = _mint(msg.sender);
        positions[positionNftId] = Position({
            dexTokenId: tokenId, liquidity: liq,
            tickLower: p.tickLower, tickUpper: p.tickUpper,
            debtRisk: debtRisk, debtLoan: debtLoan
        });

        // E-2 修复:借而未用的零头先还回各自债务腿(堵"借款变现"提款口),剩余(自带部分)才退用户
        _repayOpenDust(positionNftId, base0, base1);
        _refundDust(msg.sender, base0, base1);
        if (!(isHealthy(positionNftId))) revert UnhealthyOpen();
        emit PositionOpened(
            positionNftId, msg.sender, p.investRisk, p.investLoan, p.borrowRisk, p.borrowLoan,
            debtRisk, debtLoan, liq, p.tickLower, p.tickUpper
        );
    }

    // ─────────────────────────────── CLOSE(匹配还债 + 缺口结算)───────────────────────────────
    /// 共享增铸水管:arm Permit2 → INCREASE_LIQUIDITY+SETTLE_PAIR。amt0/amt1 仅用于 mock 环境直批。
    function _v4Increase(uint256 tokenId, uint128 addLiq, uint256 amt0, uint256 amt1, uint256 deadline) internal {
        if (PERMIT2.code.length == 0) {
            _approveIfNeeded(TOKEN0, POSITION_MANAGER, amt0);
            _approveIfNeeded(TOKEN1, POSITION_MANAGER, amt1);
        }
        _armPermit2(TOKEN0);
        _armPermit2(TOKEN1);
        IV4PositionManager(POSITION_MANAGER).modifyLiquidities(
            V4Encode.increase(_key(), tokenId, addLiq, type(uint128).max, type(uint128).max), deadline
        );
    }

    // ─────────────────────────────── INCREASE(杠杆加仓,与单币版功能对等)───────────────────────────────
    struct IncreaseParams {
        uint256 investRisk; uint256 investLoan;
        uint256 borrowRisk; uint256 borrowLoan;
        uint128 minLiquidity; uint256 deadline;
    }
    event PositionIncreased(uint256 indexed id, uint256 investRisk, uint256 investLoan, uint256 borrowRisk, uint256 borrowLoan, uint128 addedLiquidity);
    error UnhealthyIncrease();

    /// 双腿各投各借零 swap;INCREASE_LIQUIDITY+SETTLE_PAIR 经 Permit2;借而未用 E-2 自动还。
    function increase(uint256 id, IncreaseParams calldata p) external nonReentrant onlyHolder(id) {
        Position storage pos = positions[id];
        (uint256 base0, uint256 base1) = _snap();
        _pull(RISK, msg.sender, p.investRisk);
        _pull(LOAN, msg.sender, p.investLoan);
        ILendingPool(LENDING_POOL).borrow(address(this), pos.debtRisk, p.borrowRisk);
        if (p.borrowLoan > 0) ILendingPool(LENDING_POOL).borrow(address(this), pos.debtLoan, p.borrowLoan);

        uint256 totalRisk = p.investRisk + p.borrowRisk;
        uint256 totalLoan = p.investLoan + p.borrowLoan;
        (uint256 amt0, uint256 amt1) = LOAN_IS_C0 ? (totalLoan, totalRisk) : (totalRisk, totalLoan);
        uint128 addLiq = _liquidityFor(pos.tickLower, pos.tickUpper, amt0, amt1);
        if (!(addLiq >= p.minLiquidity && addLiq > 0)) revert SlippageLiq();
        _v4Increase(pos.dexTokenId, addLiq, amt0, amt1, p.deadline);
        pos.liquidity += addLiq;
        _repayOpenDust(id, base0, base1);
        _refundDust(msg.sender, base0, base1);
        if (!isHealthy(id)) revert UnhealthyIncrease();
        emit PositionIncreased(id, p.investRisk, p.investLoan, p.borrowRisk, p.borrowLoan, addLiq);
    }

    // ─────────────────────────────── HARVEST(claim/复投,与单币版功能对等)───────────────────────────────
    /// 与单币版差异:不收用户 zapPath(E-1 教训);复投=两腿 fee 经 INCREASE_LIQUIDITY+SETTLE_PAIR
    /// 直接卷回仓位(Permit2 结算,零 swap);零头 _refundDust 退还。claim 后仍过健康检查。
    function harvest(uint256 id, bool compound, uint256 deadline)
        external nonReentrant onlyHolder(id) returns (uint256 out0, uint256 out1)
    {
        Position storage pos = positions[id];
        (uint256 base0, uint256 base1) = _snap();
        (uint256 fee0, uint256 fee1) = _collectFees(pos.dexTokenId, deadline);
        (fee0, fee1) = _skimHarvestFee(fee0, fee1);

        if (!compound) {
            if (fee0 > 0) _transfer(TOKEN0, msg.sender, fee0);
            if (fee1 > 0) _transfer(TOKEN1, msg.sender, fee1);
            out0 = fee0; out1 = fee1;
        } else if (fee0 > 0 || fee1 > 0) {
            uint128 addLiq = _liquidityFor(pos.tickLower, pos.tickUpper, fee0, fee1);
            if (addLiq > 0) {
                _v4Increase(pos.dexTokenId, addLiq, fee0, fee1, deadline);
                pos.liquidity += addLiq;
            }
            _refundDust(msg.sender, base0, base1);
        }
        if (!isHealthy(id)) revert UnhealthyAfterHarvest();
        emit Harvested(id, fee0, fee1, compound);
    }

    struct CloseParams {
        uint16 percent;
        uint256 topUpRisk; uint256 topUpLoan;    // 用户自带的缺口币上限(只拉实际所需;可无损跳过 swap)
        uint256 maxSwapIn;                       // 缺口 swap 的盈余投入上限(滑点保险丝;0=拒绝 swap)
        uint256 minOutRisk; uint256 minOutLoan;  // 出金两腿下限
        bytes zapPath; uint256 deadline;
    }

    /// 平仓:撤 LP → WETH 还 WETH 债、USDG 还 USDG 债 → 短缺腿用盈余腿 exactOutput 买缺口
    /// (盈余不够则降级 exactInput 全换,部分覆盖,残债坏账)→ 剩余双币退用户。
    /// swap 量 ∝ 开仓以来的价格漂移,非半仓名义(设计 §3;KousanS 指正后的模型)。
    function close(uint256 id, CloseParams calldata c)
        external nonReentrant onlyHolder(id) returns (uint256 outRisk, uint256 outLoan)
    {
        Position storage pos = positions[id];
        bool fullClose = (c.percent >= 10000);
        uint128 dLiq = fullClose ? pos.liquidity : uint128((uint256(pos.liquidity) * c.percent) / 10000);
        if (!(dLiq > 0)) revert ZeroLiq();
        (uint256 base0, uint256 base1) = _snap();

        // M4/C1-3:预取"平仓前是否资不抵债"(lazy try:oracle 断供时 preChecked=false,
        // 干净全平不受影响;要留坏账离场则必须此证明 → 堵死健康仓自铸坏账与停摆窗口逃逸)
        bool preInsolvent; bool preChecked;
        if (fullClose) {
            try this.positionValue(id) returns (uint256 pv) {
                try this.totalDebtInLoan(id) returns (uint256 td) {
                    preInsolvent = pv < td; preChecked = true;
                } catch {}
            } catch {}
        }
        pos.liquidity -= dLiq;
        bool closedAll = fullClose || pos.liquidity == 0;
        if (closedAll) _burn(id);

        // 先收 fee 抽成再撤本金(堵"平仓白拿 fee"),合并成两腿到手额
        (uint256 fee0, uint256 fee1) = _collectFees(pos.dexTokenId, c.deadline);
        (fee0, fee1) = _skimHarvestFee(fee0, fee1);
        (uint256 got0, uint256 got1) = _removeLiquidity(pos.dexTokenId, dLiq, closedAll, c.deadline);
        got0 += fee0; got1 += fee1;
        (uint256 gotRisk, uint256 gotLoan) = LOAN_IS_C0 ? (got1, got0) : (got0, got1);

        // 应还(部分平向上取整,偏向出借人;封顶当前债务)
        (uint256 dueRisk, uint256 dueLoan) = _dues(pos, c.percent, fullClose);

        // 匹配还债:各币先还各自的腿
        uint256 payRisk = gotRisk < dueRisk ? gotRisk : dueRisk;
        uint256 payLoan = gotLoan < dueLoan ? gotLoan : dueLoan;
        payRisk = _repayLeg(pos.debtRisk, RISK, payRisk);   // 用实际还款额记账
        payLoan = _repayLeg(pos.debtLoan, LOAN, payLoan);
        gotRisk -= payRisk; gotLoan -= payLoan;

        // 缺口结算(至多一腿短缺)
        (gotRisk, gotLoan) = _settleGap(
            pos, dueRisk > payRisk ? dueRisk - payRisk : 0, dueLoan > payLoan ? dueLoan - payLoan : 0,
            gotRisk, gotLoan, c
        );

        outRisk = gotRisk; outLoan = gotLoan;
        if (!(outRisk >= c.minOutRisk && outLoan >= c.minOutLoan)) revert Slippage();
        if (outRisk > 0) _transfer(RISK, msg.sender, outRisk);
        if (outLoan > 0) _transfer(LOAN, msg.sender, outLoan);
        _refundDust(msg.sender, base0, base1);

        // 部分平仓不得把仓位磨过线;全平豁免(仓位已消灭)
        if (!closedAll) if (!(isHealthy(id))) revert UnhealthyAfterClose();

        emit PositionClosed(id, c.percent, payRisk, payLoan, outRisk, outLoan, closedAll);
        if (closedAll) {
            (uint256 resR,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtRisk);
            (uint256 resL,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtLoan);
            bool resRreal = !_riskIsDust(resR); // 价值口径:粉尘残债不触发安全闸(与缺口判定同尺)
            if (resRreal || resL > GAP_EPS) {
                // 只有"预言机作证平仓前已资不抵债"才允许留坏账离场;否则回去补币/放开 swap
                if (!(preChecked && preInsolvent)) revert SolventBadDebt();
                if (resRreal) emit BadDebt(id, pos.debtRisk, resR);
                if (resL > GAP_EPS) emit BadDebt(id, pos.debtLoan, resL);
            }
        }
    }

    function _dues(Position storage pos, uint16 percent, bool fullClose)
        internal view returns (uint256 dueRisk, uint256 dueLoan)
    {
        return LpMathExt.dues(LENDING_POOL, pos.debtRisk, pos.debtLoan, percent, fullClose);
    }

    /// 缺口/残债的粉尘判定必须按"价值"而非原始 wei:GAP_EPS=1e3 对 6 位小数的 LOAN 是 0.001 刀,
    /// 放到 18 位小数的 RISK 腿上形同虚设 —— 利息累积的几 gwei 粉尘会被当成真缺口,逼出一笔
    /// 荒谬的粉尘 swap 并使普通全平失败(Sepolia v1.2 真链实证)。shortRisk==0 时短路,
    /// 保证"无缺口的干净平仓"在喂价停摆时仍不读预言机、照常放行。
    function _riskIsDust(uint256 amtRisk) internal view returns (bool) {
        if (amtRisk == 0) return true;
        return IDualLpOracle(ORACLE).riskValueInLoan(amtRisk) <= GAP_EPS;
    }

    /// 缺口结算顺序(KousanS 定):①用户自带缺口币 top-up(无损、零 swap,只拉实际所需)
    /// ②盈余够 → exactOutput 买恰好缺口 ③盈余不够 → 降级 exactInput 全换,残债坏账。
    /// 降级仅在 maxSwapIn 允许花完盈余时发生;否则视为用户滑点保护被触发,整笔 revert。
    function _settleGap(
        Position storage pos, uint256 shortRisk, uint256 shortLoan,
        uint256 gotRisk, uint256 gotLoan, CloseParams calldata c
    ) internal returns (uint256, uint256) {
        // ① top-up:自带缺口币直接补还,选择权在用户,完全跳过 swap
        if (!_riskIsDust(shortRisk) && c.topUpRisk > 0) {
            uint256 t = c.topUpRisk < shortRisk ? c.topUpRisk : shortRisk;
            _pull(RISK, msg.sender, t);
            uint256 a = _repayLeg(pos.debtRisk, RISK, t);
            shortRisk -= t;
            if (t > a) gotRisk += t - a; // 封顶差额随出金退还用户
        }
        if (shortLoan > GAP_EPS && c.topUpLoan > 0) {
            uint256 t = c.topUpLoan < shortLoan ? c.topUpLoan : shortLoan;
            _pull(LOAN, msg.sender, t);
            uint256 a = _repayLeg(pos.debtLoan, LOAN, t);
            shortLoan -= t;
            if (t > a) gotLoan += t - a;
        }
        // 两个方向的缺口结算逻辑镜像对称,参数化合一(体积);语义与 V3 双分支逐式一致。
        bool riskShort = !_riskIsDust(shortRisk) && gotLoan > 0;
        bool loanShort = !riskShort && shortLoan > GAP_EPS && gotRisk > 0;
        if (riskShort || loanShort) {
            (address tIn, address tOut, uint256 surplus, uint256 short_, uint256 debtId) = riskShort
                ? (LOAN, RISK, gotLoan, shortRisk, pos.debtRisk)
                : (RISK, LOAN, gotRisk, shortLoan, pos.debtLoan);
            uint256 maxIn = surplus < c.maxSwapIn ? surplus : c.maxSwapIn;
            if (maxIn == 0) { if (!(c.maxSwapIn >= surplus)) revert SlippageGap(); }
            else {
            _approveIfNeeded(tIn, SWAP_EXECUTOR, maxIn); // 漏 approve 会让主路径必败、静默降级成全换(V3 红队抓出)
            try ISwapExecutor(SWAP_EXECUTOR).swapExactOutput(tIn, tOut, short_, maxIn, c.zapPath)
            returns (uint256 spent) {
                uint256 a = _repayLeg(debtId, tOut, short_);
                if (riskShort) { gotLoan = surplus - spent; if (short_ > a) gotRisk += short_ - a; }
                else { gotRisk = surplus - spent; if (short_ > a) gotLoan += short_ - a; }
            } catch {
                if (!(c.maxSwapIn >= surplus)) revert SlippageGap(); // 用户上限先于盈余耗尽 → 尊重滑点保护
                // E-1:降级强制空 path + 预言机公允 minOut(两方向公式各自成立)
                uint256 minOut = riskShort
                    ? (surplus * (10000 - MAX_GAP_SLIPPAGE_BPS) / 10000) * 1e18
                        / IDualLpOracle(ORACLE).riskValueInLoan(1e18)
                    : IDualLpOracle(ORACLE).riskValueInLoan(surplus) * (10000 - MAX_GAP_SLIPPAGE_BPS) / 10000;
                uint256 bought = _swapExactIn(tIn, tOut, surplus, minOut, "");
                uint256 want = bought < short_ ? bought : short_;
                uint256 a = _repayLeg(debtId, tOut, want);
                if (riskShort) { gotLoan = 0; gotRisk += bought - a; }
                else { gotRisk = 0; gotLoan += bought - a; }
            }
            }
        }
        return (gotRisk, gotLoan);
    }

    /// 返回实际还款额:Extra 的 repay 会封顶到 borrowed(视图利息与结算利息可差 wei 级),
    /// 调用方必须用返回值记账,差额归还相应主体 —— 否则 wei 级资金滞留金库(dual 不变量 fuzz 抓出)。
    function _repayLeg(uint256 debtId, address token, uint256 amt) internal returns (uint256 repaid) {
        if (amt == 0) return 0;
        _approveIfNeeded(token, LENDING_POOL, amt);
        repaid = ILendingPool(LENDING_POOL).repay(address(this), debtId, amt);
    }

    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes memory path)
        internal returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;
        _approveIfNeeded(tokenIn, SWAP_EXECUTOR, amountIn);
        amountOut = ISwapExecutor(SWAP_EXECUTOR).swapExactInput(tokenIn, tokenOut, amountIn, minOut, path);
    }

    // ─────────────────────────────── LIQUIDATE(双资产,价值口径)───────────────────────────────
    struct LiquidateParams {
        uint256 ratioBps;        // 清算比例 k,封顶 closeFactor;按比例同时作用两腿(最难被套利)
        uint256 minSeizeValue;   // keeper 所得的最小价值(LOAN 计,滑点保险丝)
        uint256 deadline;
    }
    event PositionLiquidated(
        uint256 indexed id, address indexed keeper,
        uint256 repaidRisk, uint256 repaidLoan, uint256 seizeValueToKeeper, uint256 protocolFeeValue, bool fullyClosed
    );

    /// 双资产清算:k 按比例同时还两腿(keeper 垫两币)→ 按合并价值扣押 LP → 双币 in-kind 分账。
    /// SettlementMath 在"价值"口径复用;F2 封顶保留:keeper 所得价值 ≤ 应得 s.liquidatorSeize,
    /// 超额先回冲该仓两腿债务、余下退借款人(均按两腿比例拆)。设计 §5。
    function liquidate(uint256 id, LiquidateParams calldata lp)
        external nonReentrant returns (bool fullyClosed)
    {
        if (!liquidators[msg.sender]) revert NotLiquidator();
        if (isHealthy(id)) revert Healthy();

        Position storage pos = positions[id];
        address borrower = ownerOf[id];

        // 比例封顶 + 两腿应还
        uint256 k = lp.ratioBps > CLOSE_FACTOR_BPS ? CLOSE_FACTOR_BPS : lp.ratioBps;
        (uint256 curR,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtRisk);
        (uint256 curL,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtLoan);
        uint256 repayRisk = (curR * k) / 10000;
        uint256 repayLoan = (curL * k) / 10000;

        // keeper 垫两币还两腿;后续价值、扣押和奖励只认 LendingPool 实际返回值
        if (repayRisk > 0) {
            _pull(RISK, msg.sender, repayRisk);
            uint256 a = _repayLeg(pos.debtRisk, RISK, repayRisk);
            if (repayRisk > a) { _transfer(RISK, msg.sender, repayRisk - a); repayRisk = a; }
        }
        if (repayLoan > 0) {
            _pull(LOAN, msg.sender, repayLoan);
            uint256 a = _repayLeg(pos.debtLoan, LOAN, repayLoan);
            if (repayLoan > a) { _transfer(LOAN, msg.sender, repayLoan - a); repayLoan = a; }
        }

        uint256 repayValue = IDualLpOracle(ORACLE).riskValueInLoan(repayRisk) + repayLoan;
        if (!(repayValue >= MIN_LIQ_VALUE)) revert DustLiq(); // 粉尘清算防线(E-3)

        // 价值口径扣押(SettlementMath 原样复用)
        SettlementMath.Seize memory s = SettlementMath.liquidationSeize(repayValue, LIQ_BONUS_BPS, PROTOCOL_FEE_BPS);
        uint256 posVal = positionValue(id);
        uint128 seizeLiq = s.seizeValue >= posVal
            ? pos.liquidity
            : uint128((uint256(pos.liquidity) * s.seizeValue) / posVal);
        if (!(seizeLiq > 0)) revert ZeroSeize();

        pos.liquidity -= seizeLiq;
        fullyClosed = (pos.liquidity == 0);
        if (fullyClosed) _burn(id);

        // 撤扣押 → 双币,按价值比例分账
        (uint256 lf0, uint256 lf1) = _collectFees(pos.dexTokenId, lp.deadline);
        (lf0, lf1) = _skimHarvestFee(lf0, lf1); // E-5:清算收 fee 同样抽成,口径与 close 一致
        (uint256 got0, uint256 got1) = _removeLiquidity(pos.dexTokenId, seizeLiq, fullyClosed, lp.deadline);
        got0 += lf0; got1 += lf1;
        (uint256 gotRisk, uint256 gotLoan) = LOAN_IS_C0 ? (got1, got0) : (got0, got1);
        _payoutLiquidation(id, pos, borrower, gotRisk, gotLoan, s, posVal, lp.minSeizeValue, repayRisk, repayLoan, fullyClosed);
    }

    /// 分账:协议费价值 + keeper 封顶应得价值,均按两腿等比例拆币;超额回冲债务→退借款人。
    function _payoutLiquidation(
        uint256 id, Position storage pos, address borrower,
        uint256 gotRisk, uint256 gotLoan, SettlementMath.Seize memory s,
        uint256 posValSnap, uint256 minSeizeValue, uint256 repaidRisk, uint256 repaidLoan, bool fullyClosed
    ) internal {
        uint256 gotValue = IDualLpOracle(ORACLE).riskValueInLoan(gotRisk) + gotLoan;
        // 分账纯数学外置 LpMathExt.liqSplit(赎回价值下限/F2 封顶/两腿等比例拆,语义与原内联逐式一致)
        (uint256 feeR, uint256 feeL, uint256 kR, uint256 kL, uint256 keeperValue, uint256 feeValue) =
            LpMathExt.liqSplit(gotRisk, gotLoan, gotValue, s.seizeValue, posValSnap, s.protocolFee, s.liquidatorSeize, minSeizeValue, MAX_GAP_SLIPPAGE_BPS);
        if (feeR > 0) _transfer(RISK, GOVERNOR, feeR);
        if (feeL > 0) _transfer(LOAN, GOVERNOR, feeL);
        gotRisk -= feeR; gotLoan -= feeL;
        if (kR > 0) _transfer(RISK, msg.sender, kR);
        if (kL > 0) _transfer(LOAN, msg.sender, kL);
        gotRisk -= kR; gotLoan -= kL;

        // Refund only after both legs are settled; failed conversions retain protocol funds.
        (gotRisk, gotLoan) = LiquidationSurplus.settle(
            LiquidationSurplus.Context(
                LENDING_POOL, ORACLE, SWAP_EXECUTOR, RISK, LOAN,
                pos.debtRisk, pos.debtLoan, MAX_GAP_SLIPPAGE_BPS
            ), gotRisk, gotLoan
        );
        _transferOrTreasury(RISK, borrower, gotRisk);
        _transferOrTreasury(LOAN, borrower, gotLoan);

        emit PositionLiquidated(id, msg.sender, repaidRisk, repaidLoan, keeperValue, feeValue, fullyClosed);
        if (fullyClosed) {
            (uint256 resR,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtRisk);
            (uint256 resL,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtLoan);
            if (resR > GAP_EPS) emit BadDebt(id, pos.debtRisk, resR);
            if (resL > GAP_EPS) emit BadDebt(id, pos.debtLoan, resL);
        }
    }

    // ─────────────────────────────── 平仓预估(前端"补多少币可无损赎回")───────────────────────────────
    /// 按当前池价估算平仓两腿到手与应还,给出各腿缺口。不含未领手续费与执行时价差,前端应加小缓冲。
    function previewClose(uint256 id, uint16 percent) external view returns (
        uint256 estGotRisk, uint256 estGotLoan, uint256 dueRisk, uint256 dueLoan,
        uint256 shortRisk, uint256 shortLoan
    ) {
        Position storage pos = positions[id];
        return LpMathExt.previewCloseExt(
            STATE_VIEW, POOL_ID, LENDING_POOL,
            pos.liquidity, pos.tickLower, pos.tickUpper, pos.debtRisk, pos.debtLoan, percent, LOAN_IS_C0
        );
    }

    // ─────────────────────────────── ADD MARGIN(补保证金 = 还债优先)───────────────────────────────
    event MarginAdded(uint256 indexed id, address indexed payer, uint256 repaidRisk, uint256 repaidLoan);

    /// 单侧/双侧皆可;各腿封顶当前债务,只拉实际所需;任何人可代还(repay-on-behalf);
    /// 不健康时更要能补(自救),无健康门槛 —— 还债只会让健康度单调改善。设计 §5.5。
    function addMargin(uint256 id, uint256 amountRisk, uint256 amountLoan) external nonReentrant {
        // 允许对"已销毁但有残债"的仓位代还(S-2:孤儿坏账至少可被清偿,如国库/善意方)
        require(
            ownerOf[id] != address(0) || positions[id].debtRisk != 0 || positions[id].debtLoan != 0,
            "NO_POSITION"
        );
        Position storage pos = positions[id];
        uint256 repaidRisk; uint256 repaidLoan;
        if (amountRisk > 0) {
            (uint256 cur,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtRisk);
            uint256 pay = amountRisk < cur ? amountRisk : cur;
            if (pay > 0) {
                _pull(RISK, msg.sender, pay);
                repaidRisk = _repayLeg(pos.debtRisk, RISK, pay);
                if (pay > repaidRisk) _transfer(RISK, msg.sender, pay - repaidRisk);
            }
        }
        if (amountLoan > 0) {
            (uint256 cur,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtLoan);
            uint256 pay = amountLoan < cur ? amountLoan : cur;
            if (pay > 0) {
                _pull(LOAN, msg.sender, pay);
                repaidLoan = _repayLeg(pos.debtLoan, LOAN, pay);
                if (pay > repaidLoan) _transfer(LOAN, msg.sender, pay - repaidLoan);
            }
        }
        emit MarginAdded(id, msg.sender, repaidRisk, repaidLoan);
    }

    // ─────────────────────────────── REBALANCE(换区间,只换 delta,债务不动)───────────────────────────────
    struct RebalanceParams {
        int24 newTickLower; int24 newTickUpper;
        int256 swapAmount;   // 链下算好的净额;>0 卖 RISK 换 LOAN,<0 卖 LOAN 换 RISK
        uint256 minSwapOut; uint128 minLiquidity; bytes zapPath; uint256 deadline;
    }
    event Harvested(uint256 indexed id, uint256 fee0, uint256 fee1, bool compound); // 净额(协议抽成后)
    event Rebalanced(uint256 indexed id, int24 newTickLower, int24 newTickUpper, int256 swapAmount, uint128 newLiquidity);

    /// Charm 三段式:撤全部 → 单笔净额 swap → 重铺新区间。债务两腿全程不动(铁律);
    /// 末尾健康检查兜滑点,也天然禁止不健康仓借"换区间"绕清算。v1 仅持有人可调。设计 §4。
    function rebalance(uint256 id, RebalanceParams calldata p) external nonReentrant onlyHolder(id) {
        _requireTwoSidedRange(p.newTickLower, p.newTickUpper);
        Position storage pos = positions[id];
        (uint256 base0, uint256 base1) = _snap();

        (uint256 fee0, uint256 fee1) = _collectFees(pos.dexTokenId, p.deadline);
        (fee0, fee1) = _skimHarvestFee(fee0, fee1);
        (uint256 got0, uint256 got1) = _removeLiquidity(pos.dexTokenId, pos.liquidity, true, p.deadline);
        got0 += fee0; got1 += fee1;

        if (p.swapAmount > 0) {
            uint256 amtIn = uint256(p.swapAmount);
            uint256 out = _swapExactIn(RISK, LOAN, amtIn, p.minSwapOut, p.zapPath);
            if (LOAN_IS_C0) { got1 -= amtIn; got0 += out; } else { got0 -= amtIn; got1 += out; }
        } else if (p.swapAmount < 0) {
            uint256 amtIn = uint256(-p.swapAmount);
            uint256 out = _swapExactIn(LOAN, RISK, amtIn, p.minSwapOut, p.zapPath);
            if (LOAN_IS_C0) { got0 -= amtIn; got1 += out; } else { got1 -= amtIn; got0 += out; }
        }

        uint128 liq = _liquidityFor(p.newTickLower, p.newTickUpper, got0, got1);
        if (!(liq > 0)) revert ZeroLiq();
        if (!(liq >= p.minLiquidity)) revert SlippageLiq();
        uint256 newTokenId = _v4Mint(
            p.newTickLower, p.newTickUpper, liq, type(uint128).max, type(uint128).max, got0, got1, p.deadline
        );

        pos.dexTokenId = newTokenId;
        pos.liquidity = liq;
        pos.tickLower = p.newTickLower;
        pos.tickUpper = p.newTickUpper;

        _refundDust(msg.sender, base0, base1);
        if (!(isHealthy(id))) revert UnhealthyAfterRebalance();
        emit Rebalanced(id, p.newTickLower, p.newTickUpper, p.swapAmount, liq);
    }

    // ─────────────────────────────── V4 撤仓/收费(与单币版同源)───────────────────────────────
    function _removeLiquidity(uint256 tokenId, uint128 dLiq, bool fullClose, uint256 deadline)
        internal returns (uint256 got0, uint256 got1)
    {
        uint256 b0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 b1 = IERC20(TOKEN1).balanceOf(address(this));
        IV4PositionManager(POSITION_MANAGER).modifyLiquidities(
            fullClose
                ? V4Encode.burn(_key(), tokenId, 0, 0, address(this))
                : V4Encode.decrease(_key(), tokenId, dLiq, 0, 0, address(this)),
            deadline
        );
        got0 = IERC20(TOKEN0).balanceOf(address(this)) - b0;
        got1 = IERC20(TOKEN1).balanceOf(address(this)) - b1;
    }

    function _collectFees(uint256 tokenId, uint256 deadline) internal returns (uint256 fee0, uint256 fee1) {
        uint256 b0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 b1 = IERC20(TOKEN1).balanceOf(address(this));
        IV4PositionManager(POSITION_MANAGER).modifyLiquidities(
            V4Encode.decrease(_key(), tokenId, 0, 0, 0, address(this)), deadline
        );
        fee0 = IERC20(TOKEN0).balanceOf(address(this)) - b0;
        fee1 = IERC20(TOKEN1).balanceOf(address(this)) - b1;
    }

    function _skimHarvestFee(uint256 fee0, uint256 fee1) internal returns (uint256 net0, uint256 net1) {
        uint256 cut0 = (fee0 * HARVEST_FEE_BPS) / 10000;
        uint256 cut1 = (fee1 * HARVEST_FEE_BPS) / 10000;
        if (cut0 > 0) _transfer(TOKEN0, GOVERNOR, cut0);
        if (cut1 > 0) _transfer(TOKEN1, GOVERNOR, cut1);
        net0 = fee0 - cut0;
        net1 = fee1 - cut1;
    }

    // ─────────────────────────────── 估值 / 健康度(双债合并,USDG 本位)───────────────────────────────
    function positionValue(uint256 id) public view returns (uint256 valueInLoan) {
        Position storage pos = positions[id];
        valueInLoan = IDualLpOracle(ORACLE).fairValueInLoan(pos.liquidity, pos.tickLower, pos.tickUpper);
    }

    /// 总债务折 LOAN(USDG):RISK 债经预言机折价 + LOAN 债原值。
    function totalDebtInLoan(uint256 id) public view returns (uint256) {
        Position storage pos = positions[id];
        (uint256 dRisk,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtRisk);
        (uint256 dLoan,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtLoan);
        return IDualLpOracle(ORACLE).riskValueInLoan(dRisk) + dLoan;
    }

    function isHealthy(uint256 id) public view returns (bool) {
        return (positionValue(id) * LLTV) / 1e18 >= totalDebtInLoan(id);
    }

    // ─────────────────────────────── 内部水管(与单币版同源)───────────────────────────────
    function _requireTwoSidedRange(int24 tickLower, int24 tickUpper) internal view {
        if (tickUpper - tickLower < MIN_WIDTH_TICKS) revert RangeTooNarrow();
        (, int24 tick,,) = IStateView(STATE_VIEW).getSlot0(POOL_ID);
        if (!(tickLower < tick && tick < tickUpper)) revert NotTwoSided();
    }

    function _liquidityFor(int24 tickLower, int24 tickUpper, uint256 amt0, uint256 amt1)
        internal view returns (uint128)
    {
        (uint160 sqrtP,,,) = IStateView(STATE_VIEW).getSlot0(POOL_ID);
        return LpMathExt.liquidityFor(sqrtP, tickLower, tickUpper, amt0, amt1);
    }

    function _v4Mint(
        int24 tickLower, int24 tickUpper, uint128 liq, uint128 max0, uint128 max1,
        uint256 amt0, uint256 amt1, uint256 deadline
    ) internal returns (uint256 tokenId) {
        if (PERMIT2.code.length == 0) {
            _approveIfNeeded(TOKEN0, POSITION_MANAGER, amt0); // mock PM 直接 transferFrom(仅无 Permit2 的测试链)
            _approveIfNeeded(TOKEN1, POSITION_MANAGER, amt1); // 真链不留这份闲置万能授权(审计 F2)
        }
        _armPermit2(TOKEN0); // 真 PM SETTLE_PAIR 经 Permit2 拉款(异构审查部署闸修复)
        _armPermit2(TOKEN1);
        tokenId = IV4PositionManager(POSITION_MANAGER).nextTokenId();
        IV4PositionManager(POSITION_MANAGER).modifyLiquidities(
            V4Encode.mint(_key(), tickLower, tickUpper, liq, max0, max1, address(this)), deadline
        );
    }

    /// open 后的零头按腿冲抵债务(封顶各腿当前债),用实际还款额记账;剩余由 _refundDust 退还。
    function _repayOpenDust(uint256 id, uint256 base0, uint256 base1) internal {
        Position storage pos = positions[id];
        uint256 cur0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 cur1 = IERC20(TOKEN1).balanceOf(address(this));
        uint256 d0 = cur0 > base0 ? cur0 - base0 : 0;
        uint256 d1 = cur1 > base1 ? cur1 - base1 : 0;
        (uint256 dustRisk, uint256 dustLoan) = LOAN_IS_C0 ? (d1, d0) : (d0, d1);
        if (dustRisk > 0) {
            (uint256 cur,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtRisk);
            uint256 pay = dustRisk < cur ? dustRisk : cur;
            _repayLeg(pos.debtRisk, RISK, pay);
        }
        if (dustLoan > 0) {
            (uint256 cur,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtLoan);
            uint256 pay = dustLoan < cur ? dustLoan : cur;
            _repayLeg(pos.debtLoan, LOAN, pay);
        }
    }

    function _snap() internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(TOKEN0).balanceOf(address(this));
        b1 = IERC20(TOKEN1).balanceOf(address(this));
    }

    /// 只退超出入口基线的零头,预存捐赠/误转绝不被扫走(继承单币版 E6 修复)。
    function _refundDust(address to, uint256 base0, uint256 base1) internal {
        uint256 cur0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 cur1 = IERC20(TOKEN1).balanceOf(address(this));
        uint256 d0 = cur0 > base0 ? cur0 - base0 : 0;
        uint256 d1 = cur1 > base1 ? cur1 - base1 : 0;
        if (d0 > 0) _transfer(TOKEN0, to, d0);
        if (d1 > 0) _transfer(TOKEN1, to, d1);
    }

    /// M5:清算尾款优先付借款人;收款失败(黑名单/暂停)则落国库代管,绝不允许收款人卡死清算。
    function _transferOrTreasury(address token, address to, uint256 amt) internal {
        if (amt == 0) return;
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amt));
        if (!(ok && (ret.length == 0 || abi.decode(ret, (bool))))) {
            _transfer(token, GOVERNOR, amt);
        }
    }

    function _safeCall(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!(ok && (ret.length == 0 || abi.decode(ret, (bool))))) revert TokenCallFailed();
    }
    function _pull(address token, address from, uint256 amt) internal {
        if (amt > 0) _safeCall(token, abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amt));
    }
    function _transfer(address token, address to, uint256 amt) internal {
        if (amt > 0) _safeCall(token, abi.encodeWithSelector(IERC20.transfer.selector, to, amt));
    }
    function _approveIfNeeded(address token, address spender, uint256 amt) internal {
        if (IERC20(token).allowance(address(this), spender) < amt) {
            _safeCall(token, abi.encodeWithSelector(IERC20.approve.selector, spender, type(uint256).max));
        }
    }

    /// 治理紧急阀:清零 Permit2→PM 额度(审计 F1);armed 复位后下次 mint 自动重新上膛。
    function revokePermit2(address token) external {
        if (msg.sender != GOVERNOR) revert NotGovernor();
        if (PERMIT2.code.length != 0) IPermit2Allowance(PERMIT2).approve(token, POSITION_MANAGER, 0, 0);
        permit2Armed[token] = false;
    }

    /// token→Permit2 万能授权 + Permit2→PM 万能额度,一次性。Permit2 无代码的链(mock 环境)跳过。
    function _armPermit2(address token) internal {
        if (permit2Armed[token] || PERMIT2.code.length == 0) return;
        _safeCall(token, abi.encodeWithSelector(IERC20.approve.selector, PERMIT2, type(uint256).max));
        IPermit2Allowance(PERMIT2).approve(token, POSITION_MANAGER, type(uint160).max, type(uint48).max);
        permit2Armed[token] = true;
    }
}
