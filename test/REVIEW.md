# IMDRocks test coverage

Run `forge build` and `forge test` from the repository root. The suite uses the
existing vendored dependencies and requires no network, fork, FFI, or environment
mutation. Fuzz and invariant settings live in the test files.

The existing sale and metadata tests cover all 100 formula values, every public
sale position, the ten factory-deployed reserve mints and their events, both
one-wei payment errors, nonexistent metadata, decoded JSON/SVG, distinct tints,
and ordinary ERC-721 transfer rules. The payment fuzz test now generates the full
uint256 domain except the exact price without discarding inputs; explicit cases
pin zero, the maximum payment, and invalid token-number boundaries.

`IMDRocks.callbacks.t.sol` adds payout rejection and retry at random sale
positions, rollback of transfers and approvals performed inside a receiver
callback, rollback of the receiver's own storage, simultaneous receiver/payout
reentry at rock 99, and final-rock failures followed by a successful retry.

`IMDRocks.invariant.t.sol` runs 128 sequences of depth 128 over seven handlers:
ordinary purchases, batches of separate purchases, receiver purchases, owner
transfers, approvals/revocations, operator transfers, and rejected direct ETH
transfers. Inputs are bounded and expected target reverts are handled explicitly;
unexpected handler reverts fail the campaign. A deterministic sequence also
reaches sellout and exercises stale and revoked approvals.

The independent model records successful purchases, each token's owner and
approval, each actor's NFT balance, operator permissions, and each payer's ETH
spending. The invariant compares those records with the contract after each
handler call and checks contiguous supply, the 100-rock cap, exact aggregate
payout, and conservation of payer funds. Receiver modes include rejection,
reentry with caught or propagated failure, and immediate transfer of the minted
rock. Actors are funded once at setup; balances are never reset during a sequence.

The zero-ETH assertion covers these ordinary calls. Forced ETH was tested
separately and violates the assignment's literal zero-balance requirement: force
one wei into the collection, buy rock 10, and one wei remains. This EVM/specification
limitation is reported in the requested `.imd-findings.json`, including a
self-contained failing Foundry proof. The old test that asserted retained forced
ETH as correct was removed. The failing proof is not part of the passing suite;
restore its source from the report to a scratch test file to reproduce it.

SVG parsing and tint checks do not establish artistic originality; that remains
a visual review criterion.
