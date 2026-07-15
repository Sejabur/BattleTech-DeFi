# BattleTech-DeFi: Algorithmic Liquidity Rebalancing Protocol
*Automated cross-pool capital efficiency protocol using volume-metric indicators and multi-version DEX routing.*

> **Note on Proprietary Intellectual Property & Status:** This repository contains an early-stage developer prototype and reference implementation. The finalized, optimized, and fully audited production deployment was built for a private client and remains proprietary. As an open-source reference prototype, this codebase may contain unresolved edge cases or development bugs. It is intended exclusively for architectural demonstration and evaluation; comprehensive third-party audits are required prior to any production use.

## Core Protocol Lifecycle & Execution Matrix
Detail the sequence within `executeBattle`:
1. **State Ingestion & Allocation:** The system calculates the target tokens to liquidate based on the input `battleTax` (scaled via `DIVISOR = 10000`) relative to the underperforming pool’s state.
2. **Multi-Protocol Swapping via Universal Router:** Capital is routed out of the losing pool into native $ETH$ using the Uniswap Universal Router. Based on the registered pool protocol version, it dynamically executes standard pathing for V2, bytes-encoded paths for V3, or action-based commands (`Actions.SWAP_EXACT_IN_SINGLE`) paired with dynamic `tickSpacing` selection for V4.
3. **Algorithmic Capital Distribution:** The contract splits the recovered native $ETH$ into three distinct components based on configured storage state limits:
   - **Platform Allocations:** Disbursed to the `admin` address.
   - **Incentive Yield:** Disbursed to the designated `highestBidder`.
   - **Pool Staking Rewards:** Injected into the winning pool's reward accounting via an automated staking share algorithm (`accRewardPerShare`).

## Mathematical Architecture
$$ETH_{\text{fees}} = \frac{ETH_{\text{received}} \times (\text{platformFee} + \text{highestBidderFee} + \text{poolFee})}{\text{DIVISOR}}$$

$$ETH_{\text{remaining}} = ETH_{\text{received}} - ETH_{\text{fees}}$$

The $ETH_{\text{remaining}}$ is immediately passed into `_phase2Buy` to build a price floor for the winning token asset.

## Technical Specification Matrix

| Component | Technical Implementation & Logic |
| :--- | :--- |
| **Uniswap Universal Router** | Acts as the unified execution hub executing multi-protocol swaps via complex command bytes mapping. |
| **DEX Routing Engine** | Natively handles `V2_SWAP_EXACT_IN`, `V3_SWAP_EXACT_IN` (concentrated liquidity), and `V4_SWAP` single actions. |
| **Permit2 Integration** | Automates a two-tier infinite token approval workflow inside `registerPool` using `IPermit2`. |
| **Staking Mechanism** | Implements a scalable `accRewardPerShare` accounting method to track individual contributor reward debt fractions. |
| **Security Architecture** | Utilizes OpenZeppelin `SafeERC20` utilities, inherited `ReentrancyGuard` protection, and administrative modifiers. |

## Deployment Verification & Environment
**Live Testnet Deployment:** [0x49e5f916f716de41970d30ea0e69cb29cf497624](https://sepolia.basescan.org/address/0x49e5f916f716de41970d30ea0e69cb29cf497624)

**Compilation Framework:**
This project utilizes the Foundry framework. To compile and test the execution sequences locally:
```bash
forge build
forge test
```
For complex configurations and advanced scripting, refer directly to the official [Foundry Book](https://book.getfoundry.sh/).
