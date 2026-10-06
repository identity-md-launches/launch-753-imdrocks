# IMDRocks

An immutable ERC-721 collection of 100 original, fully on-chain rocks. The only application contract is [`src/IMDRocks.sol`](src/IMDRocks.sol). Its name and symbol are source constants: `IMDRocks` / `IMDROCK`.

## Build and check

```sh
forge build
forge test
forge fmt --check
```

Foundry and Solidity **0.8.26** must be installed. `foundry.toml` pins the compiler, the Paris EVM target, optimization at 200 runs, and `bytecode_hash = "none"`. FFI and filesystem cheatcode permissions are disabled. Tests require no network, RPC, wallet, environment configuration, or files in `test/scratch/`.

OpenZeppelin Contracts **v5.0.2** (the required source dependency closure) and forge-std **v1.9.7** are ordinary vendored files under `lib/`, including their licenses. There are no submodules or package-install steps. [`lib/DEPENDENCIES.json`](lib/DEPENDENCIES.json) records upstream URLs, release tags, archive hashes, and per-file SHA-256 checksums. The compiler and Foundry are toolchain prerequisites, not repository dependencies.

## Deployment parameters

Deploy `IMDRocks(address reserveAndPayout)` with **zero ETH**, passing exactly:

```text
0xE89eB4D7153958F9436E2c3fe30D6F2024404cB0
```

[`launch.json`](launch.json) contains this static constructor argument. The argument is deliberately configurable so deployment can happen through the project factory; the constructor never uses `msg.sender` as beneficiary. Zero and the collection's own address are rejected. Production must use the address above; other addresses in tests are adversarial fixtures.

The constructor mints rocks 0–9 to that address with ten individual `Transfer` events. It also stores that address as immutable `payout`. Reserve minting uses `_mint`, with no receiver callbacks during construction. The deployer must confirm the reserve can control its NFTs and receive ETH, particularly if it is a contract account. Contract buyers in the public sale must implement `IERC721Receiver`.

There are no initialization calls, keys, deployment transactions, or broadcast scripts in this project. The deployment operator is responsible for confirming the target chain, beneficiary, factory arguments, deployment gas, and source/bytecode verification. No target chain was supplied, so beneficiary code and wallet control have not been verified on a live chain.

## Sale and transfer behavior

`nextRock()` and `totalSupply()` start at 10. The former is the next token on sale; the latter is the number minted so far. Both reach 100 at sellout. `MAX_SUPPLY()` is always 100. There is no burning or additional mint entry point.

For numbers 0–99:

```text
priceOf(n) = 10,000,000,000,000 × (1 + n²) wei
```

Rock 10 costs 0.00101 ETH; rock 99 costs 0.09802 ETH. Selling all 90 public rocks forwards a total of **3.28155 ETH**. `priceOf` rejects numbers outside 0–99, including at sellout; it remains readable for sold rocks.

Call payable `buy()` with exactly the current price. It returns the minted number, advances the counter, safely mints to the caller, then forwards all `msg.value` to `payout`. A receiver failure or payout failure reverts the entire purchase, including payment, ownership, and the counter. A reentrancy guard covers both callbacks. A payout contract that persistently rejects ETH stops subsequent sales; there is no authority that can replace it.

Each call buys one rock. Repeated calls from the same wallet are allowed. There is no number argument: buyers cannot skip, select, or repurchase an existing rock. Since prices strictly increase, a stale transaction submitted at the prior price reverts if another buyer purchases first. Transaction ordering still determines who gets each rock.

Transfers and approvals use plain OpenZeppelin ERC-721 semantics, with ERC-165 and metadata support. There is no transfer fee, transfer limit, royalty, enumerable extension, owner, admin, pause, upgrade, price setter, or payout setter. The reserve has ordinary ownership rights over its ten NFTs and receives sale proceeds; it has no collection-level privileges.

## Art and metadata

`imageOf(n)` returns raw SVG for any number 0–99, including unminted rocks. The original hand-drawn geometry uses a square `0 0 400 400` viewBox, flat cream background, ground shadow, irregular boulder outline, shaded facets, and small surface marks. It does not use an existing collection's image. Only one base fill changes: rock 0 is neutral `#929292`, and rocks 1–99 span 99 distinct hues around an RGB colour wheel. Shading, outline, and geometry are identical.

`tokenURI(n)` requires a minted token and returns base64 JSON containing:

- `name`: `IMDRock #<n>`;
- a one-line description;
- `image`: a base64 SVG data URI;
- `Number`: numeric token number, `Tint`: hex colour string, and `Price`: decimal ETH string with five fractional digits, such as `0.00101`.

The Price attribute describes the fixed sale formula, including for reserved rocks; reserve recipients did not pay it. Metadata is generated entirely from contract code and token number, with no server, IPFS, external contract, or mutable URI. Transfers do not change it.

## ETH assumption and operations

Successful ordinary purchases leave the collection with zero ETH when its balance started at zero. Direct ETH transfers and unknown calls revert: there is no `receive`, fallback, or withdrawal function.

**An absolute zero-balance guarantee is impossible on the EVM.** ETH can be forced in by another contract's `SELFDESTRUCT`, sent to a predicted address before deployment, or credited by protocol mechanisms without calling the recipient. Forced ETH is not a purchase and remains unrecoverable here. A test demonstrates this explicitly; future purchases still forward exactly their own payment. The application itself contains no `SELFDESTRUCT`.

After deployment, no administration, keeper, oracle, metadata hosting, or settlement service is required. The beneficiary maintains its wallet and ETH-receiving capability; buyers supply the current exact price. There is no operator recovery mechanism. The deployment operator should arrange an independent adversarial review before release; these local checks are not an independent audit. See [`docs/SECURITY_REVIEW.md`](docs/SECURITY_REVIEW.md) for attempted attacks and validation scope.
