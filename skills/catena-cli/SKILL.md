---
name: catena-cli
description: >-
  Operate a Catena Bank agent from the command line — link a profile to an agent
  with `catena-cli`, inspect policy/accounts/counterparties, and request sends,
  transfers, balance reads, or counterparty creation through the policy engine.
  Use when an AI agent needs to move USD for a Catena customer, check balances,
  create counterparties, or follow an intent to a terminal state.
metadata:
  version: "0.0.1"
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

## Read Commands

Run the relevant reads before composing money movement:

```bash
npx -y catena-cli whoami
npx -y catena-cli policy show
npx -y catena-cli accounts list
npx -y catena-cli counterparties list
```

- `policy show`: read which actions are allowed for each account, plus caps,
  approval thresholds, counterparty creation rules, and any limits on which
  counterparties can receive sends. Do not work around policy.
- `accounts list`: use returned `acct_…` ids for `--account`, `--from`, and
  `--to`.
- `counterparties list`: required for sends; use returned rail ids (`cprl_…`),
  not counterparty ids, for `send --rail`.

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
`--network`. Optional: `--email`.

## Intents

Intents are the only way the agent reads or moves money. Terminal statuses:
`completed`, `denied`, `blocked`, `failed`, `expired`. Treat `pending_approval`
as terminal-for-the-agent; only an operator can move it forward. Re-check later
with `intents get`.

Intent `reasons` explain policy decisions. Summarize them in plain language when
an intent is blocked, denied, or routed to approval.

USD is the only supported asset. Pass `--amount` as a decimal string such as
`100.50`; do not use scientific notation or signed values.

Before `send` or `transfer`:

- Confirm the user explicitly provided amount and destination details.
- Run `policy show`; do not bypass caps or approval thresholds.
- Use ids from `accounts list` and `counterparties list`.
- Prefer `--wait` unless the user asked for fire-and-follow-up.
- Do not retry ambiguous movement unless `intents get` confirms failure or
  denial.

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

Requests a balance through the policy engine.

```bash
npx -y catena-cli accounts balance acct_…
```

The completed balance result is on `.data`.

### `intents get`

```bash
npx -y catena-cli intents get int_…
```

Use this for `pending_approval`, timeout, or no-`--wait` follow-up.

## Wait And Exit Codes

Without `--wait`, `send` and `transfer` print the created intent and exit 0 even
if the intent later fails. Inspect `.status` and `.reasons`.

With `--wait`, the CLI polls for up to 60 seconds, prints the latest intent, and
exits:

| Exit | Meaning                                           |
| ---- | ------------------------------------------------- |
| `0`  | `completed`                                       |
| `1`  | `denied`, `blocked`, `failed`, or `expired`       |
| `2`  | still in-flight at timeout, or `pending_approval` |

## Configuration

| Variable         | Purpose           | Default                  |
| ---------------- | ----------------- | ------------------------ |
| `CATENA_API_URL` | Bank API base URL | `https://api.catena.com` |

## Scripting

When chaining commands, parse stdout as JSON rather than scraping text:

```bash
ACCT=$(npx -y catena-cli accounts list | jq -r '.[0].id')
RAIL=$(npx -y catena-cli counterparties list | jq -r '.[0].rails[0].id')
npx -y catena-cli send \
  --account "$ACCT" --rail "$RAIL" --amount 10.00 --method ach --wait
```

Every command supports `--help`:

```bash
npx -y catena-cli --help
npx -y catena-cli send --help
npx -y catena-cli counterparties create --help
```
