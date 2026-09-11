// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  Sepolia 最小仓烟测(checklist D.7):对已部署的 UniV3DualVault 开一笔小仓
  (双币各投一点、双币各借一点) → 读回健康度与估值 → 全平 → 断言债务清零。
  只依赖环境变量 VAULT / RISK_TOKEN / LOAN_TOKEN / LENDING_POOL。
*/
import {Script, console2} from "forge-std/Script.sol";
import {UniV3DualVault} from "../src/UniV3DualVault.sol";

interface IERC20Smoke {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
interface IPoolSlot0Smoke {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

contract SmokeSepoliaDual is Script {
    function run() external {
        UniV3DualVault vault = UniV3DualVault(vm.envAddress("VAULT"));
        address risk = vm.envAddress("RISK_TOKEN");
        address loan = vm.envAddress("LOAN_TOKEN");
        (, int24 tick,,,,,) = IPoolSlot0Smoke(vault.POOL()).slot0();

        vm.startBroadcast();
        IERC20Smoke(risk).approve(address(vault), type(uint256).max);
        IERC20Smoke(loan).approve(address(vault), type(uint256).max);

        uint256 id = vault.open(UniV3DualVault.OpenParams({
            investRisk: 0.02e18, investLoan: 50e6,
            borrowRisk: 0.01e18, borrowLoan: 25e6,
            tickLower: tick - 1000, tickUpper: tick + 1000,
            amount0Min: 0, amount1Min: 0, minLiquidity: 1,
            deadline: block.timestamp + 1800
        }));
        console2.log("opened id", id);
        console2.log("positionValue", vault.positionValue(id));
        console2.log("totalDebtInLoan", vault.totalDebtInLoan(id));
        console2.log("isHealthy", vault.isHealthy(id));

        vault.close(id, UniV3DualVault.CloseParams({
            percent: 10000, topUpRisk: 0, topUpLoan: 0,
            maxSwapIn: type(uint256).max, minOutRisk: 0, minOutLoan: 0,
            zapPath: "", deadline: block.timestamp + 1800
        }));
        require(vault.totalDebtInLoan(id) == 0, "debt not cleared");
        console2.log("closed; residual debt", vault.totalDebtInLoan(id));
        vm.stopBroadcast();
    }
}
