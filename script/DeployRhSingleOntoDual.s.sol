// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  DeployRhSingleOntoDual — 把单腿杠杆金库(UniV3LeverageVault)挂到一套已部署的 Dual 借贷栈上。

  首发时与 DeployRhDual 配套:单腿只借 LOAN 资产(USDG，reserve 1),接现有 LendingPool /
  LpShareOracleV4 / SwapExecutorV3 / SolonVaultRegistry —— 不新建池、不新种子、不碰 WETH 储备。
  只做:部署 1 个单腿金库 + 注册(新 vaultId) + 白名单 + 从 USDG 储备切一条授信 + setLiquidator。

  必填环境变量:
    LENDING_POOL / ORACLE / SWAP_EXECUTOR / VAULT_REGISTRY —— 现有 dual 栈地址;
    SINGLE_LOAN_CREDIT —— 单腿在 reserve 1 的借款授信(原始 USDG 单位);
    风控/利率参数同 DeploymentParameters(LLTV / LIQ_BONUS_BPS / PROTOCOL_FEE_BPS 等);
    GOVERNOR / KEEPER(默认=部署者);SINGLE_VAULT_ID(默认 2)。

  注意:reserve 1(USDG)总授信(dual + single)不得超过其容量,否则借款会顶到流动性上限。
  先 anvil fork 演练;真部署由 KousanS 拍板。
*/

import {console2} from "forge-std/Script.sol";
import {DeploymentParameters} from "./DeploymentParameters.s.sol";
import {UniV3LeverageVault} from "../src/UniV3LeverageVault.sol";

interface ILendingPoolWire {
    function enableVaultToBorrow(uint256 vaultId) external;
    function setCreditsOfVault(uint256 vaultId, uint256 reserveId, uint256 credit) external;
}

interface IVaultRegistryWire {
    function setVault(uint256 vaultId, address vault) external;
    // Raw storage getter: returns address(0) for a free id (getVault() instead REVERTS when unset).
    function vaults(uint256 vaultId) external view returns (address);
}

interface ILeverageVaultWire {
    function setLiquidator(address keeper, bool allowed) external;
}

contract DeployRhSingleOntoDual is DeploymentParameters {
    address constant NFPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG fee100
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function run() external {
        address deployer = msg.sender;
        Parameters memory p = _readParameters();
        address governor = vm.envOr("GOVERNOR", deployer);
        address keeper = vm.envOr("KEEPER", deployer);

        address lending = vm.envAddress("LENDING_POOL");
        address oracle = vm.envAddress("ORACLE");
        address swapExecutor = vm.envAddress("SWAP_EXECUTOR");
        address vaultReg = vm.envAddress("VAULT_REGISTRY");
        uint256 vaultId = vm.envOr("SINGLE_VAULT_ID", uint256(2));
        uint256 loanCredit = vm.envUint("SINGLE_LOAN_CREDIT"); // reserve 1 = USDG
        require(loanCredit > 0, "SINGLE_LOAN_CREDIT must be non-zero");
        require(IVaultRegistryWire(vaultReg).vaults(vaultId) == address(0), "SINGLE_VAULT_ID already taken");

        vm.startBroadcast();

        UniV3LeverageVault vault = new UniV3LeverageVault(UniV3LeverageVault.InitParams({
            governor: governor, positionManager: NFPM, pool: POOL,
            lendingPool: lending, reserveId: 1, oracle: oracle, swapExecutor: swapExecutor,
            token0: WETH, token1: USDG, loanIsC0: false, fee: 100,
            minWidthTicks: 10, liqBonusBps: p.liqBonusBps, protocolFeeBps: p.protocolFeeBps, harvestFeeBps: 1000,
            borrowFeeBps: 0, closeFactorBps: 5000, lltv: p.lltv
        }));

        IVaultRegistryWire(vaultReg).setVault(vaultId, address(vault));
        ILendingPoolWire(lending).enableVaultToBorrow(vaultId);
        ILendingPoolWire(lending).setCreditsOfVault(vaultId, 1, loanCredit);

        if (governor == deployer) {
            ILeverageVaultWire(address(vault)).setLiquidator(keeper, true);
        } else {
            console2.log("MANUAL STEP: governor must call vault.setLiquidator(keeper, true)");
            console2.log("MANUAL STEP: governor (owner of the shared pool/registry) must run setVault/enable/credit if not owned by deployer");
        }

        vm.stopBroadcast();

        console2.log("=== Solon single-borrow vault attached to dual stack ===");
        console2.log("singleVault", address(vault));
        console2.log("vaultId", vaultId);
        console2.log("loanCredit (reserve 1 USDG)", loanCredit);
    }
}
