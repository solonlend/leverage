// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  UniV3DualVault — Dual-Borrow 杠杆 LP 金库(Uniswap V3),RH 首发部署目标。
  与 UniV4DualVault 完全同构(设计 docs/DESIGN-dual-borrow-v1.md),只换 DEX 交互层:
  V3 NFPM 直调(amount-based mint 自带返回值)、collect 领费(零可领会 revert → try/catch)、
  取价走 V3 池 slot0。核心机制逐条同 V4 版:
    · open 双币借款零 swap;close 匹配还债 + topUp + 缺口 exactOutput + 水下降级;
    · addMargin 单双侧代还;rebalance 债务不动只换 delta;liquidate 双资产价值口径 F2 封顶;
    · GAP_EPS 取整尘容忍;实际还款额记账(repay 返回值);基线感知退零头(E6)。
  验证:RhDualFork.t.sol F-D 全真 e2e(真池/真喂价/真 executor/真双储备)。
*/

import {SettlementMath} from "./libraries/SettlementMath.sol";
import {LiquidationSurplus} from "./libraries/LiquidationSurplus.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {TickMath} from "./libraries/TickMath.sol";

interface ILendingPool {
    function newDebtPosition(uint256 reserveId) external returns (uint256 debtId);
    function getUnderlyingTokenAddress(uint256 reserveId) external view returns (address);
    function borrow(address onBehalfOf, uint256 debtId, uint256 amount) external;
    function repay(address onBehalfOf, uint256 debtId, uint256 amount) external returns (uint256 repaid);
    function getCurrentDebt(uint256 debtId) external view returns (uint256 currentDebt, uint256 latestBorrowingIndex);
}

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

