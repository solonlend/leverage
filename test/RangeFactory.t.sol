// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RangeFactory} from "../src/range/RangeFactory.sol";
import {SolonRangeVault} from "../src/range/SolonRangeVault.sol";
import {RangeStrategyUniV3} from "../src/range/RangeStrategyUniV3.sol";
import {RangeStratManager} from "../src/range/RangeStratManager.sol";
import {RangeMockERC20} from "./RangeVault.t.sol";
import {RangeVaultDeployer, RangeStrategyDeployer} from "../src/range/RangeDeployers.sol";

/*
  RangeFactory + 策略权限/边界单测(mock 池,零流动性路径):
  F1 createRangeVault 一笔交易接线完整(vault↔strategy↔factory+所有权落 owner)
  F2 权限:create/setFees/setKeeper/setTreasury/setRebalancer 仅 owner;globalPause keeper 可调
  F3 费率上限:total≤0.15e18,call≤0.2e18
  F4 globalPause 熔断:置位后策略 deposit 直接 StrategyPaused
  F5 setDeviation 新边界:(0,200] 有效,0/201 revert
  F6 moveTicks 仅白名单 rebalancer
*/

contract MockV3Pool {
    address public token0; address public token1;
    int24 public tickSpacing = 1;
    uint24 public fee = 100;
    constructor(address _t0, address _t1) { token0 = _t0; token1 = _t1; }
    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(2 ** 96), 0, 0, 2500, 2500, 0, true); // price 1:1, tick 0
    }
    function observe(uint32[] calldata secondsAgos) external pure returns (int56[] memory, uint160[] memory) {
        int56[] memory t = new int56[](secondsAgos.length);
        uint160[] memory s = new uint160[](secondsAgos.length);
        return (t, s); // 累计 tick 全 0 → twap=0,与现价一致=calm
    }
    function positions(bytes32) external pure returns (uint128, uint256, uint256, uint128, uint128) {
        return (0, 0, 0, 0, 0);
    }
    function burn(int24, int24, uint128) external pure returns (uint256, uint256) { return (0, 0); }
    function collect(address, int24, int24, uint128, uint128) external pure returns (uint128, uint128) { return (0, 0); }
    function mint(address, int24, int24, uint128, bytes calldata) external pure returns (uint256, uint256) { return (0, 0); }
}

