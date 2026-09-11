// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/*
  Testnet-only mocks(Sepolia 暴打测试用,禁止用于任何生产部署):
    · MockERC20 — 开放 mint(多攻击者角色演练不用转账凑钱);
    · MockFeedOwned — Chainlink 形状可控喂价,owner 才能 set(公开测试网防路人拧价格,
      暴打脚本靠它人为制造暴跌/脱锚/停摆打清算与坏账路径)。
*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s, uint8 d) { name = n; symbol = s; decimals = d; }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amount, "ALLOWANCE");
            allowance[from][msg.sender] = a - amount;
        }
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MockFeedOwned {
    address public owner;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    bool public autoFresh = true; // true: updatedAt 始终=now(免维护);false: 用 set 的时间戳(演停摆)

    constructor(int256 a) { owner = msg.sender; answer = a; updatedAt = block.timestamp; }

    function set(int256 a, uint256 u, uint80 r, bool fresh) external {
        require(msg.sender == owner, "NOT_OWNER");
        answer = a; updatedAt = u; roundId = r; autoFresh = fresh;
    }

    function setPrice(int256 a) external {
        require(msg.sender == owner, "NOT_OWNER");
        answer = a; updatedAt = block.timestamp; roundId += 1; autoFresh = true;
    }

    function decimals() external pure returns (uint8) { return 8; }

    function description() external pure returns (string memory) { return "Solon testnet mock / USD"; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 u = autoFresh ? block.timestamp : updatedAt;
        return (roundId, answer, u, u, roundId);
    }
}
