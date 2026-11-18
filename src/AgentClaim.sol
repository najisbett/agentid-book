// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentIDBook {
    function isAgent(address owner) external view returns (bool);
}

/**
 * @title AgentClaim
 * @notice A fixed-supply token that can only be claimed by an address that has bound
 *         an Agent ID (name.ai) in AgentIDBook. One claim per address, no owner, no
 *         mint after deployment, no transfer tax.
 *
 * The whole supply sits in this contract at deployment and leaves only through
 * claim(), so the distribution rule is the product: an Agent ID is the ticket.
 */
contract AgentClaim {
    string public constant name = "AgentID Book";
    string public constant symbol = "AGENT";
    uint8 public constant decimals = 18;

    uint256 public constant SUPPLY = 10_000_000e18;
    uint256 public constant CLAIM_AMOUNT = 10_000e18;   // 1,000 agents at most

    IAgentIDBook public immutable book;

    uint256 public totalSupply = SUPPLY;
    uint256 public claimedCount;
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public hasClaimed;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Claimed(address indexed agent, uint256 amount);

    error NotAnAgent(address who);
    error AlreadyClaimed(address who);
    error SoldOut();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    constructor(IAgentIDBook book_) {
        if (address(book_) == address(0)) revert ZeroAddress();
        book = book_;
        balanceOf[address(this)] = SUPPLY;
        emit Transfer(address(0), address(this), SUPPLY);
    }

    /// @notice Claim the fixed allocation. Caller must hold an Agent ID in the book.
    function claim() external returns (uint256) {
        if (!book.isAgent(msg.sender)) revert NotAnAgent(msg.sender);
        if (hasClaimed[msg.sender]) revert AlreadyClaimed(msg.sender);

        uint256 held = balanceOf[address(this)];
        if (held < CLAIM_AMOUNT) revert SoldOut();

        hasClaimed[msg.sender] = true;
        claimedCount += 1;
        balanceOf[address(this)] = held - CLAIM_AMOUNT;
        balanceOf[msg.sender] += CLAIM_AMOUNT;

        emit Transfer(address(this), msg.sender, CLAIM_AMOUNT);
        emit Claimed(msg.sender, CLAIM_AMOUNT);
        return CLAIM_AMOUNT;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < value) revert InsufficientAllowance();
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _transfer(from, to, value);
        return true;
    }

    function remaining() external view returns (uint256) {
        return balanceOf[address(this)];
    }

    function _transfer(address from, address to, uint256 value) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        balanceOf[from] = bal - value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}