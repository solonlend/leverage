// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  UniV3LeverageVault — Solon 杠杆两边平衡 LP 金库(Uniswap V3;目标 RH ETH/USDG 深池)。
  与 V4 版共享全部业务逻辑(抗操纵公允价、标准清算、SettlementMath、ExtraFi LendingPool 债务模型、
  排序无关的 LOAN/RISK 处理、四道费用位),只是 DEX 层走 Uniswap V3 的 NonfungiblePositionManager
  直调(amount-based mint,自带返回值),取价走 V3 池自带的 slot0/observe(LpShareOracle 用 TWAP)。

  仓位凭证两层:底层 V3 LP NFT 锁本合约,上层 Solon NFT 在用户钱包(持有即所有)。
  生命周期:开仓 / 加仓 / 减仓 / harvest(提取|复投)/ 平仓 / 清算。
*/

import {LpShareOracle} from "./LpShareOracle.sol";
import {SettlementMath} from "./libraries/SettlementMath.sol";

interface INonfungiblePositionManager {
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    function mint(MintParams calldata) external returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    struct IncreaseParamsV3 {
        uint256 tokenId; uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min; uint256 deadline;
    }
    function increaseLiquidity(IncreaseParamsV3 calldata) external returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    struct DecreaseParamsV3 { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    function decreaseLiquidity(DecreaseParamsV3 calldata) external returns (uint256 amount0, uint256 amount1);
    struct CollectParamsV3 { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function collect(CollectParamsV3 calldata) external returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external;
}

interface IUniV3Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

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

interface IRiskValueOracle {
    function riskValueInLoan(uint256 riskAmount) external view returns (uint256);
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

contract UniV3LeverageVault is PositionReceipt721, ReentrancyGuard {
    struct Position {
        uint256 dexTokenId;  // 底层 V3 LP NFT
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 debtId;
    }

    mapping(uint256 => Position) public positions;
    mapping(address => bool) public liquidators;

    address public immutable GOVERNOR;
    address public immutable POSITION_MANAGER; // Uniswap V3 NonfungiblePositionManager
    address public immutable POOL;             // Uniswap V3 pool(读 slot0 取价)
    address public immutable LENDING_POOL;
    uint256 public immutable RESERVE_ID;
    address public immutable ORACLE;           // LpShareOracle(V3 TWAP)
    address public immutable SWAP_EXECUTOR;
    address public immutable TOKEN0;           // pool token0(地址小)
    address public immutable TOKEN1;           // pool token1(地址大)
    bool    public immutable LOAN_IS_C0;
    address public immutable LOAN;             // USDG(借款/出金)
    address public immutable RISK;             // 风险资产腿
    uint24  public immutable FEE;

    int24   public immutable MIN_WIDTH_TICKS;
    uint256 public immutable LIQ_BONUS_BPS;
    uint256 public immutable PROTOCOL_FEE_BPS;
    uint256 public immutable HARVEST_FEE_BPS;
    uint256 public immutable BORROW_FEE_BPS;
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
    // 仓位生命周期事件:keeper 索引与前端渲染的唯一数据源,与 V4 金库同一套签名
    event PositionOpened(uint256 indexed id, address indexed owner, uint256 invest, uint256 borrowed, uint256 debtId, uint128 liquidity, int24 tickLower, int24 tickUpper);
    event PositionIncreased(uint256 indexed id, uint256 invest, uint256 borrowed, uint128 liquidityAdded);
    event PositionClosed(uint256 indexed id, uint16 percentBps, uint256 repaid, uint256 outToUser, bool full);
    event Harvested(uint256 indexed id, uint256 netFee0, uint256 netFee1, bool compounded);
    event PositionLiquidated(uint256 indexed id, address indexed keeper, uint256 repaid, uint256 seized, uint256 protocolFee, bool fullyClosed);
    // 全平/清算后仍有残债 = 抵押不足覆盖债务的坏账,社会化给出借人。链上可观测供监控告警。
    event BadDebt(uint256 indexed id, uint256 indexed debtId, uint256 residualDebt);

    modifier onlyHolder(uint256 id) { if (ownerOf[id] != msg.sender) revert NotHolder(); _; }

    struct InitParams {
        address governor; address positionManager; address pool;
        address lendingPool; uint256 reserveId; address oracle; address swapExecutor;
        address token0; address token1; bool loanIsC0; uint24 fee;
        int24 minWidthTicks; uint256 liqBonusBps; uint256 protocolFeeBps; uint256 harvestFeeBps;
        uint256 borrowFeeBps; uint256 closeFactorBps; uint256 lltv;
    }

    constructor(InitParams memory p) {
        require(
            p.governor != address(0) && p.positionManager != address(0) && p.pool != address(0)
            && p.lendingPool != address(0) && p.oracle != address(0) && p.swapExecutor != address(0)
            && p.token0 != address(0) && p.token1 != address(0),
            "ZERO_ADDR"
        );
        require(p.token0 < p.token1, "UNSORTED");
        require(p.lltv > 0 && p.lltv <= 1e18, "BAD_LLTV");
        require(p.closeFactorBps > 0 && p.closeFactorBps <= 10000, "BAD_CLOSE_FACTOR");
        require(p.liqBonusBps <= 2000 && p.protocolFeeBps <= 5000 && p.harvestFeeBps <= 3000, "BAD_FEES");
        require(p.minWidthTicks > 0, "BAD_MIN_WIDTH");
        GOVERNOR = p.governor; POSITION_MANAGER = p.positionManager; POOL = p.pool;
        LENDING_POOL = p.lendingPool; RESERVE_ID = p.reserveId; ORACLE = p.oracle; SWAP_EXECUTOR = p.swapExecutor;
        TOKEN0 = p.token0; TOKEN1 = p.token1; FEE = p.fee;
        LOAN_IS_C0 = p.loanIsC0;
        LOAN = p.loanIsC0 ? p.token0 : p.token1;
        RISK = p.loanIsC0 ? p.token1 : p.token0;
        MIN_WIDTH_TICKS = p.minWidthTicks; LIQ_BONUS_BPS = p.liqBonusBps; PROTOCOL_FEE_BPS = p.protocolFeeBps;
        HARVEST_FEE_BPS = p.harvestFeeBps; BORROW_FEE_BPS = p.borrowFeeBps;
        CLOSE_FACTOR_BPS = p.closeFactorBps; LLTV = p.lltv;
    }

    function setLiquidator(address keeper, bool allowed) external {
        if (msg.sender != GOVERNOR) revert NotGovernor();
        liquidators[keeper] = allowed;
        emit LiquidatorSet(keeper, allowed);
    }

    // ─────────────────────────────── OPEN ───────────────────────────────
    struct OpenParams {
        uint256 amountInvest; uint256 amountBorrow;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Min; uint256 amount1Min; // mint 滑点下限
        uint128 minLiquidity;
        bytes zapPath; uint256 deadline;
    }

    function open(OpenParams calldata p) external nonReentrant returns (uint256 positionNftId) {
        _requireTwoSidedRange(p.tickLower, p.tickUpper);
        (uint256 base0, uint256 base1) = _snap(); // 入口基线,退零头不碰预存资金

        _pull(LOAN, msg.sender, p.amountInvest);
        uint256 debtId = ILendingPool(LENDING_POOL).newDebtPosition(RESERVE_ID);
        ILendingPool(LENDING_POOL).borrow(address(this), debtId, p.amountBorrow);
        uint256 totalUsdg = p.amountInvest + p.amountBorrow;

        uint256 borrowFee = (p.amountBorrow * BORROW_FEE_BPS) / 10000;
        if (borrowFee > 0) { _transfer(LOAN, GOVERNOR, borrowFee); totalUsdg -= borrowFee; }

        (uint256 amt0, uint256 amt1) = _zapToBothSides(totalUsdg, p.tickLower, p.tickUpper, p.zapPath);

        (uint256 tokenId, uint128 liq) = _v3Mint(p.tickLower, p.tickUpper, amt0, amt1, p.amount0Min, p.amount1Min, p.deadline);
        require(liq > 0, "ZERO_LIQ"); // 拒绝零流动性垃圾仓位(刷 debtId/事件)
        require(liq >= p.minLiquidity, "SLIPPAGE_LIQ");

        positionNftId = _mint(msg.sender);
        positions[positionNftId] = Position({
            dexTokenId: tokenId, liquidity: liq,
            tickLower: p.tickLower, tickUpper: p.tickUpper, debtId: debtId
        });
        _refundDust(msg.sender, base0, base1);
        require(_isHealthy(positionNftId), "UNHEALTHY_OPEN"); // 开仓即须健康,不许秒开可清算仓位
        emit PositionOpened(positionNftId, msg.sender, p.amountInvest, p.amountBorrow, debtId, liq, p.tickLower, p.tickUpper);
    }

    // ─────────────────────────────── INCREASE ───────────────────────────────
    struct IncreaseParams {
        uint256 amountInvest; uint256 amountBorrow;
        uint256 amount0Min; uint256 amount1Min; uint128 minLiquidity;
        bytes zapPath; uint256 deadline;
    }

    function increase(uint256 id, IncreaseParams calldata p) external nonReentrant onlyHolder(id) {
        Position storage pos = positions[id];
        (uint256 base0, uint256 base1) = _snap();
        _pull(LOAN, msg.sender, p.amountInvest);
        ILendingPool(LENDING_POOL).borrow(address(this), pos.debtId, p.amountBorrow);
        uint256 totalUsdg = p.amountInvest + p.amountBorrow;

        (uint256 amt0, uint256 amt1) = _zapToBothSides(totalUsdg, pos.tickLower, pos.tickUpper, p.zapPath);
        _approveIfNeeded(TOKEN0, POSITION_MANAGER, amt0);
        _approveIfNeeded(TOKEN1, POSITION_MANAGER, amt1);
        (uint128 addLiq,,) = INonfungiblePositionManager(POSITION_MANAGER).increaseLiquidity(
            INonfungiblePositionManager.IncreaseParamsV3({
                tokenId: pos.dexTokenId, amount0Desired: amt0, amount1Desired: amt1,
                amount0Min: p.amount0Min, amount1Min: p.amount1Min, deadline: p.deadline
            })
        );
        require(addLiq >= p.minLiquidity, "SLIPPAGE_LIQ");
        pos.liquidity += addLiq;
        _refundDust(msg.sender, base0, base1);
        require(_isHealthy(id), "UNHEALTHY_INCREASE"); // 加仓后同样必须健康
        emit PositionIncreased(id, p.amountInvest, p.amountBorrow, addLiq);
    }

    // ─────────────────────────────── HARVEST(两模式) ───────────────────────────────
    function harvest(uint256 id, bool compound, bytes calldata zapPath, uint256 deadline)
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
        } else {
            uint256 usdg = _consolidateToLoan(fee0, fee1, zapPath);
            (uint256 amt0, uint256 amt1) = _zapToBothSides(usdg, pos.tickLower, pos.tickUpper, zapPath);
            _approveIfNeeded(TOKEN0, POSITION_MANAGER, amt0);
            _approveIfNeeded(TOKEN1, POSITION_MANAGER, amt1);
            (uint128 addLiq,,) = INonfungiblePositionManager(POSITION_MANAGER).increaseLiquidity(
                INonfungiblePositionManager.IncreaseParamsV3({
                    tokenId: pos.dexTokenId, amount0Desired: amt0, amount1Desired: amt1,
                    amount0Min: 0, amount1Min: 0, deadline: deadline
                })
            );
            pos.liquidity += addLiq;
            _refundDust(msg.sender, base0, base1); // 复投 zap/increase 的取整零头退还(invariant fuzz 抓到的滞留)
        }
        require(_isHealthy(id), "UNHEALTHY_AFTER_HARVEST");
        emit Harvested(id, fee0, fee1, compound); // fee0/fee1 已是协议抽成后的净额
    }

    // ─────────────────────────────── CLOSE ───────────────────────────────
    struct CloseParams { uint16 percent; uint256 minOutSingleToken; bytes zapPath; uint256 deadline; }

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

        (uint256 fee0, uint256 fee1) = _collectFees(pos.dexTokenId);
        (uint256 netFee0, uint256 netFee1) = _skimHarvestFee(fee0, fee1);
        (uint256 got0, uint256 got1) = _removeLiquidity(pos.dexTokenId, dLiq, fullClose, c.deadline);
        got0 += netFee0; got1 += netFee1;

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
        if (closedAll) {
            (uint256 residual,) = ILendingPool(LENDING_POOL).getCurrentDebt(debtId);
            if (residual > GAP_EPS) {
                if (!(preChecked && preInsolvent)) revert SolventBadDebt();
                emit BadDebt(id, debtId, residual);
            }
        }
    }