interface IUniV3Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    function mint(MintParams calldata) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    struct DecreaseParamsV3 { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    function decreaseLiquidity(DecreaseParamsV3 calldata) external returns (uint256 amount0, uint256 amount1);
    struct IncreaseParamsV3 { uint256 tokenId; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    function increaseLiquidity(IncreaseParamsV3 calldata) external returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    struct CollectParamsV3 { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function collect(CollectParamsV3 calldata) external returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external;
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

contract UniV3DualVault is PositionReceipt721, ReentrancyGuard {
    struct Position {
        uint256 dexTokenId;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 debtRisk;
        uint256 debtLoan;
    }

    mapping(uint256 => Position) public positions;
    mapping(address => bool) public liquidators;

    address public immutable GOVERNOR;
    address public immutable POSITION_MANAGER;
    address public immutable POOL;
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

    int24   public immutable MIN_WIDTH_TICKS;
    uint256 public immutable LIQ_BONUS_BPS;
    uint256 public immutable PROTOCOL_FEE_BPS;
    uint256 public immutable HARVEST_FEE_BPS;
    uint256 public immutable CLOSE_FACTOR_BPS;
    uint256 public immutable LLTV;

    uint256 internal constant GAP_EPS = 1e3;
    /// 降级 swap(盈余全换)的最大容忍滑点:minOut 由预言机公允价反推。
    /// 经济审计 E-1:此前 minOut=0 + 用户可控 zapPath 可把整条盈余腿洗进攻击者池子、坏账甩给出借人。
    uint256 internal constant MAX_GAP_SLIPPAGE_BPS = 500;
    /// 单笔清算最小价值(LOAN 单位),防粉尘清算骚扰(经济审计 E-3)。
    uint256 internal constant MIN_LIQ_VALUE = 1e4;

    error NotHolder();
    error NotGovernor();
    error DustLiq();
    error NotTwoSided();
    error SeizeValueLow();
    error Slippage();
    error SlippageGap();
    error SlippageLiq();
    error SolventBadDebt();
    error TokenCallFailed();
    error UnhealthyAfterClose();
    error UnhealthyAfterHarvest();
    error UnhealthyAfterRebalance();
    error UnhealthyIncrease();
    error UnhealthyOpen();
    error ZeroLiq();
    error ZeroSeize();
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
    event MarginAdded(uint256 indexed id, address indexed payer, uint256 repaidRisk, uint256 repaidLoan);
    event Harvested(uint256 indexed id, uint256 fee0, uint256 fee1, bool compound); // fee0/fee1 为协议抽成后净额
    event Rebalanced(uint256 indexed id, int24 newTickLower, int24 newTickUpper, int256 swapAmount, uint128 newLiquidity);
    event PositionLiquidated(
        uint256 indexed id, address indexed keeper,
        uint256 repaidRisk, uint256 repaidLoan, uint256 seizeValueToKeeper, uint256 protocolFeeValue, bool fullyClosed
    );

    modifier onlyHolder(uint256 id) { if (ownerOf[id] != msg.sender) revert NotHolder(); _; }

    struct InitParams {
        address governor; address positionManager; address pool;
        address lendingPool; uint256 reserveRisk; uint256 reserveLoan;
        address oracle; address swapExecutor;
        address token0; address token1; bool loanIsC0; uint24 fee;
        int24 minWidthTicks; uint256 liqBonusBps; uint256 protocolFeeBps; uint256 harvestFeeBps;
        uint256 closeFactorBps; uint256 lltv;
    }

    constructor(InitParams memory p) {
        require(
            p.governor != address(0) && p.positionManager != address(0) && p.pool != address(0)
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
        GOVERNOR = p.governor; POSITION_MANAGER = p.positionManager; POOL = p.pool;
        LENDING_POOL = p.lendingPool; RESERVE_RISK = p.reserveRisk; RESERVE_LOAN = p.reserveLoan;
        ORACLE = p.oracle; SWAP_EXECUTOR = p.swapExecutor;
        TOKEN0 = p.token0; TOKEN1 = p.token1; FEE = p.fee;
        LOAN_IS_C0 = p.loanIsC0;
        LOAN = p.loanIsC0 ? p.token0 : p.token1;
        RISK = p.loanIsC0 ? p.token1 : p.token0;
        // code-review:储备 id 与两腿代币必须绑定一致,id 写反=记账灾难(借 USDG 记成 wei 级 WETH 债)
        require(ILendingPool(p.lendingPool).getUnderlyingTokenAddress(p.reserveRisk) == (p.loanIsC0 ? p.token1 : p.token0), "RESERVE_RISK_MISMATCH");
        require(ILendingPool(p.lendingPool).getUnderlyingTokenAddress(p.reserveLoan) == (p.loanIsC0 ? p.token0 : p.token1), "RESERVE_LOAN_MISMATCH");
        MIN_WIDTH_TICKS = p.minWidthTicks; LIQ_BONUS_BPS = p.liqBonusBps; PROTOCOL_FEE_BPS = p.protocolFeeBps;
        HARVEST_FEE_BPS = p.harvestFeeBps; CLOSE_FACTOR_BPS = p.closeFactorBps; LLTV = p.lltv;
    }

    function setLiquidator(address keeper, bool allowed) external {
        if (msg.sender != GOVERNOR) revert NotGovernor();
        liquidators[keeper] = allowed;
        emit LiquidatorSet(keeper, allowed);
    }

    // ─────────────────────────────── OPEN(双币借款,零 swap)───────────────────────────────
    struct OpenParams {
        uint256 investRisk; uint256 investLoan;
        uint256 borrowRisk; uint256 borrowLoan;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Min; uint256 amount1Min; uint128 minLiquidity;
        uint256 deadline;
    }

    function open(OpenParams calldata p) external nonReentrant returns (uint256 positionNftId) {
        _requireTwoSidedRange(p.tickLower, p.tickUpper);
        (uint256 base0, uint256 base1) = _snap();

        _pull(RISK, msg.sender, p.investRisk);
        _pull(LOAN, msg.sender, p.investLoan);
        uint256 debtRisk = ILendingPool(LENDING_POOL).newDebtPosition(RESERVE_RISK);
        uint256 debtLoan = ILendingPool(LENDING_POOL).newDebtPosition(RESERVE_LOAN);
        if (p.borrowRisk > 0) ILendingPool(LENDING_POOL).borrow(address(this), debtRisk, p.borrowRisk);
        if (p.borrowLoan > 0) ILendingPool(LENDING_POOL).borrow(address(this), debtLoan, p.borrowLoan);

        uint256 totalRisk = p.investRisk + p.borrowRisk;
        uint256 totalLoan = p.investLoan + p.borrowLoan;
        (uint256 amt0, uint256 amt1) = LOAN_IS_C0 ? (totalLoan, totalRisk) : (totalRisk, totalLoan);

        (uint256 tokenId, uint128 liq) = _v3Mint(p.tickLower, p.tickUpper, amt0, amt1, p.amount0Min, p.amount1Min, p.deadline);
        if (!(liq > 0)) revert ZeroLiq();
        if (!(liq >= p.minLiquidity)) revert SlippageLiq();

        positionNftId = _mint(msg.sender);
        positions[positionNftId] = Position({
            dexTokenId: tokenId, liquidity: liq,
            tickLower: p.tickLower, tickUpper: p.tickUpper,
            debtRisk: debtRisk, debtLoan: debtLoan
        });

        _repayOpenDust(positionNftId, base0, base1); // E-2:借而未用先还债
        _refundDust(msg.sender, base0, base1);
        if (!(isHealthy(positionNftId))) revert UnhealthyOpen();
        emit PositionOpened(
            positionNftId, msg.sender, p.investRisk, p.investLoan, p.borrowRisk, p.borrowLoan,
            debtRisk, debtLoan, liq, p.tickLower, p.tickUpper
        );
    }

    // ─────────────────────────────── INCREASE(杠杆加仓,与单币版功能对等)───────────────────────────────
    struct IncreaseParams {
        uint256 investRisk; uint256 investLoan;   // 自带追加(可各为 0)
        uint256 borrowRisk; uint256 borrowLoan;   // 追加借款(沿用本仓位既有 debtId)
        uint256 amount0Min; uint256 amount1Min; uint128 minLiquidity;
        uint256 deadline;
    }
    event PositionIncreased(uint256 indexed id, uint256 investRisk, uint256 investLoan, uint256 borrowRisk, uint256 borrowLoan, uint128 addedLiquidity);

    /// 与单币版差异:双腿各投各借零 swap(无 zapPath,E-1 纪律);借而未用走 E-2 自动还债。
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
        _approveIfNeeded(TOKEN0, POSITION_MANAGER, amt0);
        _approveIfNeeded(TOKEN1, POSITION_MANAGER, amt1);
        (uint128 addLiq,,) = INonfungiblePositionManager(POSITION_MANAGER).increaseLiquidity(
            INonfungiblePositionManager.IncreaseParamsV3({
                tokenId: pos.dexTokenId, amount0Desired: amt0, amount1Desired: amt1,
                amount0Min: p.amount0Min, amount1Min: p.amount1Min, deadline: p.deadline
            })
        );
        if (!(addLiq >= p.minLiquidity && addLiq > 0)) revert SlippageLiq(); // 与 V4 逐字对齐(diff 审计 F-1)
        pos.liquidity += addLiq;
        _repayOpenDust(id, base0, base1); // E-2:追加借款未用部分先还债
        _refundDust(msg.sender, base0, base1);
        if (!(isHealthy(id))) revert UnhealthyIncrease();
        emit PositionIncreased(id, p.investRisk, p.investLoan, p.borrowRisk, p.borrowLoan, addLiq);
    }

    // ─────────────────────────────── CLOSE(匹配还债 + 缺口结算)───────────────────────────────
    // ─────────────────────────────── HARVEST(claim/复投,与单币版功能对等)───────────────────────────────
    /// 与单币版差异:不收用户 zapPath(E-1 教训,杜绝用户路由面),复投=两腿 fee 直接 increase(零 swap,
    /// 与 dual 开仓同哲学);零头经 _refundDust 退还。claim 后仍过健康检查(与单币版同,双保险)。
    function harvest(uint256 id, bool compound, uint256 deadline)
        external nonReentrant onlyHolder(id) returns (uint256 out0, uint256 out1)
    {
        Position storage pos = positions[id];
        (uint256 base0, uint256 base1) = _snap();
        (uint256 fee0, uint256 fee1) = _collectFees(pos.dexTokenId);
        (fee0, fee1) = _skimHarvestFee(fee0, fee1);

        if (!compound) {
            if (fee0 > 0) _transfer(TOKEN0, msg.sender, fee0);
            if (fee1 > 0) _transfer(TOKEN1, msg.sender, fee1);
            out0 = fee0; out1 = fee1;
        } else if (fee0 > 0 || fee1 > 0) {
            _approveIfNeeded(TOKEN0, POSITION_MANAGER, fee0);
            _approveIfNeeded(TOKEN1, POSITION_MANAGER, fee1);
            (uint128 addLiq,,) = INonfungiblePositionManager(POSITION_MANAGER).increaseLiquidity(
                INonfungiblePositionManager.IncreaseParamsV3({
                    tokenId: pos.dexTokenId, amount0Desired: fee0, amount1Desired: fee1,
                    amount0Min: 0, amount1Min: 0, deadline: deadline
                })
            );
            pos.liquidity += addLiq;
            _refundDust(msg.sender, base0, base1); // increase 取整零头退还(单币版 invariant fuzz 的教训)
        }
        if (!(isHealthy(id))) revert UnhealthyAfterHarvest();
        emit Harvested(id, fee0, fee1, compound);
    }

    struct CloseParams {
        uint16 percent;
        uint256 topUpRisk; uint256 topUpLoan;
        uint256 maxSwapIn;
        uint256 minOutRisk; uint256 minOutLoan;
        bytes zapPath; uint256 deadline;
    }

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

        (uint256 fee0, uint256 fee1) = _collectFees(pos.dexTokenId);
        (fee0, fee1) = _skimHarvestFee(fee0, fee1);
        (uint256 got0, uint256 got1) = _removeLiquidity(pos.dexTokenId, dLiq, closedAll, c.deadline);
        got0 += fee0; got1 += fee1;
        (uint256 gotRisk, uint256 gotLoan) = LOAN_IS_C0 ? (got1, got0) : (got0, got1);

        (uint256 dueRisk, uint256 dueLoan) = _dues(pos, c.percent, fullClose);

        uint256 payRisk = gotRisk < dueRisk ? gotRisk : dueRisk;
        uint256 payLoan = gotLoan < dueLoan ? gotLoan : dueLoan;
        payRisk = _repayLeg(pos.debtRisk, RISK, payRisk);
        payLoan = _repayLeg(pos.debtLoan, LOAN, payLoan);
        gotRisk -= payRisk; gotLoan -= payLoan;

        (gotRisk, gotLoan) = _settleGap(
            pos, dueRisk > payRisk ? dueRisk - payRisk : 0, dueLoan > payLoan ? dueLoan - payLoan : 0,
            gotRisk, gotLoan, c
        );

        outRisk = gotRisk; outLoan = gotLoan;
        if (!(outRisk >= c.minOutRisk && outLoan >= c.minOutLoan)) revert Slippage();
        if (outRisk > 0) _transfer(RISK, msg.sender, outRisk);
        if (outLoan > 0) _transfer(LOAN, msg.sender, outLoan);
        _refundDust(msg.sender, base0, base1);

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
        (uint256 curR,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtRisk);
        (uint256 curL,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtLoan);
        if (fullClose) return (curR, curL);
        dueRisk = (curR * percent + 9999) / 10000; if (dueRisk > curR) dueRisk = curR;
        dueLoan = (curL * percent + 9999) / 10000; if (dueLoan > curL) dueLoan = curL;
    }

