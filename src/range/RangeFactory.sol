// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// Fork of Beefy's StrategyFactory + BeefyVaultConcLiqFactory (beefyfinance/beefy-zk, MIT), merged
// and de-beacon'd: one factory that (1) deploys a full IMMUTABLE vault+strategy pair per pool in a
// single tx — no proxies, no upgrade path — and (2) serves as the central ops registry the
// strategies read live: keeper, treasury, fee numbers, rebalancer whitelist and the global pause.

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SolonRangeVault} from "./SolonRangeVault.sol";
import {RangeStrategyUniV3} from "./RangeStrategyUniV3.sol";

interface IRangeVaultDeployer {
    function deploy(string calldata _name, string calldata _symbol) external returns (address vault);
}
interface IRangeStrategyDeployer {
    function deploy(address _pool, int24 _positionWidth, address _vault, address _factory) external returns (address strategy);
}

contract RangeFactory is Ownable {
    /// @notice The address of the keeper (ops account; can also globally pause)
    address public keeper;

    /// @notice The treasury that receives the non-caller share of performance fees
    address public treasury;

    /// @notice Global pause state for all strategies deployed by this factory
    bool public globalPause;

    /// @notice approved rebalancer mapping (moveTicks callers)
    mapping (address => bool) public rebalancers;

    /// @notice Total performance fee on earnings, fraction of 1e18. Init 10%.
    uint256 public totalFee = 0.1e18;

    /// @notice Caller tip as a fraction of the total fee (0.05e18 = 5% of the fee = 0.5% of gross earnings).
    uint256 public callFee = 0.05e18;

    /// @notice Hard caps on fee setters.
    uint256 public constant MAX_TOTAL_FEE = 0.15e18;
    uint256 public constant MAX_CALL_FEE = 0.2e18;

    struct Deployment {
        address vault;
        address strategy;
        address pool;
    }

    /// @notice All vault/strategy pairs deployed by this factory.
    Deployment[] public deployments;

    // Events
    event RangeVaultCreated(uint256 indexed index, address vault, address strategy, address pool);
    event SetKeeper(address keeper);
    event SetTreasury(address treasury);
    event GlobalPause(bool paused);
    event RebalancerChanged(address rebalancer, bool isRebalancer);
    event SetFees(uint256 totalFee, uint256 callFee);

    // Errors
    error NotManager();
    error OverLimit();
    error ZeroAddress();

    /// @notice Throws if called by any account other than the owner or the keeper
    modifier onlyManager() {
        if (msg.sender != owner() && msg.sender != keeper) revert NotManager();
        _;
    }

    /// @notice Creation-bytecode holders (split out to keep every artifact under EIP-170's 24KB;
    /// caught live on Sepolia 2026-09-09 — the monolithic factory was 34.6KB).
    IRangeVaultDeployer public immutable vaultDeployer;
    IRangeStrategyDeployer public immutable strategyDeployer;

    constructor(address _keeper, address _treasury, address _vaultDeployer, address _strategyDeployer) {
        if (_treasury == address(0) || _vaultDeployer == address(0) || _strategyDeployer == address(0)) revert ZeroAddress();
        keeper = _keeper;
        treasury = _treasury;
        vaultDeployer = IRangeVaultDeployer(_vaultDeployer);
        strategyDeployer = IRangeStrategyDeployer(_strategyDeployer);
    }

    /**
     * @notice Deploys a new immutable vault + strategy pair for a Uniswap V3 pool and wires them
     * together in one transaction. Ownership of both lands on the factory owner.
     * @param _pool The Uniswap V3 pool to manage.
     * @param _name The vault share token name.
     * @param _symbol The vault share token symbol.
     * @param _positionWidth The width multiplier for tick spacing.
     * @param _maxTickDeviation The max deviation from twap allowed (see strategy.setDeviation).
     */
    function createRangeVault(
        address _pool,
        string calldata _name,
        string calldata _symbol,
        int24 _positionWidth,
        int56 _maxTickDeviation
    ) external onlyOwner returns (address vault, address strategy) {
        SolonRangeVault _vault = SolonRangeVault(vaultDeployer.deploy(_name, _symbol));
        RangeStrategyUniV3 _strategy = RangeStrategyUniV3(strategyDeployer.deploy(_pool, _positionWidth, address(_vault), address(this)));

        _strategy.setDeviation(_maxTickDeviation);
        _vault.setStrategy(address(_strategy));

        _vault.transferOwnership(owner());
        _strategy.transferOwnership(owner());

        deployments.push(Deployment({vault: address(_vault), strategy: address(_strategy), pool: _pool}));
        emit RangeVaultCreated(deployments.length - 1, address(_vault), address(_strategy), _pool);
        return (address(_vault), address(_strategy));
    }

    /// @notice Number of vault/strategy pairs deployed.
    function deploymentsLength() external view returns (uint256) {
        return deployments.length;
    }

    /// @notice Fee numbers read live by every strategy.
    function getFees() external view returns (uint256 total, uint256 call) {
        return (totalFee, callFee);
    }

    /// @notice Set the total performance fee and caller tip, hard-capped.
    function setFees(uint256 _totalFee, uint256 _callFee) external onlyOwner {
        if (_totalFee > MAX_TOTAL_FEE || _callFee > MAX_CALL_FEE) revert OverLimit();
        totalFee = _totalFee;
        callFee = _callFee;
        emit SetFees(_totalFee, _callFee);
    }

    /// @notice Set the keeper address.
    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit SetKeeper(_keeper);
    }

    /// @notice Set the treasury address.
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        emit SetTreasury(_treasury);
    }

    /// @notice Emergency circuit breaker: pauses every strategy deployed by this factory at once.
    function setGlobalPause(bool _paused) external onlyManager {
        globalPause = _paused;
        emit GlobalPause(_paused);
    }

    /// @notice Add or remove an approved rebalancer (moveTicks caller).
    function setRebalancer(address _rebalancer, bool _isRebalancer) external onlyOwner {
        rebalancers[_rebalancer] = _isRebalancer;
        emit RebalancerChanged(_rebalancer, _isRebalancer);
    }
}
