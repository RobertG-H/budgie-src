# Operating Budgie

Budgie has no admin pages. Invites, users, currencies and new months are rake tasks, run either against your local
development database or against a deployed host through Kamal.

| | Locally | On a host |
| --- | --- | --- |
| How | `docker compose run --rm web bin/rails <task>` | `docker compose run --rm kamal task <task> -d <destination>` |
| Destination | Your development database | `-d testing` or `-d production` |

The `task` alias runs `bin/rails` in the running app container, so every task below works the same way in
both places. The examples use `-d production`; swap in `-d testing` for the other host.

## Invites

Only invited email addresses can create an account. Google proves who someone is, and a pending invite for
that exact address lets their first sign-in create their Budgie user. The address is compared after
trimming and lowercasing only, so Gmail dot and plus aliases don't match.

| Task | Command |
| --- | --- |
| Invite someone and email them | `bin/rails invite:create EMAIL=someone@example.com` |
| Send a pending invite again | `bin/rails invite:resend EMAIL=someone@example.com` |
| Revoke a pending invite | `bin/rails invite:revoke EMAIL=someone@example.com` |
| List invites | `bin/rails invite:list`, optionally with `STATUS=pending`, `accepted` or `revoked` |

Each prints what it did, or exits non-zero with the reason it refused. On a host, the same tasks read:

```sh
docker compose run --rm kamal task invite:create EMAIL=someone@example.com -d production
docker compose run --rm kamal task invite:list -d production
```

The same operations are available in a Rails console as `Invite.issue!`, `Invite.resend!` and
`Invite.revoke!`.

### The rules

- An invite is **pending** until its address signs in for the first time, when it becomes **accepted**.
  Pending invites never expire.
- `invite:create` refuses an address with a pending invite (use `invite:resend`) and an address that's
  already a user. For a revoked address it invites them again, as if newly invited.
- Only pending invites can be revoked. Revoking doesn't remove an existing user's access;
  [delete the user](#deleting-a-user) instead.
- Invites are only checked when an account would be created, so existing users sign in whatever their
  invite's state.

### The invite email

The invite email links to the sign-in page and asks the person to sign in with that exact address.
In development it isn't delivered — read it at http://localhost:3000/letter_opener. See [Email](email.md)
for how it's sent from a host, and for what a delivery failure looks like.

## Deleting a user

```sh
docker compose run --rm web bin/rails user:delete EMAIL=someone@example.com
docker compose run --rm kamal task user:delete EMAIL=someone@example.com -d production
```

The task shows what it will delete and asks you to type the email to confirm. It permanently deletes the
user, their identities, their sessions (which signs them out), their budget with its envelopes, Deposits and Assigned amounts, and their
invite — so the address can be invited again with `invite:create`. That makes it the easy way to test the
invite flow with an account you've already signed in with.

## Changing a budget's currency

There's no page for this, and it's the only way to change a currency:

```sh
docker compose run --rm web bin/rails budget:currency EMAIL=someone@example.com CURRENCY=USD
docker compose run --rm kamal task budget:currency EMAIL=someone@example.com CURRENCY=USD -d production
```

The task shows the current and new currency and asks you to type the email to confirm. **Amounts aren't
converted**: every amount keeps its number and is shown in the new currency. The supported currencies are
listed in `Budget::CURRENCIES`.

## Starting new months

Each month starts with the previous month's Assigned amounts. A job does this every hour, so a month begins within an
hour of midnight Eastern on the 1st, and a run that was missed is made up by the next one. You normally never run it
yourself, but you can, to try the copy in development (where recurring tasks don't run) or if the job on a host stops:

```sh
docker compose run --rm web bin/rails budget:start_months
docker compose run --rm kamal task budget:start_months -d production
```

It starts the new months of every budget that's behind and prints how many that was, or says that none had a month to
start. Running it again does nothing, because each month is copied into once: an amount a user cleared or changed after
their month began stays as they left it. A month begins by `config.time_zone`, so the task only does something once
midnight Eastern on the 1st has passed.

## Reaching a running host

The other Kamal aliases, all of which need `-d testing` or `-d production`:

| Alias | What it does |
| --- | --- |
| `console` | Opens a Rails console in the running app container |
| `logs` | Follows the app's logs |
| `dbc` | Opens `psql` on the primary database. It asks for that destination's database password rather than printing it |
| `shell` | Opens `bash` in the running app container |

```sh
docker compose run --rm kamal logs -d production
docker compose run --rm kamal console -d production
```

`user:delete` and `budget:currency` ask you to type the email to confirm, which is why the `task` alias is
interactive.

## A caution about production

Production's database lives on the VPS's own disk and nowhere else: there are no backups and no restore
drill yet. Only invite people who know that. See [Deploying](deployment.md).