    /// 缺口/残债的粉尘判定必须按"价值"而非原始 wei:GAP_EPS=1e3 对 6 位小数的 LOAN 是 0.001 刀,
    /// 放到 18 位小数的 RISK 腿上形同虚设 —— 利息累积的几 gwei 粉尘会被当成真缺口,逼出一笔
    /// 荒谬的粉尘 swap 并使普通全平失败(Sepolia v1.2 真链实证)。shortRisk==0 时短路,
    /// 保证"无缺口的干净平仓"在喂价停摆时仍不读预言机、照常放行。
    function _riskIsDust(uint256 amtRisk) internal view returns (bool) {
        if (amtRisk == 0) return true;
        return IDualLpOracle(ORACLE).riskValueInLoan(amtRisk) <= GAP_EPS;
    }

    function _settleGap(
        Position storage pos, uint256 shortRisk, uint256 shortLoan,
        uint256 gotRisk, uint256 gotLoan, CloseParams calldata c
    ) internal returns (uint256, uint256) {
        if (!_riskIsDust(shortRisk) && c.topUpRisk > 0) {
            uint256 t = c.topUpRisk < shortRisk ? c.topUpRisk : shortRisk;
            _pull(RISK, msg.sender, t);
            uint256 a = _repayLeg(pos.debtRisk, RISK, t);
            shortRisk -= t;
            if (t > a) gotRisk += t - a;
        }
        if (shortLoan > GAP_EPS && c.topUpLoan > 0) {
            uint256 t = c.topUpLoan < shortLoan ? c.topUpLoan : shortLoan;
            _pull(LOAN, msg.sender, t);
            uint256 a = _repayLeg(pos.debtLoan, LOAN, t);
            shortLoan -= t;
            if (t > a) gotLoan += t - a;
        }
        if (!_riskIsDust(shortRisk) && gotLoan > 0) {
            uint256 maxIn = gotLoan < c.maxSwapIn ? gotLoan : c.maxSwapIn;
            if (maxIn == 0) { if (!(c.maxSwapIn >= gotLoan)) revert SlippageGap(); }
            else {
            _approveIfNeeded(LOAN, SWAP_EXECUTOR, maxIn); // 漏 approve 会让主路径必败、静默降级成全换(V3 红队抓出)
            try ISwapExecutor(SWAP_EXECUTOR).swapExactOutput(LOAN, RISK, shortRisk, maxIn, c.zapPath)
            returns (uint256 spent) {
                gotLoan -= spent;
                uint256 a = _repayLeg(pos.debtRisk, RISK, shortRisk);
                if (shortRisk > a) gotRisk += shortRisk - a;
            } catch {
                if (!(c.maxSwapIn >= gotLoan)) revert SlippageGap();
                // E-1 修复:降级强制直连默认池(空 path,禁用户路由),minOut 按预言机公允价反推。
                // 这笔 swap 的受益人是出借人(换出的钱用于还债),绝不允许无价出清。
                uint256 minOut = (gotLoan * (10000 - MAX_GAP_SLIPPAGE_BPS) / 10000) * 1e18
                    / IDualLpOracle(ORACLE).riskValueInLoan(1e18);
                uint256 bought = _swapExactIn(LOAN, RISK, gotLoan, minOut, "");
                gotLoan = 0;
                uint256 want = bought < shortRisk ? bought : shortRisk;
                uint256 a = _repayLeg(pos.debtRisk, RISK, want);
                gotRisk += bought - a;
            }
            }
        } else if (shortLoan > GAP_EPS && gotRisk > 0) { // LOAN 腿本就是价值口径,阈值直接可用
            uint256 maxIn = gotRisk < c.maxSwapIn ? gotRisk : c.maxSwapIn;
            if (maxIn == 0) { if (!(c.maxSwapIn >= gotRisk)) revert SlippageGap(); }
            else {
            _approveIfNeeded(RISK, SWAP_EXECUTOR, maxIn);
            try ISwapExecutor(SWAP_EXECUTOR).swapExactOutput(RISK, LOAN, shortLoan, maxIn, c.zapPath)
            returns (uint256 spent) {
                gotRisk -= spent;
                uint256 a = _repayLeg(pos.debtLoan, LOAN, shortLoan);
                if (shortLoan > a) gotLoan += shortLoan - a;
            } catch {
                if (!(c.maxSwapIn >= gotRisk)) revert SlippageGap();
                uint256 minOut = IDualLpOracle(ORACLE).riskValueInLoan(gotRisk)
                    * (10000 - MAX_GAP_SLIPPAGE_BPS) / 10000;
                uint256 bought = _swapExactIn(RISK, LOAN, gotRisk, minOut, "");
                gotRisk = 0;
                uint256 want = bought < shortLoan ? bought : shortLoan;
                uint256 a = _repayLeg(pos.debtLoan, LOAN, want);
                gotLoan += bought - a;
            }
            }
        }
        return (gotRisk, gotLoan);
    }

