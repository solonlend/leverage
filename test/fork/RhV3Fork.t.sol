// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniV3LeverageVault} from "../../src/UniV3LeverageVault.sol";
import {LpShareOracleV4} from "../../src/LpShareOracleV4.sol";
import {SwapExecutorV3} from "../../src/SwapExecutorV3.sol";
import {LendingPool} from "../../src/lending/lendingpool/LendingPool.sol";
import {AddressRegistry} from "../../src/lending/address-registry/AddressRegistry.sol";
import {AddressId} from "../../src/lending/libraries/helpers/AddressId.sol";
import {SolonVaultRegistry} from "../../src/lending/SolonVaultRegistry.sol";

/// FULL V3 fork e2e (Robinhood Chain mainnet): our V3 vault opens/closes a REAL leveraged LP position
/// against the REAL Uniswap V3 NonfungiblePositionManager + real WETH/USDG pool + real swapRouter02,
/// valued by the REAL Chainlink ETH/USDG feeds. Only the LendingPool is a local mock (our own fork of
/// Extra, audited separately). Nothing is deployed to the real chain — all runs on a local fork.
/// Run: REQUIRE_RH_FORK=true forge test --match-contract RhV3Fork  (needs network)

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}
interface IV3Pool { function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool); }
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn; address tokenOut; uint24 fee; address recipient;
        uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

contract RhV3ForkTest is Test {
    string RPC = "https://rpc.mainnet.chain.robinhood.com/rpc";
    address constant NFPM   = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant POOL   = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG fee100
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant WETH   = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG   = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH_FEED  = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    UniV3LeverageVault vault;
    LendingPool lending;
    LpShareOracleV4 oracle;
    SwapExecutorV3 swapAdapter;
    address user = makeAddr("user");
    address lender = makeAddr("lender");
    address gov = makeAddr("gov");
    bool forked;

    function setUp() public {
        try vm.createSelectFork(RPC) { forked = true; } catch {
            if (vm.envOr("REQUIRE_RH_FORK", false)) revert("required RH fork unavailable");
            forked = false;
            return;
        }

        // REAL LendingPool (ExtraFi fork, vendored) — the only mock left in this e2e is the keeper.
        AddressRegistry registry = new AddressRegistry(WETH);
        registry.setAddress(AddressId.ADDRESS_ID_TREASURY, makeAddr("treasury"));
        lending = new LendingPool(address(registry), WETH);
        lending.initReserve(USDG); // reserveId 1; reads real USDG name/symbol/decimals(6)
        SolonVaultRegistry vaultReg = new SolonVaultRegistry();
        registry.setAddress(AddressId.ADDRESS_ID_VAULT_FACTORY, address(vaultReg));
        // WETH(0x0Bd7) < USDG(0x5fc5): currency0=WETH(risk,18), currency1=USDG(loan,6); loan=USDG=c1
        oracle = new LpShareOracleV4(ETH_FEED, USDG_FEED, USDG_FEED, 18, 6, 6, 26 hours, 26 hours, 100);
        swapAdapter = new SwapExecutorV3(ROUTER, 100);

        vault = new UniV3LeverageVault(UniV3LeverageVault.InitParams({
            governor: gov, positionManager: NFPM, pool: POOL,
            lendingPool: address(lending), reserveId: 1, oracle: address(oracle), swapExecutor: address(swapAdapter),
            token0: WETH, token1: USDG, loanIsC0: false, fee: 100,
            minWidthTicks: 10, liqBonusBps: 800, protocolFeeBps: 1000, harvestFeeBps: 1000,
            borrowFeeBps: 0, closeFactorBps: 5000, lltv: 0.8e18
        }));

        // whitelist + credit for the vault on the real pool
        vaultReg.setVault(1, address(vault));
        lending.enableVaultToBorrow(1);
        lending.setCreditsOfVault(1, 1, type(uint128).max);

        // fund: user 20k USDG to invest; lender deposits 100k USDG into the real pool
        deal(USDG, user, 20_000e6);
        deal(USDG, lender, 100_000e6);
        vm.startPrank(lender);
        IERC20(USDG).approve(address(lending), type(uint256).max);
        lending.deposit(1, 100_000e6, lender, 0);
        vm.stopPrank();
    }

    function test_v3_open_and_close_real_pool() public {
        vm.skip(!forked, "RH fork unavailable");
        (, int24 cur,,,,,) = IV3Pool(POOL).slot0();
        int24 lower = cur - 2000; int24 upper = cur + 2000; // straddle real price (fee100 spacing=1)

        vm.startPrank(user);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        uint256 id = vault.open(UniV3LeverageVault.OpenParams({
            amountInvest: 5_000e6, amountBorrow: 5_000e6, tickLower: lower, tickUpper: upper,
            amount0Min: 0, amount1Min: 0, minLiquidity: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        (uint256 dexId, uint128 liq,,, uint256 debtId) = vault.positions(id);
        emit log_named_uint("V3 position tokenId (real NFPM)", dexId);
        emit log_named_uint("liquidity minted", liq);
        assertGt(liq, 0, "real V3 position minted via our vault");
        (uint256 debtAfterOpen,) = lending.getCurrentDebt(debtId);
        assertEq(debtAfterOpen, 5_000e6, "real pool debt recorded");
        assertEq(vault.ownerOf(id), user, "Solon NFT to user");

        uint256 before = IERC20(USDG).balanceOf(user);
        uint256 out = vault.close(id, UniV3LeverageVault.CloseParams({
            percent: 10000, minOutSingleToken: 0, zapPath: "", deadline: block.timestamp + 1
        }));
        vm.stopPrank();
        emit log_named_uint("USDG returned on close", out);
        assertEq(vault.ownerOf(id), address(0), "NFT burned on full close");
        assertGt(IERC20(USDG).balanceOf(user), before, "user got USDG back");
        (uint256 debtAfterClose,) = lending.getCurrentDebt(debtId);
        assertEq(debtAfterClose, 0, "debt repaid to real pool");
        assertGe(
            IERC20(USDG).balanceOf(lending.getETokenAddress(1)), 100_000e6,
            "lender liquidity restored in eToken vault"
        );
    }
}