    // ─────────────────────────────── LIQUIDATE ───────────────────────────────
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

        (uint256 fee0, uint256 fee1) = _collectFees(pos.dexTokenId);
        (fee0, fee1) = _skimHarvestFee(fee0, fee1); // Match close and dual liquidation fee accounting.
        (uint256 got0, uint256 got1) = _removeLiquidity(pos.dexTokenId, seizeLiq, fullyClosed, lp.deadline);
        got0 += fee0; got1 += fee1;
        uint256 gotLoan = _consolidateToLoan(got0, got1, lp.zapPath);

        uint256 protocolFee = s.protocolFee > gotLoan ? gotLoan : s.protocolFee;
        if (protocolFee > 0) _transfer(LOAN, GOVERNOR, protocolFee);
        uint256 avail = gotLoan - protocolFee;
        // keeper 净得封顶到"应得 bonus",防止预言机低估/正滑点时超额扣押借款人抵押(红队 F2)
        uint256 toLiquidator = avail > s.liquidatorSeize ? s.liquidatorSeize : avail;
        require(toLiquidator >= lp.minSeizeOut, "SLIPPAGE");
        if (toLiquidator > 0) _transfer(LOAN, msg.sender, toLiquidator);

        // 超过 keeper 应得的部分归借款人:先冲抵剩余债务(降坏账),余额退还本人
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
        (, int24 cur,,,,,) = IUniV3Pool(POOL).slot0();
        require(tickLower < cur && cur < tickUpper, "NOT_STRADDLING");
    }

    // ─────────────────────────────── V3 DEX 交互 ───────────────────────────────
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

    /// 撤流动性(部分或全平)+ 收 fee/本金到本合约;全平额外 burn 底层 V3 NFT。
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

    /// 只领手续费:V3 collect 在未 decrease 时只扫累积的 swap 费。真实 NFPM 在"零可领"时会 revert
    /// (fork e2e 抓到),用 try/catch 优雅归零——刚开仓无 fee 的仓位平仓不该因此失败。
    function _collectFees(uint256 tokenId) internal returns (uint256 fee0, uint256 fee1) {
        try INonfungiblePositionManager(POSITION_MANAGER).collect(
            INonfungiblePositionManager.CollectParamsV3({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        ) returns (uint256 a0, uint256 a1) {
            fee0 = a0; fee1 = a1;
        } catch {
            // 无可领手续费(刚开仓/已领过)→ 0
        }
    }

    // ─────────────────────────────── zap / 分账 / 辅助 ───────────────────────────────
    function _zapToBothSides(uint256 totalLoan, int24 tickLower, int24 tickUpper, bytes memory zapPath)
        internal returns (uint256 amt0, uint256 amt1)
    {
        uint256 loanForC0 = LpShareOracle(ORACLE).zapAmountToToken0(totalLoan, tickLower, tickUpper);
        if (LOAN_IS_C0) {
            uint256 swapIn = totalLoan - loanForC0;
            amt1 = _swapExactIn(LOAN, RISK, swapIn, _minRiskOut(swapIn), zapPath);
            amt0 = loanForC0;
        } else {
            amt0 = _swapExactIn(LOAN, RISK, loanForC0, _minRiskOut(loanForC0), zapPath);
            amt1 = totalLoan - loanForC0;
        }
    }

    function _consolidateToLoan(uint256 got0, uint256 got1, bytes memory zapPath)
        internal returns (uint256 gotLoan)
    {
        if (LOAN_IS_C0) {
            gotLoan = got0;
            if (got1 > 0) gotLoan += _swapExactIn(RISK, LOAN, got1, _minLoanOut(got1), zapPath);
        } else {
            gotLoan = got1;
            if (got0 > 0) gotLoan += _swapExactIn(RISK, LOAN, got0, _minLoanOut(got0), zapPath);
        }
    }

    function _minRiskOut(uint256 loanAmount) internal view returns (uint256) {
        if (loanAmount == 0) return 0;
        return (loanAmount * (10000 - MAX_GAP_SLIPPAGE_BPS) / 10000) * 1e18
            / IRiskValueOracle(ORACLE).riskValueInLoan(1e18);
    }

    function _minLoanOut(uint256 riskAmount) internal view returns (uint256) {
        if (riskAmount == 0) return 0;
        return IRiskValueOracle(ORACLE).riskValueInLoan(riskAmount)
            * (10000 - MAX_GAP_SLIPPAGE_BPS) / 10000;
    }

    function _skimHarvestFee(uint256 fee0, uint256 fee1) internal returns (uint256 net0, uint256 net1) {
        uint256 cut0 = (fee0 * HARVEST_FEE_BPS) / 10000;
        uint256 cut1 = (fee1 * HARVEST_FEE_BPS) / 10000;
        if (cut0 > 0) _transfer(TOKEN0, GOVERNOR, cut0);
        if (cut1 > 0) _transfer(TOKEN1, GOVERNOR, cut1);
        net0 = fee0 - cut0;
        net1 = fee1 - cut1;
    }

    function _snap() internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20(TOKEN0).balanceOf(address(this));
        b1 = IERC20(TOKEN1).balanceOf(address(this));
    }

    /// 只退超出入口基线的零头,预存捐赠/误转绝不被 open/close 整包薅走(红队 E6)。
    function _refundDust(address to, uint256 base0, uint256 base1) internal {
        uint256 cur0 = IERC20(TOKEN0).balanceOf(address(this));
        uint256 cur1 = IERC20(TOKEN1).balanceOf(address(this));
        uint256 d0 = cur0 > base0 ? cur0 - base0 : 0;
        uint256 d1 = cur1 > base1 ? cur1 - base1 : 0;
        if (d0 > 0) _transfer(TOKEN0, to, d0);
        if (d1 > 0) _transfer(TOKEN1, to, d1);
    }

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
}
