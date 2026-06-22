---
name: catena-cli
description: >-
  Operate a Catena Bank agent from the command line — link a profile to an
  existing agent (or create a new one) with `catena-cli`, inspect
  policy/accounts/counterparties, and request sends, transfers, balance reads,
  or counterparty creation through the policy engine. Use when an AI agent needs
  to move USD for a Catena customer, check balances, read transaction history,
  get a deposit address, create counterparties, or follow an intent to a
  terminal state.
metadata:
  version: "0.0.4"
---

# Catena Bank Agent CLI

Catena gives an agent its own customer-approved bank identity. Once linked, the
agent requests governed operations that the policy engine evaluates, may route
to human approval, and may execute against the customer's accounts. Governed
operations — money movement and counterparty creation — return an intent
envelope; use the returned intent id for follow-up.

Invoke the Catena CLI:

```bash
npx -y catena-cli <command> [args]
```

Published as both `catena-cli` and `catena` (same binary; `--help` shows the
program name as `catena`). Every non-`link` command resolves credentials from
the selected profile and prints pretty JSON on stdout; errors go to stderr.

Every command supports `--help` — use it for the exact flags, choices, and
defaults rather than guessing. This skill covers what `--help` can't: when to
run each command, how ids flow between them, and how to read the results.

## Setup

1. Run `npx -y catena-cli whoami`. If it returns an agent, you're linked —
   continue.
2. Otherwise `link`. There are three flows:
   - **Link an existing agent** on the customer's own machine: ask the customer
     for the agent id (`agent_…`) shown in the Catena console, then run
     `link <agent-id>`. A browser opens for approval (~5-minute window) and
     writes the profile on success.
   - **Create a new agent**: run `link` with *no* agent id. The CLI starts a
     console approval flow and prints a verification URL and short code — relay
     both to the customer to approve in the Catena console. Add `--name "…"` to
     suggest a name for the new agent (only valid when no agent id is given; the
     approving operator can still edit it).
   - **Remote or headless**: `link <agent-id> --no-browser` (or any headless
     host, automatically) uses the same device-code flow — relay the printed URL
     and code and keep the command running until the customer approves from
     their own device. The printed prompt includes the expiry.

`--bank-url` defaults to `$CATENA_API_URL` or prod; `--profile` defaults to the
configured default. Re-run `link` after timeout, denial, or revocation — and
also if a `send`/`transfer` fails with a local-signer error (no registered
signer, or a signer public-key mismatch).

`npx -y catena-cli unlink` disconnects the selected profile (add `--profile
<name>` to target another).

### Profiles

One machine can hold several linked agents, each a named profile. Any command
takes `--profile <name>`; without it the default is used. Manage with `profiles
current | list | use <name>` — `use` sets the default and the profile must
already be linked.

## Reads before money movement

Run the reads first: they give you the ids every send/transfer needs and the
policy you must not work around.

- `policy show` — `policyCapabilities[]` grant per-account `read`/`send`/
  `transfer` capabilities (legacy responses may say `query_balance`) with
  block/approval `rules`; `counterpartyRules` scope send recipients and
  counterparty creation. Do not work around policy.
- `accounts list` — accounts under `.accounts[]`; each `id` (`acct_…`) feeds
  `--account`, `--from`, `--to`.
- `counterparties list` — under `.counterparties[]`, each with `rails[]`. A
  `send` targets a **rail id (`cprl_…`)**, not the counterparty id, via
  `--rail`.

Three direct per-account reads — plain reads, not intents:

- `accounts balance acct_…`
- `accounts transactions acct_…` — `.transactions[]` (newest-first) plus a
  `.total` count; page with `--limit`/`--offset`. A transaction's `status` is
  its own enum (`pending|processing|completed|failed|reversed`), distinct from
  intent status — use it to confirm a movement actually settled.
- `accounts deposit-address acct_…` — the account's on-chain funding address on
  `.address`. Use it when the user needs to deposit funds.

## Counterparties

Create counterparties only when `counterpartyRules` allow it. `counterparties
create` takes the rail as a **positional** (`bank` or `wallet`) followed by
flags — there are no `create bank` / `create wallet` subcommands. Every flag for
both rails appears on the single `counterparties create --help` screen, and that
help marks only the rail and `--name` as required even though each rail needs
more. Pass the full set below; missing required flags fail one at a time.

