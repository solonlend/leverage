// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SolonRangeVault} from "../src/range/SolonRangeVault.sol";

/*
  SolonRangeVault 份额数学单测(mock 策略,不碰池子):
  V1 首存:shares = token1 等值 − MINIMUM_SHARES,烧毁份额进黑洞
  V2 二存等比:无稀释,份额与价值成正比
  V3 取款:按比例双币返还 + 滑点参数 revert 面
  V4 滑动费:失衡入金收费,费留在系统内增厚存量持有人
  V5 通胀攻击:首存 1 wei + 直接捐赠,受害人存款不可被偷
  V6 setStrategy 一次性 + vault 校验
  V7 previewDeposit/previewWithdraw 与实际一致
*/

contract RangeMockERC20 {
    string public name; string public symbol; uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, uint8 d) { name = n; symbol = n; decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract MockRangeStrategy {
    address public vault;
    RangeMockERC20 public t0; RangeMockERC20 public t1;
    uint256 public price;      // token1 per token0, 1e36 scale (equal decimals)
    uint256 public swapFee;    // pool fee, 1e18 scale
    bool public calm = true;

    constructor(address _vault, RangeMockERC20 _t0, RangeMockERC20 _t1, uint256 _price, uint256 _swapFee) {
        vault = _vault; t0 = _t0; t1 = _t1; price = _price; swapFee = _swapFee;
    }
    function setPrice(uint256 p) external { price = p; }
    function setCalm(bool c) external { calm = c; }
    function isCalm() external view returns (bool) { return calm; }
    function pool() external pure returns (address) { return address(0xBEEF); }
    function lpToken0() external view returns (address) { return address(t0); }
    function lpToken1() external view returns (address) { return address(t1); }
    function balances() public view returns (uint256, uint256) {
        return (t0.balanceOf(address(this)), t1.balanceOf(address(this)));
    }
    function beforeAction() external {}
    function deposit() external {}
    function withdraw(uint256 a0, uint256 a1) external {
        if (a0 > 0) t0.transfer(vault, a0);
        if (a1 > 0) t1.transfer(vault, a1);
    }
}

contract RangeVaultTest is Test {
    SolonRangeVault vault;
    MockRangeStrategy strat;
    RangeMockERC20 t0; RangeMockERC20 t1;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 constant MIN_SHARES = 1e3;

    function setUp() public {
        t0 = new RangeMockERC20("T0", 18);
        t1 = new RangeMockERC20("T1", 18);
        vault = new SolonRangeVault("Solon Range T0-T1", "srT0T1");
        strat = new MockRangeStrategy(address(vault), t0, t1, 1e36, 0.0001e18); // 1:1, 1bp
        vault.setStrategy(address(strat));

        t0.mint(alice, 1_000e18); t1.mint(alice, 1_000e18);
        t0.mint(bob, 1_000e18);   t1.mint(bob, 1_000e18);
        vm.startPrank(alice);
        t0.approve(address(vault), type(uint256).max); t1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        t0.approve(address(vault), type(uint256).max); t1.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    // V1 首存
    function testFirstDepositSharesAndBurn() public {
        vm.prank(alice);
        vault.deposit(100e18, 100e18, 0);
        // token1 等值 = 100 + 100*1 = 200e18,烧掉 MINIMUM_SHARES
        assertEq(vault.balanceOf(alice), 200e18 - MIN_SHARES);
        assertEq(vault.balanceOf(BURN), MIN_SHARES);
        assertEq(vault.totalSupply(), 200e18);
    }

    // V2 二存等比无稀释
    function testSecondDepositorProportional() public {
        vm.prank(alice); vault.deposit(100e18, 100e18, 0);
        vm.prank(bob);   vault.deposit(100e18, 100e18, 0);
        // bob 存入与整池等值 → 份额=totalSupply 之前值(200e18)
        assertEq(vault.balanceOf(bob), 200e18);
        (uint256 a0, uint256 a1) = vault.previewWithdraw(vault.balanceOf(bob));
        // bob 可取回 ≥ 存入的一半以上(50%持份),等值不缩水(容许 1 wei 取整)
        assertApproxEqAbs(a0, 100e18, 2);
        assertApproxEqAbs(a1, 100e18, 2);
    }

    // V3 取款 + 滑点
    function testWithdrawAndSlippage() public {
        vm.prank(alice); vault.deposit(100e18, 100e18, 0);
        uint256 shares = vault.balanceOf(alice);
        (uint256 p0, uint256 p1) = vault.previewWithdraw(shares);

        vm.prank(alice);
        vm.expectRevert(SolonRangeVault.TooMuchSlippage.selector);
        vault.withdraw(shares, p0 + 1, 0); // min 高于应得 → revert

        vm.prank(alice);
        vault.withdraw(shares, p0, p1);
        assertEq(vault.balanceOf(alice), 0);
        // 烧毁的 MINIMUM_SHARES(1e3)对应的资产留在池里 → 粉尘级差额
        assertApproxEqAbs(t0.balanceOf(alice), 1_000e18, 1e3);
        assertApproxEqAbs(t1.balanceOf(alice), 1_000e18, 1e3);
    }

    // V4 滑动费:策略失衡时单边入金收费
    function testSlidingFeeOnImbalancedDeposit() public {
        vm.prank(alice); vault.deposit(100e18, 100e18, 0);
        // 人为制造失衡:策略里 token1 少一半(模拟价格移动后的持仓形态)
        vm.prank(address(strat));
        t1.transfer(address(0xD00D), 50e18);

        // bob 全 token1 单边入金(填的正是缺的一侧→不收费方向为 0,填充侧收费)
        (,,, uint256 fee0, uint256 fee1) = vault.previewDeposit(0, 50e18);
        assertEq(fee0, 0);
        assertGt(fee1, 0); // 填充部分按池费×滑动系数收费
        // 费≤池费上限:fee1 < fill × swapFee(50% cap 由滑动系数保证,宽松断言)
        assertLt(fee1, 50e18 * 0.0001e18 / 1e18);
    }

    // V5 通胀攻击
    function testInflationAttackDoesNotRobVictim() public {
        // 攻击者最小首存
        vm.prank(bob);
        vault.deposit(0, 2e3, 0); // token1 等值 2000 wei → 份额 1000(其余烧毁)
        // 攻击者直接向策略捐赠拉高每股净值
        vm.prank(bob);
        t1.transfer(address(strat), 500e18);

        // 受害人正常入金(池被捐赠推成极端失衡,金库会只收缺的那侧——按实际扣款算价值)
        uint256 a0Before = t0.balanceOf(alice); uint256 a1Before = t1.balanceOf(alice);
        vm.prank(alice);
        vault.deposit(100e18, 100e18, 0);
        uint256 aliceShares = vault.balanceOf(alice);
        assertGt(aliceShares, 0); // 不会被取整归零

        uint256 takenValue = (a0Before - t0.balanceOf(alice)) + (a1Before - t1.balanceOf(alice)); // price=1e36 等值直加
        (uint256 a0, uint256 a1) = vault.previewWithdraw(aliceShares);
        uint256 valueOut = a0 + a1;
        // 受害人取回价值 ≥ 实际被扣价值的 99.5%(份额取整损失必须是粉尘级,攻击者补贴远大于此)
        assertGt(valueOut, takenValue * 995 / 1000);

        // 攻击者不获利:取回 ≤ 自己投入(首存 2e3 + 捐赠 500e18)
        uint256 b0Before = t0.balanceOf(bob); uint256 b1Before = t1.balanceOf(bob);
        vm.prank(bob);
        vault.withdrawAll(0, 0);
        uint256 bobOut = (t0.balanceOf(bob) - b0Before) + (t1.balanceOf(bob) - b1Before);
        assertLe(bobOut, 500e18 + 2e3);
    }

    // V6 setStrategy 一次性
    function testSetStrategyOneShot() public {
        vm.expectRevert(SolonRangeVault.StrategyAlreadySet.selector);
        vault.setStrategy(address(strat));

        SolonRangeVault v2 = new SolonRangeVault("V2", "V2");
        // 策略的 vault 指向不匹配 → revert
        vm.expectRevert(SolonRangeVault.StrategyVaultMismatch.selector);
        v2.setStrategy(address(strat));

        // 非 owner 不可设
        SolonRangeVault v3 = new SolonRangeVault("V3", "V3");
        MockRangeStrategy s3 = new MockRangeStrategy(address(v3), t0, t1, 1e36, 0);
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        v3.setStrategy(address(s3));
    }

    // V7 preview 与实际一致
    function testPreviewMatchesDeposit() public {
        vm.prank(alice); vault.deposit(100e18, 100e18, 0);
        (uint256 pShares,,,,) = vault.previewDeposit(40e18, 40e18);
        vm.prank(bob); vault.deposit(40e18, 40e18, 0);
        assertApproxEqAbs(vault.balanceOf(bob), pShares, 2);
    }

    // minShares 滑点参数
    function testDepositMinSharesReverts() public {
        vm.prank(alice);
        vm.expectRevert(SolonRangeVault.TooMuchSlippage.selector);
        vault.deposit(100e18, 100e18, 300e18);
    }
}
