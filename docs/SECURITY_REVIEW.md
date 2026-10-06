# Local adversarial review

This is a review of the delivered source and local tests, not an independent audit or authorization to deploy. The pinned security reference was used as background; unrelated token, pool, oracle, lottery, and administrative mechanisms were not added.

## Attacks exercised

| Attempt | Observed behavior / test coverage |
| --- | --- |
| Skip to a later rock or buy an earlier one | `buy()` has no token-number argument. Wrong prices and an invented `buy(uint256)` selector revert. |
| Buy the same rock twice / submit a stale purchase | After #10 sells, its former price cannot buy #11. Ownership of #10 is unchanged. |
| Pay too little or too much | Every sale position rejects one wei under and over; fuzzed inexact values also revert without balance or supply changes. |
| Buy beyond #99 / mint a 101st rock | Full-sale test ends at 100; subsequent purchases and invented mint calls fail. Transfers cannot mint from the zero address. |
| Reenter from the payout callback | Attempt uses sufficient funds and the correct next price; it returns the exact reentrancy-guard error. Callback sees updated supply and ownership. Propagating callback failure rolls back the purchase. |
| Reenter from `onERC721Received` | The same guarded failure occurs with a funded malicious buyer. Catching the failure permits exactly one sale; propagating it reverts. |
| Reject payout | Payment, mint, ownership, buyer balance, and counter roll back. If the fixture later accepts ETH, a purchase succeeds, demonstrating the lock also rolled back. |
| Reject / omit the NFT receiver hook | Safe mint reverts without taking payment. Safe transfer to a rejecting receiver also rolls back. |
| Transfer the newly minted token within its hook | Permitted by ERC-721; sale state and exact payout remain correct. |
| Unauthorized transfer or approval / revoked approval | Reverts. Transfer clears per-token approval; operator revocation is effective; transfers to zero and incorrect `from` fail. |
| Strand ETH via direct transfer or payable nonpayable call | Rejected. No fallback or `receive` exists. |
| Force ETH using a separate contract | Succeeds, as required by EVM behavior. Forced balance remains; sales continue forwarding exactly `msg.value`. No withdrawal is available. |
| Change price, pause, upgrade, burn, or withdraw | No exposed entry points. No collection administrator. |

## Invariants and metadata

Stateful tests mix purchases (valid and invalid) with ordinary transfers among four buyers and the reserve. After each sequence they check bounded, contiguous supply; total balances; every existing token's owner; absence of the next token; exact aggregate payout; and zero collection balance in the absence of forced ETH.

All 100 formula values are checked independently. For all 100 metadata records the tests decode both base64 layers, parse JSON, verify field names and types, parse the decimal price back to wei, and compare image bytes with `imageOf`. A strict SVG-subset parser checks balanced tags, quoted attributes, namespace, and square viewBox. All tints are valid distinct hex strings, rock zero has equal RGB channels, and masking the base tint produces identical geometry for all 100. Previews before minting match minted images, and transfers preserve metadata.

Factory deployment is exercised with an explicit reserve argument and ten constructor events. Runtime and initcode limits are checked. The runtime is scanned for `DELEGATECALL`, `CALLCODE`, and `SELFDESTRUCT`, skipping PUSH operands in the same manner as the pinned protected floor. The test-only forced-ETH helper is not an application or manifest entry.

## Checks and limits

Validated with Solidity 0.8.26 and Foundry 1.8.3:

- `forge build` and `forge build --sizes`;
- `forge test`: 27 tests, including two 256-case fuzz tests and 64 invariant runs of depth 64 (4,096 calls);
- `forge fmt --check`.

The optimized application runtime is 8,328 bytes; creation code is 9,969 bytes, plus a 32-byte constructor argument. Both are below the protected deployment bounds. No FFI, filesystem cheatcode access, environment-dependent tests, fork, live RPC, wallet key, or external service is used.

Foundry's lint warnings were reviewed: the constructor intentionally uses `_mint` for the explicit reserve without callbacks, and the payout call is protected by OpenZeppelin's storage reentrancy guard as well as prior sale-state updates. The guard's reset after the external call is intentional. The compiler's `SELFDESTRUCT` deprecation warning is confined to the test adversary. Slither and Mythril were not run.

The environment-driven protected harness requires deployment-service inputs and is not copied into ordinary tests. Equivalent local checks establish size, opcode constraints, and constructor behavior; they do not substitute for the final protected run or independent review.

Operational assumptions remain: the production constructor argument is the specified beneficiary, its wallet can control reserve NFTs and accept ETH, and deployment occurs on the intended compatible EVM chain. A rejecting beneficiary can halt future sales; forced ETH cannot be prevented or recovered; there is no upgrade or rescue path. No live deployment or chain-specific beneficiary verification was performed.
