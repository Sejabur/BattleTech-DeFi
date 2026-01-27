// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title BattlePool
 * @notice Manages token pools for the Battle Game.
 *
 * When a token is deposited, a pool is automatically registered (if not already).
 * Contributors deposit tokens to earn proportional ETH rewards. Battle wins and losses
 * update the pool's token balance, and ETH rewards (from battles or external distributions)
 * are stored per pool for contributors to claim.
 *
 * @dev Uses a staking reward pattern with accRewardPerShare.
 */

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
using SafeERC20 for IERC20;


// --- Simple Uniswap V3 & V2 Interfaces ---
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}
interface IUniswapV3Pool {
    function liquidity() external view returns (uint128);
}
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
}

contract BattlePool is Ownable, ReentrancyGuard {
    // ========================================================
    // EVENTS
    // ========================================================
    event PoolRegistered(address indexed token);
    event Deposit(address indexed token, address indexed contributor, uint256 amount, uint256 shares, uint256 totalTokens);
    event RewardClaimed(address indexed token, address indexed contributor, uint256 reward);
    event RewardDistributed(address indexed token, uint256 amount);
    event ProtocolUpdated(address indexed token, uint8 oldProtocol, uint8 newProtocol);

    // ========================================================
    // STRUCTS
    // ========================================================
    struct Pool {
        address token;
        uint256 totalTokens;       // Deposited tokens plus battle wins minus losses
        uint256 totalShares;       // Total shares issued to contributors
        uint256 accRewardPerShare; // Accumulated reward per share, scaled by 1e18
        uint8 protocol;            // 2 = V2, 3 = V3, 4 = V4
        uint256 ethRewardStorage;  // ETH rewards available for distribution to contributors
        mapping(address => uint256) shares;         // Contributor shares
        mapping(address => uint256) rewardDebt;       // Used for pending reward calculation
        mapping(address => uint256) claimableRewards; // Stored pending rewards from previous deposits
    }

    struct BattleRecord {
        uint256 battleId;
        address loserToken;
        address winnerToken;
        uint256 battleTax;
        uint256 tokensSold;
        uint256 ethReceived;
        uint256 tokensBought;
        uint256 newLoserBalance;
        uint256 newWinnerBalance;
        uint256 platformFeeETH;
        uint256 highestBidderFeeETH;
        uint256 poolFeeETH;
        address highestBidder;
    }
    
    // ========================================================
    // STATE VARIABLES
    // ========================================================
    mapping(address => bool) public isPool;
    mapping(address => Pool) internal pools;
    address[] private poolTokens;
    mapping(address => uint256) public lastDepositTime; // Each address may deposit at most once per minute.
    mapping(uint256 => BattleRecord) public battleRecords; // Battle ID => record.
    mapping(uint256 => bool) public battleExecuted; // To prevent duplicate battles.
    
    // --- Essential addresses & thresholds ---
    address public constant WETH_ADDRESS = 0x4200000000000000000000000000000000000006; // WETH
    address public constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // Permit2
    address private constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD; // Uniswap V3 Factory
    address private constant UNISWAP_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6; // Uniswap V2 Factory
    address private constant UR_ADDRESS = 0x6fF5693b99212Da76ad316178A184AB56D299b43;  // Uniswap V4 Universal Router
    uint128 private constant THRESHOLD_V3 = 1e10;
    uint112 private constant THRESHOLD_V2 = 1e10;

    // ========================================================
    // CONSTRUCTOR
    // ========================================================
    constructor(address initialOwner) Ownable(initialOwner) { }

    /**
     * @notice Checks token liquidity to determine its protocol.
     * @param token The ERC20 token address.
     * @return protocol The protocol version (2, 3, or 4).
     */
    function _checkTokenProtocol(address token) internal view returns (uint8 protocol) {
        // Check Uniswap V3 pool with WETH.
        address poolV3 = IUniswapV3Factory(UNISWAP_V3_FACTORY).getPool(token, WETH_ADDRESS, 3000);
        if (poolV3 != address(0)) {
            uint128 liquidity = IUniswapV3Pool(poolV3).liquidity();
            if (liquidity >= THRESHOLD_V3) return 3;
        }
        // Check Uniswap V2 pair with WETH.
        address pairV2 = IUniswapV2Factory(UNISWAP_V2_FACTORY).getPair(token, WETH_ADDRESS);
        if (pairV2 != address(0)) {
            (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pairV2).getReserves();
            uint112 tokenReserve = token < WETH_ADDRESS ? reserve0 : reserve1;
            if (tokenReserve >= THRESHOLD_V2) return 2;
        }
        return 4; // Considers token as V4 if there isn't liquidity on V2 and V3
    }

    /**
     * @notice Registers a new pool for a token.
     * The pool is registered with a protocol determined by liquidity against WETH or VIRTUAL.
     * The token is approved for use with the Universal Router via Permit2.
     * @param token The ERC20 token address.
     */
    function registerPool(address token) public virtual {
        require(!isPool[token], "Pool already registered");
        isPool[token] = true;
        Pool storage pool = pools[token];
        pool.token = token;
        pool.totalTokens = 0;
        pool.totalShares = 0;
        pool.accRewardPerShare = 0;
        pool.ethRewardStorage = 0;
        pool.protocol = _checkTokenProtocol(token);
        poolTokens.push(token);
        SafeERC20.forceApprove(IERC20(token), address(PERMIT2_ADDRESS), type(uint256).max);
        IPermit2(PERMIT2_ADDRESS).approve(token, UR_ADDRESS, type(uint160).max, type(uint48).max); 
        emit PoolRegistered(token);
    }

    /**
     * @notice Deposits tokens into the pool.
     * @param token The token address.
     * @param amount The amount to deposit.
     *
     * Pending rewards for an existing contributor are recorded.
     */
    function deposit(address token, uint256 amount) external nonReentrant {
        require(block.timestamp >= lastDepositTime[msg.sender] + 60, "Deposit cooldown: wait 1 minute");
        lastDepositTime[msg.sender] = block.timestamp;
        if (!isPool[token]) {
            registerPool(token);
        }
        Pool storage pool = pools[token];
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        if (pool.shares[msg.sender] > 0) {
            uint256 pending = (pool.shares[msg.sender] * pool.accRewardPerShare) / 1e18 - pool.rewardDebt[msg.sender];
            if (pending > 0) {
                pool.claimableRewards[msg.sender] += pending;
            }
        }
        
        uint256 sharesToMint = (pool.totalShares == 0 || pool.totalTokens == 0)
            ? amount
            : (amount * pool.totalShares) / pool.totalTokens;
        pool.totalTokens += amount;
        pool.totalShares += sharesToMint;
        pool.shares[msg.sender] += sharesToMint;
        pool.rewardDebt[msg.sender] = (pool.shares[msg.sender] * pool.accRewardPerShare) / 1e18;
        emit Deposit(token, msg.sender, amount, sharesToMint, pool.totalTokens);
    }

    /**
     * @notice Claims pending ETH rewards for a specific pool.
     * @param token The token address of the pool.
     */
    function claimReward(address token) public nonReentrant {
        require(isPool[token], "Pool not registered");
        Pool storage pool = pools[token];
        uint256 userShares = pool.shares[msg.sender];
        require(userShares > 0, "No shares");
        uint256 pending = (userShares * pool.accRewardPerShare) / 1e18 - pool.rewardDebt[msg.sender];
        pending += pool.claimableRewards[msg.sender];
        require(pending > 0, "No reward");
        
        pool.claimableRewards[msg.sender] = 0;
        pool.rewardDebt[msg.sender] = (userShares * pool.accRewardPerShare) / 1e18;
        require(pool.ethRewardStorage >= pending, "Reward storage underflow");
        pool.ethRewardStorage -= pending;
        
        (bool success, ) = msg.sender.call{value: pending}("");
        require(success, "ETH transfer failed");
        emit RewardClaimed(token, msg.sender, pending);
    }

    /**
     * @notice Claims rewards from all pools in which the contributor has participated.
     */
    function claimAllRewards() external nonReentrant {
        uint256 totalClaimed = 0;
        for (uint256 i = 0; i < poolTokens.length; i++) {
            address token = poolTokens[i];
            if (isPool[token]) {
                Pool storage pool = pools[token];
                uint256 userShares = pool.shares[msg.sender];
                if (userShares > 0) {
                    uint256 pending = (userShares * pool.accRewardPerShare) / 1e18 - pool.rewardDebt[msg.sender];
                    pending += pool.claimableRewards[msg.sender];
                    if (pending > 0) {
                        pool.claimableRewards[msg.sender] = 0;
                        pool.rewardDebt[msg.sender] = (userShares * pool.accRewardPerShare) / 1e18;
                        totalClaimed += pending;
                        emit RewardClaimed(token, msg.sender, pending);
                        require(pool.ethRewardStorage >= pending, "Reward storage underflow");
                        pool.ethRewardStorage -= pending;
                    }
                }
            }
        }
        require(totalClaimed > 0, "No rewards");
        (bool success, ) = msg.sender.call{value: totalClaimed}("");
        require(success, "ETH transfer failed");
    }

    /**
     * @notice Returns pool information.
     * @param token The token address.
     * @return totalTokens Total tokens in the pool.
     * @return totalShares Total shares in the pool.
     * @return accRewardPerShare Accumulated reward per share.
     * @return protocol Protocol version.
     */
    function getPoolInfo(address token) public view returns (uint256 totalTokens, uint256 totalShares, uint256 accRewardPerShare, uint8 protocol) {
        require(isPool[token], "Pool not registered");
        Pool storage pool = pools[token];
        return (pool.totalTokens, pool.totalShares, pool.accRewardPerShare, pool.protocol);
    }

    /**
     * @notice Returns the claimable ETH reward for a contributor in a pool.
     * @param token The token address.
     * @param user The contributor's address.
     * @return pending The pending reward amount.
     */
    function getClaimableReward(address token, address user) public view returns (uint256 pending) {
        require(isPool[token], "Pool not registered");
        Pool storage pool = pools[token];
        uint256 userShares = pool.shares[user];
        if (userShares == 0) return 0;
        pending = (userShares * pool.accRewardPerShare) / 1e18 - pool.rewardDebt[user];
        pending += pool.claimableRewards[user];
    }

    /**
     * @notice Returns the total claimable reward for a contributor across all pools.
     * @param user The contributor's address.
     * @return totalReward The total pending reward.
     */
    function getTotalClaimableReward(address user) public view returns (uint256 totalReward) {
        for (uint256 i = 0; i < poolTokens.length; i++) {
            address token = poolTokens[i];
            if (isPool[token]) {
                Pool storage pool = pools[token];
                uint256 userShares = pool.shares[user];
                if (userShares > 0) {
                    totalReward += (userShares * pool.accRewardPerShare) / 1e18 - pool.rewardDebt[user] + pool.claimableRewards[user];
                }
            }
        }
        return totalReward;
    }

    /**
     * @notice Updates reward variables for a pool when new ETH is added.
     * @param token The token address.
     * @param reward The ETH reward to distribute.
     */
    function _updatePoolReward(address token, uint256 reward) internal {
        Pool storage pool = pools[token];
        if (pool.totalShares > 0) {
            pool.accRewardPerShare += (reward * 1e18) / pool.totalShares;
            pool.ethRewardStorage += reward;
            emit RewardDistributed(token, reward);
        }
    }
}