contract RangeFactoryTest is Test {
    RangeFactory factory;
    MockV3Pool pool;
    RangeMockERC20 t0; RangeMockERC20 t1;
    address keeper;
    address treasury = address(0x7EA);
    address stranger = address(0x5713);

    function setUp() public {
        keeper = address(0xCE); // valid hex
        t0 = new RangeMockERC20("T0", 18);
        t1 = new RangeMockERC20("T1", 18);
        pool = new MockV3Pool(address(t0), address(t1));
        factory = new RangeFactory(keeper, treasury, address(new RangeVaultDeployer()), address(new RangeStrategyDeployer()));
    }

    function _create() internal returns (SolonRangeVault v, RangeStrategyUniV3 s) {
        (address va, address sa) = factory.createRangeVault(address(pool), "Solon Range", "srT", 500, 30);
        v = SolonRangeVault(va); s = RangeStrategyUniV3(sa);
    }

    // F1 接线
    function testCreateWiring() public {
        (SolonRangeVault v, RangeStrategyUniV3 s) = _create();
        assertEq(address(v.strategy()), address(s));
        assertEq(s.vault(), address(v));
        assertEq(address(s.factory()), address(factory));
        assertEq(s.pool(), address(pool));
        assertEq(s.lpToken0(), address(t0));
        assertEq(s.lpToken1(), address(t1));
        assertEq(s.maxTickDeviation(), 30);
        assertEq(s.positionWidth(), 500);
        assertEq(v.owner(), address(this));
        assertEq(s.owner(), address(this));
        assertEq(factory.deploymentsLength(), 1);
        (address dv, address ds, address dp) = factory.deployments(0);
        assertEq(dv, address(v)); assertEq(ds, address(s)); assertEq(dp, address(pool));
    }

    // F2 权限
    function testAccessControl() public {
        vm.startPrank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.createRangeVault(address(pool), "x", "x", 500, 30);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.setFees(0.1e18, 0.05e18);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.setKeeper(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.setTreasury(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        factory.setRebalancer(stranger, true);
        vm.expectRevert(RangeFactory.NotManager.selector);
        factory.setGlobalPause(true);
        vm.stopPrank();

        // keeper 可全局熔断
        vm.prank(keeper);
        factory.setGlobalPause(true);
        assertTrue(factory.globalPause());
    }

    // F3 费率上限
    function testFeeCaps() public {
        vm.expectRevert(RangeFactory.OverLimit.selector);
        factory.setFees(0.150000001e18, 0.05e18);
        vm.expectRevert(RangeFactory.OverLimit.selector);
        factory.setFees(0.1e18, 0.200000001e18);
        factory.setFees(0.15e18, 0.2e18);
        (uint256 tf, uint256 cf) = factory.getFees();
        assertEq(tf, 0.15e18); assertEq(cf, 0.2e18);
    }

    // F4 globalPause 熔断
    function testGlobalPauseBlocksDeposit() public {
        (SolonRangeVault v, RangeStrategyUniV3 s) = _create();
        // 真实流程中 vault 先把存款转给策略再调 deposit;这里补上余额,否则 alt 区间
        // 无从设置(lower==upper)会在 V3 流动性数学里除零——真实路径不可达的人造态
        t1.mint(address(s), 10e18);
        vm.prank(address(v));
        s.deposit();

        factory.setGlobalPause(true);
        vm.prank(address(v));
        vm.expectRevert(RangeStratManager.StrategyPaused.selector);
        s.deposit();

        factory.setGlobalPause(false);
        vm.prank(address(v));
        s.deposit();
    }

    // F5 deviation 新边界
    function testDeviationBounds() public {
        (, RangeStrategyUniV3 s) = _create();
        vm.expectRevert(RangeStrategyUniV3.InvalidInput.selector);
        s.setDeviation(0);
        vm.expectRevert(RangeStrategyUniV3.InvalidInput.selector);
        s.setDeviation(201);
        s.setDeviation(200);
        assertEq(s.maxTickDeviation(), 200);
        s.setDeviation(1); // 上游原上限内的值也仍有效
        assertEq(s.maxTickDeviation(), 1);
    }

    // F7 RT-1 修复:两币价值精确相等的首存不再除零(上游会 revert)
    function testBalancedFirstDepositDoesNotBrick() public {
        (SolonRangeVault v, RangeStrategyUniV3 s) = _create();
        // mock 池价 1:1,等额余额=价值精确相等 → 上游 alt 区间未初始化,除零
        t0.mint(address(s), 10e18);
        t1.mint(address(s), 10e18);
        vm.prank(address(v));
        s.deposit(); // 修复后走 token0 侧分支,不 revert
        (int24 altLower, int24 altUpper) = s.positionAlt();
        assertTrue(altLower != altUpper); // alt 区间已初始化
    }

    // F8 retireVault:仅全员退出后可退役;资金扫给 treasury;所有权烧毁(C-6 补)
    function testRetireVault() public {
        (SolonRangeVault v, RangeStrategyUniV3 s) = _create();
        // 用户经 vault 正常存取一轮,只剩烧毁份额
        address u = address(0xA1);
        t0.mint(u, 100e18); t1.mint(u, 100e18);
        vm.startPrank(u);
        t0.approve(address(v), type(uint256).max);
        t1.approve(address(v), type(uint256).max);
        v.deposit(10e18, 10e18, 0);
        vm.stopPrank();

        // 有外部份额时不可退役
        vm.expectRevert(RangeStrategyUniV3.NotAuthorized.selector);
        s.retireVault();

        uint256 uShares = v.balanceOf(u);
        vm.prank(u);
        v.withdraw(uShares, 0, 0);
        assertEq(v.totalSupply(), 1e3); // 只剩烧毁份额

        uint256 tr0 = t0.balanceOf(treasury); uint256 tr1 = t1.balanceOf(treasury);
        s.retireVault();
        assertEq(s.owner(), address(0)); // 所有权烧毁
        // 残余粉尘进 treasury(烧毁份额对应的资产)
        assertGe(t0.balanceOf(treasury) + t1.balanceOf(treasury), tr0 + tr1);
        assertEq(t0.balanceOf(address(s)), 0);
        assertEq(t1.balanceOf(address(s)), 0);
    }

    // F6 moveTicks 白名单
    function testMoveTicksOnlyRebalancers() public {
        (SolonRangeVault v, RangeStrategyUniV3 s) = _create();
        t1.mint(address(s), 10e18); // 同上:先有余额再初始化区间
        vm.prank(address(v)); s.deposit(); // initTicks

        vm.expectRevert(RangeStrategyUniV3.NotAuthorized.selector);
        s.moveTicks(); // owner 也不行,必须白名单

        factory.setRebalancer(address(this), true);
        s.moveTicks(); // 白名单后走通(零流动性路径)
    }
}
