// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title BattleEngine
 * @notice Executes battles between token pools using the Universal Router.
 *
 * When a battle is triggered by the admin, the contract:
 *  1. Sells a portion (battleTax %) of the losing pool’s tokens for native ETH.
 *     - For V2 swaps: the router swaps tokens using a provided address[] path then unwraps WETH.
 *     - For V3 swaps: the router swaps tokens using a provided bytes-encoded path then unwraps WETH.
 *     - For V4 swaps: the router uses action-based encoding; the backend supplies the fee.
 *
 *  2. Deducts fees from the obtained ETH:
 *     - Platform fee is sent to admin.
 *     - Highest bidder fee is sent to the highest bidder.
 *     - Pool fee is added to the winning pool’s ETH reward storage.
 *
 *  3. Uses the remaining ETH to buy tokens for the winning pool.
 *     - For V2/V3 swaps: the router wraps ETH automatically and swaps using the provided path.
 *     - For V4 swaps: the router uses action-based encoding; the backend supplies the fee.
 */


import {BattlePool} from "./BattlePool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

// Simple Universal Router Interface
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
    bytes hookData;
}

contract BattleEngine is BattlePool {
    // ========================================================
    // STATE VARIABLES
    // ========================================================
    address public admin;               // Admin trigger battles.
    uint256 public platformFee;         // Fee percentage (0-1000), 100 = 1%
    uint256 public highestBidderFee;    // Fee percentage (0-1000), 100 = 1%
    uint256 public poolFee;             // Fee percentage (0-1000), 100 = 1%
    UniversalRouter public universalRouter; // Uniswap Universal Router.
    uint256 public MIN_ETH_OUTPUT = 1e12; // 0.000001 ETH minimum.
    uint256 public constant DIVISOR = 10000; // Divisor.

    // ========================================================
    // EVENTS
    // ========================================================
    event FeesUpdated(uint256 platformFee, uint256 highestBidderFee, uint256 poolFee);
    event MinEthOutputUpdated(uint256 oldMinEthOutput, uint256 newMinEthOutput);
    event AdminUpdated(address indexed newAdmin);
    event BattleExecuted(
        uint256 battleId,
        address indexed loserToken,
        address indexed winnerToken,
        uint256 tokensSold,
        uint256 ethReceived,
        uint256 tokensBought,
        uint256 newLoserBalance,
        uint256 newWinnerBalance,
        uint256 platformFeeETH,
        uint256 highestBidderFeeETH,
        uint256 poolFeeETH,
        address highestBidder
    );
    event SwapFailed(string reason);

    // ========================================================
    // CONSTRUCTOR
    // ========================================================
    constructor(
        address initialOwner,
        UniversalRouter _universalRouter,
        address _admin,
        uint256 _platformFee,
        uint256 _highestBidderFee,
        uint256 _poolFee
    ) BattlePool(initialOwner) {
        require(_platformFee <= 1000 && _highestBidderFee <= 1000 && _poolFee <= 1000, "Fees must be 0-1000");
        universalRouter = _universalRouter;
        admin = _admin;
        platformFee = _platformFee;
        highestBidderFee = _highestBidderFee;
        poolFee = _poolFee;
    }

    // ========================================================
    // ADMIN FUNCTIONS
    // ========================================================
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }
    
    // Update battle tax
    function updateFees(uint256 _platformFee, uint256 _highestBidderFee, uint256 _poolFee) external onlyAdmin {
        require(_platformFee <= 1000 && _highestBidderFee <= 1000 && _poolFee <= 1000, "Fees must be 0-1000"); // Not more than 10%
        platformFee = _platformFee;
        highestBidderFee = _highestBidderFee;
        poolFee = _poolFee;
        emit FeesUpdated(_platformFee, _highestBidderFee, _poolFee);
    }

    // Update minimum ETH output for battles
    function updateMinEthOutput(uint256 newMinEthOutput) external onlyAdmin {
        uint256 oldMin = MIN_ETH_OUTPUT;
        MIN_ETH_OUTPUT = newMinEthOutput;
        emit MinEthOutputUpdated(oldMin, newMinEthOutput);
    }

    /**
     * @notice Updates the protocol version for a token's pool.
     * @param token The address of the token whose pool protocol should be updated.
     * @param newProtocol The new protocol version (allowed values: 2, 3, or 4).
    */    
    function updatePoolProtocol(address token, uint8 newProtocol) external onlyAdmin {
        require(isPool[token], "Pool not registered");
        require(newProtocol == 2 || newProtocol == 3 || newProtocol == 4, "Invalid protocol");
        Pool storage pool = pools[token];
        uint8 oldProtocol = pool.protocol;
        pool.protocol = newProtocol;
        emit ProtocolUpdated(token, oldProtocol, newProtocol);
    }

    // ========================================================
    // OWNER FUNCTIONS
    // ========================================================
    function setAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), "Invalid admin");
        admin = _admin;
        emit AdminUpdated(_admin);
    }

    // ========================================================
    // HELPER FUNCTIONS FOR V4 ENCODING
    // ========================================================

    // This helper calculates tickSpacing based on fee.
    function getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 10000) {
            return 200;
        } else if (fee == 500) {
            return 10;
        } else if (fee == 3000) {
            return 60;
        } else if (fee == 400) {
            return 8;
        } else if (fee == 300) {
            return 6;
        } else if (fee == 200) {
            return 4;
        } else if (fee == 100) {
            return 1;
        } else {
            revert("Unsupported fee tier");
        }
    }

    // Accepts fee parameter and calculates tickSpacing dynamically.
    function _buildPoolKeyWithFee(address tokenA, address tokenB, uint24 fee) internal pure returns (PoolKey memory) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0) || token1 != address(0), "Invalid ETH pair");
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: getTickSpacing(fee),
            hooks: address(0)
        });
    }

    // ========================================================
    // PHASE 1: Sell Loser Token → ETH
    // ========================================================

    /**
     * @notice Sells a portion of the loser pool’s tokens for native ETH.
     * For V2 and V3 swaps, the swap path is provided by the caller.
     * For V4 swaps, the backend also provides the fee via `sellFee`.
     * @param loserToken The token to sell.
     * @param protocol Protocol version (2, 3, or 4).
     * @param amount Amount of tokens to sell.
     * @param minOutput Minimum acceptable ETH output.
     * @param sellPathV2 Swap path for V2 (address[]). Ignored if protocol != 2.
     * @param sellPathV3 Swap path for V3 (bytes). Ignored if protocol != 3.
     * @param sellFee Fee for V4 swap (e.g. 3000, 10000). Ignored if protocol != 4.
     * @return ethReceived Amount of ETH received.
     */
    function _phase1Sell(
        address loserToken,
        uint8 protocol,
        uint256 amount,
        uint256 minOutput,
        address[] memory sellPathV2,
        bytes memory sellPathV3,
        uint24 sellFee
    ) internal returns (uint256 ethReceived) {
        uint256 deadline = block.timestamp + 300;
        uint256 initialEth = address(this).balance;
        if (protocol == 2) {
            require(sellPathV2.length >= 2, "Invalid V2 sell path");
            bytes memory commands = abi.encodePacked(
                uint8(Commands.V2_SWAP_EXACT_IN) | 0x80,
                uint8(Commands.UNWRAP_WETH) | 0x80
            );
            bytes[] memory inputs = new bytes[](2);
            inputs[0] = abi.encode(
                address(universalRouter),
                amount,
                minOutput,
                sellPathV2,
                true
            );
            inputs[1] = abi.encode(address(this), minOutput);
            try universalRouter.execute(commands, inputs, deadline) {} catch (bytes memory reason) {
                emit SwapFailed(string(reason));
                revert("Phase1Sell: V2 swap failed");
            }
        } else if (protocol == 3) {
            require(sellPathV3.length > 0, "Invalid V3 sell path");
            bytes memory commands = abi.encodePacked(
                uint8(Commands.V3_SWAP_EXACT_IN) | 0x80,
                uint8(Commands.UNWRAP_WETH) | 0x80
            );
            bytes[] memory inputs = new bytes[](2);
            inputs[0] = abi.encode(
                address(universalRouter),
                amount,
                minOutput,
                sellPathV3,
                true
            );
            inputs[1] = abi.encode(address(this), minOutput);
            try universalRouter.execute(commands, inputs, deadline) {} catch (bytes memory reason) {
                emit SwapFailed(string(reason));
                revert("Phase1Sell: V3 swap failed");
            }
        } else if (protocol == 4) {
            // For V4, use backend-supplied sellFee.
            PoolKey memory key = _buildPoolKeyWithFee(loserToken, address(0), sellFee);
            ExactInputSingleParams memory v4Params = ExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: amount,
                amountOutMinimum: minOutput,
                sqrtPriceLimitX96: 0,
                hookData: ""
            });
            bytes[] memory paramsArray = new bytes[](3);
            paramsArray[0] = abi.encode(v4Params);
            // Input: loserToken (key.currency1)
            paramsArray[1] = abi.encode(key.currency1, amount);
            // Output: ETH (key.currency0)
            paramsArray[2] = abi.encode(key.currency0, minOutput);
            bytes memory actions = abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE_ALL),
                uint8(Actions.TAKE_ALL)
            );
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = abi.encode(actions, paramsArray);
            bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP) | 0x80);
            try universalRouter.execute(commands, inputs, deadline) {} catch (bytes memory reason) {
                emit SwapFailed(string(reason));
                revert("Phase1Sell: V4 swap failed");
            }
        } else {
            revert("Phase1Sell: Unsupported protocol");
        }
        ethReceived = address(this).balance - initialEth;
        require(ethReceived >= minOutput, "Phase1Sell: insufficient ETH output");
    }

    // ========================================================
    // PHASE 2: Buy Winner Token with ETH
    // ========================================================

    /**
     * @notice Buys the winner token using ETH.
     * For V2 and V3 swaps, the swap path is provided by the caller.
     * For V4 swaps, the backend also provides the fee via `buyFee`.
     * @param winnerToken The token to buy.
     * @param protocol Protocol version (2, 3, or 4).
     * @param ethAmount Amount of ETH to spend.
     * @param minTokenOut Minimum acceptable token output.
     * @param buyPathV2 Swap path for V2 (address[]). Ignored if protocol != 2.
     * @param buyPathV3 Swap path for V3 (bytes). Ignored if protocol != 3.
     * @param buyFee Fee for V4 swap (e.g. 3000, 10000). Ignored if protocol != 4.
     * @return tokensBought Amount of tokens bought.
     */
    function _phase2Buy(
        address winnerToken,
        uint8 protocol,
        uint256 ethAmount,
        uint256 minTokenOut,
        address[] memory buyPathV2,
        bytes memory buyPathV3,
        uint24 buyFee
    ) internal returns (uint256 tokensBought) {
        uint256 deadline = block.timestamp + 300;
        uint256 initialTokenBalance = IERC20(winnerToken).balanceOf(address(this));
        if (protocol == 2) {
            require(buyPathV2.length >= 2, "Invalid V2 buy path");
            bytes memory commands = abi.encodePacked(
                uint8(Commands.WRAP_ETH) | 0x80,
                uint8(Commands.V2_SWAP_EXACT_IN) | 0x80
            );
            bytes[] memory inputs = new bytes[](2);
            inputs[0] = abi.encode(address(universalRouter), ethAmount);
            inputs[1] = abi.encode(
                address(this),
                ethAmount,
                minTokenOut,
                buyPathV2,
                false
            );
            try universalRouter.execute{value: ethAmount}(commands, inputs, deadline) {} catch (bytes memory reason) {
                emit SwapFailed(string(reason));
                revert("Phase2Buy: V2 swap failed");
            }
        } else if (protocol == 3) {
            require(buyPathV3.length > 0, "Invalid V3 buy path");
            bytes memory commands = abi.encodePacked(
                uint8(Commands.WRAP_ETH) | 0x80,
                uint8(Commands.V3_SWAP_EXACT_IN) | 0x80
            );
            bytes[] memory inputs = new bytes[](2);
            inputs[0] = abi.encode(address(universalRouter), ethAmount);
            inputs[1] = abi.encode(
                address(this),
                ethAmount,
                minTokenOut,
                buyPathV3,
                false
            );
            try universalRouter.execute{value: ethAmount}(commands, inputs, deadline) {} catch (bytes memory reason) {
                emit SwapFailed(string(reason));
                revert("Phase2Buy: V3 swap failed");
            }
        } else if (protocol == 4) {
            // For V4, use backend-supplied buyFee.
            PoolKey memory key = _buildPoolKeyWithFee(address(0), winnerToken, buyFee);
            ExactInputSingleParams memory v4Params = ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: ethAmount,
                amountOutMinimum: minTokenOut,
                sqrtPriceLimitX96: 0,
                hookData: ""
            });
            bytes[] memory paramsArray = new bytes[](3);
            paramsArray[0] = abi.encode(v4Params);
            // Input: ETH (key.currency0)
            paramsArray[1] = abi.encode(key.currency0, ethAmount);
            // Output: winnerToken (key.currency1)
            paramsArray[2] = abi.encode(key.currency1, minTokenOut);
            bytes memory actions = abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE_ALL),
                uint8(Actions.TAKE_ALL)
            );
            bytes[] memory inputs = new bytes[](1);
            inputs[0] = abi.encode(actions, paramsArray);
            bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP) | 0x80);
            try universalRouter.execute{value: ethAmount}(commands, inputs, deadline) {} catch (bytes memory reason) {
                emit SwapFailed(string(reason));
                revert("Phase2Buy: V4 swap failed");
            }
        } else {
            revert("Phase2Buy: Unsupported protocol");
        }
        tokensBought = IERC20(winnerToken).balanceOf(address(this)) - initialTokenBalance;
        require(tokensBought >= minTokenOut, "Phase2Buy: insufficient token output");
    }

    // ========================================================
    // BATTLE FUNCTION
    // ========================================================

    /**
     * @notice Executes a battle between two pools.
     * @param battleId Unique battle identifier.
     * @param loserToken Token of the losing pool.
     * @param winnerToken Token of the winning pool.
     * @param battleTax Percentage (0-10000) of the loser pool’s tokens to sell.
     * @param highestBidder Address to receive the highest bidder fee.
     * @param sellPathV2 Swap path for selling (V2).
     * @param sellPathV3 Swap path for selling (V3).
     * @param buyPathV2 Swap path for buying (V2).
     * @param buyPathV3 Swap path for buying (V3).
     * @param sellFee Fee for V4 swap when selling.
     * @param buyFee Fee for V4 swap when buying.
     */
    function executeBattle(
        uint256 battleId,
        address loserToken,
        address winnerToken,
        uint256 battleTax,
        address highestBidder,
        address[] calldata sellPathV2,
        bytes calldata sellPathV3,
        address[] calldata buyPathV2,
        bytes calldata buyPathV3,
        uint24 sellFee,
        uint24 buyFee
    ) external onlyAdmin nonReentrant {
        require(!battleExecuted[battleId], "Battle already executed");
        battleExecuted[battleId] = true;
        require(isPool[loserToken] && isPool[winnerToken], "Both pools must be registered");
        require(battleTax > 0 && battleTax <= 10000, "Invalid battle tax percentage"); // 100% = 10000

        (uint256 loserBalance, , , uint8 loserProtocol) = getPoolInfo(loserToken);
        require(loserBalance > 0, "Loser pool empty");
        uint256 tokensToSell = (loserBalance * battleTax) / DIVISOR;
        require(tokensToSell > 0, "Tokens to sell is 0");

        // Phase 1: Sell loser token to obtain ETH.
        uint256 ethReceived = _phase1Sell(loserToken, loserProtocol, tokensToSell, MIN_ETH_OUTPUT, sellPathV2, sellPathV3, sellFee);
        pools[loserToken].totalTokens -= tokensToSell;

        // Fee distribution.
        uint256 platformFeeETH = (ethReceived * platformFee) / DIVISOR;
        uint256 highestBidderFeeETH = (ethReceived * highestBidderFee) / DIVISOR;
        uint256 poolFeeETH = (ethReceived * poolFee) / DIVISOR;
        if (platformFeeETH > 0) {
            (bool sentAdmin, ) = payable(admin).call{value: platformFeeETH}("");
            require(sentAdmin, "Platform fee transfer failed");
        }
        if (highestBidderFeeETH > 0) {
            (bool sentHB, ) = payable(highestBidder).call{value: highestBidderFeeETH}("");
            require(sentHB, "Highest bidder fee transfer failed");
        }
        _updatePoolReward(winnerToken, poolFeeETH);

        uint256 ethUsedForFees = platformFeeETH + highestBidderFeeETH + poolFeeETH;
        require(ethReceived >= ethUsedForFees, "Fees exceed ETH received");
        uint256 remainingEth = ethReceived - ethUsedForFees;
        require(remainingEth > 0, "No ETH left for purchase");

        (, , , uint8 winnerProtocol) = getPoolInfo(winnerToken);
        uint256 tokensBought = _phase2Buy(winnerToken, winnerProtocol, remainingEth, 1, buyPathV2, buyPathV3, buyFee);
        require(tokensBought >= 1, "Swap ETH to token failed");
        pools[winnerToken].totalTokens += tokensBought;

        battleRecords[battleId] = BattleRecord({
            battleId: battleId,
            loserToken: loserToken,
            winnerToken: winnerToken,
            battleTax: battleTax,
            tokensSold: tokensToSell,
            ethReceived: ethReceived,
            tokensBought: tokensBought,
            newLoserBalance: pools[loserToken].totalTokens,
            newWinnerBalance: pools[winnerToken].totalTokens,
            platformFeeETH: platformFeeETH,
            highestBidderFeeETH: highestBidderFeeETH,
            poolFeeETH: poolFeeETH,
            highestBidder: highestBidder
        });

        emit BattleExecuted(
            battleId,
            loserToken,
            winnerToken,
            tokensToSell,
            ethReceived,
            tokensBought,
            pools[loserToken].totalTokens,
            pools[winnerToken].totalTokens,
            platformFeeETH,
            highestBidderFeeETH,
            poolFeeETH,
            highestBidder
        );
    }

    // ========================================================
    // ACCEPT ETH
    // ========================================================
    receive() external payable {}
}
