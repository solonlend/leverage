// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  UniV4LeverageVault — Solon 杠杆两边平衡 LP 金库(Uniswap V4)。
  与 V3 版共享全部核心(抗操纵公允价、标准清算、SettlementMath、ExtraFi LendingPool 债务模型、KERNEL 数学),
  只换 DEX 交互层:V4 走 v4-periphery PositionManager 的 modifyLiquidities(action 编码,见 V4Periphery.sol)。

  与 V3 的关键差异(已按 source-verified 接口处理):
    · mint/increase 传"目标流动性 + 支付上限",不是"想投的两边数量" → 用 LiquidityAmounts.getLiquidityForAmounts
      在当前池价(StateView.getSlot0)下反算目标流动性。
    · modifyLiquidities 无返回值 → 撤仓到手数量用"本合约 token 余额差"测量。
    · 领手续费 = DECREASE_LIQUIDITY(liquidity=0)。全平 = BURN_POSITION(同时销毁底层 V4 仓位 NFT)。
    · V4 池无内置 observe() TWAP → 公允价源在 LpShareOracle 里改走 Chainlink(V4 版预言机),本合约只调 fairValueInLoan/zapAmountToToken0。
  仓位凭证仍是两层:底层 V4 仓位 NFT 锁本合约,上层 Solon NFT 在用户钱包(持有即所有)。
*/

import "./LpShareOracle.sol";
import {SettlementMath} from "./libraries/SettlementMath.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {
    Currency, IHooks, PoolKey, IV4PositionManager, V4Encode, PositionInfoLib
} from "./v4/V4Periphery.sol";

interface ILendingPool {
    function newDebtPosition(uint256 reserveId) external returns (uint256 debtId);
    function borrow(address onBehalfOf, uint256 debtId, uint256 amount) external;
    function repay(address onBehalfOf, uint256 debtId, uint256 amount) external returns (uint256 repaid);
    function getCurrentDebt(uint256 debtId) external view returns (uint256 currentDebt, uint256 latestBorrowingIndex);
}

interface ISwapExecutor {
    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata path)
        external returns (uint256 amountOut);
}

interface IRiskValueOracleV4 {
    function riskValueInLoan(uint256 riskAmount) external view returns (uint256);
}

/// V4 pool state lens (v4-periphery StateView): current spot sqrtPrice for mint liquidity sizing.
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
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId); // ERC-721 标准签名,钱包/索引器识别 mint(from=0)/burn(to=0)
    mapping(uint256 => address) public ownerOf;
    uint256 internal _nextId = 1;
    function nextPositionId() external view returns (uint256) { return _nextId; } // keeper 扫仓上界
    function _mint(address to) internal returns (uint256 id) { id = _nextId++; ownerOf[id] = to; emit Transfer(address(0), to, id); }
    function _burn(uint256 id) internal { emit Transfer(ownerOf[id], address(0), id); delete ownerOf[id]; }
}

abstract contract ReentrancyGuard {
    uint256 private _lock = 1;
    modifier nonReentrant() { require(_lock == 1, "REENTRANCY"); _lock = 2; _; _lock = 1; }
}