    // ─────────────────────────────── ADD MARGIN ───────────────────────────────
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

    // ─────────────────────────────── REBALANCE ───────────────────────────────
    struct RebalanceParams {
        int24 newTickLower; int24 newTickUpper;
        int256 swapAmount;
        uint256 minSwapOut; uint128 minLiquidity; bytes zapPath; uint256 deadline;
    }

    function rebalance(uint256 id, RebalanceParams calldata p) external nonReentrant onlyHolder(id) {
        _requireTwoSidedRange(p.newTickLower, p.newTickUpper);
        Position storage pos = positions[id];
        (uint256 base0, uint256 base1) = _snap();

        (uint256 fee0, uint256 fee1) = _collectFees(pos.dexTokenId);
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

        (uint256 tokenId, uint128 liq) = _v3Mint(p.newTickLower, p.newTickUpper, got0, got1, 0, 0, p.deadline);
        if (!(liq > 0)) revert ZeroLiq();
        if (!(liq >= p.minLiquidity)) revert SlippageLiq();

        pos.dexTokenId = tokenId;
        pos.liquidity = liq;
        pos.tickLower = p.newTickLower;
        pos.tickUpper = p.newTickUpper;

        _refundDust(msg.sender, base0, base1);
        if (!(isHealthy(id))) revert UnhealthyAfterRebalance();
        emit Rebalanced(id, p.newTickLower, p.newTickUpper, p.swapAmount, liq);
    }

