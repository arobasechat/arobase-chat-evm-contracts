# arobase.chat — EVM contracts

Solidity contracts and deployment tooling for [arobase.chat](https://arobase.chat), a decentralized, censorship-resistant social network that runs on several EVM chains, with no backend.

## Architecture

| Role | Default chain | Contracts |
|---|---|---|
| **Social** (likes, follows, roles, usernames, config) | Gnosis (100) | `Registry`, `Social`, `Stake`, `Names`, `PushRelays`, `Media`, `Vault`, `Paymaster` |
| **Content** (posts, comments, notes, direct messages), indexed | Arc (5042) | `Content`, `Inbox`, `Paymaster` |
| **Anchoring** (optional permanent copies), not indexed | Base (8453, sponsored), Arbitrum, Polygon | `Content`, `Inbox` (+ `Paymaster` on Base) |

- **`Content`**: signed messages (posts, comments, notes, profiles, reposts, retractions, poll votes). It indexes hashtags, mentions, notifications (`Notify`), reposts, quotes and polls. Indexing can be turned off per chain (`setIndexing`).
- **`Social`**: batched signed actions (react, follow, moderation votes, encryption keys, community-note ratings, roles), with a stake-weighted moderation vote. The hide score is computed with each voter's current weight, so withdrawing a stake withdraws its influence.
- **`Registry`**: the instance configuration (chains, RPCs, JSON parameters), read by the front at startup.
- **`Inbox`**: end-to-end encrypted conversations. Invites carry no recipient (members find theirs by trial decryption), and messages are indexed by a tag that rotates every 4,096 blocks and is derived from the conversation key, so the chain shows neither who talks to whom nor which messages belong together. Apps send them from a throwaway sponsored account.
- **`Vault`**: per-user encrypted blobs, such as bookmarks and mute/block lists synced across devices. Writes are signed with EIP-712 (`Save`).
- **`Names`**: unique usernames, claimed with a signature.
- **`PushRelays`**: registry of Web Push relays, plus encrypted subscriptions (see [arobase-chat-push-relay](https://github.com/arobasechat/arobase-chat-push-relay)).
- **`Media`**: images stored in event logs (content-addressed by `keccak256`). Only PNG, JPEG, WebP and GIF are accepted.
- **`Paymaster`**: an ERC-4337 (EntryPoint v0.8) paymaster. It sponsors only allow-listed calls made through the standard EIP-7702 account (`Simple7702Account`, set with `setAccount`), requires a proof of work tied to the operation, and enforces a daily budget and a per-sender quota. `Limits` cap the pre-verification gas (a base plus a per-byte allowance) and the priority fee, the two fields a bundler could inflate to pocket the difference; the gas limits themselves stay free for bundler estimation and are bounded by `maxCostPerOp`. Users never need gas.
- **`Stake`**: a refundable anti-spam deposit that gives weight to moderation votes. **Not upgradeable on purpose**, since it holds user funds; `Social.setStake` can point to a new one.

**Signatures.** Every message and action is EIP-712 signed by the author. The domain is `{ name: "arobase.chat", version: "1" }`, without chain id or verifying contract, so the same signed message is valid on every chain. Session keys sign on behalf of an identity through a signed delegation (138-byte signatures):
- a delegation is valid until its `expiry`, checked against the block time;
- `revoke(author, key, sig)` (on `Social` and on each `Content`) disables a session key at once. It takes a `Revoke` signature from the identity, or from the key itself, and uses no nonce, so a stolen key cannot front-run it. The same signature works on every chain, and `Vault` reads the revocations of `Social`;
- the encryption key, roles and usernames need the identity itself, not a session key;
- private messages use their own `Private` type, so they can never be published as posts.

### Upgradeability

Every contract except `Stake` and the `TimelockController` sits behind a UUPS proxy (ERC-1967). The owner of each proxy is the chain's timelock, and only the timelock can upgrade.

- Keep the storage layout **append-only**: never remove, reorder or retype state variables.
- The owner slot uses ERC-7201 namespaced storage (`src/base/Upgradeable.sol`).

## Requirements

- [Foundry](https://getfoundry.sh) 1.0+
- Node.js 22+ and pnpm 10+ (TypeScript tooling)

```bash
git clone --recursive https://github.com/arobasechat/arobase-chat-evm-contracts
cd arobase-chat-evm-contracts
pnpm install
```

If you cloned without `--recursive`, run `git submodule update --init --recursive`. The Solidity dependencies are pinned git submodules:
- OpenZeppelin Contracts v5.4.0
- eth-infinitism account-abstraction v0.8.0
- forge-std v1.17.0

## Build and test

```bash
pnpm build      # forge build
pnpm test       # forge test --evm-version prague (EIP-7702 needs Prague)
pnpm gen-abi    # abi/*.json + ABIs of the sibling front and relay repositories
```

## Local development

Clone the three app repositories side by side:

```
arobase-chat-evm-contracts/
arobase-chat-front/
arobase-chat-push-relay/
```

```bash
pnpm dev                                 # in arobase-chat-evm-contracts
cd ../arobase-chat-front && pnpm dev     # http://localhost:5173
```

`pnpm dev`:
- starts 3 anvil chains (social, content, anchoring);
- deploys everything with the same code path as production;
- starts 3 ERC-4337 bundlers (Alto) on ports 4337 to 4339;
- seeds demo data, then starts a local push relay if `arobase-chat-push-relay` is present;
- writes the front's `.env.local` and the relay's `config/local.json`.

Use `FRONT_DIR` and `RELAY_DIR` to point to other locations.

## Production deployment

The network plan lives in `tooling/networks.mainnet.json`:
- chains and roles;
- your own RPCs (`ownRpcs`, always listed first in the Registry);
- sponsoring per chain: stake, deposit, maximum cost per operation, daily budget, per-sender quota and bundlers;
- the timelock delay and the initial parameters.

```bash
read -rs DEPLOYER_PK && export DEPLOYER_PK   # typed silently, kept out of shell history and files
pnpm deploy:chains                 # prints the plan, balances and costs, then asks for confirmation
pnpm check mainnet
```

The script is idempotent: its state is saved in `tooling/deployments.mainnet.json`, and running it again resumes where it stopped. It does the following:
1. Deploys the content chains, then the social chain, with `script/Deploy.s.sol`.
2. Stakes and funds the paymasters.
3. Fills the Registry, then transfers it to the timelock.
4. Writes the front's `.env.production` and the relay's `config/mainnet.json`, if those repositories are cloned next to this one.

### After deployment

```bash
pnpm grant-role 0x<passkey address> admin
pnpm propose set-param platform '"0x<platform account>"'   # everyone follows it automatically
pnpm propose set-bundlers 100 https://bundler.example https://public.pimlico.io/v2/100/rpc
pnpm propose set-push-relays 0                             # push relays verified by the instance
pnpm propose refresh-rpcs 5042
pnpm propose update-delay 172800                           # 48 h timelock before upgrades
pnpm fund-paymaster 100 5                                  # anyone can fund a paymaster
```

`propose` goes through the timelock. With a delay above 0, run it again once the delay has passed to execute the operation; `--calldata` prints the transactions for a Safe instead.

### Upgrading a contract

```bash
pnpm upgrade-contract Content                 # every content chain
pnpm upgrade-contract Paymaster --chain 100
```

The script deploys the new implementation, then has the timelock call `upgradeToAndCall`. Addresses and data stay unchanged.

### Private RPCs

`tooling/rpcs.local.json` (ignored by git) lists private RPCs per chain id. The scripts try them first, but they are never published in the Registry.

## Layout

```
src/          contracts (src/base: upgradeable base, src/lib: EIP-712 signatures)
test/         Foundry tests
script/       Deploy.s.sol (one chain, social or content role), Upgrade.s.sol
tooling/      TypeScript deployment, governance and local stack
abi/          generated ABIs (JSON)
```

## Security

The contracts have not been audited. With a timelock delay of 0, the deployer key can upgrade every proxy immediately; raise the delay (`pnpm propose update-delay`) and move the proposer role to a multisig before relying on the instance.

## License

[Apache-2.0](LICENSE). Redistributions must keep the [NOTICE](NOTICE) file; please credit "arobase.chat" if you host a fork.
