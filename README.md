# Irreversible Monkey Dinasty (MONKEY)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum (chain id 1).

| Field | Value |
| --- | --- |
| Solidity contract | `MonkeyToken` (`src/MonkeyToken.sol`) |
| `name()` | `Irreversible Monkey Dinasty` |
| `symbol()` | `MONKEY` |
| `decimals()` | 18 |
| Total supply | 67,676,767 MONKEY = `67676767000000000000000000` minor units |
| Constructor arguments | none |
| Minted to | `msg.sender` of the constructor, once, in full |
| Standards | ERC-20, ERC-2612 `permit`, holder-only `burn` / allowance-gated `burnFrom` |

The token name is spelled exactly as requested ("Dinasty"); it is not corrected to "Dynasty".

## Behaviour

- The constructor mints the entire supply to the deployer. On the launch, the deployer is
  `ProjectFactory`, which then pays the supply out: 10% to the launch's MerkleDistributor, 84% to
  seed the single-sided Uniswap v4 pool paired with IMD, and the remaining 6% to the requester's
  `remainderTo` address.
- There is no mint function, no owner, no admin role, no pause, no blocklist, no upgrade path,
  and no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in the runtime. Supply can never grow.
- Transfers move exactly the amount sent. No fee, tax, reflection or burn-on-transfer.
- Holders may burn their own tokens. `burnFrom` only spends an allowance the holder granted.
  Burning is the only way the supply changes, and only downward.
- `permit` (ERC-2612) lets holders approve a spender with a signature; the EIP-712 domain name is
  the token name and the version is `1`.

## Assumptions

- The brief asks for a plain token with no transfer rules, so none are implemented. Adding a tax,
  reflection, vesting or governance later would require a new contract; this one is immutable.
- "Deployer" means the constructor's `msg.sender`. The launch deploys through the factory with
  CREATE2, so the factory receives the supply, which is what the launch floor requires.
- The constructor takes no arguments and calls no other contract, so it deploys on an empty chain
  and needs none of the optional `$factory` / `$poolManager` / `$launchNumber` exemptions: there is
  nothing to exempt because every transfer already moves the full amount.
- The launch pool parameters (IMD pair at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, fee 12500,
  tick spacing 60, 84% pool share, 2,710 IMD opening market cap, remainder to
  `0x70bcBDE387539d95ffE6d43EDBf7C6AA2dA87A09`) are the launch's and the manifest step's. The token
  itself has no knowledge of them and no `launch.json` is written here.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Compiler | solc 0.8.26, optimizer on, 200 runs, EVM `cancun`, `bytecode_hash = "none"`, `cbor_metadata = false` |
| Constructor arguments | none |
| Expected `totalSupply()` | `67676767000000000000000000` |
| Expected `decimals()` | 18 |
| Runtime size | about 4.1 KB (limit 24,576 bytes) |

`script/DeployMonkeyToken.s.sol` is a reviewable reference deployment for dry runs or testnets. Its
`deploy()` function is what the tests call; `run()` only wraps it in a broadcast and reads no
environment variables. The IdentityMD launch does not use this script: the factory deploys the
token from the built bytecode. Example dry run:

```bash
forge script script/DeployMonkeyToken.s.sol --rpc-url <RPC>            # simulate only
forge script script/DeployMonkeyToken.s.sol --rpc-url <RPC> --broadcast # a real deployment
```

This assignment holds no keys and broadcasts nothing.

## After launch

There is nothing to configure. The token has no setters and no owner. Operational items that
belong to the launch's deployer rather than to this repository:

- Verify the source on the block explorer after deployment (`forge verify-contract` with the
  settings above, no constructor arguments).
- Confirm on chain that `totalSupply()` equals the manifest supply and that the factory held it all
  before paying it out.

## Operational responsibilities

- Nobody can recover tokens sent to a wrong address, including the token contract itself.
  There is no admin to call. Holders are responsible for their own transfers and approvals.
- Because nothing can pause or freeze transfers, there is no incident response lever on the
  token. Any problem with the pool or distributor has to be handled in those contracts.
- Tests passing is not a security audit. The token is OpenZeppelin v5.4.0 `ERC20`,
  `ERC20Burnable` and `ERC20Permit` with no custom logic beyond the constructor mint, which keeps
  the review surface small, but an independent adversarial review before release is still the
  launch policy.

## Security checklist outcome

Checked against the pinned eth-security reference:

- Access control: no privileged functions exist, so there is nothing to restrict.
- Reentrancy: the token makes no external calls.
- Decimals: 18, stated in the constants and the tests.
- Return values: `transfer`, `transferFrom` and `approve` return `true` or revert.
- Input validation: zero-address receivers and spenders revert (OpenZeppelin errors).
- Events: `Transfer` on mint, transfer and burn; `Approval` on approve and permit.
- EIP-712 replay safety: permit uses a nonce, a deadline and a chain-bound domain separator.
- No proxies, no delegatecall, no selfdestruct, no infinite approvals granted by the contract.
- Tools run: `forge build`, `forge test` (31 tests, including a 256-run fuzz test) and
  `forge fmt --check`. Slither and Mythril were not available in this environment.

## Layout

```
foundry.toml                     compiler pins and profile (solc 0.8.26, bytecode_hash none)
remappings.txt                   forge-std and @openzeppelin/contracts
src/MonkeyToken.sol              the token
script/DeployMonkeyToken.s.sol   reference deploy script
test/MonkeyToken.t.sol           success and failure tests
lib/forge-std/                   vendored forge-std 1.17.0 (plain files, no submodule)
lib/openzeppelin-contracts/      vendored OpenZeppelin Contracts 5.4.0 (plain files, no submodule)
```

Dependencies are committed as ordinary files so the project builds with no network.

## Commands

```bash
forge build
forge test
forge fmt --check
```
