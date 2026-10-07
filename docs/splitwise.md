# Splitwise setup

Budgie connects an Account to Splitwise, so that your share of each Splitwise expense can become a bank transaction there ([ADR 0016](adr/0016-splitwise-is-synced-as-an-account.md)).
People sign in to Splitwise from the Accounts page ("Connect Splitwise"), so each environment needs a Splitwise app of its own, and a pair of keys to keep the tokens under.
Without any of this, nothing breaks: "Connect Splitwise" and Reconnect just aren't offered.

Connecting isn't signing in to Budgie. That's still [Google](google-oauth.md).
Splitwise's API is for non-commercial use, which an invite-only personal budget is, and it may come to ask for a Splitwise Pro subscription.

This page is for the operator: Claude edits the config and these docs, and never generates, reads or handles a client secret, an encryption key or a token.
Once connected, **Sync now** on the Account's page and a job every hour bring each expense you're part of in as a bank transaction of your share ([Syncing](#5-check-syncing)); there's nothing more to set up for it.

- [1. Register a Splitwise app for each environment](#1-register-a-splitwise-app-for-each-environment)
- [2. Generate the encryption keys](#2-generate-the-encryption-keys)
- [3. Give the values to the app](#3-give-the-values-to-the-app)
- [4. Check it](#4-check-it)
- [5. Check syncing](#5-check-syncing)
- [Rotating and losing things](#rotating-and-losing-things)

## 1. Register a Splitwise app for each environment

Each environment has its own app, because an app takes one callback URL and Splitwise only sends people back to that exact address.
A wrong or missing callback fails after the person has signed in to Splitwise, so spell each one exactly as below.

| App | Callback URL |
| --- | --- |
| Budgie development | `http://localhost:3000/splitwise/callback` |
| Budgie testing | `https://testing.budgiebuddie.com/splitwise/callback` |
| Budgie production | `https://budgiebuddie.com/splitwise/callback` |

For each one:

1. Go to [secure.splitwise.com/apps](https://secure.splitwise.com/apps) and register a new application with that name.
2. Fill in a description and a homepage URL (the environment's own address), and the callback URL from the table.
3. Copy the app's **Consumer Key** and **Consumer Secret** from its details page. They're the client id and the client secret.
   The API key on that page is a different thing, a personal Bearer token, and Budgie doesn't use it.

Development's callback is `localhost`, not `127.0.0.1`, though Compose publishes the port on both: open http://localhost:3000 when you connect, or the host differs from the registered one.

## 2. Generate the encryption keys

A connection's token is kept encrypted, with Active Record encryption, under keys that Budgie reads from the environment, since credentials can't be edited from the repo.
Make one set for each destination, with `bin/rails db:encryption:init`:

```sh
docker compose run --rm web bin/rails db:encryption:init
```

It prints three values. Budgie needs two of them:

| Printed as | Variable |
| --- | --- |
| `primary_key` | `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` |
| `key_derivation_salt` | `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` |

The third, `deterministic_key`, is for a kind of encryption Budgie doesn't use. Leave it out.

**Put each set in your password manager before anything else.** A different key can't read what another wrote, so a lost one leaves every token under it unreadable.
That's recoverable, since a connection whose token can't be read can still be reconnected (see [Rotating and losing things](#rotating-and-losing-things)), but it's one more thing to do for every connection.
Development doesn't need a set: it falls back to fixed throwaway keys that are in the repo, which protect nothing. Testing and production have no fallback.

## 3. Give the values to the app

### Development

Put the development app's key and secret in `.env`, then restart the app:

```sh
SPLITWISE_CLIENT_ID=
SPLITWISE_CLIENT_SECRET=
```

Compose loads `.env` into the `web` container, and git ignores it.
Restart with `docker compose up` (or `docker compose restart web`), since the container reads its environment when it starts.
Add the two `ACTIVE_RECORD_ENCRYPTION_…` variables as well only if you want development's tokens under keys of your own.

### Testing and production

Each destination has four more secrets, named the same way as the others ([Deploying](deployment.md#the-secrets-on-your-laptop)):

| In `.env.testing` and the `testing` GitHub environment | In `.env.production` and the `production` GitHub environment |
| --- | --- |
| `TESTING_SPLITWISE_CLIENT_ID` | `PRODUCTION_SPLITWISE_CLIENT_ID` |
| `TESTING_SPLITWISE_CLIENT_SECRET` | `PRODUCTION_SPLITWISE_CLIENT_SECRET` |
| `TESTING_ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | `PRODUCTION_ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` |
| `TESTING_ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | `PRODUCTION_ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` |

Use the **Budgie testing** app's key and secret for testing and the **Budgie production** app's for production, and a separate set of encryption keys for each.
Put the same values in your password manager.
`.kamal/secrets-common` and `.kamal/secrets.<destination>` map these to the names the app reads, so there's nothing else to wire up.

Then deploy. Testing deploys on the next push to `main`, and production when you dispatch **Deploy production**.
A deploy before the values are set is harmless: the four arrive empty, and the app treats that as Splitwise not being set up.

## 4. Check it

Do this on each environment once its values are deployed. Claude can't: it can't reach the hosts, and it never signs in to Splitwise.

- [ ] **Accounts** shows a **Connect Splitwise** button beside **New account**
- [ ] It opens a form with the Account's name, starting as `Splitwise`, and the date to read expenses from
- [ ] **Continue to Splitwise** goes to Splitwise's own sign-in, and signing in there lands on the new Account's page, which says `Synced from Splitwise as <your name>, reading expenses dated from <the date>.`
- [ ] The Account has **Reconnect** and **Disconnect**, and its Filing rules are off (**Edit** shows the box cleared)
- [ ] Starting again and declining at Splitwise comes back to the form with `Splitwise wasn't connected, since the sign-in was declined.` and no new Account
- [ ] **Reconnect**, signing in as the same Splitwise user, keeps the Account and says `Reconnected Splitwise as <your name>`
- [ ] **Disconnect** says it's disconnected, and the Account and its page stay
- [ ] The Account's **Import** is gone: its page has none, and the **Import** form's Account list doesn't offer it
- [ ] The token is ciphertext in the database. On the host, `docker exec budgie-db psql -U budgie budgie_production -c "select left(access_token, 12) from budget_bank_connections"` shows something that starts `{"p":"`, not a token
- [ ] The token isn't in the logs: `docker compose logs web` in development, or the app's logs on the host, show `code` as `[FILTERED]` in the callback's request

## 5. Check syncing

Do this on each environment once a Splitwise Account is connected, with a real Splitwise account that has a few expenses in it, some of them yours alone and some shared. Claude can't: it never signs in to Splitwise, and it never syncs with a real token.
**Sync now** says what it did ("Synced from Splitwise: 9 new, 2 changed, 1 deleted. 3 settle-ups ignored, 4 skipped."), and the same sync runs every hour, at twenty past, on testing and production alike.

- [ ] **The date.** In Splitwise, enter an expense dated the **1st** of a month (the web app, and the phone app too), and one dated the last day of a month. After **Sync now**, their bank transactions are dated the 1st and the last day, not the day before. Budgie reads the date as the UTC date of the timestamp Splitwise sends, which is right when Splitwise stamps a day with midnight UTC. If an expense comes in a day early or late, tell Claude which, and which app entered it: it's a one-line change in `Splitwise::Expense`
- [ ] **Your share.** An expense you paid for, split evenly, comes in as money in of the other person's half (your net share, positive); one someone else paid for comes in as money out of your half
- [ ] **Settle-ups.** A payment recorded in Splitwise (a settle-up) comes in already ignored, and is counted in the notice as `settle-ups ignored`; **Un-ignore** brings it back to Unfiled
- [ ] **Skipped.** An expense between two other people, one where you paid exactly your share, and one in a currency other than the budget's are not brought in, and the notice counts them as `skipped`
- [ ] **Edits.** Change an expense's amount in Splitwise, and **Sync now** changes the bank transaction's amount in place. If you had filed it, it shows **Doesn't add up** and its records are untouched
- [ ] **Deletes.** Delete an expense in Splitwise, and **Sync now** shows **Deleted in Splitwise** on its bank transaction: beside **Un-file** if you had filed it, and out of the Unfiled state (and the header's count) if you hadn't. Restore it in Splitwise, and the next sync clears that
- [ ] **Filing.** Money in from Splitwise starts as a **Refund** on the filing form. **File and next** and **File N as guessed** work on the Account's Unfiled state, which is its review queue
- [ ] **The hourly job.** An hour or so later, the Account says `Last synced` a time within the last hour, without anyone pressing anything
- [ ] **The date to read from.** Under **Date to read from** on the Account's page, move it earlier and press **Change date**: the next **Sync now** brings in the older expenses and nothing is duplicated. Moving it later leaves what's already there as it is
- [ ] **A token that stopped working.** Remove Budgie from your Splitwise apps, then **Sync now**: it says Splitwise stopped accepting the sign-in, the Account says it needs reconnecting, and **Reconnect** puts it right

## Rotating and losing things

- **A leaked or rotated client secret.** Generate a new one on the app's page at Splitwise, put it in the environment's `…_SPLITWISE_CLIENT_SECRET` (the laptop file, the GitHub environment secret and your password manager) and redeploy.
- **Someone removes Budgie from their Splitwise apps.** The token stops working. The next sync, **Sync now** or the hourly one, finds out: the Account says it needs reconnecting, the hourly job skips it, and **Reconnect** puts it right.
- **A person leaves.** `user:delete` deletes their connections with everything else ([Operating Budgie](operations.md)). A connection that's disconnected holds no token, but it keeps the Splitwise user's id and name until the Account is deleted.
- **Losing an encryption key.** The tokens under it can't be read. Nothing else is affected: the Account page still says what it's synced from, and **Reconnect** and **Disconnect** both still work, because replacing a token never reads the old one. Put the new keys in the environment, deploy, and have each person reconnect.
- **Changing an encryption key on purpose** is the same thing: every connection under the old key has to be reconnected. There's no migration, since a token is cheap to get again.
