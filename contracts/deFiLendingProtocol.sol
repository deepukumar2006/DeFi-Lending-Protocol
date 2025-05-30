// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DeFiLendingProtocol
 * @dev A decentralized lending protocol allowing users to lend and borrow ERC20 tokens
 */
contract DeFiLendingProtocol is ReentrancyGuard, Ownable {
    
    // Struct to store user lending information
    struct LendingPool {
        uint256 totalSupply;
        uint256 totalBorrowed;
        uint256 interestRate; // Annual interest rate in basis points (e.g., 500 = 5%)
        mapping(address => uint256) userSupply;
        mapping(address => uint256) userBorrowed;
        mapping(address => uint256) lastUpdateTime;
    }
    
    // Mapping from token address to lending pool
    mapping(address => LendingPool) public pools;
    
    // Supported tokens
    address[] public supportedTokens;
    
    // Collateralization ratio (150% = 15000 basis points)
    uint256 public constant COLLATERAL_RATIO = 15000;
    uint256 public constant BASIS_POINTS = 10000;
    
    // Events
    event TokenSupplied(address indexed user, address indexed token, uint256 amount);
    event TokenBorrowed(address indexed user, address indexed token, uint256 amount);
    event TokenRepaid(address indexed user, address indexed token, uint256 amount);
    event TokenWithdrawn(address indexed user, address indexed token, uint256 amount);
    
    constructor() Ownable(msg.sender) {}
    
    /**
     * @dev Supply tokens to the lending pool
     * @param tokenAddress Address of the ERC20 token to supply
     * @param amount Amount of tokens to supply
     */
    function supplyToken(address tokenAddress, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(isTokenSupported(tokenAddress), "Token not supported");
        
        IERC20 token = IERC20(tokenAddress);
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        LendingPool storage pool = pools[tokenAddress];
        
        // Update interest before modifying supply
        _updateInterest(tokenAddress, msg.sender);
        
        pool.userSupply[msg.sender] += amount;
        pool.totalSupply += amount;
        
        emit TokenSupplied(msg.sender, tokenAddress, amount);
    }
    
    /**
     * @dev Borrow tokens from the lending pool
     * @param tokenAddress Address of the ERC20 token to borrow
     * @param amount Amount of tokens to borrow
     */
    function borrowToken(address tokenAddress, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(isTokenSupported(tokenAddress), "Token not supported");
        
        LendingPool storage pool = pools[tokenAddress];
        require(pool.totalSupply >= pool.totalBorrowed + amount, "Insufficient liquidity");
        
        // Check collateralization ratio
        require(_checkCollateralization(msg.sender, tokenAddress, amount), "Insufficient collateral");
        
        // Update interest before modifying borrow
        _updateInterest(tokenAddress, msg.sender);
        
        pool.userBorrowed[msg.sender] += amount;
        pool.totalBorrowed += amount;
        
        IERC20 token = IERC20(tokenAddress);
        require(token.transfer(msg.sender, amount), "Transfer failed");
        
        emit TokenBorrowed(msg.sender, tokenAddress, amount);
    }
    
    /**
     * @dev Repay borrowed tokens
     * @param tokenAddress Address of the ERC20 token to repay
     * @param amount Amount of tokens to repay
     */
    function repayToken(address tokenAddress, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(isTokenSupported(tokenAddress), "Token not supported");
        
        LendingPool storage pool = pools[tokenAddress];
        
        // Update interest before repayment
        _updateInterest(tokenAddress, msg.sender);
        
        uint256 userBorrowed = pool.userBorrowed[msg.sender];
        require(userBorrowed > 0, "No debt to repay");
        
        // Don't allow overpayment
        if (amount > userBorrowed) {
            amount = userBorrowed;
        }
        
        IERC20 token = IERC20(tokenAddress);
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        pool.userBorrowed[msg.sender] -= amount;
        pool.totalBorrowed -= amount;
        
        emit TokenRepaid(msg.sender, tokenAddress, amount);
    }
    
    /**
     * @dev Withdraw supplied tokens
     * @param tokenAddress Address of the ERC20 token to withdraw
     * @param amount Amount of tokens to withdraw
     */
    function withdrawToken(address tokenAddress, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(isTokenSupported(tokenAddress), "Token not supported");
        
        LendingPool storage pool = pools[tokenAddress];
        
        // Update interest before withdrawal
        _updateInterest(tokenAddress, msg.sender);
        
        uint256 userSupply = pool.userSupply[msg.sender];
        require(userSupply >= amount, "Insufficient balance");
        
        // Check if withdrawal maintains collateralization for existing borrows
        require(_checkWithdrawalCollateralization(msg.sender, tokenAddress, amount), "Would break collateralization");
        
        pool.userSupply[msg.sender] -= amount;
        pool.totalSupply -= amount;
        
        IERC20 token = IERC20(tokenAddress);
        require(token.transfer(msg.sender, amount), "Transfer failed");
        
        emit TokenWithdrawn(msg.sender, tokenAddress, amount);
    }
    
    /**
     * @dev Add a new supported token (only owner)
     * @param tokenAddress Address of the token to add
     * @param interestRate Annual interest rate in basis points
     */
    function addSupportedToken(address tokenAddress, uint256 interestRate) external onlyOwner {
        require(!isTokenSupported(tokenAddress), "Token already supported");
        require(interestRate <= 5000, "Interest rate too high"); // Max 50%
        
        supportedTokens.push(tokenAddress);
        pools[tokenAddress].interestRate = interestRate;
    }
    
    /**
     * @dev Update interest for a user's position
     */
    function _updateInterest(address tokenAddress, address user) internal {
        LendingPool storage pool = pools[tokenAddress];
        uint256 timeElapsed = block.timestamp - pool.lastUpdateTime[user];
        
        if (timeElapsed > 0 && pool.userBorrowed[user] > 0) {
            uint256 interest = (pool.userBorrowed[user] * pool.interestRate * timeElapsed) / (365 days * BASIS_POINTS);
            pool.userBorrowed[user] += interest;
            pool.totalBorrowed += interest;
        }
        
        pool.lastUpdateTime[user] = block.timestamp;
    }
    
    /**
     * @dev Check if user has sufficient collateral for borrowing
     */
    function _checkCollateralization(address user, address /* tokenToBorrow */, uint256 borrowAmount) internal view returns (bool) {
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;
        
        // Calculate total collateral value (simplified - assumes 1:1 token prices)
        for (uint i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            totalCollateralValue += pools[token].userSupply[user];
            totalBorrowValue += pools[token].userBorrowed[user];
        }
        
        totalBorrowValue += borrowAmount;
        
        return totalCollateralValue * BASIS_POINTS >= totalBorrowValue * COLLATERAL_RATIO;
    }
    
    /**
     * @dev Check if withdrawal maintains collateralization
     */
    function _checkWithdrawalCollateralization(address user, address tokenToWithdraw, uint256 withdrawAmount) internal view returns (bool) {
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;
        
        for (uint i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            uint256 supply = pools[token].userSupply[user];
            if (token == tokenToWithdraw) {
                supply = supply >= withdrawAmount ? supply - withdrawAmount : 0;
            }
            totalCollateralValue += supply;
            totalBorrowValue += pools[token].userBorrowed[user];
        }
        
        if (totalBorrowValue == 0) return true;
        return totalCollateralValue * BASIS_POINTS >= totalBorrowValue * COLLATERAL_RATIO;
    }
    
    /**
     * @dev Check if a token is supported
     */
    function isTokenSupported(address tokenAddress) public view returns (bool) {
        for (uint i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == tokenAddress) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @dev Get user's supply balance for a token
     */
    function getUserSupply(address tokenAddress, address user) external view returns (uint256) {
        return pools[tokenAddress].userSupply[user];
    }
    
    /**
     * @dev Get user's borrow balance for a token
     */
    function getUserBorrow(address tokenAddress, address user) external view returns (uint256) {
        return pools[tokenAddress].userBorrowed[user];
    }
    
    /**
     * @dev Get pool information for a token
     */
    function getPoolInfo(address tokenAddress) external view returns (uint256 totalSupply, uint256 totalBorrowed, uint256 interestRate) {
        LendingPool storage pool = pools[tokenAddress];
        return (pool.totalSupply, pool.totalBorrowed, pool.interestRate);
    }
}
