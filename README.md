# BattleTech: Multi-Version DEX Routing & Capital Execution Engine
*Smart contract infrastructure for automated, cross-pool asset rebalancing via the Uniswap Universal Router.*

> **About this Repository:** This repository serves as an open-source technical reference implementation demonstrating advanced smart contract composition. It focuses on abstracting complex liquidity interactions across Uniswap V2, V3, and V4 into a single, cohesive execution layer. It is designed as an architectural prototype for developers building modular DEX routing systems and high-level execution protocols.

## Core Protocol Lifecycle & Execution Matrix
Detail the sequence within the execution engine (`executeBattle`):
1. **State Ingestion & Allocation:** The system calculates the target liquidity volume to route based on a dynamic input parameter (scaled via `DIVISOR = 10000`) relative to the current pool’s state.
2. **Multi-Protocol Swapping via Universal Router:** Capital is routed through the Uniswap Universal Router. Based on the registered pool protocol version, it dynamically executes standard pathing for V2, bytes-encoded paths for V3, or action-based commands (`Actions.SWAP_EXACT_IN_SINGLE`) paired with dynamic `tickSpacing` selection for V4.
3. **Execution Incentives & Yield Distribution:** The contract securely distributes the recovered native $ETH$ to maintain protocol sustainability and incentivize decentralized execution:
   - **Infrastructure Allocation:** Disbursed to maintain protocol operations (administrative address).
   - **Executor/Searcher Incentive:** Disbursed to the entity triggering the execution (MEV/Searcher incentive, designated in-code as `highestBidder`).
   - **Liquidity Provider Rewards:** Injected into the target pool's reward accounting via an automated, gas-efficient staking share algorithm (`accRewardPerShare`).

## Mathematical Architecture
$$ETH_{\text{allocations}} = \frac{ETH_{\text{received}} \times (\text{platformFee} + \text{executorIncentive} + \text{poolYield})}{\text{DIVISOR}}$$

$$ETH_{\text{remaining}} = ETH_{\text{received}} - ETH_{\text{allocations}}$$

The $ETH_{\text{remaining}}$ is immediately utilized to execute an optimal buy swap for the target token asset, enforcing deep liquidity.

## Technical Specification Matrix

| Component | Technical Implementation & Logic |
| :--- | :--- |
| **Uniswap Universal Router** | Acts as the unified execution hub executing multi-protocol swaps via complex command bytes mapping. |
| **DEX Routing Engine** | Natively handles `V2_SWAP_EXACT_IN`, `V3_SWAP_EXACT_IN` (concentrated liquidity), and `V4_SWAP` single actions. |
| **Permit2 Integration** | Automates a two-tier infinite token approval workflow inside `registerPool` using `IPermit2` to minimize gas. |
| **Accounting Mechanism** | Implements a scalable `accRewardPerShare` debt method to track individual contributor yields efficiently. |
| **Security Architecture** | Utilizes OpenZeppelin `SafeERC20` utilities and inherited `ReentrancyGuard` protection for secure execution. |

## Deployment Verification & Environment
**Live Testnet Deployment:** [0x49e5f916f716de41970d30ea0e69cb29cf497624](https://sepolia.basescan.org/address/0x49e5f916f716de41970d30ea0e69cb29cf497624)

**Compilation Framework:**
This project utilizes the Foundry framework. To compile and test the execution sequences locally:
```bash
forge build
forge test
```
For complex configurations and advanced scripting, refer directly to the official [Foundry Book](https://book.getfoundry.sh/).
