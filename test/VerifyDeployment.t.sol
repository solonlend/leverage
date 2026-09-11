// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {MockFeedOwned} from "../script/testnet/TestnetMocks.sol";

import {Test} from "forge-std/Test.sol";
import {DataTypes} from "../src/lending/libraries/types/DataTypes.sol";
import {VerifyDeployment} from "../script/VerifyDeployment.s.sol";

contract VerifyFeedHarness is VerifyDeployment {
    function verifyTestnetFeed(address feed) external view {
        _verifyFeed("testnet feed", feed, 8, "Solon testnet mock / USD");
    }
}

contract VerifyCode {}

contract VerifyOwned {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

contract VerifyToken {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

contract VerifyFeed {
    uint8 public immutable decimals;
    string public description;

    constructor(uint8 decimals_, string memory description_) {
        decimals = decimals_;
        description = description_;
    }
}

contract VerifyPoolMock {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;

    constructor(address token0_, address token1_, uint24 fee_, int24 tickSpacing_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
    }

    function setFee(uint24 fee_) external {
        fee = fee_;
    }
}

contract VerifyOracleMock {
    address public FEED0;
    address public FEED1;
    address public LOAN_FEED;
    address public RISK_FEED;
    uint8 public DEC0;
    uint8 public DEC1;
    uint8 public LOAN_DEC;
    uint8 public RISK_DEC;
    uint256 public RISK_MAX_STALENESS;
    uint256 public STABLE_MAX_STALENESS;
    uint256 public STABLE_DEPEG_BPS;

    constructor(
        address feed0,
        address feed1,
        address loanFeed,
        uint8 dec0,
        uint8 dec1,
        uint8 loanDec,
        uint256 riskMaxStaleness,
        uint256 stableMaxStaleness,
        uint256 stableDepegBps
    ) {
        FEED0 = feed0;
        FEED1 = feed1;
        LOAN_FEED = loanFeed;
        RISK_FEED = loanFeed == feed0 ? feed1 : feed0;
        DEC0 = dec0;
        DEC1 = dec1;
        LOAN_DEC = loanDec;
        RISK_DEC = loanFeed == feed0 ? dec1 : dec0;
        RISK_MAX_STALENESS = riskMaxStaleness;
        STABLE_MAX_STALENESS = stableMaxStaleness;
        STABLE_DEPEG_BPS = stableDepegBps;
    }
}

contract VerifySwapMock {
    // Mirrors the real SwapExecutorV3 surface: an immutable owner() revoke brake.
    address public immutable owner;
    address public immutable ROUTER;
    uint24 public immutable DEFAULT_FEE;

    constructor(address router, uint24 fee) {
        owner = msg.sender;
        ROUTER = router;
        DEFAULT_FEE = fee;
    }
}

contract VerifyAddressRegistryMock {
    address public owner;
    mapping(uint256 => address) internal addresses;

    constructor(address owner_) {
        owner = owner_;
    }

    function setAddress(uint256 id, address value) external {
        addresses[id] = value;
    }

    function getAddress(uint256 id) external view returns (address) {
        return addresses[id];
    }
}

contract VerifyVaultRegistryMock {
    address public owner;
    address public pendingOwner;
    mapping(uint256 => address) public vaults;

    constructor(address owner_) {
        owner = owner_;
    }

    function setVault(uint256 id, address vault) external {
        vaults[id] = vault;
    }

    function setPendingOwner(address pending) external {
        pendingOwner = pending;
    }
}

contract VerifyLendingMock {
    address public owner;
    address public addressRegistry;
    uint256 public nextReserveId = 3;
    mapping(uint256 => DataTypes.ReserveData) internal reserveData;
    mapping(address => bool) public borrowingWhiteList;
    mapping(uint256 => mapping(address => uint256)) public credits;

    constructor(address owner_, address registry_) {
        owner = owner_;
        addressRegistry = registry_;
    }

    function setReserve(uint256 id, address token, address eToken, address staking, uint256 capacity) external {
        DataTypes.ReserveData storage reserve = reserveData[id];
        reserve.underlyingTokenAddress = token;
        reserve.eTokenAddress = eToken;
        reserve.stakingAddress = staking;
        reserve.reserveCapacity = capacity;
        reserve.id = id;
        reserve.flags = DataTypes.Flags({isActive: true, frozen: false, borrowingEnabled: true});
    }

    function removeReserve(uint256 id) external { delete reserveData[id]; }

    function setNextReserveId(uint256 id) external { nextReserveId = id; }

    function authorize(address vault, uint256 riskReserveId, uint256 loanReserveId) external {
        borrowingWhiteList[vault] = true;
        credits[riskReserveId][vault] = 10;
        credits[loanReserveId][vault] = 20;
    }

    function getUnderlyingTokenAddress(uint256 id) external view returns (address) {
        return reserveData[id].underlyingTokenAddress;
    }

    function getETokenAddress(uint256 id) external view returns (address) {
        return reserveData[id].eTokenAddress;
    }

    function getStakingAddress(uint256 id) external view returns (address) {
        return reserveData[id].stakingAddress;
    }

    function reserves(uint256 id)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            address,
            address,
            address,
            uint256,
            DataTypes.InterestRateConfig memory,
            uint256,
            uint128,
            uint16,
            DataTypes.Flags memory
        )
    {
        DataTypes.ReserveData storage reserve = reserveData[id];
        return (
            reserve.borrowingIndex,
            reserve.currentBorrowingRate,
            reserve.totalBorrows,
            reserve.underlyingTokenAddress,
            reserve.eTokenAddress,
            reserve.stakingAddress,
            reserve.reserveCapacity,
            reserve.borrowingRateConfig,
            reserve.id,
            reserve.lastUpdateTimestamp,
            reserve.reserveFeeRate,
            reserve.flags
        );
    }
}

contract VerifyVaultMock {
    address public GOVERNOR;
    address public POSITION_MANAGER;
    address public STATE_VIEW;
    address public POOL;
    address public LENDING_POOL;
    address public ORACLE;
    address public SWAP_EXECUTOR;
    address public TOKEN0;
    address public TOKEN1;
    address public LOAN;
    address public RISK;
    bool public LOAN_IS_C0;
    uint24 public FEE;
    int24 public TICK_SPACING;
    address public HOOKS;
    bytes32 public POOL_ID;
    uint256 public RESERVE_ID;
    uint256 public RESERVE_RISK;
    uint256 public RESERVE_LOAN;
    uint256 public LLTV;

    constructor(
        address governor,
        address positionManager,
        address stateView,
        address pool,
        address lending,
        address oracle,
        address swapExecutor,
        address token0,
        address token1,
        bool loanIsC0,
        uint24 fee,
        int24 tickSpacing,
        uint256 reserveRisk,
        uint256 reserveLoan,
        uint256 lltv
    ) {
        GOVERNOR = governor;
        POSITION_MANAGER = positionManager;
        STATE_VIEW = stateView;
        POOL = pool;
        LENDING_POOL = lending;
        ORACLE = oracle;
        SWAP_EXECUTOR = swapExecutor;
        TOKEN0 = token0;
        TOKEN1 = token1;
        LOAN_IS_C0 = loanIsC0;
        LOAN = loanIsC0 ? token0 : token1;
        RISK = loanIsC0 ? token1 : token0;
        FEE = fee;
        TICK_SPACING = tickSpacing;
        RESERVE_ID = reserveLoan;
        RESERVE_RISK = reserveRisk;
        RESERVE_LOAN = reserveLoan;
        LLTV = lltv;
        POOL_ID = keccak256(abi.encode(token0, token1, fee, tickSpacing, address(0)));
    }
}

contract VerifyDeploymentTest is Test {
    uint256 internal constant RISK_RESERVE_ID = 2;
    uint256 internal constant LOAN_RESERVE_ID = 1;
    uint256 internal constant LLTV = 0.77e18;

    VerifyDeployment internal verifier;
    VerifyPoolMock internal pool;
    VerifyOracleMock internal oracle;
    VerifySwapMock internal swapExecutor;
    VerifyAddressRegistryMock internal addressRegistry;
    VerifyVaultRegistryMock internal vaultRegistry;
    VerifyLendingMock internal lending;
    VerifyToken internal token0;
    VerifyToken internal token1;
    VerifyToken internal riskToken;
    VerifyToken internal loanToken;
    VerifyFeed internal feed0;
    VerifyFeed internal feed1;
    VerifyFeed internal loanFeed;
    VerifyCode internal router;
    VerifyCode internal permit2;
    VerifyCode internal positionManager;
    VerifyCode internal stateView;
    VerifyVaultMock[4] internal vaults;

    function setUp() public {
        verifier = new VerifyDeployment();

        VerifyToken tokenA = new VerifyToken(18);
        VerifyToken tokenB = new VerifyToken(6);
        riskToken = tokenA;
        loanToken = tokenB;
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        VerifyFeed riskFeed = new VerifyFeed(8, "ETH / USD");
        VerifyFeed stableFeed = new VerifyFeed(8, "USDG / USD");
        (feed0, feed1) = address(token0) == address(riskToken) ? (riskFeed, stableFeed) : (stableFeed, riskFeed);
        loanFeed = stableFeed;

        router = new VerifyCode();
        permit2 = new VerifyCode();
        positionManager = new VerifyCode();
        stateView = new VerifyCode();
        pool = new VerifyPoolMock(address(token0), address(token1), 100, 1);
        oracle = new VerifyOracleMock(
            address(feed0),
            address(feed1),
            address(loanFeed),
            token0.decimals(),
            token1.decimals(),
            loanToken.decimals(),
            3 hours,
            26 hours,
            100
        );
        swapExecutor = new VerifySwapMock(address(router), 100);
        addressRegistry = new VerifyAddressRegistryMock(address(this));
        vaultRegistry = new VerifyVaultRegistryMock(address(this));
        lending = new VerifyLendingMock(address(this), address(addressRegistry));

        addressRegistry.setAddress(1, address(riskToken));
        addressRegistry.setAddress(10, address(vaultRegistry));
        addressRegistry.setAddress(11, address(this));

        lending.setReserve(
            RISK_RESERVE_ID,
            address(riskToken),
            address(new VerifyCode()),
            address(new VerifyOwned(address(this))),
            500e18
        );
        lending.setReserve(
            LOAN_RESERVE_ID,
            address(loanToken),
            address(new VerifyCode()),
            address(new VerifyOwned(address(this))),
            1_000_000e6
        );

        for (uint256 i; i < 4; ++i) {
            vaults[i] = new VerifyVaultMock(
                address(this),
                address(positionManager),
                address(stateView),
                address(pool),
                address(lending),
                address(oracle),
                address(swapExecutor),
                address(token0),
                address(token1),
                address(loanToken) == address(token0),
                100,
                1,
                RISK_RESERVE_ID,
                LOAN_RESERVE_ID,
                LLTV
            );
            vaultRegistry.setVault(i + 1, address(vaults[i]));
            lending.authorize(address(vaults[i]), RISK_RESERVE_ID, LOAN_RESERVE_ID);
        }
    }

    function test_verify_acceptsCompleteFourVaultDeployment() public view {
        verifier.verify(_config());
    }

    function test_verify_namesPoolFeeMismatch() public {
        pool.setFee(500);
        VerifyDeployment.Config memory config = _config();
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.UintMismatch.selector, "pool.fee", 100, 500));
        verifier.verify(config);
    }

    function test_verify_reportsPendingVaultRegistryOwnership() public {
        address pending = address(0xBEEF);
        vaultRegistry.setPendingOwner(pending);
        VerifyDeployment.Config memory config = _config();
        vm.expectRevert(
            abi.encodeWithSelector(
                VerifyDeployment.OwnershipTransferPending.selector, "VaultRegistry", address(this), pending
            )
        );
        verifier.verify(config);
    }

    function test_run_acceptsStandaloneV3WithoutRiskReserveOrPermit2() public {
        lending.removeReserve(RISK_RESERVE_ID);
        lending.setNextReserveId(2);
        _setRunEnv();
        vm.setEnv("DEPLOY_SHAPE", "single");
        vm.setEnv("RISK_RESERVE_ID", "");
        vm.setEnv("RISK_TOKEN_DECIMALS", "");
        vm.setEnv("RISK_RESERVE_CAPACITY", "");
        vm.setEnv("PERMIT2", "");
        verifier.run();
    }

    function test_verify_acceptsSepoliaMockFeedDescription() public {
        MockFeedOwned feed = new MockFeedOwned(1e8);
        new VerifyFeedHarness().verifyTestnetFeed(address(feed));
    }

    function test_run_acceptsDualDeployment() public {
        _setRunEnv();
        vm.setEnv("V3_DUAL_VAULT", vm.toString(address(vaults[2])));
        vm.setEnv("V3_DUAL_VAULT_ID", "3");
        verifier.run();
    }

    function test_run_rejectsInvalidShape() public {
        _setRunEnv();
        vm.setEnv("DEPLOY_SHAPE", "typo");
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.InvalidDeployShape.selector, "typo"));
        verifier.run();
    }

    function test_run_rejectsEmptyShape() public {
        _setRunEnv();
        vm.setEnv("DEPLOY_SHAPE", "");
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.InvalidDeployShape.selector, ""));
        verifier.run();
    }

    function test_run_dualRequiresRiskReserveEnvironment() public {
        _setRunEnv();
        vm.setEnv("RISK_RESERVE_ID", "");
        vm.expectRevert();
        verifier.run();
    }

    function test_verify_dualRejectsMissingRiskReserve() public {
        lending.removeReserve(RISK_RESERVE_ID);
        VerifyDeployment.Config memory config = _config();
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.UintMismatch.selector, "risk reserve.id", 2, 0));
        verifier.verify(config);
    }

    function test_verify_singleRejectsDualVault() public {
        VerifyDeployment.Config memory config = _config();
        config.shape = VerifyDeployment.DeployShape.Single;
        vm.expectRevert(VerifyDeployment.DualVaultInSingleDeployment.selector);
        verifier.verify(config);
    }

    function test_verify_singleRejectsExtraReserve() public {
        VerifyDeployment.Config memory config = _singleConfig();
        lending.setNextReserveId(3);
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.UintMismatch.selector, "lending.nextReserveId", 2, 3));
        verifier.verify(config);
    }

    function test_verify_singleRejectsMissingLoanReserve() public {
        VerifyDeployment.Config memory config = _singleConfig();
        lending.removeReserve(LOAN_RESERVE_ID);
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.UintMismatch.selector, "loan reserve.id", 1, 0));
        verifier.verify(config);
    }

    function test_verify_singleRejectsWrongLltv() public {
        VerifyDeployment.Config memory config = _singleConfig();
        config.core.lltv = 0.8e18;
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.UintMismatch.selector, "UniV3LeverageVault.LLTV", 0.8e18, LLTV));
        verifier.verify(config);
    }

    function test_verify_acceptsStandaloneV4() public {
        VerifyDeployment.Config memory config = _singleConfig();
        config.vaults.v3Single = address(0);
        config.vaults.v4Single = address(vaults[1]);
        config.vaults.v4SingleId = 2;
        verifier.verify(config);
    }

    function test_verify_v4RequiresPermit2() public {
        VerifyDeployment.Config memory config = _singleConfig();
        config.vaults.v4Single = address(vaults[1]);
        config.core.permit2 = address(0);
        vm.expectRevert(abi.encodeWithSelector(VerifyDeployment.CodeMissing.selector, "Permit2", address(0)));
        verifier.verify(config);
    }

    function _singleConfig() internal returns (VerifyDeployment.Config memory config) {
        config = _config();
        config.shape = VerifyDeployment.DeployShape.Single;
        config.vaults.v4Single = address(0);
        config.vaults.v3Dual = address(0);
        config.vaults.v4Dual = address(0);
        delete config.riskReserve;
        lending.removeReserve(RISK_RESERVE_ID);
        lending.setNextReserveId(2);
    }

    function _setRunEnv() internal {
        vm.setEnv("GOVERNOR", vm.toString(address(this)));
        vm.setEnv("LENDING_POOL", vm.toString(address(lending)));
        vm.setEnv("ORACLE", vm.toString(address(oracle)));
        vm.setEnv("SWAP_EXECUTOR", vm.toString(address(swapExecutor)));
        vm.setEnv("ADDRESS_REGISTRY", vm.toString(address(addressRegistry)));
        vm.setEnv("VAULT_REGISTRY", vm.toString(address(vaultRegistry)));
        vm.setEnv("POOL", vm.toString(address(pool)));
        vm.setEnv("ROUTER", vm.toString(address(router)));
        vm.setEnv("PERMIT2", vm.toString(address(permit2)));
        vm.setEnv("TOKEN0", vm.toString(address(token0)));
        vm.setEnv("TOKEN1", vm.toString(address(token1)));
        vm.setEnv("RISK_TOKEN", vm.toString(address(riskToken)));
        vm.setEnv("LOAN_TOKEN", vm.toString(address(loanToken)));
        vm.setEnv("FEED0", vm.toString(address(feed0)));
        vm.setEnv("FEED1", vm.toString(address(feed1)));
        vm.setEnv("LOAN_FEED", vm.toString(address(loanFeed)));
        vm.setEnv("V3_VAULT", vm.toString(address(vaults[0])));
        vm.setEnv("V4_VAULT", vm.toString(address(0)));
        vm.setEnv("V3_DUAL_VAULT", vm.toString(address(0)));
        vm.setEnv("V4_DUAL_VAULT", vm.toString(address(0)));
        vm.setEnv("POOL_FEE", vm.toString(uint256(100)));
        vm.setEnv("POOL_TICK_SPACING", vm.toString(uint256(1)));
        vm.setEnv("LLTV", vm.toString(uint256(LLTV)));
        vm.setEnv("FEED0_DECIMALS", vm.toString(uint256(8)));
        vm.setEnv("FEED1_DECIMALS", vm.toString(uint256(8)));
        vm.setEnv("LOAN_FEED_DECIMALS", vm.toString(uint256(8)));
        vm.setEnv("RISK_MAX_STALENESS_SECONDS", vm.toString(uint256(3 hours)));
        vm.setEnv("STABLE_MAX_STALENESS_SECONDS", vm.toString(uint256(26 hours)));
        vm.setEnv("STABLE_DEPEG_BPS", vm.toString(uint256(100)));
        vm.setEnv("RISK_RESERVE_ID", vm.toString(uint256(RISK_RESERVE_ID)));
        vm.setEnv("RISK_TOKEN_DECIMALS", vm.toString(uint256(18)));
        vm.setEnv("RISK_RESERVE_CAPACITY", vm.toString(uint256(500e18)));
        vm.setEnv("LOAN_RESERVE_ID", vm.toString(uint256(LOAN_RESERVE_ID)));
        vm.setEnv("LOAN_TOKEN_DECIMALS", vm.toString(uint256(6)));
        vm.setEnv("LOAN_RESERVE_CAPACITY", vm.toString(uint256(1_000_000e6)));
        vm.setEnv("V3_VAULT_ID", vm.toString(uint256(1)));
        vm.setEnv("V4_VAULT_ID", vm.toString(uint256(0)));
        vm.setEnv("V3_DUAL_VAULT_ID", vm.toString(uint256(0)));
        vm.setEnv("V4_DUAL_VAULT_ID", vm.toString(uint256(0)));
        vm.setEnv("FEED0_DESCRIPTION", feed0.description());
        vm.setEnv("FEED1_DESCRIPTION", feed1.description());
        vm.setEnv("LOAN_FEED_DESCRIPTION", loanFeed.description());
        vm.setEnv("DEPLOY_SHAPE", "dual");
    }

    function _config() internal view returns (VerifyDeployment.Config memory config) {
        config.core = VerifyDeployment.CoreConfig({
            governor: address(this),
            lendingPool: address(lending),
            oracle: address(oracle),
            swapExecutor: address(swapExecutor),
            addressRegistry: address(addressRegistry),
            vaultRegistry: address(vaultRegistry),
            pool: address(pool),
            router: address(router),
            permit2: address(permit2),
            token0: address(token0),
            token1: address(token1),
            riskToken: address(riskToken),
            loanToken: address(loanToken),
            poolFee: 100,
            tickSpacing: 1,
            lltv: LLTV
        });
        config.oracle = VerifyDeployment.OracleConfig({
            feed0: address(feed0),
            feed1: address(feed1),
            loanFeed: address(loanFeed),
            feed0Decimals: 8,
            feed1Decimals: 8,
            loanFeedDecimals: 8,
            feed0Description: feed0.description(),
            feed1Description: feed1.description(),
            loanFeedDescription: loanFeed.description(),
            riskMaxStaleness: 3 hours,
            stableMaxStaleness: 26 hours,
            stableDepegBps: 100
        });
        config.riskReserve = VerifyDeployment.ReserveConfig({
            id: RISK_RESERVE_ID, token: address(riskToken), decimals: riskToken.decimals(), capacity: 500e18
        });
        config.loanReserve = VerifyDeployment.ReserveConfig({
            id: LOAN_RESERVE_ID, token: address(loanToken), decimals: loanToken.decimals(), capacity: 1_000_000e6
        });
        config.vaults = VerifyDeployment.VaultConfig({
            v3Single: address(vaults[0]),
            v3SingleId: 1,
            v4Single: address(vaults[1]),
            v4SingleId: 2,
            v3Dual: address(vaults[2]),
            v3DualId: 3,
            v4Dual: address(vaults[3]),
            v4DualId: 4
        });
    }
}
