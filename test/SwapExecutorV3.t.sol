// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SwapExecutorV3} from "../src/SwapExecutorV3.sol";

/// 单测:SwapExecutorV3(ISwapExecutor → Uniswap V3 SwapRouter02 适配器)。
/// 真 router 行为由 fork 测试(RhV3Fork)覆盖;这里用 MockRouter02 验证适配器自身的
/// 拉币/路径构造/端点校验/回款/无滞留等契约。

contract MockERC20 {
    string public symbol; uint8 public decimals = 18;
    bool public strictApproval;
    bool public noReturn;
    function setCompatibility(bool strict_, bool noReturn_) external {
        strictApproval = strict_; noReturn = noReturn_;
    }
    function _return() private view returns (bool) {
        if (noReturn) assembly { return(0, 0) }
        return true;
    }
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory s) { symbol = s; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return _return();
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return _return();
    }
    function approve(address s, uint256 a) external returns (bool) {
        require(!strictApproval || a == 0 || allowance[msg.sender][s] == 0, "ZERO_FIRST");
        allowance[msg.sender][s] = a; return _return();
    }
}

/// SwapRouter02.exactInput 的最小 mock:按固定 rate 兑付 path 末端 token,记录收到的参数。
contract MockRouter02 {
    MockERC20 public tokenOut; uint256 public rate; // out = in * rate / 1e18
    bytes public lastPath; uint256 public lastAmountIn; uint256 public lastMinOut; address public lastRecipient;
    constructor(MockERC20 o, uint256 r) { tokenOut = o; rate = r; }

    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    struct ExactOutputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountOut; uint256 amountInMaximum; uint160 sqrtPriceLimitX96;
    }
    struct ExactOutputParams { bytes path; address recipient; uint256 amountOut; uint256 amountInMaximum; }
    uint256 public allowanceAtSwap;
    uint256 public inPerOut = 1e18; // 买 1 out 需要多少 in
    function setInPerOut(uint256 v) external { inPerOut = v; }
    uint24 public lastOutFee; bytes public lastOutPath;

    function _pull(address token, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(
            MockERC20.transferFrom.selector, msg.sender, address(this), amount
        ));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "PULL_FAILED");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata p) external returns (uint256 amountIn) {
        lastOutFee = p.fee;
        amountIn = (p.amountOut * inPerOut + 1e18 - 1) / 1e18;
        require(amountIn <= p.amountInMaximum, "Too much requested");
        allowanceAtSwap = MockERC20(p.tokenIn).allowance(msg.sender, address(this));
        _pull(p.tokenIn, amountIn);
        MockERC20(p.tokenOut).mint(p.recipient, p.amountOut);
    }
    function exactOutput(ExactOutputParams calldata p) external returns (uint256 amountIn) {
        lastOutPath = p.path;
        address tokenOut_ = address(bytes20(p.path[0:20]));           // 反向 path:头=tokenOut
        address tokenIn_ = address(bytes20(p.path[p.path.length-20:])); // 尾=tokenIn
        amountIn = (p.amountOut * inPerOut + 1e18 - 1) / 1e18;
        require(amountIn <= p.amountInMaximum, "Too much requested");
        allowanceAtSwap = MockERC20(tokenIn_).allowance(msg.sender, address(this));
        _pull(tokenIn_, amountIn);
        MockERC20(tokenOut_).mint(p.recipient, p.amountOut);
    }

    function exactInput(ExactInputParams calldata p) external returns (uint256 amountOut) {
        lastPath = p.path; lastAmountIn = p.amountIn; lastMinOut = p.amountOutMinimum; lastRecipient = p.recipient;
        // 像真 router 一样把 tokenIn 拉走(path 头 20 字节)
        address tokenIn = address(bytes20(p.path[0:20]));
        allowanceAtSwap = MockERC20(tokenIn).allowance(msg.sender, address(this));
        _pull(tokenIn, p.amountIn);
        amountOut = (p.amountIn * rate) / 1e18;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        tokenOut.mint(p.recipient, amountOut);
    }
}

