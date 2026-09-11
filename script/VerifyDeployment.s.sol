// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DataTypes} from "../src/lending/libraries/types/DataTypes.sol";

interface IVerifyOwnable {
    function owner() external view returns (address);
}

interface IVerifyAddressRegistry is IVerifyOwnable {
    function getAddress(uint256 id) external view returns (address);
}

interface IVerifyVaultRegistry is IVerifyOwnable {
    function pendingOwner() external view returns (address);
    function vaults(uint256 id) external view returns (address);
}

interface IVerifyLending is IVerifyOwnable {
    function addressRegistry() external view returns (address);
    function nextReserveId() external view returns (uint256);
    function borrowingWhiteList(address vault) external view returns (bool);
    function credits(uint256 reserveId, address vault) external view returns (uint256);
    function reserves(uint256 id)
        external
        view
        returns (
            uint256 borrowingIndex,
            uint256 currentBorrowingRate,
            uint256 totalBorrows,
            address underlyingTokenAddress,
            address eTokenAddress,
            address stakingAddress,
            uint256 reserveCapacity,
            DataTypes.InterestRateConfig memory borrowingRateConfig,
            uint256 reserveId,
            uint128 lastUpdateTimestamp,
            uint16 reserveFeeRate,
            DataTypes.Flags memory flags
        );
}

interface IVerifyToken {
    function decimals() external view returns (uint8);
}

interface IVerifyFeed {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
}

interface IVerifyOracle {
    function FEED0() external view returns (address);
    function FEED1() external view returns (address);
    function LOAN_FEED() external view returns (address);
    function RISK_FEED() external view returns (address);
    function DEC0() external view returns (uint8);
    function DEC1() external view returns (uint8);
    function LOAN_DEC() external view returns (uint8);
    function RISK_DEC() external view returns (uint8);
    function RISK_MAX_STALENESS() external view returns (uint256);
    function STABLE_MAX_STALENESS() external view returns (uint256);
    function STABLE_DEPEG_BPS() external view returns (uint256);
}

interface IVerifySwapExecutor {
    function ROUTER() external view returns (address);
    function DEFAULT_FEE() external view returns (uint24);
}

interface IVerifyPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
}

interface IVerifyVaultCommon {
    function GOVERNOR() external view returns (address);
    function POSITION_MANAGER() external view returns (address);
    function LENDING_POOL() external view returns (address);
    function ORACLE() external view returns (address);
    function SWAP_EXECUTOR() external view returns (address);
    function TOKEN0() external view returns (address);
    function TOKEN1() external view returns (address);
    function LOAN() external view returns (address);
    function RISK() external view returns (address);
    function LOAN_IS_C0() external view returns (bool);
    function FEE() external view returns (uint24);
    function LLTV() external view returns (uint256);
}

interface IVerifyV3Vault {
    function POOL() external view returns (address);
}

interface IVerifyV4Vault {
    function STATE_VIEW() external view returns (address);
    function TICK_SPACING() external view returns (int24);
    function HOOKS() external view returns (address);
    function POOL_ID() external view returns (bytes32);
}

interface IVerifySingleVault {
    function RESERVE_ID() external view returns (uint256);
}

interface IVerifyDualVault {
    function RESERVE_RISK() external view returns (uint256);
    function RESERVE_LOAN() external view returns (uint256);
}

