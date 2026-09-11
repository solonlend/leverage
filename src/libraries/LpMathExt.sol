// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {TickMath} from "./TickMath.sol";
import {LiquidityAmounts} from "./LiquidityAmounts.sol";

/*
  LpMathExt — external(deployed) library:把 TickMath+LiquidityAmounts 的重型定点数学
  从金库 runtime 里挪出去(UniV4DualVault 曾超 EIP-170 上限 1.4KB)。
  external 库函数经 delegatecall 调用,语义与 internal 内联完全一致,只是代码住在独立地址。
  部署:forge 自动链接(script/test 均自动部署);生产部署清单需记录库地址。
*/
library LpMathExt {
    error SeizeValueLow();
    error Slippage(); // 与金库同名同选择子(diff 审计 F-2:keeper 按选择子匹配)

    /// 清算分账纯数学(外置省金库体积):校验赎回价值下限 → 算协议费/keeper 两腿等比例拆分。
    /// 语义与金库内联版逐式一致;revert 经 delegatecall 原样上抛。
    function liqSplit(
        uint256 gotRisk, uint256 gotLoan, uint256 gotValue,
        uint256 seizeValue, uint256 posValSnap, uint256 protocolFee, uint256 liquidatorSeize,
        uint256 minSeizeValue, uint256 maxGapSlippageBps
    ) external pure returns (uint256 feeR, uint256 feeL, uint256 kR, uint256 kL, uint256 keeperValue, uint256 feeValue) {
        uint256 expectVal = seizeValue > posValSnap ? posValSnap : seizeValue;
        if (!(gotValue >= (expectVal * (10000 - maxGapSlippageBps)) / 10000)) revert SeizeValueLow();
        feeValue = protocolFee > gotValue ? gotValue : protocolFee;
        uint256 availValue = gotValue - feeValue;
        keeperValue = availValue > liquidatorSeize ? liquidatorSeize : availValue; // F2 封顶
        if (!(keeperValue >= minSeizeValue)) revert Slippage();
        (feeR, feeL) = _split(gotRisk, gotLoan, feeValue, gotValue);
        uint256 remainValue = gotValue - feeValue;
        (kR, kL) = _split(gotRisk - feeR, gotLoan - feeL, keeperValue, remainValue);
    }

    /// 平仓应还额(比例向上取整,封顶当前债)。lendingPool.getCurrentDebt 经 delegatecall 以金库身份读。
    function dues(address lendingPool, uint256 debtRisk, uint256 debtLoan, uint16 percent, bool fullClose)
        external view returns (uint256 dueRisk, uint256 dueLoan)
    {
        return _duesInternal(lendingPool, debtRisk, debtLoan, percent, fullClose);
    }

    /// 平仓预估全量外置(dual 金库体积):撤出两币估算 + 应还 + 缺口。
    function previewCloseExt(
        address stateView, bytes32 poolId, address lendingPool,
        uint128 liquidity, int24 tickLower, int24 tickUpper,
        uint256 debtRisk, uint256 debtLoan, uint16 percent, bool loanIsC0
    ) external view returns (
        uint256 estGotRisk, uint256 estGotLoan, uint256 dueRisk, uint256 dueLoan,
        uint256 shortRisk, uint256 shortLoan
    ) {
        bool fullClose = percent >= 10000;
        uint128 dLiq = fullClose ? liquidity : uint128((uint256(liquidity) * percent) / 10000);
        (bool okS, bytes memory rs) = stateView.staticcall(abi.encodeWithSignature("getSlot0(bytes32)", poolId));
        require(okS, "SLOT0_READ");
        (uint160 sqrtP,,,) = abi.decode(rs, (uint160, int24, uint24, uint24));
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), dLiq
        );
        (estGotRisk, estGotLoan) = loanIsC0 ? (a1, a0) : (a0, a1);
        (dueRisk, dueLoan) = _duesInternal(lendingPool, debtRisk, debtLoan, percent, fullClose);
        shortRisk = dueRisk > estGotRisk ? dueRisk - estGotRisk : 0;
        shortLoan = dueLoan > estGotLoan ? dueLoan - estGotLoan : 0;
    }

    function _duesInternal(address lendingPool, uint256 debtRisk, uint256 debtLoan, uint16 percent, bool fullClose)
        internal view returns (uint256 dueRisk, uint256 dueLoan)
    {
        (bool ok1, bytes memory r1) = lendingPool.staticcall(abi.encodeWithSignature("getCurrentDebt(uint256)", debtRisk));
        (bool ok2, bytes memory r2) = lendingPool.staticcall(abi.encodeWithSignature("getCurrentDebt(uint256)", debtLoan));
        require(ok1 && ok2, "DUES_READ");
        (uint256 curR,) = abi.decode(r1, (uint256, uint256));
        (uint256 curL,) = abi.decode(r2, (uint256, uint256));
        if (fullClose) return (curR, curL);
        dueRisk = (curR * percent + 9999) / 10000; if (dueRisk > curR) dueRisk = curR;
        dueLoan = (curL * percent + 9999) / 10000; if (dueLoan > curL) dueLoan = curL;
    }

    function _split(uint256 amtRisk, uint256 amtLoan, uint256 part, uint256 total)
        internal pure returns (uint256 outRisk, uint256 outLoan)
    {
        if (part == 0 || total == 0) return (0, 0);
        outRisk = (amtRisk * part) / total;
        outLoan = (amtLoan * part) / total;
    }

    function liquidityFor(uint160 sqrtP, int24 tickLower, int24 tickUpper, uint256 amt0, uint256 amt1)
        external pure returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), amt0, amt1
        );
    }

    function amountsFor(uint160 sqrtP, int24 tickLower, int24 tickUpper, uint128 liq)
        external pure returns (uint256 a0, uint256 a1)
    {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liq
        );
    }
}
