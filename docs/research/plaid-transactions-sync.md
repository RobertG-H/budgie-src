# Research: Plaid's `/transactions/sync`

Answers [#142](https://github.com/RobertG-H/budgie-src/issues/142), part of the map [#141](https://github.com/RobertG-H/budgie-src/issues/141): how Plaid's Transactions product, through `/transactions/sync`, describes a Canadian bank's transactions over time, so Budgie can map them onto Accounts and bank transactions (posted only, polled hourly).

Researched 2026-11-19 against Plaid's own documentation at plaid.com/docs. It builds on [bank-sync-aggregators.md](bank-sync-aggregators.md) (#37), which already covers the Item, the shape of a sync and pending-to-posted in outline. This note is about the detail that matters for matching synced rows against CSV rows. Short links used below:

- **API**: the Transactions API reference, [plaid.com/docs/api/products/transactions](https://plaid.com/docs/api/products/transactions/) (`/transactions/sync` unless another endpoint is named).
- **States**: [Transaction states](https://plaid.com/docs/transactions/transactions-data/).
- **Intro**: [Introduction to Transactions](https://plaid.com/docs/transactions/).
- **Add**: [Add Transactions to your app](https://plaid.com/docs/transactions/add-to-app/).
- **Migration**: [Migrating to Transactions Sync](https://plaid.com/docs/transactions/sync-migration/).
- **Webhooks**: [Transactions webhooks](https://plaid.com/docs/transactions/webhooks/).
- **Troubleshooting**: [Transactions troubleshooting](https://plaid.com/docs/transactions/troubleshooting/).
- **Accounts**: the [Accounts API](https://plaid.com/docs/api/accounts/).
- **Items**: the [Items API](https://plaid.com/docs/api/items/), including Item webhooks.
- **Update mode**: [Link update mode](https://plaid.com/docs/link/update-mode/).
- **Duplicates**: [Preventing duplicate Items](https://plaid.com/docs/link/duplicate-items/).
- **Item errors**: [Item errors](https://plaid.com/docs/errors/item/). **Tx errors**: [Transactions errors](https://plaid.com/docs/errors/transactions/). **Errors**: [Errors overview](https://plaid.com/docs/errors/). **Rate limits**: [Rate limit errors](https://plaid.com/docs/errors/rate-limit-exceeded/).

Anything not stated by Plaid is marked **inferred** or listed under [open questions](#open-questions-for-the-real-bank-task).

## Summary

- **Sync is a per-Item delta feed.** Each call returns `added`, `modified` and `removed` since a cursor, paged by `has_more`/`next_cursor`, up to 500 a page. A mutation mid-pagination is `TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION`, and the whole loop restarts from the first page's cursor, so persist nothing until `has_more` is false.
- **History is fixed when Transactions is first initialised on the Item:** `days_requested`, default 90, max 730. It can't be changed afterwards without removing the Item and linking again.
- **Pending to posted is never a modify.** The pending ID arrives in `removed` and the posted one in `added` with a new `transaction_id` and, where the bank allows, `pending_transaction_id`. There's no option to exclude pending: Budgie filters `pending: false` itself.
- **Descriptions:** `original_description` is "the string returned by the financial institution", only sent when `include_original_description` is true. `name` is deprecated and no longer actively maintained, and `merchant_name` is Plaid's enrichment and can be null. `original_description` is the one to compare with a bank CSV.
- **Sign is the opposite of Budgie's:** positive amount means money out. `date` is the posted date for a posted transaction, and `authorized_date` (nullable) is when it was authorised. The currency is `iso_currency_code` or, exclusively, `unofficial_currency_code`.
- **Posted transactions aren't immutable**, and Plaid publishes no frequency for modifies or removes.
- **`account_id` is stable within an Item, but a new Item for the same login gets new `account_id`s.** `persistent_account_id` exists only for Chase, PNC and US Bank. Update mode keeps the Item and its `access_token`, so it's the way to repair a connection without new IDs.
- **Item errors come back as an HTTP 400 `ITEM_ERROR` on the call itself**, and `ITEM_LOGIN_REQUIRED` covers changed passwords, changed MFA and expired consent. `PENDING_EXPIRATION` is a UK/EU webhook. Canada gets `PENDING_DISCONNECT`, which is also a webhook, so a polling-only Budgie learns about pending expiry only from `/item/get`.

## `added`, `modified`, `removed`, the cursor and pagination

**The call.** "The cursor value represents the last update requested." Omitting it means "the entire history of updates will be returned, starting with the first-added transactions on the Item" (API). `count` is "The number of transaction updates to fetch": default 100, minimum 1, maximum 500 (API). The response has `added` and `modified`, which are full transaction objects "ordered by ascending last modified time", and `removed`, whose items hold only `transaction_id` ("The ID of the removed transaction.") and `account_id` ("The ID of the account of the removed transaction.") (API).

**Paging.** When `has_more` is true, call again with `next_cursor` (API, Add). `next_cursor` is the "Cursor used for fetching any future updates after the latest update provided in this response". The one from the final page, where `has_more` is false, "will be valid for at least 1 year", and it's an empty string while transactions aren't available yet (API). "After successfully pulling all currently available pages, you can store the cursor for later requests" (Add), and "it is important to retrieve all available updates before persisting the transactions updates to your database" (Migration).

**`TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION`.** It's HTTP 400, and its cause is "Transaction data was updated during pagination" (Tx errors). If a paginated call fails this way, "the entire pagination request loop must be restarted beginning with the cursor for the first page of the update" (API), so keep both the latest `next_cursor` and the cursor that the first `has_more: true` call started from (API sample). A related error, `TRANSACTIONS_SYNC_ITEM_LIMIT_EXCEEDED` (HTTP 400), means the Item's history "exceeds the size limit for starting or restarting" sync without a cursor. Plaid then says to use `/transactions/get` instead, or contact support (Tx errors).

**Per account.** `options.account_id` makes "the returned updates and cursor … only reflect the specified account's transactions", with its own cursor stream (API). Without it, one cursor covers the Item's accounts. The response's `accounts` array is "An array of accounts at a financial institution associated with the transactions in this response", and "Only accounts that have associated transactions will be shown" (API).

**Other options.** The `options` object is `include_original_description`, `personal_finance_category_version`, `days_requested` and `account_id`. None of them filters out pending transactions (API).

**Rate limits (Production).** `/transactions/sync` allows 50 per minute per Item and 2,500 per minute per client ("500 per empty cursor request"). `/item/get` allows 15 per minute per Item. Exceeding either is HTTP 429, `RATE_LIMIT_EXCEEDED` (Rate limits). Hourly polling is far inside these.

## The first sync and how far back history goes

**Readiness.** "When you first call it on an Item with no `cursor` parameter, transactions data available at that time is returned" (Add). "the first 30 days of transaction history is available to be fetched almost immediately", while "full transaction history may take a minute or more", and an empty response shortly after linking means it hasn't been pulled yet: "wait until it is complete, and call the endpoint again" (Add). Called before data is ready, sync returns "a response with no transactions and an empty `next_cursor`" (Migration). `transactions_update_status` says which stage the Item is at: `TRANSACTIONS_UPDATE_STATUS_UNKNOWN`, `NOT_READY`, `INITIAL_UPDATE_COMPLETE` ("historical pull is pending") or `HISTORICAL_UPDATE_COMPLETE` (API). The equivalent webhook fields are `initial_update_complete` (at least 30 days of history) and `historical_update_complete` ("the full history (up to 24 months)") (Webhooks).

**`days_requested`.** Its range is 1 to 730, and "If no value is specified, 90 days of history will be requested by default." It "only applies to calls for Items where the Transactions product has not already been initialized" (API). "The default is 90 days and the maximum is 730 days (about 24 months)", and "The more transaction history is requested, the longer the historical update poll will take" (Intro). It can be set in `/link/token/create` (`transactions.days_requested`) when Link initialises the product (Add, API), and on `/transactions/get` "In Production, if a value under 30 is provided, a minimum of 30 days of history will be requested" (API). Changing it later has no effect: "By default, Plaid will only request 90 days of transaction history" when Transactions is first added, and more can only be asked for at that first initialisation (Troubleshooting). So more history would take a new Item, linked again (**inferred**).

**Refresh cadence.** Plaid itself checks the bank "typically between one and four times per day, depending on the institution" (Intro, Webhooks). `/transactions/refresh` forces a check, but it's an add-on that has to be requested and is billed per request (API, Intro). So an hourly poll mostly returns nothing new. That's harmless, but polling more often than Plaid refreshes gains nothing (**inferred** from those two facts).

## Pending to posted, and taking posted only

"A transaction begins its life as a pending transaction, then becomes posted once the funds have actually been transferred", which takes "about one to five business days" and "up to fourteen days in rare situations". Some pending transactions "may not convert to a posted transaction at all and will simply disappear" (States).

In sync, the posted version arrives "in the `added` section of the response" and the pending one "with the pending transaction's `transaction_id` in the `removed` field". "these aren't guaranteed to be in the same page, but should happen within the same overall update" (States). Plaid doesn't edit the pending transaction: it removes it and adds a new posted one (Webhooks). `pending_transaction_id` is "The ID of a posted transaction's associated pending transaction, where applicable". It's null "If no pending transaction is provided, or the pending transaction cannot be matched", and not all institutions provide pending transactions (States, API). "The pending and posted versions of a transaction may not necessarily share the same details: their name and amount may change" (States).

**Posted only.** No request option excludes pending (API), so Budgie keeps the `added`/`modified` items with `pending: false` and drops the rest. A `removed` ID that Budgie never stored (a pending one) then matches nothing and can be ignored (**inferred**: `removed` carries only IDs). The posted row is a fresh `transaction_id`, so Budgie never needs `pending_transaction_id`.

## Description fields

| Field | What Plaid says | Nullable |
| --- | --- | --- |
| `original_description` | "The string returned by the financial institution to describe the transaction." Only included when `options.include_original_description` is true (API). That option is "Include the raw unparsed transaction description from the financial institution", default `false` (API). | yes |
| `name` | "The merchant name or transaction description." Deprecated: a legacy field no longer actively maintained, and "Use `merchant_name` instead for the merchant name" (API). | no |
| `merchant_name` | "The merchant name, as enriched by Plaid from the `name` field." Null for transactions such as checks or account transfers that have no meaningful merchant (API). | yes |
| `counterparties` | Merchants or institutions Plaid extracted from the description, each with a `type` and `confidence_level` (API). | |

**Closest to the bank's CSV: `original_description`**, the only one Plaid describes as the institution's own string. `name` is Plaid's cleaned-up text, which used to be the default and is now deprecated. `merchant_name` is enrichment derived from `name`. "information about a merchant, such as its name or category, may be incorrect" (Troubleshooting).

**Caveats.**
- Third-party SDK mirrors say the option is off by default and that getting the raw description means contacting a Plaid Account Manager. Plaid's own reference shows it as an ordinary boolean option. **Unverified:** whether Trial/Production returns it without asking Plaid. Check it in Sandbox and on the first real Item.
- Sync returns deltas, so a transaction already delivered without `original_description` isn't sent again just because the option is turned on later (**inferred**). Send it from the very first call.
- Whether `original_description` for CIBC, TD and Wealthsimple matches their CSV export character for character isn't documented anywhere. Even the bank's website can differ: a missing transaction may be one that "appears differently on the online banking portal" (Troubleshooting).

## Sign, dates and currency

- **Sign.** `amount` is "The settled value of the transaction, denominated in the transaction's currency". Positive values mean money moved out of the account and negative values money in, except for the Income endpoints (API). It's declared `number`, format `double` (API), so the adapter should parse it from the JSON text with BigDecimal, not through a float (**inferred**).
- **`date`** (string, `date`, never null): "For pending transactions, the date that the transaction occurred;" for posted ones it's the posting date, in YYYY-MM-DD (API). "The posted transaction's date will reflect the date the transaction was posted, which may differ from the date on which the transaction actually occurred" (States). Plaid doesn't say which time zone the date is in (States).
- **`authorized_date`** (nullable): "The date that the transaction was authorized." For posted transactions it's generally preferable to `date` for display (API). `datetime` and `authorized_datetime` are nullable timestamps, and `datetime` "may contain default time values" (API).
- **Currency.** `iso_currency_code` is "The ISO-4217 currency code of the transaction. Always `null` if `unofficial_currency_code` is non-null." `unofficial_currency_code` is for currencies without an ISO code, such as cryptocurrencies, and is null when `iso_currency_code` is set (API). Accounts' balances carry the same pair (Accounts), so the currency can be checked at link time.

**How often posted transactions change.** "a posted transaction cannot necessarily be considered immutable", since "a refund or a recategorization of a transaction by the institution could cause" changes. Apps should "apply all `modified`, `added`, and `removed` updates" (States). Transactions "are not immutable and can also be removed altogether by the institution" (API, `/transactions/get`). Plaid publishes no rate or frequency for either (States, Troubleshooting).

## Account identity

- **`account_id`:** "This value will not change unless Plaid can't reconcile the account with the data returned by the financial institution." If the access token is deleted and the same credentials later make a new one, "the new `account_id` will be different from the old `account_id`" (Accounts).
- **A new Item for the same login is a different Item.** "Two Items created for the same set of credentials at the same institution will be considered different" (glossary, cited in #37). "A duplicate Item will be created if the end user logs into the same institution with the same credentials a second time", and duplicates "may cause you to be charged multiple times for the same Item" (Duplicates). To detect one, compare `institution_id`, account `name` and `mask` before exchanging the public token (Duplicates). A `mask` is "The last 2-4 alphanumeric characters" and "may be non-unique between an Item's accounts" (Accounts). That a new Item's transactions also get new `transaction_id`s isn't stated, but follows from the new `account_id`s (**inferred**, as #37 also concluded).
- **`persistent_account_id`** is supported "only for Items at institutions that use Tokenized Account Numbers" (Chase, PNC and US Bank) (Accounts). It's no help for CIBC, TD or Wealthsimple.
- **Update mode keeps the Item.** It's "any Link session launched for an Item after that Item's initial creation", and "An Item's access_token does not change when using Link in update mode" (Update mode). The docs don't say outright that `account_id`s survive update mode, but the Item does, and `account_id` changes only when Plaid can't reconcile the account (Accounts). With `update.account_selection_enabled`, "Any de-selected accounts will no longer be shared with you" (Update mode). For an unhealthy Item, use update mode "instead of creating a new one" (Duplicates).
- **`/item/remove`:** "Once removed, the `access_token`, as well as any processor tokens or bank account tokens … is no longer valid and cannot be used to access any data that was associated with the Item." For subscription products such as Transactions, "calling /item/remove is required to end subscription billing for the Item", unless the user revoked permission (Items). Data Budgie already stored is Budgie's own. On a Trial plan, removing an Item doesn't free its slot (Billing, cited in #37).

## Item errors and how they surface

**Shape.** Plaid errors are "identified by `error_code` and categorized by `error_type`", and those should be used in preference to HTTP status codes (Errors). `ITEM_LOGIN_REQUIRED`, `ACCESS_NOT_GRANTED`, `NO_ACCOUNTS`, `ITEM_NOT_FOUND`, `USER_SETUP_REQUIRED` and `MFA_NOT_SUPPORTED` are all HTTP 400 with `error_type` `ITEM_ERROR` (Item errors). The error arrives "via an API call or the ITEM: ERROR webhook" (Update mode), so a polling sync sees it as the response to `/transactions/sync` itself. Separately, "An Item with a non-`null` error object will only be part of an API response when calling /item/get to view Item status" (Errors, Items). That's the Item's stored `error` field, not the per-call error.

| Condition | What it is | How Budgie (polling, no webhooks) sees it |
| --- | --- | --- |
| `ITEM_LOGIN_REQUIRED` | "Additional input from the user is required to continue getting data for this Item." Causes include a changed password or MFA at a non-OAuth bank, which is every Canadian bank (#37); consent that "is no longer valid, either because it has expired" or was revoked; and "(Sandbox only) The Item was created in the Sandbox environment and is over 30 days old." Fixed by update mode (Item errors). | HTTP 400 `ITEM_ERROR` from `/transactions/sync`. Maps to Splitwise's needs-reconnect. |
| `PENDING_EXPIRATION` | A webhook, not an error, fired 7 days before consent expires, "only for Items associated with institutions in Europe (including the UK)" (Items). | Never, for Canadian banks. |
| `PENDING_DISCONNECT` | The US/CA equivalent: a webhook 7 days before disconnection, with reason `INSTITUTION_MIGRATION` or `INSTITUTION_TOKEN_EXPIRATION` ("consent for a US or CA institution is about to expire") (Items). Update mode renews it, and "you do not need to wait for this webhook in order to refresh the Item" (Update mode). | Only through webhooks, which are out of scope. Instead, `/item/get` has `consent_expiration_time`, though "Currently, only institutions in Europe and a small number of institutions in the US have expiring consent" (Items). Once consent lapses it becomes `ITEM_LOGIN_REQUIRED`. |
| `LOGIN_REPAIRED` | A webhook fired when an Item leaves `ITEM_LOGIN_REQUIRED` without update mode in your app (Items). | The next sync simply succeeds. |
| `ITEM_NOT_FOUND` | The Item was removed via `/item/remove`, or the user deleted or depermissioned it at my.plaid.com (Item errors). | HTTP 400. Treat it as disconnected, since update mode can't fix it (**inferred**: no repair step is listed). |
| `ACCESS_NOT_GRANTED`, `NO_ACCOUNTS`, `USER_SETUP_REQUIRED` | Access not shared or revoked; accounts closed or churned; the bank requires an action from the user (Item errors). | HTTP 400 `ITEM_ERROR`. Show it as needing attention. |
| `RATE_LIMIT_EXCEEDED` | HTTP 429 (Rate limits). | Maps to Splitwise's try-later. |

`/item/get`'s `update_type` is `background` or `user_present_required` (Items). Credential-based Canadian Items most likely refresh in the background (**inferred**).

## Implications for Budgie

**Connection and Accounts**
- One `BankConnection` per Item holds the cursor (`sync_cursor`, which the Splitwise sync already has) and the Item's several Accounts. Each Account's `external_account_id` is Plaid's `account_id`. Persist the cursor only once a whole paged update has been applied, in the same database transaction as the rows, as `SyncSplitwise` does. Restart the page loop from the saved cursor on `TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION`.
- Repair is always update mode: same Item, same `access_token`, same `account_id`s. A second Link for the same bank makes new `account_id`s that won't match the existing Accounts, so Connect must check `institution_id`, name and mask first and steer to Reconnect, or else let the person map new external accounts onto existing Accounts (#37). Removing an Item calls `/item/remove` to stop billing, and on Trial it doesn't give back a slot.
- `days_requested` is set once, at Link, and can't be raised later, so choose it there (up to 730). A per-Account read-from date is then a filter Budgie applies on top, not a Plaid setting.
- Refuse at link time an account whose balances' `iso_currency_code` isn't the budget's, and skip-and-count any transaction whose `iso_currency_code` differs, as Splitwise does.

**Bank transactions**
- Keep `pending: false` only. Treat `modified` as update-in-place by `transaction_id`, and `removed` as `removed_at`. A removed ID Budgie never stored is a pending one and is a no-op.
- The adapter negates `amount` (Plaid positive = money out) and parses it as a decimal. `date` is the posted date. Keep `authorized_date` as well if matching needs it.
- Request `include_original_description: true` from the first call, and store `original_description` as the bank transaction's description, falling back to `name` only when it's null (and saying so). Never use `merchant_name` for the description or the content key.

**Recognising CSV rows and synced rows (dedupe)**
- No identifier is shared: a CSV row has no `transaction_id`, and a new Item renumbers everything. Recognition has to be by content, which means the Account, a date, the signed amount and the description, which is what ADR 0010's content key already is.
- Exact matching only works if the synced row's date and description equal the CSV's. Plaid's `date` is the posting date, and its `original_description` is "the string returned by the financial institution". Plaid doesn't document whether either equals a given bank's CSV export, which may use the transaction date, or the authorised date for cards, and may format the description differently. That's the first thing the real-bank task has to check, per bank and per account type.
- Posted rows can still change or vanish in the bank's own data, so a CSV downloaded before a change and a sync after it can disagree. The exact-or-never stance then leaves a rare duplicate, unfiled, which ADR 0010's stance accepts.

## Open questions for the real-bank task

1. Does Trial/Production return `original_description` without a request to Plaid, and is it populated for CIBC, TD and Wealthsimple?
2. Per bank and account type (chequing, credit card), does the CSV's date equal Plaid's `date` or `authorized_date`? Does the CSV's description equal `original_description` after Budgie's normalisation?
3. How often do posted transactions arrive in `modified` or `removed` for these banks? Plaid publishes no figure.
4. Does `update_type` come back `background` for these Items, and does consent expire for any of them (`consent_expiration_time`)?
5. In Sandbox, which a testing host would use, does an Item hit `ITEM_LOGIN_REQUIRED` after 30 days at every institution? Item errors suggests so.