contract SwapExecutorV3Test is Test {
    MockERC20 usdg; MockERC20 weth; MockERC20 mid;
    MockRouter02 router;
    SwapExecutorV3 exec;
    address vault = makeAddr("vault");
    uint24 constant DEFAULT_FEE = 100;

    function setUp() public {
        usdg = new MockERC20("USDG");
        weth = new MockERC20("WETH");
        mid = new MockERC20("MID");
        router = new MockRouter02(weth, 5e14); // 1 USDG -> 0.0005 WETH
        exec = new SwapExecutorV3(address(router), DEFAULT_FEE);

        usdg.mint(vault, 1_000_000e18);
        vm.prank(vault); usdg.approve(address(exec), type(uint256).max);
    }

    function _swap(uint256 amountIn, uint256 minOut, bytes memory path) internal returns (uint256) {
        vm.prank(vault);
        return exec.swapExactInput(address(usdg), address(weth), amountIn, minOut, path);
    }

    function test_exactInput_approvalIsExactAndCleared() public {
        _swap(123e18, 0, "");
        assertEq(router.allowanceAtSwap(), 123e18, "router receives exact allowance");
        assertEq(usdg.allowance(address(exec), address(router)), 0, "no standing approval");
    }

    function test_exactOutput_approvalClearedWithRefund() public {
        uint256 before = usdg.balanceOf(vault);
        _swapOut(10e18, 50e18, "");
        assertEq(router.allowanceAtSwap(), 50e18);
        assertEq(usdg.allowance(address(exec), address(router)), 0, "unused approval cleared");
        assertEq(before - usdg.balanceOf(vault), 10e18);
    }

    function test_ownerCanRevokeSeededAllowance() public {
        vm.prank(address(exec));
        usdg.approve(address(router), 999e18);
        vm.expectEmit(true, false, false, true, address(exec));
        emit RouterApprovalRevoked(address(usdg));
        (bool ok,) = address(exec).call(abi.encodeWithSignature("revokeRouterApproval(address)", address(usdg)));
        assertTrue(ok, "owner revoke exists");
        assertEq(usdg.allowance(address(exec), address(router)), 0);
    }

    event RouterApprovalRevoked(address indexed token);

    function test_nonOwnerCannotRevoke() public {
        vm.prank(address(exec));
        usdg.approve(address(router), 999e18);
        vm.prank(vault);
        (bool ok, bytes memory reason) = address(exec).call(
            abi.encodeWithSignature("revokeRouterApproval(address)", address(usdg))
        );
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSignature("Unauthorized()"));
        assertEq(usdg.allowance(address(exec), address(router)), 999e18);
    }

    function test_zeroFirstToken_replacesSeededAllowanceAndRepeatedSwaps() public {
        vm.prank(address(exec));
        usdg.approve(address(router), 1);
        usdg.setCompatibility(true, false);
        _swap(123e18, 0, "");
        assertEq(router.allowanceAtSwap(), 123e18);
        assertEq(usdg.allowance(address(exec), address(router)), 0);
        _swap(234e18, 0, "");
        assertEq(router.allowanceAtSwap(), 234e18);
        assertEq(usdg.allowance(address(exec), address(router)), 0);
    }

    function test_noReturnToken_exactOutputRefundAndApprovalCleanup() public {
        usdg.setCompatibility(true, true);
        uint256 before = usdg.balanceOf(vault);
        bytes memory path = abi.encodePacked(address(weth), uint24(500), address(usdg));
        _swapOut(10e18, 50e18, path);
        assertEq(router.allowanceAtSwap(), 50e18);
        assertEq(usdg.allowance(address(exec), address(router)), 0);
        assertEq(before - usdg.balanceOf(vault), 10e18);
        assertEq(usdg.balanceOf(address(exec)), 0);
    }

    /// 空 path → 用默认 fee 构造单跳 path(tokenIn|fee|tokenOut),输出直接回到调用方。
    function test_emptyPath_buildsSingleHop_andPaysCaller() public {
        uint256 before = weth.balanceOf(vault);
        uint256 out = _swap(1000e18, 0, "");
        assertEq(out, (1000e18 * 5e14) / 1e18, "amountOut");
        assertEq(weth.balanceOf(vault) - before, out, "output must land on caller");
        assertEq(router.lastPath(), abi.encodePacked(address(usdg), DEFAULT_FEE, address(weth)), "single-hop path");
        assertEq(router.lastRecipient(), vault, "recipient = caller");
        assertEq(router.lastMinOut(), 0, "minOut passthrough");
    }

    /// 显式多跳 path 原样透传给 router。
    function test_explicitMultiHopPath_passthrough() public {
        bytes memory path = abi.encodePacked(address(usdg), uint24(500), address(mid), uint24(3000), address(weth));
        _swap(500e18, 0, path);
        assertEq(router.lastPath(), path, "multi-hop path passthrough");
    }

    /// path 首端 != tokenIn → revert(防错路径把别的币兑出去)。
    function test_pathHeadMismatch_reverts() public {
        bytes memory path = abi.encodePacked(address(mid), uint24(500), address(weth));
        vm.prank(vault);
        vm.expectRevert(bytes("PATH_IN"));
        exec.swapExactInput(address(usdg), address(weth), 100e18, 0, path);
    }

    /// path 末端 != tokenOut → revert(防兑成无关 token 被当作产出计数)。
    function test_pathTailMismatch_reverts() public {
        bytes memory path = abi.encodePacked(address(usdg), uint24(500), address(mid));
        vm.prank(vault);
        vm.expectRevert(bytes("PATH_OUT"));
        exec.swapExactInput(address(usdg), address(weth), 100e18, 0, path);
    }

    /// 畸形 path(长度不是 20+n*23)→ revert。
    function test_malformedPathLength_reverts() public {
        bytes memory path = abi.encodePacked(address(usdg), uint24(500)); // 23 字节,缺尾端 token
        vm.prank(vault);
        vm.expectRevert(bytes("PATH_LEN"));
        exec.swapExactInput(address(usdg), address(weth), 100e18, 0, path);
    }

    /// minOut 透传:router 兑不出 minOut 时整体 revert。
    function test_minOutEnforced() public {
        vm.prank(vault);
        vm.expectRevert("Too little received");
        exec.swapExactInput(address(usdg), address(weth), 1000e18, type(uint128).max, "");
    }

    /// amountIn = 0 → 直接返回 0,不 revert 不动账。
    function test_zeroAmountIn_returnsZero() public {
        uint256 out = _swap(0, 0, "");
        assertEq(out, 0);
        assertEq(router.lastAmountIn(), 0, "router must not be called"); // 初值 0,未被写
    }

    /// swap 后执行器内不滞留任何 token。
    function test_noTokensStranded() public {
        _swap(1234e18, 0, "");
        assertEq(usdg.balanceOf(address(exec)), 0, "no tokenIn stranded");
        assertEq(weth.balanceOf(address(exec)), 0, "no tokenOut stranded");
    }

    // ─────────── swapExactOutput(dual-borrow 平仓缺口买入)───────────
    function _swapOut(uint256 amountOut, uint256 maxIn, bytes memory path) internal returns (uint256) {
        vm.prank(vault);
        return exec.swapExactOutput(address(usdg), address(weth), amountOut, maxIn, path);
    }

    /// 空 path → 默认 fee 单跳 exactOutputSingle;产出到调用方;未花完的 maxIn 退回;不滞留。
    function test_exactOutput_emptyPath_refundsUnspent() public {
        router.setInPerOut(2e18); // 买 1 WETH 要 2 USDG
        uint256 uBefore = usdg.balanceOf(vault);
        uint256 wBefore = weth.balanceOf(vault);
        uint256 spent = _swapOut(10e18, 50e18, "");
        assertEq(spent, 20e18, "spent = out*rate");
        assertEq(uBefore - usdg.balanceOf(vault), 20e18, "only spent pulled net (rest refunded)");
        assertEq(weth.balanceOf(vault) - wBefore, 10e18, "exact output delivered");
        assertEq(router.lastOutFee(), DEFAULT_FEE, "default fee tier");
        assertEq(usdg.balanceOf(address(exec)), 0, "no tokenIn stranded");
        assertEq(weth.balanceOf(address(exec)), 0, "no tokenOut stranded");
    }

    /// maxIn 不够 → revert(router 报价高于上限)。
    function test_exactOutput_maxIn_insufficient_reverts() public {
        router.setInPerOut(2e18);
        vm.prank(vault);
        vm.expectRevert("Too much requested");
        exec.swapExactOutput(address(usdg), address(weth), 10e18, 19e18, "");
    }

    /// 显式 path 必须是反向编码:头=tokenOut,尾=tokenIn;错则拦。
    function test_exactOutput_reversedPath_validated() public {
        // 正确反向 path:WETH(out) | fee | USDG(in)
        bytes memory ok = abi.encodePacked(address(weth), uint24(500), address(usdg));
        _swapOut(1e18, 10e18, ok);
        assertEq(router.lastOutPath(), ok, "reversed path passthrough");

        bytes memory badHead = abi.encodePacked(address(usdg), uint24(500), address(usdg));
        vm.prank(vault);
        vm.expectRevert(bytes("PATH_OUT"));
        exec.swapExactOutput(address(usdg), address(weth), 1e18, 10e18, badHead);

        bytes memory badTail = abi.encodePacked(address(weth), uint24(500), address(mid));
        vm.prank(vault);
        vm.expectRevert(bytes("PATH_IN"));
        exec.swapExactOutput(address(usdg), address(weth), 1e18, 10e18, badTail);
    }

    /// amountOut=0 → 0,不动账。
    function test_exactOutput_zero() public {
        uint256 spent = _swapOut(0, 10e18, "");
        assertEq(spent, 0);
    }

}