    // ─────────────────────────────── LIQUIDATE(双资产)───────────────────────────────
    struct LiquidateParams { uint256 ratioBps; uint256 minSeizeValue; uint256 deadline; }

    function liquidate(uint256 id, LiquidateParams calldata lp)
        external nonReentrant returns (bool fullyClosed)
    {
        if (!liquidators[msg.sender]) revert NotLiquidator();
        if (isHealthy(id)) revert Healthy();

        Position storage pos = positions[id];
        address borrower = ownerOf[id];

        uint256 k = lp.ratioBps > CLOSE_FACTOR_BPS ? CLOSE_FACTOR_BPS : lp.ratioBps;
        (uint256 curR,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtRisk);
        (uint256 curL,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtLoan);
        uint256 repayRisk = (curR * k) / 10000;
        uint256 repayLoan = (curL * k) / 10000;

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

        SettlementMath.Seize memory s = SettlementMath.liquidationSeize(repayValue, LIQ_BONUS_BPS, PROTOCOL_FEE_BPS);
        uint256 posVal = positionValue(id);
        uint128 seizeLiq = s.seizeValue >= posVal
            ? pos.liquidity
            : uint128((uint256(pos.liquidity) * s.seizeValue) / posVal);
        if (!(seizeLiq > 0)) revert ZeroSeize();

        pos.liquidity -= seizeLiq;
        fullyClosed = (pos.liquidity == 0);
        if (fullyClosed) _burn(id);

        (uint256 lf0, uint256 lf1) = _collectFees(pos.dexTokenId);
        (lf0, lf1) = _skimHarvestFee(lf0, lf1); // E-5:清算收 fee 同样抽成
        (uint256 got0, uint256 got1) = _removeLiquidity(pos.dexTokenId, seizeLiq, fullyClosed, lp.deadline);
        got0 += lf0; got1 += lf1;
        (uint256 gotRisk, uint256 gotLoan) = LOAN_IS_C0 ? (got1, got0) : (got0, got1);
        _payoutLiquidation(id, pos, borrower, gotRisk, gotLoan, s, posVal, lp.minSeizeValue, repayRisk, repayLoan, fullyClosed);
    }

