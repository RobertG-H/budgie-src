# Plaid setup

Budgie connects a bank through Plaid, so that each account a person shares becomes an Account whose bank transactions are synced instead of imported ([ADR 0018](adr/0018-a-plaid-connection-is-an-item-whose-accounts-become-new-or-existing-accounts.md)).
"Connect a bank" on the Accounts page opens Plaid Link, where the person signs in to their bank and chooses the accounts to share, and then a Budgie page where they choose what each one becomes: a new Account, linked onto an Account that's already there, or left out.
Without any of this, nothing breaks: "Connect a bank" just isn't offered, and its pages turn a request away.

This page is for the operator: Claude edits the config and these docs, and never handles a Plaid secret, an encryption key or a token. The research behind it is [Plaid's Sandbox, Trial and Production](research/plaid-sandbox-trial-production.md) and [Plaid Link in a Rails app](research/plaid-link-rails-importmap.md).

**What's built** is connecting, syncing, Reconnect, Choose accounts, Disconnect and linking onto an existing Account (the `roadmap` issue #152's first build ticket, #155, #156, #157 and #158): a connection and its Accounts are made, **Sync TD now** on an Account's page and a job every hour bring each posted transaction in as a bank transaction, keeping it up to date as the bank changes or removes it ([Syncing](#7-check-syncing)), and **Reconnect** and **Choose accounts** use Link's update mode to sign in again and to change which accounts are shared ([Reconnect and Choose accounts](#8-check-reconnect-and-choose-accounts)). **Disconnect TD** removes the Item at Plaid and forgets the token, and deleting a bank connection's last Account removes the Item too ([Disconnect](#9-check-disconnect)). A bank's account can be linked onto an Account that takes CSV Imports, or onto one whose bank was disconnected, which **Connect TD again** brings back, keeping its name, bank transactions and Filing rules ([Linking](#10-check-linking-onto-an-existing-account)).

- [1. The Plaid team and its keys](#1-the-plaid-team-and-its-keys)
- [2. Link customization](#2-link-customization)
- [3. Data Transparency Messaging](#3-data-transparency-messaging)
- [4. A Sandbox user with Canadian dollars](#4-a-sandbox-user-with-canadian-dollars)
- [5. Give the values to the app](#5-give-the-values-to-the-app)
- [6. Check it](#6-check-it)
- [7. Check syncing](#7-check-syncing)
- [8. Check Reconnect and Choose accounts](#8-check-reconnect-and-choose-accounts)
- [9. Check Disconnect](#9-check-disconnect)
- [10. Check linking onto an existing Account](#10-check-linking-onto-an-existing-account)
- [The Trial's 10 Items](#the-trials-10-items)
- [Coverage](#coverage)

## 1. The Plaid team and its keys

Make a Plaid team at [dashboard.plaid.com](https://dashboard.plaid.com), in Canada. A team created on or after 2026-04-15 in the US or Canada starts on the **Trial**: free Production with 10 Items ([below](#the-trials-10-items)).
Its **Keys** page (Developers → Keys) has one client id and a secret for each environment:

| Environment | Used by | `PLAID_ENV` |
| --- | --- | --- |
| Sandbox | development and testing | `sandbox` |
| Production | production, **once [Section 10](#10-check-linking-onto-an-existing-account) is ticked on testing** | `production` |

Linking onto an existing Account has shipped (#158), so production's values can now go in: connecting a bank there links each account onto the CSV Account it already has, rather than leaving that Account as a dead twin of a new synced one. Tick Section 10 on testing first, since each try in production spends one of the Trial's 10 Items for good.

**Put each value in your password manager first.**

## 2. Link customization

In the Dashboard, under Link → Link customization, edit the `default` customization (the one a link token gets when it names none):

- [x] **Account Select** is set to **Multi select**, so the person chooses which of the bank's accounts to share, and Link sends only those
- [x] Its **countries** are exactly Canada and its **language** English (`CA` and `en`), which is what Budgie's link token asks for: a customization applies only when they match exactly. They're under the **gear** beside the customization's name ("default"), not in the list of panes on the right
- [x] **Publish changes**

The preview's banks are the United States' whatever the countries are set to; Link itself shows the banks of the countries the link token asks for.

## 3. Data Transparency Messaging

Link in Production needs a Data Transparency Messaging use case, set in the Dashboard (Link → Data Transparency Messaging). Sandbox works without it.

- [x] A use case is chosen that says Budgie reads transactions to budget with, such as personal financial management

## 4. A Sandbox user with Canadian dollars

Sandbox's test users have accounts in US dollars, and Budgie leaves out an account that isn't in the budget's currency, so a CAD budget would be left with nothing to connect. Make a custom user with CAD accounts in **Sandbox Studio** (Build → Sandbox): **+ Create** on its Users tab, editing the JSON rather than describing the user. Then sign in to **Tartan-Dominion Bank of Canada** (`ins_43`), Sandbox's one Canadian bank, with it in Link.

This one has been connected through Budgie in development. Its USD account is there to be left out of a CAD budget (and is the only one a USD budget keeps). In Plaid's amounts, positive is money out, and a sync turns them round, so LOBLAWS comes in as money out.

```json
{
  "override_accounts": [
    {
      "type": "depository", "subtype": "checking", "currency": "CAD", "starting_balance": 2500,
      "meta": { "name": "Tartan Chequing", "mask": "4821" },
      "transactions": [
        { "date_transacted": "2026-11-03", "date_posted": "2026-11-04", "currency": "CAD", "amount": 82.45, "description": "LOBLAWS #1029" },
        { "date_transacted": "2026-11-14", "date_posted": "2026-11-14", "currency": "CAD", "amount": -2800, "description": "PAYROLL DEPOSIT" }
      ]
    },
    {
      "type": "depository", "subtype": "savings", "currency": "CAD", "starting_balance": 8000,
      "meta": { "name": "Tartan Savings", "mask": "1100" }, "transactions": []
    },
    {
      "type": "credit", "subtype": "credit card", "currency": "CAD", "starting_balance": 450,
      "meta": { "name": "Tartan Visa", "mask": "9001", "limit": 5000 },
      "transactions": [
        { "date_transacted": "2026-11-10", "date_posted": "2026-11-11", "currency": "CAD", "amount": 14.99, "description": "NETFLIX.COM" }
      ]
    },
    {
      "type": "depository", "subtype": "checking", "currency": "USD", "starting_balance": 300,
      "meta": { "name": "Tartan U.S. Dollar", "mask": "7777" }, "transactions": []
    }
  ]
}
```

Once it's saved, choose it in the **Credentials** dropdown at the top of Sandbox Studio, which shows the username and password to type into Link.

- [x] A custom user with a chequing account, a savings account and a credit card, each with `"currency": "CAD"`, and one account with `"currency": "USD"` to see it left out
- [x] Its name and password written down where you test from, from the **Credentials** dropdown

## 5. Give the values to the app

### Development

Put the Sandbox client id and secret in `.env`, then recreate the app's container with `docker compose up -d web`. `docker compose restart web` isn't enough: Compose reads `.env` only when it creates the container, so a restart keeps the old environment and "Connect a bank" stays hidden.

```sh
PLAID_CLIENT_ID=
PLAID_SECRET=
PLAID_ENV=sandbox
```

The token is encrypted under development's fixed throwaway keys unless `.env` has the `ACTIVE_RECORD_ENCRYPTION_…` variables too ([Splitwise setup](splitwise.md#2-generate-the-encryption-keys)), which is fine for Sandbox.

### Testing and production

Each destination has three more secrets, named the same way as the others ([Deploying](deployment.md#the-secrets-on-your-laptop)), beside the encryption keys it already has for Splitwise's tokens:

| In `.env.testing` and the `testing` GitHub environment | In `.env.production` and the `production` GitHub environment |
| --- | --- |
| `TESTING_PLAID_CLIENT_ID` | `PRODUCTION_PLAID_CLIENT_ID` |
| `TESTING_PLAID_SECRET`, the **Sandbox** secret | `PRODUCTION_PLAID_SECRET`, the **Production** secret, once Section 10 is ticked |
| `TESTING_PLAID_ENV=sandbox` | `PRODUCTION_PLAID_ENV=production`, once Section 10 is ticked |

`.kamal/secrets.<destination>` maps them to the names the app reads. A deploy with them empty is harmless: the app treats that as Plaid not being set up.

## 6. Check it

Do this on testing once its values are deployed. Claude can't: it can't reach the hosts, and it never runs Plaid Link.

- [x] **Accounts** shows **Connect a bank** beside **Connect Splitwise** and **New account**
- [x] **Connect a bank**, then **Continue to Plaid**, opens Link; choosing Tartan-Dominion Bank of Canada and signing in as the custom user shows the Account Select pane with every account to tick
- [x] Finishing Link lands on **Connect Tartan-Dominion Bank of Canada**, which lists the accounts that were ticked, each with its name, its last digits, its kind and **Becomes** (A new Account or Leave out)
- [x] **Connect Tartan-Dominion Bank of Canada** goes to the first new Account's page with `Connected Tartan-Dominion Bank of Canada. Its bank transactions arrive within the hour.`, and names the USD account as left out
- [x] Each new Account's page has the bank's panel and no **Import**, and the Accounts list says `Synced from Tartan-Dominion Bank of Canada.` under each
- [x] Connecting the same custom user again is refused before Link's token is exchanged: `Tartan-Dominion Bank of Canada is already connected, …`
- [x] **Cancel** on the choice page, and waiting more than 30 minutes before pressing Connect, both keep nothing
- [ ] The token is ciphertext in the database: on the host, `docker exec budgie-db psql -U budgie budgie_production -c "select provider, left(access_token, 12) from budget_bank_connections"` shows something that starts `{"p":"` for `plaid`
- [x] The app's logs show `public_token` as `[FILTERED]` in the request that Link's answer was sent in

## 7. Check syncing

Do this on testing, with the custom user connected (each Account's date to read from on or before the custom user's transactions' dates). Claude can't: it can't reach the hosts, it never calls Plaid with real keys, and what only Plaid's own answers can settle is here. The Sandbox endpoints are calls to `sandbox.plaid.com` with the Sandbox client id, secret and the connection's access token, which is only in the database, encrypted, so they're easiest from the Dashboard's API explorer or Postman with a token from a Sandbox Item made there.

- [x] **Sync Tartan now** on a connected Account's page says `Synced from Tartan-Dominion Bank of Canada: 3 new.` (or however many there are), and **Last synced** under the panel. A first sync right after connecting can say `… hasn't sent its bank transactions yet. Try again in a few minutes.`: that's Plaid still gathering the history
- [x] **The bank's own description arrives.** The bank transactions read `LOBLAWS #1029`, `PAYROLL DEPOSIT` and `NETFLIX.COM`, the custom user's `description`, and not a tidied merchant name: that's `original_description`, which Budgie asks for on every call. If they read as Plaid's tidied names instead, tell Claude
- [x] **Signs and dates.** LOBLAWS is money out (red) and PAYROLL DEPOSIT money in, each dated its `date_posted` (Nov 4 for LOBLAWS, not Nov 3)
- [x] **New transactions come in.** Add a CAD transaction with `/sandbox/transactions/create` (or by editing the custom user and resetting the Item), then **Sync Tartan now** brings it in, once, however often it's pressed. One in another currency is counted as skipped
- [x] **Filing rules.** A Filing rule for `loblaws` on the Account files the next LOBLAWS that comes in, and the notice says `Filing rules filed 1 of them.` with a **Review them** link
- [x] **The date to read from.** Under **Date to read from** on an Account's page, move it earlier and press **Change date**: the next sync reads every transaction again, and nothing is duplicated
- [x] **A connection that needs signing in again.** `/sandbox/item/reset_login` on the Item, then **Sync Tartan now**: it says `Tartan-Dominion Bank of Canada stopped accepting the connection, so nothing was synced.`, the panel says the Account isn't syncing and has no **Sync Tartan now**, and the hourly job skips it. Section 8 puts it right
- [x] **The hourly job.** At twenty past the hour, **Last synced** moves on without pressing anything

## 8. Check Reconnect and Choose accounts

Do this on testing, with the custom user connected and at least two of its accounts made Accounts. Both are Plaid Link's update mode, which keeps the Item: what to look for is that nothing is renumbered, which only Plaid's own answers can show.

- [x] **Reconnect clears needs-reconnect.** `/sandbox/item/reset_login` on the Item, then **Sync Tartan now** says it stopped accepting the connection. The Accounts page has a **Needs reconnecting** badge on each of the connection's Accounts, and each Account's panel names the others as not syncing, with **Reconnect** as the primary button. **Reconnect**, then **Continue to Plaid**, signs in again in Link (no Account Select pane), and finishing it says `Reconnected Tartan-Dominion Bank of Canada.`, the badges are gone and **Sync Tartan now** is back
- [x] **Reconnect changes nothing when left.** Closing Link without finishing leaves the connection as it was
- [x] **Sync after Reconnect brings nothing in twice.** **Sync Tartan now** after reconnecting says nothing new for what was already there
- [x] **Choose accounts adds an account.** With one of the custom user's accounts left out, **Choose accounts** on an Account's page, then **Continue to Plaid**, shows the Account Select pane with the current selection ticked. Ticking the one left out lands on **Choose accounts on Tartan-Dominion Bank of Canada**, listing only that one (the USD one, if ticked, shows **Left out** greyed out with its reason). **Save** says `Added … from Tartan-Dominion Bank of Canada.`, and the next **Sync Tartan now** brings its bank transactions in and nothing twice in the Accounts that were already there
- [x] **Choose accounts removes an account.** Choose accounts again and untick one: it saves straight away (no choice page) with `… is no longer shared, so nothing new comes in.`; that Account's page says `No longer shared from Tartan-Dominion Bank of Canada, …` above the panel and keeps its bank transactions, and the Accounts list says `No longer shared from Tartan-Dominion Bank of Canada.`
- [x] **The ids that stayed are unchanged.** `/accounts/get` on the Item (from the Dashboard's API explorer) after both shows the same `account_id` for every account that stayed selected as before, and Budgie's Accounts for them still sync. If an id changed, tell Claude
- [x] **Sharing it again.** Choose accounts once more and tick it again: `… is shared again.`, the warning is gone, and the next sync brings in what's new without bringing in twice what it already had

## 9. Check Disconnect

Do this on testing, with the custom user connected and at least two of its accounts made Accounts. **Disconnect TD** is final, and on Sandbox it costs nothing, so connect the bank again afterwards (Section 6) to check the rest. On production's Trial, removing an Item frees no slot, so don't try it there.

- [x] **The question names the Accounts and the Trial.** On an Account's page, **Disconnect Tartan** (named for your bank) asks `Disconnect Tartan-Dominion Bank of Canada? … stop syncing and keep their bank transactions. Connecting Tartan-Dominion Bank of Canada again later counts as a new connection on Plaid's Trial.`, naming every Account the connection syncs. Cancel leaves everything as it was
- [x] **Disconnect removes the Sandbox Item.** Confirming says `Disconnected from Tartan-Dominion Bank of Canada.` In the Plaid Dashboard's activity log (Developers, Logs) there's a successful `/item/remove` for the Item, and the Item's access token no longer works (`/accounts/get` on it answers `INVALID_ACCESS_TOKEN`)
- [x] **The Accounts keep what they had.** Each Account's page says `Was synced from Tartan-Dominion Bank of Canada, which was disconnected.` with no **Sync Tartan now**, **Reconnect**, **Choose accounts** or **Disconnect**, and still has its bank transactions, its Filing rules and its **Date to read from**. The Accounts list says the same under each name, with no **Needs reconnecting** badge, and an Account still takes no Import
- [x] **The hourly job skips it.** At twenty past the hour, **Last synced** doesn't move
- [x] **Removed outside Budgie.** Connect again, then remove the Item at my.plaid.com (or `/item/remove` from the API explorer) and press **Sync Tartan now**: it says `Tartan-Dominion Bank of Canada was disconnected, since Plaid says it's no longer there, so nothing was synced.` and the Accounts now say they were disconnected
- [x] **Deleting the last Account.** On a connection with an Account that has no bank transactions, delete the others first, then the last: the question says `Its connection to Tartan-Dominion Bank of Canada is removed with it, and Budgie stops having access to Tartan-Dominion Bank of Canada.`, and afterwards the Dashboard's log has a `/item/remove` for the Item and the Account and connection are gone. Deleting an Account of a disconnected connection makes no `/item/remove` call
- [x] **Plaid refusing it.** With `PLAID_SECRET` changed to a wrong one in `.env.testing` (restore it after), **Disconnect** and deleting a last Account are each refused with an alert saying `Plaid refused it (…), so … and nothing was changed. Try again later.`, and the connection and its Accounts are as they were

## 10. Check linking onto an existing Account

Do this on testing, with the custom user's bank not connected (Disconnect it first if it is). Claude can't: it can't reach the hosts and never runs Plaid Link. What to look for is that the Account stays one Account the whole way through, which only real Plaid answers can show.

- [ ] **An Account with CSV rows.** Make an Account (say Chequing), give it a CSV format and **Import** a file into it whose latest row is dated the same day as one of the custom user's transactions for the account you'll link, and file a row or two
- [ ] **The choice page offers it.** **Connect a bank**, finish Link, and the **Becomes** select of each row has **Link onto an existing Account** with Chequing in it, between **A new Account** and **Leave out**. Choosing Chequing shows **Read bank transactions dated from** set to Chequing's latest bank transaction's date and the note `That day's bank transactions may come in twice. Ignore the ones you've already filed.`
- [ ] **The same Account twice is refused.** Choosing Chequing on two rows and pressing Connect says `… Becomes is already chosen for another account on this page` and exchanges nothing (the Dashboard's log has no new `/item/public_token/exchange`)
- [ ] **Linking keeps the Account.** Link one row onto Chequing and **Connect**: it goes to Chequing's page with `… Chequing keeps its bank transactions and is synced from it now.`, which has the bank's panel and no **Import**, its name, its earlier bank transactions (filed as they were) and its Filing rules; its **Edit** form has no Default CSV format
- [ ] **The first sync brings the day in again.** **Sync Tartan now** brings in that day's transactions, unfiled beside the CSV rows of the same day, and nothing dated before it. **Ignore** the twins
- [ ] **Disconnect and Connect again.** **Disconnect Tartan** on Chequing's page. Its panel says `Was synced from …, which was disconnected. … Connecting … again can link this Account back onto it, keeping its bank transactions.` with **Connect Tartan again** and no **Reconnect**. Press it and finish Link: on the choice page Chequing's row already says **Becomes** Chequing. **Connect** keeps Chequing as one Account with all its bank transactions, the next sync brings in only what's new (matched by Plaid's id, the same day's twins at most), and the old connection is gone (the Accounts list no longer says `Was synced from …, which was disconnected.` under Chequing)

## The Trial's 10 Items

On the Trial, a team can make 10 Items in Production, ever. Every public token exchanged for an access token counts, and **removing an Item (`/item/remove`) frees none**, so Disconnect doesn't either, and connecting a bank again after it is a new Item. Budgie keeps no count: it exchanges only when the person presses Connect on the choice page, after the duplicate check, so no Item is spent by leaving Link or the page, and once the 10 are used Plaid refuses the exchange and the Accounts page says so in Plaid's words. Sandbox has no limit.

Budgie removes an Item it exchanged but couldn't keep, such as one where every account chosen was in another currency, so Plaid stops reading the bank for it, but that Item still counts.

## Coverage

These list Transactions in Plaid's Dashboard (Institutions page), which is the check to run again before relying on one:

| Bank | Plaid's id |
| --- | --- |
| CIBC | `ins_37` |
| TD Canada Trust | `ins_42` |
| Wealthsimple | `ins_118273` |

No Canadian bank uses OAuth with Plaid, so Budgie needs no redirect URI, no allowed-redirect list in the Dashboard and no webhook, and Plaid never calls Budgie's hosts.
