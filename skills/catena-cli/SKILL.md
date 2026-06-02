---
name: catena-cli
description: >-
  Operate a Catena Bank agent from the command line — link a profile to an agent
  with `catena-cli`, inspect policy/accounts/counterparties, and request sends,
  transfers, balance reads, or counterparty creation through the policy engine.
  Use when an AI agent needs to move USD for a Catena customer, check balances,
  create counterparties, or follow an intent to a terminal state.
metadata:
  version: "0.0.2"
---

# Catena Bank Agent CLI

Catena gives an agent its own customer-approved bank identity. Once linked, the
agent requests governed operations that the policy engine evaluates, may route
to human approval, and may execute against the customer's accounts. Governed
operations return intent envelopes; use the returned intent id for follow-up.

Invoke the Catena CLI:

```bash
npx -y catena-cli <command> [args]
```

Every non-`link` command resolves credentials from the selected profile and
prints pretty JSON on stdout. Errors go to stderr.

## Setup

Before using the CLI:

1. Run `npx -y catena-cli whoami`. If it returns an agent, continue.
2. If not linked, get the agent id (`agent_…`) from the user. The customer must
   create or choose the agent in the Catena console; do not invent a signup or
   agent-creation command.
3. Run `npx -y catena-cli link <agent-id>`. A browser opens for customer
   approval and writes the selected profile on success.

`link` flags: `--bank-url <url>` defaults to `$CATENA_API_URL` or prod;
`--profile <name>` defaults to the configured default profile or `default`. The
browser approval window lasts 5 minutes. Re-run `link` after timeout, denial, or
revocation.

Use `npx -y catena-cli unlink --profile <name>` to disconnect only the selected
local profile and remove its credential. `--profile` defaults the same way as
other commands.

### Profiles

One machine can hold several linked agents. Any command takes `--profile
<name>`; without it the default is used.

```bash
npx -y catena-cli profiles current    # selected profile + its bankUrl/agentId
npx -y catena-cli profiles list       # all profiles; marks the default
npx -y catena-cli profiles use <name> # set the default (must be linked)
```

## Read Commands

Run the relevant reads before composing money movement:

```bash
npx -y catena-cli whoami
npx -y catena-cli policy show
npx -y catena-cli accounts list
npx -y catena-cli counterparties list
```

- `policy show`: `policyCapabilities[]` each grant one `query_balance`, `read`,
  `send`, or `transfer` capability on one account, with block/approval `rules`
  (per-transaction and time-windowed amount/count caps). `counterpartyRules`
  sets send-recipient scope (`open`/`restricted`, `allowedCounterparties`) and
  whether the agent may create counterparties. Do not work around policy.
- `accounts list`: under `.accounts[]`; use each `id` (`acct_…`) for
  `--account`, `--from`, `--to`.
- `counterparties list`: required for sends. Under `.counterparties[]`, each
  with `rails[]`. Use a rail `id` (`cprl_…`), not the counterparty id, for
  `send --rail`.

## Counterparties

Create counterparties only when policy allows it.

```bash
npx -y catena-cli counterparties create bank \
  --name "Acme Vendor" \
  --bank-name "Chase" \
  --routing-number 021000021 \
  --account-number 123456789 \
  --address-street "123 Main St" \
  --address-city "New York" \
  --address-state NY \
  --address-postal-code 10001
```

`counterparties create bank` required flags: `--name`, `--bank-name`,
`--routing-number`, `--account-number`, `--address-street`, `--address-city`,
`--address-state`, `--address-postal-code`. Optional:
`--account-type checking|savings`, `--address-country`, `--email`.

```bash
npx -y catena-cli counterparties create wallet \
  --name "DAO Treasury" \
  --address 0xAbC123... \
  --network base
```

`counterparties create wallet` required flags: `--name`, `--address`,
`--network` (only `base` today). Optional: `--email`.

Both return an intent envelope; on `completed` the new counterparty (with its
`rails[].id` for a follow-up `send`) is on `.data.counterparty`. Creation routed
to approval is `pending` — re-check with `intents get`.

## Intents

Intents move money and create counterparties (balance reads do not — see
`accounts balance`). `.status` is always one of these simplified values:

| `.status`    | Meaning                              | Terminal?          |
| ------------ | ------------------------------------ | ------------------ |
| `completed`  | Succeeded.                           | yes                |
| `blocked`    | Stopped by policy (incl. denied).    | yes                |
| `failed`     | Execution failed (incl. expired).    | yes                |
| `pending`    | Awaiting human approval.             | terminal-for-agent |
| `processing` | Accepted, still in flight.           | no — re-check      |

Raw `denied`/`expired`/`pending_approval` fold into `blocked`/`failed`/`pending`
— never match the raw strings. `pending` is terminal-for-the-agent (only an
operator advances it). Re-check `processing` (and later `pending`) with `intents
get`. `reasons` (string array) explains the decision — summarize it when an
intent is blocked or routed to approval.

USD is the only supported asset. Pass `--amount` as a decimal string such as
`100.50`; do not use scientific notation or signed values.

Before `send` or `transfer`:

- Confirm the user explicitly provided amount and destination details.
- Run `policy show`; do not bypass caps or approval thresholds.
- Use ids from `accounts list` and `counterparties list`.
- Prefer `--wait` unless the user asked for fire-and-follow-up.
- Do not retry ambiguous movement unless `intents get` confirms a `blocked` or
  `failed` status.

### `send`

```bash
npx -y catena-cli send \
  --account acct_… \
  --rail cprl_… \
  --amount 125.00 \
  --method ach
```

Required: `--account`, `--rail`, `--amount`, `--method ach|wire|on-chain`.
Optional: `--memo`, `--description`, `--wait`.

### `transfer`

```bash
npx -y catena-cli transfer \
  --from acct_… \
  --to acct_… \
  --amount 125.00
```

Required: `--from`, `--to`, `--amount`. Optional: `--memo`, `--description`,
`--wait`.

### `accounts balance`

A direct read, not an intent (no `--wait`). Returns `{ "accountId": …,
"balance": … }`.

```bash
npx -y catena-cli accounts balance acct_…
```

### `intents get`

```bash
npx -y catena-cli intents get int_…
```

Use this for `pending_approval`, timeout, or no-`--wait` follow-up.

## Wait And Exit Codes

Without `--wait`, `send` and `transfer` print the created intent and exit 0 even
if the intent later fails. Inspect `.status` and `.reasons`.

With `--wait`, the CLI polls while `processing` (1s interval, 60s max), prints
the latest intent, and exits. A `pending` intent returns immediately, not at
timeout.

| Exit | `.status`                                       |
| ---- | ----------------------------------------------- |
| `0`  | `completed`                                     |
| `1`  | `blocked` or `failed`                           |
| `2`  | `pending`, or still `processing` at 60s timeout |

## Configuration

| Variable         | Purpose           | Default                  |
| ---------------- | ----------------- | ------------------------ |
| `CATENA_API_URL` | Bank API base URL | `https://api.catena.com` |

## Scripting

When chaining commands, parse stdout as JSON rather than scraping text:

```bash
ACCT=$(npx -y catena-cli accounts list | jq -r '.accounts[0].id')
RAIL=$(npx -y catena-cli counterparties list | jq -r '.counterparties[0].rails[0].id')
npx -y catena-cli send \
  --account "$ACCT" --rail "$RAIL" --amount 10.00 --method ach --wait
```

Every command supports `--help`:

```bash
npx -y catena-cli --help
npx -y catena-cli send --help
npx -y catena-cli counterparties create --help
```