    function _payoutLiquidation(
        uint256 id, Position storage pos, address borrower,
        uint256 gotRisk, uint256 gotLoan, SettlementMath.Seize memory s,
        uint256 posValSnap, uint256 minSeizeValue, uint256 repaidRisk, uint256 repaidLoan, bool fullyClosed
    ) internal {
        uint256 gotValue = IDualLpOracle(ORACLE).riskValueInLoan(gotRisk) + gotLoan;
        // code-review:赎回价值不得远低于预言机口径的应扣押价值(防清算交易被夹/借款人预先推价,
        // 把"还债+退借款人"两份额吃掉)。偏差大 → revert,keeper 等价格回归重试。
        {
            uint256 expectVal = s.seizeValue > posValSnap ? posValSnap : s.seizeValue;
            if (!(gotValue >= (expectVal * (10000 - MAX_GAP_SLIPPAGE_BPS)) / 10000)) revert SeizeValueLow();
        }
        uint256 feeValue = s.protocolFee > gotValue ? gotValue : s.protocolFee;
        uint256 availValue = gotValue - feeValue;
        uint256 keeperValue = availValue > s.liquidatorSeize ? s.liquidatorSeize : availValue;
        if (!(keeperValue >= minSeizeValue)) revert Slippage();

        (uint256 feeR, uint256 feeL) = _splitByValue(gotRisk, gotLoan, feeValue, gotValue);
        if (feeR > 0) _transfer(RISK, GOVERNOR, feeR);
        if (feeL > 0) _transfer(LOAN, GOVERNOR, feeL);
        gotRisk -= feeR; gotLoan -= feeL;

        uint256 remainValue = gotValue - feeValue;
        (uint256 kR, uint256 kL) = _splitByValue(gotRisk, gotLoan, keeperValue, remainValue);
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

    function _splitByValue(uint256 amtRisk, uint256 amtLoan, uint256 part, uint256 total)
        internal pure returns (uint256 outRisk, uint256 outLoan)
    {
        if (part == 0 || total == 0) return (0, 0);
        outRisk = (amtRisk * part) / total;
        outLoan = (amtLoan * part) / total;
    }

    // ─────────────────────────────── 预估 / 估值 / 健康度 ───────────────────────────────
    function previewClose(uint256 id, uint16 percent) external view returns (
        uint256 estGotRisk, uint256 estGotLoan, uint256 dueRisk, uint256 dueLoan,
        uint256 shortRisk, uint256 shortLoan
    ) {
        Position storage pos = positions[id];
        bool fullClose = percent >= 10000;
        uint128 dLiq = fullClose ? pos.liquidity : uint128((uint256(pos.liquidity) * percent) / 10000);
        (uint160 sqrtP,,,,,,) = IUniV3Pool(POOL).slot0();
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(pos.tickLower), TickMath.getSqrtRatioAtTick(pos.tickUpper), dLiq
        );
        (estGotRisk, estGotLoan) = LOAN_IS_C0 ? (a1, a0) : (a0, a1);
        (dueRisk, dueLoan) = _dues(pos, percent, fullClose);
        shortRisk = dueRisk > estGotRisk ? dueRisk - estGotRisk : 0;
        shortLoan = dueLoan > estGotLoan ? dueLoan - estGotLoan : 0;
    }

