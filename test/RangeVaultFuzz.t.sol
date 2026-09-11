// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SolonRangeVault} from "../src/range/SolonRangeVault.sol";
import {RangeMockERC20, MockRangeStrategy} from "./RangeVault.t.sol";

/*
  份额数学性质 fuzz(mock 策略,静态价格——专攻会计层,池内经济学在 fork 套件):
  P1 无免费价值:任意首存,previewWithdraw 价值 ≤ 存入价值;损失 ≤ MINIMUM_SHARES 等值+取整粉尘
  P2 守恒:两人任意额存款后各自全额取出,总取出 ≤ 总存入(金库不凭空印钱)
  P3 滑动费上界:fee ≤ fill × swapFee(上游"不超池费 50%"的强化上界)
  P4 后来者不稀释先来者:第二人存款前后,第一人的可取价值不减少(允许 1 wei 取整)
*/

contract RangeVaultFuzzTest is Test {
    SolonRangeVault vault;
    MockRangeStrategy strat;
    RangeMockERC20 t0; RangeMockERC20 t1;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 constant MIN_SHARES = 1e3;

    function setUp() public {
        t0 = new RangeMockERC20("T0", 18);
        t1 = new RangeMockERC20("T1", 18);
        vault = new SolonRangeVault("SR", "SR");
        strat = new MockRangeStrategy(address(vault), t0, t1, 1e36, 0.0001e18);
        vault.setStrategy(address(strat));
        for (uint256 i; i < 2; ++i) {
            address u = i == 0 ? alice : bob;
            t0.mint(u, type(uint128).max); t1.mint(u, type(uint128).max);
            vm.startPrank(u);
            t0.approve(address(vault), type(uint256).max);
            t1.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _value(uint256 a0, uint256 a1, uint256 price) internal pure returns (uint256) {
        return a1 + a0 * price / 1e36;
    }

    // P1 无免费价值
    function testFuzz_NoFreeValueOnFirstDeposit(uint96 a0, uint96 a1, uint64 priceMul) public {
        uint256 price = (uint256(priceMul) % 1e12 + 1) * 1e30; // 1e30 ~ 1e42,防 a0×price 溢出(uint96×1e42 < 2^256)
        strat.setPrice(price);
        uint256 v = _value(a0, a1, price);
        vm.assume(v > MIN_SHARES * 2); // 首存必须超过烧毁份额

        vm.prank(alice);
        vault.deposit(a0, a1, 0);
        uint256 shares = vault.balanceOf(alice);

        (uint256 o0, uint256 o1) = vault.previewWithdraw(shares);
        uint256 vOut = _value(o0, o1, price);
        assertLe(vOut, v); // 取出永远 ≤ 存入
        // 损失上界:烧毁份额等值 + 每币 1 wei 取整
        assertGe(vOut + MIN_SHARES + 2 + price / 1e36, v);
    }

    // P2 守恒:金库不印钱
    function testFuzz_ConservationTwoUsers(uint96 a0, uint96 a1, uint96 b0, uint96 b1) public {
        vm.assume(_value(a0, a1, 1e36) > MIN_SHARES * 2);
        vm.assume(uint256(b0) + b1 > 0);

        uint256 aliceBefore = _value(t0.balanceOf(alice), t1.balanceOf(alice), 1e36);
        uint256 bobBefore = _value(t0.balanceOf(bob), t1.balanceOf(bob), 1e36);

        vm.prank(alice); vault.deposit(a0, a1, 0);
        // bob 的入金额过 preview 修正(失衡时金库只收部分)
        (, uint256 nb0, uint256 nb1,,) = vault.previewDeposit(b0, b1);
        if (_value(nb0, nb1, 1e36) > 0) {
            vm.prank(bob);
            try vault.deposit(nb0, nb1, 0) {} catch {} // 取整可致 NoShares,允许
        }

        uint256 aShares = vault.balanceOf(alice);
        uint256 bShares = vault.balanceOf(bob);
        // alice 是大额主路径,取款必须成功(Codex INFO-5:不许吞主路径失败);bob 可能是粉尘,
        // 取整到 (0,0) 被拒付(TooMuchSlippage)是设计行为,留金库,守恒仍成立
        if (aShares > 0) { vm.prank(alice); vault.withdraw(aShares, 0, 0); }
        if (bShares > 0) { vm.prank(bob); try vault.withdraw(bShares, 0, 0) {} catch {} }

        uint256 aliceAfter = _value(t0.balanceOf(alice), t1.balanceOf(alice), 1e36);
        uint256 bobAfter = _value(t0.balanceOf(bob), t1.balanceOf(bob), 1e36);
        // 两人合计不多拿(烧毁份额留在金库,只会少不会多)
        assertLe(aliceAfter + bobAfter, aliceBefore + bobBefore);
    }

    // P3 滑动费上界
    function testFuzz_SlidingFeeBounded(uint96 seed0, uint96 seed1, uint96 dep1) public {
        vm.assume(uint256(seed0) > 1e6 && uint256(seed1) > 1e6);
        vm.assume(_value(seed0, seed1, 1e36) > MIN_SHARES * 2);
        vm.prank(alice); vault.deposit(seed0, seed1, 0);

        // 制造失衡:抽走策略一半 token1
        uint256 half = t1.balanceOf(address(strat)) / 2;
        vm.assume(half > 0);
        vm.prank(address(strat)); t1.transfer(address(0xD00D), half);

        (,, uint256 d1t, uint256 fee0, uint256 fee1) = vault.previewDeposit(0, dep1);
        d1t;
        assertEq(fee0, 0); // 全 token1 入金,token0 侧无费
        // fee1 ≤ fill × swapFee;fill ≤ dep1
        assertLe(fee1, uint256(dep1) * 0.0001e18 / 1e18 + 1);
    }

    // P4 后来者不稀释先来者
    function testFuzz_NoDilution(uint96 a0, uint96 a1, uint96 b0, uint96 b1) public {
        vm.assume(_value(a0, a1, 1e36) > MIN_SHARES * 2);
        vm.prank(alice); vault.deposit(a0, a1, 0);
        uint256 aShares = vault.balanceOf(alice);
        (uint256 p0, uint256 p1) = vault.previewWithdraw(aShares);
        uint256 valBefore = _value(p0, p1, 1e36);

        (, uint256 nb0, uint256 nb1,,) = vault.previewDeposit(b0, b1);
        if (_value(nb0, nb1, 1e36) > 0) {
            vm.prank(bob);
            try vault.deposit(nb0, nb1, 0) {} catch {}
        }

        (uint256 q0, uint256 q1) = vault.previewWithdraw(aShares);
        uint256 valAfter = _value(q0, q1, 1e36);
        assertGe(valAfter + 2, valBefore); // 允许 wei 级取整,不允许实质稀释
    }
}
