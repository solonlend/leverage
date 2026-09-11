// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  SwapExecutorV3 — ISwapExecutor(金库 zap 换币口)→ Uniswap V3 SwapRouter02 适配器。

  单币金库的 zap 与 dual 金库的缺口/delta 兑换都经它执行(exactInput + exactOutput)。
  不持币:拉入 tokenIn → router → 产出直达调用方;exactOutput 未花完部分退回。

  path 语义(与金库 zapPath 参数对齐):
  - 空 path:用部署时的 DEFAULT_FEE 构造单跳 tokenIn|fee|tokenOut(RH 上 WETH/USDG fee100 最深)。
  - 显式 path:V3 标准编码 token(20B) + [fee(3B) + token(20B)]*n,原样透传;
    但首端必须 = tokenIn、末端必须 = tokenOut —— zapPath 是用户可控入参,端点校验防止
    错币/恶意路径把产出兑成无关 token 还被金库当作 amt0/amt1 计数。
  滑点保护由金库层负责(开仓 minLiquidity / 平仓 minOutSingleToken),minOut 原样透传。
*/

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// SwapRouter02(RH 0xCAf681A6...)的 exactInput/exactOutput 面。02 版结构体无 deadline 字段。
interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    struct ExactOutputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountOut; uint256 amountInMaximum; uint160 sqrtPriceLimitX96;
    }
    struct ExactOutputParams {
        bytes path;      // 反向编码:tokenOut 开头 → tokenIn 结尾(Uniswap 惯例)
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}

contract SwapExecutorV3 {
    /// Deployer can only remove router approvals; it cannot move funds or change the router.
    address public immutable owner;
    error Unauthorized();
    event RouterApprovalRevoked(address indexed token);

    address public immutable ROUTER;
    uint24 public immutable DEFAULT_FEE;

    uint256 private constant ADDR_SIZE = 20;
    uint256 private constant HOP_SIZE = 23; // fee(3) + token(20)

    constructor(address router, uint24 defaultFee) {
        require(router != address(0), "ROUTER_0");
        owner = msg.sender;
        ROUTER = router;
        DEFAULT_FEE = defaultFee;
    }

    function revokeRouterApproval(address token) external {
        if (msg.sender != owner) revert Unauthorized();
        _approveExact(token, ROUTER, 0);
        emit RouterApprovalRevoked(token);
    }

    function swapExactInput(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, bytes calldata path)
        external returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;

        bytes memory routePath;
        if (path.length == 0) {
            routePath = abi.encodePacked(tokenIn, DEFAULT_FEE, tokenOut);
        } else {
            require(path.length >= ADDR_SIZE + HOP_SIZE && (path.length - ADDR_SIZE) % HOP_SIZE == 0, "PATH_LEN");
            require(address(bytes20(path[0:ADDR_SIZE])) == tokenIn, "PATH_IN");
            require(address(bytes20(path[path.length - ADDR_SIZE:])) == tokenOut, "PATH_OUT");
            routePath = path;
        }

        _pull(tokenIn, msg.sender, amountIn);
        _approveExact(tokenIn, ROUTER, amountIn);
        amountOut = ISwapRouter02(ROUTER).exactInput(ISwapRouter02.ExactInputParams({
            path: routePath,
            recipient: msg.sender, // 产出不经本合约,直达调用方
            amountIn: amountIn,
            amountOutMinimum: minOut
        }));
        _approveExact(tokenIn, ROUTER, 0);
    }

    /// dual-borrow 平仓缺口买入:买恰好 amountOut 的 tokenOut,投入 tokenIn ≤ maxIn。
    /// 拉 maxIn → router exactOutput(产出直达调用方)→ 未花完部分退回调用方。不持币。
    /// 显式 path 必须反向编码(头=tokenOut,尾=tokenIn),端点强校验,防错币路径。
    function swapExactOutput(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxIn, bytes calldata path)
        external returns (uint256 amountIn)
    {
        if (amountOut == 0) return 0;
        _pull(tokenIn, msg.sender, maxIn);
        _approveExact(tokenIn, ROUTER, maxIn);

        if (path.length == 0) {
            amountIn = ISwapRouter02(ROUTER).exactOutputSingle(ISwapRouter02.ExactOutputSingleParams({
                tokenIn: tokenIn, tokenOut: tokenOut, fee: DEFAULT_FEE, recipient: msg.sender,
                amountOut: amountOut, amountInMaximum: maxIn, sqrtPriceLimitX96: 0
            }));
        } else {
            require(path.length >= ADDR_SIZE + HOP_SIZE && (path.length - ADDR_SIZE) % HOP_SIZE == 0, "PATH_LEN");
            require(address(bytes20(path[0:ADDR_SIZE])) == tokenOut, "PATH_OUT");
            require(address(bytes20(path[path.length - ADDR_SIZE:])) == tokenIn, "PATH_IN");
            amountIn = ISwapRouter02(ROUTER).exactOutput(ISwapRouter02.ExactOutputParams({
                path: path, recipient: msg.sender, amountOut: amountOut, amountInMaximum: maxIn
            }));
        }

        _approveExact(tokenIn, ROUTER, 0);
        if (maxIn > amountIn) _transfer(tokenIn, msg.sender, maxIn - amountIn); // 未花完退回
    }

    // 兼容非标 ERC20(不返回 bool)的安全调用,与金库同一套写法。
    function _safeCall(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "TOKEN_CALL_FAILED");
    }
    function _pull(address token, address from, uint256 amt) private {
        if (amt == 0) return; // 零值守卫:revert-on-zero 类非标 token 兼容
        _safeCall(token, abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, address(this), amt));
    }
    function _transfer(address token, address to, uint256 amt) private {
        _safeCall(token, abi.encodeWithSelector(bytes4(keccak256("transfer(address,uint256)")), to, amt));
    }
    function _approveExact(address token, address spender, uint256 amt) private {
        if (IERC20Minimal(token).allowance(address(this), spender) != 0) {
            _safeCall(token, abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, 0));
        }
        if (amt != 0) _safeCall(token, abi.encodeWithSelector(IERC20Minimal.approve.selector, spender, amt));
    }
}