    function positionValue(uint256 id) public view returns (uint256 valueInLoan) {
        Position storage pos = positions[id];
        valueInLoan = IDualLpOracle(ORACLE).fairValueInLoan(pos.liquidity, pos.tickLower, pos.tickUpper);
    }

    function totalDebtInLoan(uint256 id) public view returns (uint256) {
        Position storage pos = positions[id];
        (uint256 dRisk,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtRisk);
        (uint256 dLoan,) = ILendingPool(LENDING_POOL).getCurrentDebt(pos.debtLoan);
        return IDualLpOracle(ORACLE).riskValueInLoan(dRisk) + dLoan;
    }

    function isHealthy(uint256 id) public view returns (bool) {
        return (positionValue(id) * LLTV) / 1e18 >= totalDebtInLoan(id);
    }

    // ─────────────────────────────── V3 水管 ───────────────────────────────
    function _requireTwoSidedRange(int24 tickLower, int24 tickUpper) internal view {
        if (tickUpper - tickLower < MIN_WIDTH_TICKS) revert RangeTooNarrow();
        (, int24 cur,,,,,) = IUniV3Pool(POOL).slot0();
        if (!(tickLower < cur && cur < tickUpper)) revert NotTwoSided();
    }

    function _v3Mint(int24 tl, int24 tu, uint256 amt0, uint256 amt1, uint256 min0, uint256 min1, uint256 deadline)
        internal returns (uint256 tokenId, uint128 liq)
    {
        _approveIfNeeded(TOKEN0, POSITION_MANAGER, amt0);
        _approveIfNeeded(TOKEN1, POSITION_MANAGER, amt1);
        (tokenId, liq,,) = INonfungiblePositionManager(POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: TOKEN0, token1: TOKEN1, fee: FEE, tickLower: tl, tickUpper: tu,
                amount0Desired: amt0, amount1Desired: amt1, amount0Min: min0, amount1Min: min1,
                recipient: address(this), deadline: deadline
            })
        );
    }