/// @notice Read-only post-deployment verification. It deliberately has no broadcast or mutation path.
contract VerifyDeployment is Script {
    uint256 internal constant EIP170_MAX_RUNTIME_SIZE = 24_576;
    uint256 internal constant ADDRESS_ID_WETH9 = 1;
    uint256 internal constant ADDRESS_ID_VAULT_FACTORY = 10;
    uint256 internal constant ADDRESS_ID_TREASURY = 11;

    error AddressMismatch(string item, address expected, address actual);
    error UintMismatch(string item, uint256 expected, uint256 actual);
    error IntMismatch(string item, int256 expected, int256 actual);
    error BoolMismatch(string item, bool expected, bool actual);
    error Bytes32Mismatch(string item, bytes32 expected, bytes32 actual);
    error StringMismatch(string item, string expected, string actual);
    error CodeMissing(string item, address target);
    error CodeTooLarge(string item, address target, uint256 actualSize);
    error OwnershipTransferPending(string item, address currentOwner, address pendingOwner);
    error UnexpectedGovernanceSurface(string item, bytes4 selector, address reportedAuthority);
    error NoVaultConfigured();

    enum DeployShape {
        Dual,
        Single
    }

    error InvalidDeployShape(string shape);
    error DualVaultInSingleDeployment();

    struct CoreConfig {
        address governor;
        address lendingPool;
        address oracle;
        address swapExecutor;
        address addressRegistry;
        address vaultRegistry;
        address pool;
        address router;
        address permit2;
        address token0;
        address token1;
        address riskToken;
        address loanToken;
        uint24 poolFee;
        int24 tickSpacing;
        uint256 lltv;
    }

    struct OracleConfig {
        address feed0;
        address feed1;
        address loanFeed;
        uint8 feed0Decimals;
        uint8 feed1Decimals;
        uint8 loanFeedDecimals;
        string feed0Description;
        string feed1Description;
        string loanFeedDescription;
        uint256 riskMaxStaleness;
        uint256 stableMaxStaleness;
        uint256 stableDepegBps;
    }

    struct ReserveConfig {
        uint256 id;
        address token;
        uint8 decimals;
        uint256 capacity;
    }

    struct VaultConfig {
        address v3Single;
        uint256 v3SingleId;
        address v4Single;
        uint256 v4SingleId;
        address v3Dual;
        uint256 v3DualId;
        address v4Dual;
        uint256 v4DualId;
    }

    struct Config {
        DeployShape shape;
        CoreConfig core;
        OracleConfig oracle;
        ReserveConfig riskReserve;
        ReserveConfig loanReserve;
        VaultConfig vaults;
    }

    /// @dev Environment-only entrypoint used by `forge script`; every operation below is a read.
    function run() external view {
        Config memory config;
        string memory shape = vm.envString("DEPLOY_SHAPE");
        if (keccak256(bytes(shape)) == keccak256("dual")) config.shape = DeployShape.Dual;
        else if (keccak256(bytes(shape)) == keccak256("single")) config.shape = DeployShape.Single;
        else revert InvalidDeployShape(shape);
        config.core = CoreConfig({
            governor: vm.envAddress("GOVERNOR"),
            lendingPool: vm.envAddress("LENDING_POOL"),
            oracle: vm.envAddress("ORACLE"),
            swapExecutor: vm.envAddress("SWAP_EXECUTOR"),
            addressRegistry: vm.envAddress("ADDRESS_REGISTRY"),
            vaultRegistry: vm.envAddress("VAULT_REGISTRY"),
            pool: vm.envAddress("POOL"),
            router: vm.envAddress("ROUTER"),
            permit2: address(0),
            token0: vm.envAddress("TOKEN0"),
            token1: vm.envAddress("TOKEN1"),
            riskToken: vm.envAddress("RISK_TOKEN"),
            loanToken: vm.envAddress("LOAN_TOKEN"),
            poolFee: uint24(vm.envUint("POOL_FEE")),
            tickSpacing: int24(uint24(vm.envUint("POOL_TICK_SPACING"))),
            lltv: vm.envUint("LLTV")
        });
        config.oracle = OracleConfig({
            feed0: vm.envAddress("FEED0"),
            feed1: vm.envAddress("FEED1"),
            loanFeed: vm.envAddress("LOAN_FEED"),
            feed0Decimals: uint8(vm.envUint("FEED0_DECIMALS")),
            feed1Decimals: uint8(vm.envUint("FEED1_DECIMALS")),
            loanFeedDecimals: uint8(vm.envUint("LOAN_FEED_DECIMALS")),
            feed0Description: vm.envString("FEED0_DESCRIPTION"),
            feed1Description: vm.envString("FEED1_DESCRIPTION"),
            loanFeedDescription: vm.envString("LOAN_FEED_DESCRIPTION"),
            riskMaxStaleness: vm.envUint("RISK_MAX_STALENESS_SECONDS"),
            stableMaxStaleness: vm.envUint("STABLE_MAX_STALENESS_SECONDS"),
            stableDepegBps: vm.envUint("STABLE_DEPEG_BPS")
        });
        if (config.shape == DeployShape.Dual) {
            config.riskReserve = ReserveConfig({
                id: vm.envUint("RISK_RESERVE_ID"),
                token: config.core.riskToken,
                decimals: uint8(vm.envUint("RISK_TOKEN_DECIMALS")),
                capacity: vm.envUint("RISK_RESERVE_CAPACITY")
            });
        }
        config.loanReserve = ReserveConfig({
            id: vm.envUint("LOAN_RESERVE_ID"),
            token: config.core.loanToken,
            decimals: uint8(vm.envUint("LOAN_TOKEN_DECIMALS")),
            capacity: vm.envUint("LOAN_RESERVE_CAPACITY")
        });
        config.vaults = VaultConfig({
            v3Single: vm.envOr("V3_VAULT", address(0)),
            v3SingleId: vm.envOr("V3_VAULT_ID", uint256(0)),
            v4Single: vm.envOr("V4_VAULT", address(0)),
            v4SingleId: vm.envOr("V4_VAULT_ID", uint256(0)),
            v3Dual: vm.envOr("V3_DUAL_VAULT", address(0)),
            v3DualId: vm.envOr("V3_DUAL_VAULT_ID", uint256(0)),
            v4Dual: vm.envOr("V4_DUAL_VAULT", address(0)),
            v4DualId: vm.envOr("V4_DUAL_VAULT_ID", uint256(0))
        });

        if (config.vaults.v4Single != address(0) || config.vaults.v4Dual != address(0)) {
            config.core.permit2 = vm.envAddress("PERMIT2");
        }

        verify(config);
        console2.log("Deployment verification: PASS");
    }

    function verify(Config memory config) public view {
        if (
            config.shape == DeployShape.Single
                && (config.vaults.v3Dual != address(0) || config.vaults.v4Dual != address(0))
        ) {
            revert DualVaultInSingleDeployment();
        }
        _verifyCoreCode(config);
        _verifyOwnershipAndRegistries(config);
        if (config.shape == DeployShape.Dual) _verifyReserve(config.core, config.riskReserve, "risk reserve");
        _verifyReserve(config.core, config.loanReserve, "loan reserve");
        uint256 lastReserveId = config.shape == DeployShape.Dual
            ? _max(config.riskReserve.id, config.loanReserve.id)
            : config.loanReserve.id;
        _uint("lending.nextReserveId", lastReserveId + 1, IVerifyLending(config.core.lendingPool).nextReserveId());
        _verifyOracle(config);
        _verifyPoolAndSwap(config.core);
        _verifyVaults(config);
    }

    function _verifyCoreCode(Config memory config) internal view {
        _code("LendingPool", config.core.lendingPool);
        _code("LpShareOracleV4", config.core.oracle);
        _code("SwapExecutorV3", config.core.swapExecutor);
        _code("AddressRegistry", config.core.addressRegistry);
        _code("VaultRegistry", config.core.vaultRegistry);
        _code("pool", config.core.pool);
        _code("router", config.core.router);
        if (config.vaults.v4Single != address(0) || config.vaults.v4Dual != address(0)) {
            _code("Permit2", config.core.permit2);
        }
        _code("token0", config.core.token0);
        _code("token1", config.core.token1);
        _code("feed0", config.oracle.feed0);
        _code("feed1", config.oracle.feed1);
        _code("loanFeed", config.oracle.loanFeed);
        if (config.core.token0 >= config.core.token1) revert BoolMismatch("token0 < token1", true, false);
        bool tokenPairMatches =
            (config.core.token0 == config.core.riskToken && config.core.token1 == config.core.loanToken)
                || (config.core.token0 == config.core.loanToken && config.core.token1 == config.core.riskToken);
        if (!tokenPairMatches) revert BoolMismatch("risk/loan token pair", true, false);
    }

    function _verifyOwnershipAndRegistries(Config memory config) internal view {
        CoreConfig memory core = config.core;
        IVerifyVaultRegistry vaultRegistry = IVerifyVaultRegistry(core.vaultRegistry);
        address pendingOwner = vaultRegistry.pendingOwner();
        console2.log("expected governor      ", core.governor);
        console2.log("VaultRegistry.owner    ", vaultRegistry.owner());
        console2.log("VaultRegistry.pending  ", pendingOwner);
        if (pendingOwner != address(0)) {
            revert OwnershipTransferPending("VaultRegistry", vaultRegistry.owner(), pendingOwner);
        }
        _address("VaultRegistry.owner", core.governor, vaultRegistry.owner());

        IVerifyLending lending = IVerifyLending(core.lendingPool);
        console2.log("LendingPool.owner      ", lending.owner());
        _address("LendingPool.owner", core.governor, lending.owner());
        _address("LendingPool.addressRegistry", core.addressRegistry, lending.addressRegistry());

        IVerifyAddressRegistry registry = IVerifyAddressRegistry(core.addressRegistry);
        console2.log("AddressRegistry.owner  ", registry.owner());
        _address("AddressRegistry.owner", core.governor, registry.owner());
        _address("AddressRegistry.WETH9", core.riskToken, registry.getAddress(ADDRESS_ID_WETH9));
        _address("AddressRegistry.VAULT_FACTORY", core.vaultRegistry, registry.getAddress(ADDRESS_ID_VAULT_FACTORY));
        _address("AddressRegistry.TREASURY", core.governor, registry.getAddress(ADDRESS_ID_TREASURY));

        _noGovernance("LpShareOracleV4", core.oracle);
        // SwapExecutorV3 deliberately keeps ONE immutable surface: owner() = the deployer,
        // able only to revokeRouterApproval (zero the router allowance). It cannot move funds,
        // change the router, or be transferred. Assert it matches the expected brake holder
        // (SWAP_EXECUTOR_OWNER, default = governor) and that no GOVERNOR() surface exists.
        _ownerOnlySurface(
            "SwapExecutorV3", core.swapExecutor, vm.envOr("SWAP_EXECUTOR_OWNER", core.governor)
        );
    }

    function _verifyReserve(CoreConfig memory core, ReserveConfig memory expected, string memory label) internal view {
        IVerifyLending lending = IVerifyLending(core.lendingPool);
        (
            ,,,
            address token,
            address eToken,
            address staking,
            uint256 capacity,,
            uint256 reserveId,,,
            DataTypes.Flags memory flags
        ) = lending.reserves(expected.id);

        console2.log(string.concat(label, ".id       "), reserveId);
        console2.log(string.concat(label, ".token    "), token);
        console2.log(string.concat(label, ".capacity "), capacity);
        _uint(string.concat(label, ".id"), expected.id, reserveId);
        _address(string.concat(label, ".underlying"), expected.token, token);
        _uint(string.concat(label, ".decimals"), expected.decimals, IVerifyToken(token).decimals());
        _uint(string.concat(label, ".capacity"), expected.capacity, capacity);
        _bool(string.concat(label, ".active"), true, flags.isActive);
        _bool(string.concat(label, ".frozen"), false, flags.frozen);
        _bool(string.concat(label, ".borrowingEnabled"), true, flags.borrowingEnabled);
        _code(string.concat(label, ".eToken"), eToken);
        _code(string.concat(label, ".staking"), staking);
        _address(string.concat(label, ".staking.owner"), core.governor, IVerifyOwnable(staking).owner());
    }

    function _verifyOracle(Config memory config) internal view {
        CoreConfig memory core = config.core;
        OracleConfig memory expected = config.oracle;
        IVerifyOracle oracle = IVerifyOracle(core.oracle);

        _address("oracle.FEED0", expected.feed0, oracle.FEED0());
        _address("oracle.FEED1", expected.feed1, oracle.FEED1());
        _address("oracle.LOAN_FEED", expected.loanFeed, oracle.LOAN_FEED());
        _uint("oracle.DEC0", IVerifyToken(core.token0).decimals(), oracle.DEC0());
        _uint("oracle.DEC1", IVerifyToken(core.token1).decimals(), oracle.DEC1());
        _uint("oracle.LOAN_DEC", IVerifyToken(core.loanToken).decimals(), oracle.LOAN_DEC());
        address expectedRiskFeed = expected.loanFeed == expected.feed0 ? expected.feed1 : expected.feed0;
        address expectedRiskToken = expected.loanFeed == expected.feed0 ? core.token1 : core.token0;
        _address("oracle.RISK_FEED", expectedRiskFeed, oracle.RISK_FEED());
        _uint("oracle.RISK_DEC", IVerifyToken(expectedRiskToken).decimals(), oracle.RISK_DEC());
        _uint("oracle.RISK_MAX_STALENESS", expected.riskMaxStaleness, oracle.RISK_MAX_STALENESS());
        _uint("oracle.STABLE_MAX_STALENESS", expected.stableMaxStaleness, oracle.STABLE_MAX_STALENESS());
        _uint("oracle.STABLE_DEPEG_BPS", expected.stableDepegBps, oracle.STABLE_DEPEG_BPS());

        _verifyFeed("feed0", expected.feed0, expected.feed0Decimals, expected.feed0Description);
        _verifyFeed("feed1", expected.feed1, expected.feed1Decimals, expected.feed1Description);
        _verifyFeed("loanFeed", expected.loanFeed, expected.loanFeedDecimals, expected.loanFeedDescription);
    }

    function _verifyFeed(string memory label, address feed, uint8 decimals_, string memory description_) internal view {
        IVerifyFeed aggregator = IVerifyFeed(feed);
        console2.log(string.concat(label, ".description"), aggregator.description());
        _uint(string.concat(label, ".decimals"), decimals_, aggregator.decimals());
        _string(string.concat(label, ".description"), description_, aggregator.description());
    }

    function _verifyPoolAndSwap(CoreConfig memory core) internal view {
        IVerifyPool pool = IVerifyPool(core.pool);
        _address("pool.token0", core.token0, pool.token0());
        _address("pool.token1", core.token1, pool.token1());
        _uint("pool.fee", core.poolFee, pool.fee());
        _int("pool.tickSpacing", core.tickSpacing, pool.tickSpacing());

        IVerifySwapExecutor swapExecutor = IVerifySwapExecutor(core.swapExecutor);
        _address("swapExecutor.ROUTER", core.router, swapExecutor.ROUTER());
        _uint("swapExecutor.DEFAULT_FEE", core.poolFee, swapExecutor.DEFAULT_FEE());
    }

    function _verifyVaults(Config memory config) internal view {
        VaultConfig memory vaults = config.vaults;
        if (
            vaults.v3Single == address(0) && vaults.v4Single == address(0) && vaults.v3Dual == address(0)
                && vaults.v4Dual == address(0)
        ) revert NoVaultConfigured();

        if (vaults.v3Single != address(0)) {
            _verifyVaultCommon(config, "UniV3LeverageVault", vaults.v3Single, vaults.v3SingleId);
            _verifyV3(config.core, "UniV3LeverageVault", vaults.v3Single);
            _verifySingle(config, "UniV3LeverageVault", vaults.v3Single);
        }
        if (vaults.v4Single != address(0)) {
            _verifyVaultCommon(config, "UniV4LeverageVault", vaults.v4Single, vaults.v4SingleId);
            _verifyV4(config.core, "UniV4LeverageVault", vaults.v4Single);
            _verifySingle(config, "UniV4LeverageVault", vaults.v4Single);
        }
        if (vaults.v3Dual != address(0)) {
            _verifyVaultCommon(config, "UniV3DualVault", vaults.v3Dual, vaults.v3DualId);
            _verifyV3(config.core, "UniV3DualVault", vaults.v3Dual);
            _verifyDual(config, "UniV3DualVault", vaults.v3Dual);
        }
        if (vaults.v4Dual != address(0)) {
            _verifyVaultCommon(config, "UniV4DualVault", vaults.v4Dual, vaults.v4DualId);
            _verifyV4(config.core, "UniV4DualVault", vaults.v4Dual);
            _verifyDual(config, "UniV4DualVault", vaults.v4Dual);
        }
    }

    function _verifyVaultCommon(Config memory config, string memory label, address vault, uint256 vaultId)
        internal
        view
    {
        CoreConfig memory core = config.core;
        IVerifyVaultCommon target = IVerifyVaultCommon(vault);
        _code(label, vault);
        console2.log(string.concat(label, ".GOVERNOR"), target.GOVERNOR());
        _address(string.concat(label, ".GOVERNOR"), core.governor, target.GOVERNOR());
        _address(string.concat(label, ".LENDING_POOL"), core.lendingPool, target.LENDING_POOL());
        _address(string.concat(label, ".ORACLE"), core.oracle, target.ORACLE());
        _address(string.concat(label, ".SWAP_EXECUTOR"), core.swapExecutor, target.SWAP_EXECUTOR());
        _address(string.concat(label, ".TOKEN0"), core.token0, target.TOKEN0());
        _address(string.concat(label, ".TOKEN1"), core.token1, target.TOKEN1());
        _address(string.concat(label, ".LOAN"), core.loanToken, target.LOAN());
        _address(string.concat(label, ".RISK"), core.riskToken, target.RISK());
        _bool(string.concat(label, ".LOAN_IS_C0"), core.loanToken == core.token0, target.LOAN_IS_C0());
        _uint(string.concat(label, ".FEE"), core.poolFee, target.FEE());
        _uint(string.concat(label, ".LLTV"), core.lltv, target.LLTV());
        _code(string.concat(label, ".POSITION_MANAGER"), target.POSITION_MANAGER());

        IVerifyVaultRegistry vaultRegistry = IVerifyVaultRegistry(core.vaultRegistry);
        IVerifyLending lending = IVerifyLending(core.lendingPool);
        _address(string.concat(label, ".registry entry"), vault, vaultRegistry.vaults(vaultId));
        _bool(string.concat(label, ".borrowing whitelist"), true, lending.borrowingWhiteList(vault));
    }

    function _verifyV3(CoreConfig memory core, string memory label, address vault) internal view {
        _address(string.concat(label, ".POOL"), core.pool, IVerifyV3Vault(vault).POOL());
    }

    function _verifyV4(CoreConfig memory core, string memory label, address vault) internal view {
        IVerifyV4Vault target = IVerifyV4Vault(vault);
        _int(string.concat(label, ".TICK_SPACING"), core.tickSpacing, target.TICK_SPACING());
        address hooks = target.HOOKS();
        bytes32 expectedPoolId = keccak256(abi.encode(core.token0, core.token1, core.poolFee, core.tickSpacing, hooks));
        _bytes32(string.concat(label, ".POOL_ID"), expectedPoolId, target.POOL_ID());
        _code(string.concat(label, ".STATE_VIEW"), target.STATE_VIEW());
        if (hooks != address(0)) _code(string.concat(label, ".HOOKS"), hooks);
    }

    function _verifySingle(Config memory config, string memory label, address vault) internal view {
        uint256 reserveId = IVerifySingleVault(vault).RESERVE_ID();
        _uint(string.concat(label, ".RESERVE_ID"), config.loanReserve.id, reserveId);
        _positiveCredit(config.core.lendingPool, label, reserveId, vault);
    }

    function _verifyDual(Config memory config, string memory label, address vault) internal view {
        IVerifyDualVault target = IVerifyDualVault(vault);
        _uint(string.concat(label, ".RESERVE_RISK"), config.riskReserve.id, target.RESERVE_RISK());
        _uint(string.concat(label, ".RESERVE_LOAN"), config.loanReserve.id, target.RESERVE_LOAN());
        _positiveCredit(config.core.lendingPool, label, config.riskReserve.id, vault);
        _positiveCredit(config.core.lendingPool, label, config.loanReserve.id, vault);
    }

    function _positiveCredit(address lendingPool, string memory label, uint256 reserveId, address vault) internal view {
        uint256 credit = IVerifyLending(lendingPool).credits(reserveId, vault);
        console2.log(string.concat(label, ".credit reserve"), reserveId, credit);
        if (credit == 0) revert UintMismatch(string.concat(label, ".credit"), 1, 0);
    }

    function _noGovernance(string memory item, address target) internal view {
        bytes4[2] memory selectors = [bytes4(keccak256("owner()")), bytes4(keccak256("GOVERNOR()"))];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok, bytes memory result) = target.staticcall(abi.encodeWithSelector(selectors[i]));
            if (ok && result.length >= 32) {
                revert UnexpectedGovernanceSurface(item, selectors[i], abi.decode(result, (address)));
            }
        }
    }

    /// owner() must respond AND equal the expected brake holder; GOVERNOR() must not exist.
    function _ownerOnlySurface(string memory item, address target, address expectedOwner) internal view {
        (bool ok, bytes memory result) = target.staticcall(abi.encodeWithSelector(bytes4(keccak256("owner()"))));
        if (!ok || result.length < 32) {
            revert UnexpectedGovernanceSurface(item, bytes4(keccak256("owner()")), address(0));
        }
        address actual = abi.decode(result, (address));
        console2.log(string.concat(item, ".owner (revoke brake)"), actual);
        _address(string.concat(item, ".owner"), expectedOwner, actual);
        (bool govOk, bytes memory govResult) =
            target.staticcall(abi.encodeWithSelector(bytes4(keccak256("GOVERNOR()"))));
        if (govOk && govResult.length >= 32) {
            revert UnexpectedGovernanceSurface(item, bytes4(keccak256("GOVERNOR()")), abi.decode(govResult, (address)));
        }
    }

    function _code(string memory item, address target) internal view {
        uint256 size = target.code.length;
        if (size == 0) revert CodeMissing(item, target);
        if (size > EIP170_MAX_RUNTIME_SIZE) revert CodeTooLarge(item, target, size);
        console2.log(string.concat(item, ".runtime bytes"), size);
    }

    function _address(string memory item, address expected, address actual) internal pure {
        if (actual != expected) revert AddressMismatch(item, expected, actual);
    }

    function _uint(string memory item, uint256 expected, uint256 actual) internal pure {
        if (actual != expected) revert UintMismatch(item, expected, actual);
    }

    function _int(string memory item, int256 expected, int256 actual) internal pure {
        if (actual != expected) revert IntMismatch(item, expected, actual);
    }

    function _bool(string memory item, bool expected, bool actual) internal pure {
        if (actual != expected) revert BoolMismatch(item, expected, actual);
    }

    function _bytes32(string memory item, bytes32 expected, bytes32 actual) internal pure {
        if (actual != expected) revert Bytes32Mismatch(item, expected, actual);
    }

    function _string(string memory item, string memory expected, string memory actual) internal pure {
        if (keccak256(bytes(actual)) != keccak256(bytes(expected))) revert StringMismatch(item, expected, actual);
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