contract UniV4LeverageVault is PositionReceipt721, ReentrancyGuard {
    struct Position {
        uint256 v4TokenId;   // 底层 V4 仓位 NFT(锁本合约)
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 debtId;      // ExtraFi LendingPool 债务仓位 id
    }

    mapping(uint256 => Position) public positions;   // Solon NFT id => 仓位
    mapping(address => bool) public liquidators;

    address public immutable GOVERNOR;
    address public immutable POSITION_MANAGER;
    /// canonical Permit2(全链同址);真 PM 的 SETTLE_PAIR 只认 Permit2 额度(与 dual 版同步修复)
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    mapping(address => bool) internal permit2Armed;   // v4-periphery PositionManager
    address public immutable STATE_VIEW;         // v4-periphery StateView(读 slot0)
    address public immutable LENDING_POOL;
    uint256 public immutable RESERVE_ID;
    address public immutable ORACLE;
    address public immutable SWAP_EXECUTOR;
    address public immutable TOKEN0;             // = pool currency0(地址小的那个,Uniswap 排序)
    address public immutable TOKEN1;             // = pool currency1(地址大的那个)
    // 借款/出金币(USDG=LOAN)可能排在 currency0 或 currency1(按地址排,如 NVDA/USDG 里 USDG 是 c0)。
    // 内部数学/mint 一律用排序后的 TOKEN0/TOKEN1;借还/zap/出金按 LOAN/RISK 语义走。
    bool    public immutable LOAN_IS_C0;         // true=USDG 是 currency0(TOKEN0)
    address public immutable LOAN;               // USDG(借款/出金)
    address public immutable RISK;               // 风险资产腿
    uint24  public immutable FEE;
    int24   public immutable TICK_SPACING;
    address public immutable HOOKS;
    bytes32 public immutable POOL_ID;

    int24   public immutable MIN_WIDTH_TICKS;
    uint256 public immutable LIQ_BONUS_BPS;
    uint256 public immutable PROTOCOL_FEE_BPS;  // 清算奖励里协议抽成
    uint256 public immutable HARVEST_FEE_BPS;   // LP 手续费/claim 收益的协议抽成(Beefy/Extra 式,提取+复投都抽)
    uint256 public immutable BORROW_FEE_BPS;    // 借款开仓费(Extra borrowFeeRate 式,开仓时对借款额抽一口)
    uint256 public immutable CLOSE_FACTOR_BPS;
    uint256 public immutable LLTV;

    uint256 internal constant GAP_EPS = 1e3;
    uint256 internal constant MAX_GAP_SLIPPAGE_BPS = 500;

    error NotHolder();
    error NotGovernor();
    error NotLiquidator();
    error RangeTooNarrow();
    error Healthy();
    error SolventBadDebt();
    error UnhealthyAfterClose();

    event LiquidatorSet(address indexed keeper, bool allowed);
    // 仓位生命周期事件:keeper 索引与前端渲染的唯一数据源,两个金库(V3/V4)同一套签名
    event PositionOpened(uint256 indexed id, address indexed owner, uint256 invest, uint256 borrowed, uint256 debtId, uint128 liquidity, int24 tickLower, int24 tickUpper);
    event PositionIncreased(uint256 indexed id, uint256 invest, uint256 borrowed, uint128 liquidityAdded);
    event PositionClosed(uint256 indexed id, uint16 percentBps, uint256 repaid, uint256 outToUser, bool full);
    event Harvested(uint256 indexed id, uint256 netFee0, uint256 netFee1, bool compounded);
    event PositionLiquidated(uint256 indexed id, address indexed keeper, uint256 repaid, uint256 seized, uint256 protocolFee, bool fullyClosed);
    // 全平/清算后债务仓仍有残债 = 抵押不足以覆盖债务的坏账,社会化给出借人。链上可观测供监控告警。
    event BadDebt(uint256 indexed id, uint256 indexed debtId, uint256 residualDebt);

    modifier onlyHolder(uint256 id) { if (ownerOf[id] != msg.sender) revert NotHolder(); _; }

    struct InitParams {
        address governor; address positionManager; address stateView;
        address lendingPool; uint256 reserveId; address oracle; address swapExecutor;
        address token0; address token1; bool loanIsC0; uint24 fee; int24 tickSpacing; address hooks;
        int24 minWidthTicks; uint256 liqBonusBps; uint256 protocolFeeBps; uint256 harvestFeeBps;
        uint256 borrowFeeBps; uint256 closeFactorBps; uint256 lltv;
    }

    constructor(InitParams memory p) {
        require(
            p.governor != address(0) && p.positionManager != address(0) && p.stateView != address(0)
            && p.lendingPool != address(0) && p.oracle != address(0) && p.swapExecutor != address(0)
            && p.token0 != address(0) && p.token1 != address(0),
            "ZERO_ADDR"
        );
        require(p.lltv > 0 && p.lltv <= 1e18, "BAD_LLTV");
        require(p.closeFactorBps > 0 && p.closeFactorBps <= 10000, "BAD_CLOSE_FACTOR");
        require(p.liqBonusBps <= 2000 && p.protocolFeeBps <= 5000 && p.harvestFeeBps <= 3000, "BAD_FEES");
        require(p.minWidthTicks > 0, "BAD_MIN_WIDTH");
        GOVERNOR = p.governor; POSITION_MANAGER = p.positionManager; STATE_VIEW = p.stateView;
        LENDING_POOL = p.lendingPool; RESERVE_ID = p.reserveId; ORACLE = p.oracle; SWAP_EXECUTOR = p.swapExecutor;
        require(p.token0 < p.token1, "UNSORTED"); // Uniswap 要求 currency0 < currency1
        TOKEN0 = p.token0; TOKEN1 = p.token1; FEE = p.fee; TICK_SPACING = p.tickSpacing; HOOKS = p.hooks;
        LOAN_IS_C0 = p.loanIsC0;
        LOAN = p.loanIsC0 ? p.token0 : p.token1;
        RISK = p.loanIsC0 ? p.token1 : p.token0;
        MIN_WIDTH_TICKS = p.minWidthTicks; LIQ_BONUS_BPS = p.liqBonusBps; PROTOCOL_FEE_BPS = p.protocolFeeBps;
        HARVEST_FEE_BPS = p.harvestFeeBps; BORROW_FEE_BPS = p.borrowFeeBps;
        CLOSE_FACTOR_BPS = p.closeFactorBps; LLTV = p.lltv;
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

    // ─────────────────────────────── OPEN ───────────────────────────────
    struct OpenParams {
        uint256 amountInvest; uint256 amountBorrow;
        int24 tickLower; int24 tickUpper;
        uint128 amount0Max; uint128 amount1Max; // mint 支付上限
        uint128 minLiquidity;                    // 最小可接受流动性(滑点保护:zap 被夹→liq 变小→revert)
        bytes zapPath; uint256 deadline;
    }

    function open(OpenParams calldata p) external nonReentrant returns (uint256 positionNftId) {
        _requireTwoSidedRange(p.tickLower, p.tickUpper);
        (uint256 base0, uint256 base1) = _snap(); // 入口基线,退零头不碰预存资金

        _pull(LOAN, msg.sender, p.amountInvest);
        uint256 debtId = ILendingPool(LENDING_POOL).newDebtPosition(RESERVE_ID);
        ILendingPool(LENDING_POOL).borrow(address(this), debtId, p.amountBorrow);
        uint256 totalUsdg = p.amountInvest + p.amountBorrow;

        // 借款开仓费:对借款额抽 BORROW_FEE_BPS 进金库(债务仍是全额 → 等于一道开仓利差)
        uint256 borrowFee = (p.amountBorrow * BORROW_FEE_BPS) / 10000;
        if (borrowFee > 0) { _transfer(LOAN, GOVERNOR, borrowFee); totalUsdg -= borrowFee; }

        (uint256 amt0, uint256 amt1) = _zapToBothSides(totalUsdg, p.tickLower, p.tickUpper, p.zapPath);

        // 目标流动性:当前池价下,amt0/amt1 能撑起多少 L
        uint128 liq = _liquidityFor(p.tickLower, p.tickUpper, amt0, amt1);
        require(liq > 0, "ZERO_LIQ"); // 拒绝零流动性垃圾仓位(刷 debtId/事件)
        require(liq >= p.minLiquidity, "SLIPPAGE_LIQ"); // 滑点下限:zap 被夹导致 liq 缩水就 revert
        uint256 tokenId = _v4Mint(p.tickLower, p.tickUpper, liq, p.amount0Max, p.amount1Max, amt0, amt1, p.deadline);

        positionNftId = _mint(msg.sender);
        positions[positionNftId] = Position({
            v4TokenId: tokenId, liquidity: liq,
            tickLower: p.tickLower, tickUpper: p.tickUpper, debtId: debtId
        });

        // 退还 zap/mint 后没用完的零头给用户(取较小值那边会剩一点,不能闷在合约里)
        _refundDust(msg.sender, base0, base1);
        require(_isHealthy(positionNftId), "UNHEALTHY_OPEN"); // 开仓即须健康,不许秒开可清算仓位
        emit PositionOpened(positionNftId, msg.sender, p.amountInvest, p.amountBorrow, debtId, liq, p.tickLower, p.tickUpper);
    }

    // ─────────────────────────────── INCREASE(加仓) ───────────────────────────────
    struct IncreaseParams {
        uint256 amountInvest; uint256 amountBorrow;
        uint128 amount0Max; uint128 amount1Max; uint128 minLiquidity;
        bytes zapPath; uint256 deadline;
    }

    /// 加仓:再投/再借 → zap 拆两边 → 往现有仓位 increaseLiquidity,提升本金与杠杆。
    function increase(uint256 id, IncreaseParams calldata p) external nonReentrant onlyHolder(id) {
        Position storage pos = positions[id];
        (uint256 base0, uint256 base1) = _snap();
        _pull(LOAN, msg.sender, p.amountInvest);
        ILendingPool(LENDING_POOL).borrow(address(this), pos.debtId, p.amountBorrow);
        uint256 totalUsdg = p.amountInvest + p.amountBorrow;

        (uint256 amt0, uint256 amt1) = _zapToBothSides(totalUsdg, pos.tickLower, pos.tickUpper, p.zapPath);
        uint128 addLiq = _liquidityFor(pos.tickLower, pos.tickUpper, amt0, amt1);
        require(addLiq >= p.minLiquidity, "SLIPPAGE_LIQ");

        pos.liquidity += addLiq; // 记账在外部 increase 之前(revert 会整体回滚,CEI)
        if (PERMIT2.code.length == 0) {
            if (PERMIT2.code.length == 0) {
                _approveIfNeeded(TOKEN0, POSITION_MANAGER, amt0);
                _approveIfNeeded(TOKEN1, POSITION_MANAGER, amt1);
            }
            _armPermit2(TOKEN0);
            _armPermit2(TOKEN1);
        }
        _armPermit2(TOKEN0);
        _armPermit2(TOKEN1);
        IV4PositionManager(POSITION_MANAGER).modifyLiquidities(
            V4Encode.increase(_key(), pos.v4TokenId, addLiq, p.amount0Max, p.amount1Max), p.deadline
        );
        _refundDust(msg.sender, base0, base1); // 加仓零头也退还
        require(_isHealthy(id), "UNHEALTHY_INCREASE"); // 加仓后同样必须健康
        emit PositionIncreased(id, p.amountInvest, p.amountBorrow, addLiq);
    }

    // ─────────────────────────────── HARVEST(claim,两模式) ───────────────────────────────
    /// 领手续费。compound=false 提给用户落袋;compound=true 复投回仓位利滚利。领完做健康检查防抽穿。
    function harvest(uint256 id, bool compound, bytes calldata zapPath, uint256 deadline)
        external nonReentrant onlyHolder(id) returns (uint256 out0, uint256 out1)
    {
        Position storage pos = positions[id];
        (uint256 base0, uint256 base1) = _snap();
        (uint256 fee0, uint256 fee1) = _collectFees(pos.v4TokenId, deadline);
        (fee0, fee1) = _skimHarvestFee(fee0, fee1); // 协议抽成先进金库,剩下归用户

        if (!compound) {
            // 提取:两边手续费直接给用户
            if (fee0 > 0) _transfer(TOKEN0, msg.sender, fee0);
            if (fee1 > 0) _transfer(TOKEN1, msg.sender, fee1);
            out0 = fee0; out1 = fee1;
        } else {
            // 复投:手续费合并成 LOAN → 重新拆两边 → increaseLiquidity
            uint256 usdg = _consolidateToLoan(fee0, fee1, zapPath);
            (uint256 amt0, uint256 amt1) = _zapToBothSides(usdg, pos.tickLower, pos.tickUpper, zapPath);
            uint128 addLiq = _liquidityFor(pos.tickLower, pos.tickUpper, amt0, amt1);
            pos.liquidity += addLiq; // 记账在外部 increase 之前(CEI)
            if (PERMIT2.code.length == 0) {
                _approveIfNeeded(TOKEN0, POSITION_MANAGER, amt0);
                _approveIfNeeded(TOKEN1, POSITION_MANAGER, amt1);
            }
            _armPermit2(TOKEN0);
            _armPermit2(TOKEN1);
            IV4PositionManager(POSITION_MANAGER).modifyLiquidities(
                V4Encode.increase(_key(), pos.v4TokenId, addLiq, type(uint128).max, type(uint128).max), deadline
            );
            _refundDust(msg.sender, base0, base1); // 复投 zap/increase 的取整零头退还(invariant fuzz 抓到的滞留)
        }
        require(_isHealthy(id), "UNHEALTHY_AFTER_HARVEST");
        emit Harvested(id, fee0, fee1, compound); // fee0/fee1 已是协议抽成后的净额
    }

    // ─────────────────────────────── CLOSE ───────────────────────────────
    struct CloseParams { uint16 percent; uint256 minOutSingleToken; bytes zapPath; uint256 deadline; }

    /// 平仓:撤仓 → token0 换 USDG → 按比例还债 → 剩余 USDG 单币还用户 →(全平)销毁两层 NFT。
    function close(uint256 id, CloseParams calldata c)
        external nonReentrant onlyHolder(id) returns (uint256 out)
    {
        Position storage pos = positions[id];
        uint256 debtId = pos.debtId;
        bool fullClose = (c.percent >= 10000);
        uint128 dLiq = fullClose ? pos.liquidity : uint128((uint256(pos.liquidity) * c.percent) / 10000);
        require(dLiq > 0, "ZERO_LIQ");

        bool preInsolvent; bool preChecked;
        if (fullClose) {
            try this.positionValue(id) returns (uint256 pv) {
                try ILendingPool(LENDING_POOL).getCurrentDebt(debtId) returns (uint256 td, uint256) {
                    preInsolvent = pv < td; preChecked = true;
                } catch {}
            } catch {}
        }

        pos.liquidity -= dLiq;
        bool closedAll = fullClose || pos.liquidity == 0;
        if (closedAll) _burn(id);

        // 先单独收累积手续费 + 抽我们那一刀(堵死"直接平仓白拿 fee 绕过 harvest 抽成"的路径),再撤本金。
        (uint256 fee0, uint256 fee1) = _collectFees(pos.v4TokenId, c.deadline);
        (uint256 netFee0, uint256 netFee1) = _skimHarvestFee(fee0, fee1);
        (uint256 got0, uint256 got1) = _removeLiquidity(pos.v4TokenId, dLiq, fullClose, c.deadline);
        got0 += netFee0; got1 += netFee1; // 本金 + 净手续费

        // 风险腿换成 LOAN,统一出金 USDG
        uint256 gotLoan = _consolidateToLoan(got0, got1, c.zapPath);

        (uint256 curDebt,) = ILendingPool(LENDING_POOL).getCurrentDebt(debtId);
        uint256 debtToRepay = fullClose ? curDebt : (curDebt * c.percent + 9999) / 10000;
        if (debtToRepay > curDebt) debtToRepay = curDebt;
        if (debtToRepay > gotLoan) debtToRepay = gotLoan;
        _approveIfNeeded(LOAN, LENDING_POOL, debtToRepay);
        uint256 repaid = ILendingPool(LENDING_POOL).repay(address(this), debtId, debtToRepay);

        out = gotLoan - repaid;
        require(out >= c.minOutSingleToken, "SLIPPAGE");
        if (out > 0) _transfer(LOAN, msg.sender, out);
        if (!closedAll) if (!_isHealthy(id)) revert UnhealthyAfterClose();
        emit PositionClosed(id, c.percent, repaid, out, closedAll);
        // 全平后仍有残债 = 坏账(抵押卖光都不够还),链上标记供监控;债务仓从此无 receipt 可触达
        if (closedAll) {
            (uint256 residual,) = ILendingPool(LENDING_POOL).getCurrentDebt(debtId);
            if (residual > GAP_EPS) {
                if (!(preChecked && preInsolvent)) revert SolventBadDebt();
                emit BadDebt(id, debtId, residual);
            }
        }
    }

    // ─────────────────────────────── LIQUIDATE(标准模型) ───────────────────────────────
    struct LiquidateParams { uint256 repayAmount; uint256 minSeizeOut; bytes zapPath; uint256 deadline; }

    function liquidate(uint256 id, LiquidateParams calldata lp)
        external nonReentrant returns (bool fullyClosed)
    {
        if (!liquidators[msg.sender]) revert NotLiquidator();
        if (_isHealthy(id)) revert Healthy();

        Position storage pos = positions[id];
        uint256 debtId = pos.debtId;
        address borrower = ownerOf[id]; // 在 _burn 前记下,超额扣押的部分要退还给他

        (uint256 curDebt,) = ILendingPool(LENDING_POOL).getCurrentDebt(debtId);
        uint256 declaredRepay = lp.repayAmount;
        uint256 maxRepay = (curDebt * CLOSE_FACTOR_BPS) / 10000;
        if (declaredRepay > maxRepay) declaredRepay = maxRepay;
        require(declaredRepay > 0, "ZERO_REPAY");

        _pull(LOAN, msg.sender, declaredRepay);
        _approveIfNeeded(LOAN, LENDING_POOL, declaredRepay);
        uint256 repayAmount = ILendingPool(LENDING_POOL).repay(address(this), debtId, declaredRepay);
        if (declaredRepay > repayAmount) _transfer(LOAN, msg.sender, declaredRepay - repayAmount);
        require(repayAmount > 0, "ZERO_REPAY");

        SettlementMath.Seize memory s = SettlementMath.liquidationSeize(repayAmount, LIQ_BONUS_BPS, PROTOCOL_FEE_BPS);
        uint256 posVal = positionValue(id);
        uint128 seizeLiq = s.seizeValue >= posVal
            ? pos.liquidity
            : uint128((uint256(pos.liquidity) * s.seizeValue) / posVal);
        require(seizeLiq > 0, "ZERO_SEIZE");

        pos.liquidity -= seizeLiq;
        fullyClosed = (pos.liquidity == 0);
        if (fullyClosed) _burn(id);

        (uint256 fee0, uint256 fee1) = _collectFees(pos.v4TokenId, lp.deadline);
        (fee0, fee1) = _skimHarvestFee(fee0, fee1); // Match close and dual liquidation fee accounting.
        (uint256 got0, uint256 got1) = _removeLiquidity(pos.v4TokenId, seizeLiq, fullyClosed, lp.deadline);
        got0 += fee0; got1 += fee1;
        uint256 gotLoan = _consolidateToLoan(got0, got1, lp.zapPath);

        uint256 protocolFee = s.protocolFee > gotLoan ? gotLoan : s.protocolFee;
        if (protocolFee > 0) _transfer(LOAN, GOVERNOR, protocolFee);
        uint256 avail = gotLoan - protocolFee;
        // keeper 净得封顶到"应得 bonus"(s.liquidatorSeize),防止预言机低估/正滑点时超额扣押借款人抵押(红队 F2)
        uint256 toLiquidator = avail > s.liquidatorSeize ? s.liquidatorSeize : avail;
        require(toLiquidator >= lp.minSeizeOut, "SLIPPAGE");
        if (toLiquidator > 0) _transfer(LOAN, msg.sender, toLiquidator);

        // 超过 keeper 应得的部分归借款人:先冲抵其剩余债务(降坏账),余额退还本人
        uint256 excess = avail - toLiquidator;
        if (excess > 0) {
            (uint256 stillOwed,) = ILendingPool(LENDING_POOL).getCurrentDebt(debtId);
            uint256 extra = excess > stillOwed ? stillOwed : excess;
            if (extra > 0) {
                _approveIfNeeded(LOAN, LENDING_POOL, extra);
                excess -= ILendingPool(LENDING_POOL).repay(address(this), debtId, extra);
            }
            if (excess > 0) _transfer(LOAN, borrower, excess);
        }

        emit PositionLiquidated(id, msg.sender, repayAmount, toLiquidator, protocolFee, fullyClosed);
        if (fullyClosed) {
            (uint256 residual,) = ILendingPool(LENDING_POOL).getCurrentDebt(debtId);
            if (residual > 0) emit BadDebt(id, debtId, residual);
        }
    }

    // ─────────────────────────────── 估值 / 健康度 ───────────────────────────────
    function positionValue(uint256 id) public view returns (uint256 valueInLoan) {
        Position storage pos = positions[id];
        valueInLoan = LpShareOracle(ORACLE).fairValueInLoan(pos.liquidity, pos.tickLower, pos.tickUpper);
    }

    function _isHealthy(uint256 id) internal view returns (bool) {
        Position storage pos = positions[id];
        uint256 val = LpShareOracle(ORACLE).fairValueInLoan(pos.liquidity, pos.tickLower, pos.tickUpper);
        (uint256 debt,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtId);
        return (val * LLTV) / 1e18 >= debt;
    }

    function _requireTwoSidedRange(int24 tickLower, int24 tickUpper) internal view {
        if (tickUpper - tickLower < MIN_WIDTH_TICKS) revert RangeTooNarrow();
        (, int24 cur,,) = IStateView(STATE_VIEW).getSlot0(POOL_ID);
        require(tickLower < cur && cur < tickUpper, "NOT_STRADDLING"); // 强制跨现价,拒单边
    }

    // ─────────────────────────────── V4 DEX 交互 ───────────────────────────────
    function _liquidityFor(int24 tickLower, int24 tickUpper, uint256 amt0, uint256 amt1)
        internal view returns (uint128)
    {
        (uint160 sqrtP,,,) = IStateView(STATE_VIEW).getSlot0(POOL_ID);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(tickUpper);
        return LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, amt0, amt1);
    }

    function _v4Mint(
        int24 tickLower, int24 tickUpper, uint128 liq, uint128 max0, uint128 max1,
        uint256 amt0, uint256 amt1, uint256 deadline
    ) internal returns (uint256 tokenId) {
        if (PERMIT2.code.length == 0) {
            if (PERMIT2.code.length == 0) {
                _approveIfNeeded(TOKEN0, POSITION_MANAGER, amt0);
                _approveIfNeeded(TOKEN1, POSITION_MANAGER, amt1);
            }
            _armPermit2(TOKEN0);
            _armPermit2(TOKEN1);
        }
        _armPermit2(TOKEN0);
        _armPermit2(TOKEN1);
        tokenId = IV4PositionManager(POSITION_MANAGER).nextTokenId(); // 新 id = 调用前的 nextTokenId
        IV4PositionManager(POSITION_MANAGER).modifyLiquidities(
            V4Encode.mint(_key(), tickLower, tickUpper, liq, max0, max1, address(this)), deadline
        );
    }

    /// 撤流动性(部分=DECREASE,全平=BURN 销毁底层 V4 NFT),用余额差测量到手两边。
    function _removeLiquidity(uint256 tokenId, uint128 dLiq, bool full, uint256 deadline)
        internal returns (uint256 got0, uint256 got1)
    {
        uint256 b0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 b1 = IERC20(TOKEN1).balanceOf(address(this));
        bytes memory data = full
            ? V4Encode.burn(_key(), tokenId, 0, 0, address(this))
            : V4Encode.decrease(_key(), tokenId, dLiq, 0, 0, address(this));
        IV4PositionManager(POSITION_MANAGER).modifyLiquidities(data, deadline);
        got0 = IERC20(TOKEN0).balanceOf(address(this)) - b0;
        got1 = IERC20(TOKEN1).balanceOf(address(this)) - b1;
    }

    /// 领手续费 = DECREASE_LIQUIDITY(liquidity=0);用余额差测量。
    function _collectFees(uint256 tokenId, uint256 deadline) internal returns (uint256 fee0, uint256 fee1) {
        uint256 b0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 b1 = IERC20(TOKEN1).balanceOf(address(this));
        IV4PositionManager(POSITION_MANAGER).modifyLiquidities(
            V4Encode.decrease(_key(), tokenId, 0, 0, 0, address(this)), deadline
        );
        fee0 = IERC20(TOKEN0).balanceOf(address(this)) - b0;
        fee1 = IERC20(TOKEN1).balanceOf(address(this)) - b1;
    }

    /// 入口余额快照:退零头只退"当前 - 基线"的增量,预存捐赠/误转(计入基线)绝不被扫走。
    function _snap() internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(TOKEN0).balanceOf(address(this));
        b1 = IERC20(TOKEN1).balanceOf(address(this));
    }

    /// 退还本次操作产生的松散 token0/token1 零头给 `to`。base0/base1 = 函数入口快照,
    /// 只退超出基线的部分 —— 堵死"误转进金库的币被下一笔 open/close 整包薅走"(红队 E6)。
    function _refundDust(address to, uint256 base0, uint256 base1) internal {
        uint256 cur0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 cur1 = IERC20(TOKEN1).balanceOf(address(this));
        uint256 d0 = cur0 > base0 ? cur0 - base0 : 0;
        uint256 d1 = cur1 > base1 ? cur1 - base1 : 0;
        if (d0 > 0) _transfer(TOKEN0, to, d0);
        if (d1 > 0) _transfer(TOKEN1, to, d1);
    }

    /// 从领到的手续费里 skim HARVEST_FEE_BPS 进金库(GOVERNOR 国库),返回归用户的净额。
    /// harvest 和 close 共用 —— 无论用户怎么 realize LP 手续费,我们的抽成都拿得到。
    function _skimHarvestFee(uint256 fee0, uint256 fee1) internal returns (uint256 net0, uint256 net1) {
        uint256 cut0 = (fee0 * HARVEST_FEE_BPS) / 10000;
        uint256 cut1 = (fee1 * HARVEST_FEE_BPS) / 10000;
        if (cut0 > 0) _transfer(TOKEN0, GOVERNOR, cut0);
        if (cut1 > 0) _transfer(TOKEN1, GOVERNOR, cut1);
        net0 = fee0 - cut0;
        net1 = fee1 - cut1;
    }

    /// 把手里的 totalLoan(USDG)拆成 mint 需要的 (amt0, amt1)=currency0/currency1 数量。
    /// 预言机给"应放到 currency0 那腿的 loan 价值",再按 LOAN 排在哪一边决定换哪边。
    function _zapToBothSides(uint256 totalLoan, int24 tickLower, int24 tickUpper, bytes memory zapPath)
        internal returns (uint256 amt0, uint256 amt1)
    {
        uint256 loanForC0 = LpShareOracle(ORACLE).zapAmountToToken0(totalLoan, tickLower, tickUpper);
        if (LOAN_IS_C0) {
            // LOAN=c0, RISK=c1:c0 腿留 loan,把其余换成 c1(RISK)
            uint256 swapIn = totalLoan - loanForC0;
            amt1 = _swapExactIn(LOAN, RISK, swapIn, _minRiskOut(swapIn), zapPath);
            amt0 = loanForC0;
        } else {
            // LOAN=c1, RISK=c0:把 loanForC0 换成 c0(RISK),其余留 loan
            amt0 = _swapExactIn(LOAN, RISK, loanForC0, _minRiskOut(loanForC0), zapPath);
            amt1 = totalLoan - loanForC0;
        }
    }

    /// 把撤仓到手的 (got0, got1)=c0/c1,风险腿换成 LOAN,返回合并后的 LOAN 总额。
    function _consolidateToLoan(uint256 got0, uint256 got1, bytes memory zapPath)
        internal returns (uint256 gotLoan)
    {
        if (LOAN_IS_C0) {
            gotLoan = got0;
            if (got1 > 0) gotLoan += _swapExactIn(RISK, LOAN, got1, _minLoanOut(got1), zapPath); // c1=RISK→LOAN
        } else {
            gotLoan = got1;
            if (got0 > 0) gotLoan += _swapExactIn(RISK, LOAN, got0, _minLoanOut(got0), zapPath); // c0=RISK→LOAN
        }
    }

    function _minRiskOut(uint256 loanAmount) internal view returns (uint256) {
        if (loanAmount == 0) return 0;
        return (loanAmount * (10000 - MAX_GAP_SLIPPAGE_BPS) / 10000) * 1e18
            / IRiskValueOracleV4(ORACLE).riskValueInLoan(1e18);
    }

    function _minLoanOut(uint256 riskAmount) internal view returns (uint256) {
        if (riskAmount == 0) return 0;
        return IRiskValueOracleV4(ORACLE).riskValueInLoan(riskAmount)
            * (10000 - MAX_GAP_SLIPPAGE_BPS) / 10000;
    }

    // ─────────────────────────────── 通用辅助 ───────────────────────────────
    function _safeCall(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "TOKEN_CALL_FAILED");
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
    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes memory path)
        internal returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;
        _approveIfNeeded(tokenIn, SWAP_EXECUTOR, amountIn);
        amountOut = ISwapExecutor(SWAP_EXECUTOR).swapExactInput(tokenIn, tokenOut, amountIn, minOut, path);
    }

    /// 治理紧急阀:清零 Permit2→PM 额度;armed 复位后下次 mint 自动重新上膛。
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