    function _removeLiquidity(uint256 tokenId, uint128 dLiq, bool full, uint256 deadline)
        internal returns (uint256 got0, uint256 got1)
    {
        INonfungiblePositionManager(POSITION_MANAGER).decreaseLiquidity(
            INonfungiblePositionManager.DecreaseParamsV3({
                tokenId: tokenId, liquidity: dLiq, amount0Min: 0, amount1Min: 0, deadline: deadline
            })
        );
        (got0, got1) = INonfungiblePositionManager(POSITION_MANAGER).collect(
            INonfungiblePositionManager.CollectParamsV3({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        if (full) INonfungiblePositionManager(POSITION_MANAGER).burn(tokenId);
    }

    /// 零可领时真实 NFPM 会 revert → try/catch 归零(同单币版 fork 教训)。
    function _collectFees(uint256 tokenId) internal returns (uint256 fee0, uint256 fee1) {
        try INonfungiblePositionManager(POSITION_MANAGER).collect(
            INonfungiblePositionManager.CollectParamsV3({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        ) returns (uint256 a0, uint256 a1) {
            fee0 = a0; fee1 = a1;
        } catch {}
    }

    function _skimHarvestFee(uint256 fee0, uint256 fee1) internal returns (uint256 net0, uint256 net1) {
        uint256 cut0 = (fee0 * HARVEST_FEE_BPS) / 10000;
        uint256 cut1 = (fee1 * HARVEST_FEE_BPS) / 10000;
        if (cut0 > 0) _transfer(TOKEN0, GOVERNOR, cut0);
        if (cut1 > 0) _transfer(TOKEN1, GOVERNOR, cut1);
        net0 = fee0 - cut0;
        net1 = fee1 - cut1;
    }

    // ─────────────────────────────── 通用辅助 ───────────────────────────────
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
}