- **bank** — all required: `--name`, `--bank-name`, `--routing-number`,
  `--account-number`, and the four address parts `--address-street`,
  `--address-city`, `--address-state`, `--address-postal-code`. Optional:
  `--account-type checking|savings` (default checking), `--address-country`
  (default USA), and `--email`.
- **wallet** — required: `--name` and `--address` (a `0x…` address or an ENS
  name). Optional: `--network` (defaults to `base`, the only network today) and
  `--email`.

```bash
npx -y catena-cli counterparties create bank --name "Acme Inc" \
  --bank-name "First Bank" --routing-number 123456789 \
  --account-number 000123456 --address-street "123 Main St" \
  --address-city "New York" --address-state NY --address-postal-code 10001
npx -y catena-cli counterparties create wallet --name "Acme Wallet" \
  --address 0xAbC0000000000000000000000000000000000000
```

Both return an intent envelope. On `completed` the new counterparty — with its
`rails[].id` for a follow-up `send` — is on `.data.counterparty`. Creation
routed to approval is `pending`; re-check with `intents get`.

## Money movement

`send` submits a USD send to a counterparty rail; `transfer` moves USD between
two of the agent's own accounts. Both run through the policy engine.

Before either:

- Confirm the user explicitly provided the amount and destination details.
- Run `policy show`; do not bypass caps or approval thresholds.
- Use ids from `accounts list` and `counterparties list`.
- USD only. Pass `--amount` as a plain decimal string (`100.50`) — no
  scientific notation, no signed values.
- Do not retry an ambiguous movement unless `intents get` shows it `blocked` or
  `failed`.

```bash
npx -y catena-cli send --account acct_… --rail cprl_… --amount 125.00 --method ach
npx -y catena-cli transfer --from acct_… --to acct_… --amount 125.00
```

`--method` is `ach|wire|on-chain`. See `--help` for `--memo`/`--description`.

Both **create the intent and return immediately** — there is no wait/poll flag.
The command exits `0` once the intent is submitted **even if the intent is later
blocked, pending, or failed**. Always read `.status` and `.reasons` on the
returned envelope, then follow up with `intents get <id>` for anything not
already `completed`.

## Intents

Money movement and counterparty creation return intents (balance, transaction,
and deposit-address reads do not). `.status` is always one of these simplified
values:

| `.status`    | Meaning                                          | Terminal?          |
| ------------ | ------------------------------------------------ | ------------------ |
| `completed`  | Succeeded.                                        | yes                |
| `blocked`    | Stopped by policy (incl. denied).                 | yes                |
| `failed`     | Execution failed (incl. expired).                 | yes                |
| `pending`    | Awaiting approval; only an operator advances it.  | terminal-for-agent |
| `processing` | Accepted, still in flight.                        | no — re-check      |

Raw `denied`/`expired`/`pending_approval` fold into `blocked`/`failed`/`pending`
— match the simplified values, never the raw strings. `reasons` (string array)
explains the decision; summarize it when an intent is blocked or routed to
approval.

`npx -y catena-cli intents get int_…` re-reads an intent's current state. Its
`.data` carries the result once one exists — the linked transaction for
`send`/`transfer`, or the created counterparty for creation — and is `null`
when there is none yet.

## Output, exit codes, and scripting

stdout is JSON — parse it rather than scraping text. Every credentialed command
accepts `--json` for compact single-line output, and `catena --version` prints
the CLI version.

Every credentialed command exits `0` after printing its JSON result, or `1` on
error (message to stderr). **The exit code reflects whether the command ran, not
an intent's policy outcome** — a submitted-but-blocked `send` still exits `0`,
so read `.status` and `.reasons`.

`CATENA_API_URL` overrides the bank API base URL (defaults to
`https://api.catena.com`).

## Feedback

If the CLI fights you — a confusing error, a missing capability, an operation
you needed but couldn't express — tell the Catena team:

```bash
npx -y catena-cli feedback "Plain-text message (max 4000 chars)"
```

The message must be 1–4000 characters and is write-only. Longer messages can be
piped on stdin instead of passed as an argument.
