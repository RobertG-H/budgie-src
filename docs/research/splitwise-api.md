# Research: the Splitwise API

Answers [#38](https://github.com/RobertG-H/budgie-src/issues/38), part of the map [#33](https://github.com/RobertG-H/budgie-src/issues/33): how the Splitwise API represents shared expenses, and how Budgie would read them.

Researched 2026-09-30. The primary source is Splitwise's own OpenAPI spec, which is what [dev.splitwise.com](https://dev.splitwise.com/) renders. It lives in [`splitwise/api-docs`](https://github.com/splitwise/api-docs) ("This repo powers the official documentation for the Splitwise API"), read at commit [`f7bdbe2`](https://github.com/splitwise/api-docs/tree/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c) (2026-07-28). Links below are pinned to that commit, abbreviated as `spec:`. The second source is answers from Splitwise staff (GitHub "collaborator" `jas14`) in that repo's issues. Anything else is labelled as community-reported or inferred, and the [open questions](#open-questions-to-settle-with-a-live-call) list what only a live call can settle.

## Summary

- An **expense** has one `cost` and one `currency_code`, and a `users` array of shares: each person's `paid_share` (what they put in), `owed_share` (what their part of it was) and `net_balance`. The Budgie user's real cost is their `owed_share`.
- A **settle up** is an expense with `payment: true`, using the same shape. There is no separate payments resource.
- **Groups** and **friends** only scope expenses: an expense has a nullable `group_id` and `friendship_id`.
- **Changes**: `get_expenses` takes `updated_after` and pages with `limit` (default 20) and `offset`. Deletion is soft: `deleted_at` is set and the expense can be restored.
- **Auth**: OAuth 2 (authorization code) for other people's accounts. A personal API key is available for your own account.
- **Rate limits** aren't published. The API returns `429`, and Splitwise calls them lenient for hobby use.
- **There are no webhooks.** Budgie would have to poll.

## Expenses

Source: [spec: `schemas/expense.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/schemas/expense.yaml), [`schemas/expense/common.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/schemas/expense/common.yaml) and [`schemas/share.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/schemas/share.yaml).

| Field | Type | Notes |
| --- | --- | --- |
| `id` | integer, `int64` | The expense's ID. |
| `group_id` | integer, nullable | "Null if the expense is not associated with a group." |
| `friendship_id` | integer, nullable | "Null if the expense is not associated with a friendship." |
| `expense_bundle_id` | integer, nullable | Not described in the spec. |
| `description` | string | Short text, such as "Brunch". |
| `details` | string, nullable | "Also known as 'notes.'" |
| `cost` | string | "A string representation of a decimal value, limited to 2 decimal places", for example `"25.0"`. |
| `currency_code` | string | "Must be in the list from `get_currencies`". Each expense has one currency. |
| `date` | string, `date-time` | "The date and time the expense took place. May differ from `created_at`", for example `2012-05-02T13:00:00Z`. |
| `created_at`, `updated_at` | string, `date-time` | `updated_at` is "The last time the expense was updated." |
| `deleted_at` | string, `date-time`, nullable | "If the expense was deleted, when it was deleted." |
| `created_by`, `updated_by`, `deleted_by` | user, nullable | |
| `payment` | boolean | "Whether this was a payment between users". See [settle up](#settle-up-and-payments). |
| `transaction_confirmed` | boolean | "If a payment was made via an integrated third party service, whether it was confirmed by that service." |
| `repeats`, `repeat_interval`, `next_repeat`, … | | For recurring expenses: `repeat_interval` is one of `never`, `weekly`, `fortnightly`, `monthly` or `yearly`. |
| `category` | `{ id, name }` | `name` is "Translated to the current user's locale". |
| `repayments` | array of `{ from, to, amount }` | `from` is the "ID of the owing user" and `to` the "ID of the owed user". |
| `users` | array of shares | See below. |
| `receipt`, `comments`, `comments_count` | | |

### Who paid and who owes

Each entry in `users` is a share ([`share.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/schemas/share.yaml)): `user` (`id`, `first_name`, `last_name`, `picture`), `user_id`, `paid_share`, `owed_share` and `net_balance`. All the amounts are decimal strings.

- `paid_share` is "The amount this user paid for the expense", and `owed_share` is "The amount this user owes for the expense". Both definitions come from the create-expense request schema, [`schemas/expense/by_shares.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/schemas/expense/by_shares.yaml#L11-L18), which uses the same names.
- `net_balance` isn't described. The spec's example is `paid_share` 8.99, `owed_share` 4.5 and `net_balance` 4.49, which fits `net_balance = paid_share − owed_share`: positive means others owe this user, negative means this user owes others.
- `repayments` are the debts the expense creates between pairs of people, from the person who owes to the person who is owed.
- More than one person can pay: when you create an expense from shares, each share carries its own `paid_share` and `owed_share` ([`paths/create_expense.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/paths/create_expense.yaml#L6-L16)).
- Negative amounts aren't allowed. Staff explained that a reimbursement is entered as an "inverse expense", with the paid and owed amounts swapped: "the Splitwise API doesn't allow negative costs or shares" ([api-docs#60](https://github.com/splitwise/api-docs/issues/60), `jas14`).

### Settle up and payments

A settle up is an ordinary expense with `payment: true`. There is no separate payments endpoint: the full list of paths is in [`paths/index.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/paths/index.yaml).

The spec doesn't say how a payment's shares are laid out. From the share model, a payment where A pays B an amount X would give A `paid_share` X and `owed_share` 0, and B `paid_share` 0 and `owed_share` X. That's inferred, not documented.

`transaction_confirmed` marks a payment made through an integrated service, and the example notification icon is `…/0-venmo.png` ([`schemas/notification.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/schemas/notification.yaml)).

## Groups and friends

- A group is "a collection of users who share expenses together … Importantly, two users in a Group can also have expenses with one another outside of the Group" ([spec: `splitwise.yaml` L302–L304](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/splitwise.yaml#L302-L304)).
- A group has an `id`, a `name`, a `group_type` (`home`, `trip`, `couple`, `other`, `apartment` or `house`), and `members`, each with a `balance` per currency. It also has `original_debts` and `simplified_debts`, which are lists of `{from, to, amount, currency_code}`, and a `simplify_by_default` flag ([`schemas/group.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/schemas/group.yaml)).
- "Expenses that are not associated with a group are listed in a group with ID 0" in `get_groups` ([`paths/get_groups.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/paths/get_groups.yaml)). On the expense itself, though, `group_id` is null, and `create_expense` takes `group_id: 0` to mean "outside of a group".
- A friend is a user plus `balance` (per currency), `groups` (the balance with that friend in each group) and `updated_at` ([`schemas/friend.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/schemas/friend.yaml)). An expense between two friends outside any group carries a `friendship_id`.
- A user's `registration_status` can be `confirmed`, `dummy` or `invited`, so a share can belong to someone who has never signed up ([`schemas/user.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/schemas/user.yaml)).

## Currencies

- Every expense has one `currency_code`, and balances are always lists of `{currency_code, amount}`, one per currency, never a single total ([`schemas/balance.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/schemas/balance.yaml)).
- `get_currencies` needs no authentication. It returns `{currency_code, unit}` pairs, which are "mostly ISO 4217 codes, but we do sometimes use pending codes or unofficial, colloquial codes (like BTC instead of XBT for Bitcoin)" ([`paths/get_currencies.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/paths/get_currencies.yaml)).
- The current user has a `default_currency` ([`schemas/current_user.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/schemas/current_user.yaml)).
- Splitwise can convert currencies after the fact: the notification types include 14 "Group currency conversion" and 15 "Friend currency conversion" ([`paths/get_notifications.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/paths/get_notifications.yaml#L14-L31)). What a conversion does to existing expenses isn't documented.

## Fetching changes

`GET /get_expenses` "List the current user's expenses" ([`paths/get_expenses.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/paths/get_expenses.yaml)) takes these parameters:

| Parameter | Notes |
| --- | --- |
| `group_id` | "only expenses in that group will be returned, and `friend_id` will be ignored" |
| `friend_id` | "only expenses between the current and provided user" |
| `dated_after`, `dated_before` | Filter by the expense's `date`. |
| `updated_after`, `updated_before` | Filter by `updated_at`. |
| `limit` | Default 20. |
| `offset` | Default 0. |

- **Pagination** is offset-based. The response is `{ "expenses": [...] }` with no total or cursor, so you page until a page comes back short. The spec states no maximum `limit` and no sort order.
- **Deletions** are soft. `delete_expense` and `undelete_expense` ("Restore an expense") both take the expense ID ([`paths/delete_expense.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/paths/delete_expense.yaml), [`paths/undelete_expense.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/paths/undelete_expense.yaml)), and the expense object keeps `deleted_at` and `deleted_by`.
  - The official spec doesn't say whether `get_expenses` returns deleted expenses.
  - The unofficial Python SDK, which the official docs list, has an undocumented `visible` parameter, "Boolean to show only not deleted expenses" ([splitwise.readthedocs.io](https://splitwise.readthedocs.io/en/latest/api.html)). That suggests deleted expenses come back by default with `deleted_at` set, but it's community-reported, not confirmed.
- **Edits**: `update_expense/{id}` edits in place by ID. It's a partial update, but "If any values is supplied for `users__{index}__{property}`, _all_ shares for the expense will be overwritten" ([`paths/update_expense.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/paths/update_expense.yaml)). Nothing in the spec suggests that an edit or a delete changes an expense's `id`. The spec doesn't guarantee it either, but edit, delete and restore all address the expense by the same ID.
- **Notifications**: `get_notifications?updated_after=` is a cheaper feed of what changed. It covers expenses added (type 0), updated (1), deleted (2) and undeleted (13), and each notification has a `source: {type: "Expense", id}`. Its default `limit` of 0 means "the maximum", but "the server sets arbitrary (but large) limits" ([`paths/get_notifications.yaml`](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/paths/get_notifications.yaml)).
- **Errors**: the write endpoints can return `200 OK` and still fail ("successful only if `errors` is empty" / "`success` is true"). This doesn't affect reading.

## Authentication

From [spec: `splitwise.yaml` L319–L346](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/splitwise.yaml#L319-L346):

- **OAuth 2, authorization code flow.** "you'll need to [register your app](https://secure.splitwise.com/apps). When you register, you'll be given a key and secret." The endpoints are `/oauth/authorize` and `/oauth/token`, and there are no scopes (`scopes: {}`), so a token can read everything the user can see. The base URL is `https://secure.splitwise.com/api/v3.0` (L289).
  - Staff say the client ID and secret must go in the request as `client_id` and `client_secret` parameters, "not as a header", and that `grant_type` must be `authorization_code` ([api-docs#43](https://github.com/splitwise/api-docs/issues/43)).
  - Splitwise follows RFC 6749's recommended authorization-code lifetime of 10 minutes ([api-docs#90](https://github.com/splitwise/api-docs/issues/90)).
  - Community-reported, not in the spec: the token response is just `{access_token, token_type: "bearer"}` with no refresh token, and each app registers a single callback URL ([api-docs#43](https://github.com/splitwise/api-docs/issues/43)).
- **Personal API key.** "For speed and ease of prototyping, you can generate a personal API key on your app's details page … present this key … as a Bearer token. The API key is an access token for your personal account". You still have to register an app to get one ([api-docs#8](https://github.com/splitwise/api-docs/issues/8), `jas14`). An open, unanswered report says `create_expense` fails with an API key ([api-docs#64](https://github.com/splitwise/api-docs/issues/64)), which doesn't matter for reading.

## Rate limits and terms

- Rate limits "vary by endpoint and resource, and are subject to change at any time without notice". Going over them returns `HTTP 429 Too Many Requests`, and you should "slow down … and retry after a short delay". Splitwise adds: "our rate limits are fairly lenient, and almost no hobby integration has ever exceeded them" ([spec: L275–L287](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/splitwise.yaml#L275-L287)). No limits or rate-limit headers are published.
- The terms matter for Budgie ([spec: L51–L62](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/splitwise.yaml#L51-L62), [L97](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/splitwise.yaml#L97), [L139](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/splitwise.yaml#L139), [L151](https://github.com/splitwise/api-docs/blob/f7bdbe2d639b74c649ad3971d68bc4b5262cbb2c/splitwise.yaml#L151)):
  - "The API is not intended for commercial use … may not be used in connection with any fee-based service."
  - Splitwise "may impose conditions … including, for example, maintaining an active Splitwise Pro subscription".
  - You must get "explicit consent from end users", have a privacy policy that covers Splitwise data, and delete Splitwise data on request.

## Webhooks

There are none. The spec has no webhook, callback or subscription resource, and the feature request "[Webhooks/subscriptions/push support](https://github.com/splitwise/api-docs/issues/88)" has been open with no reply since 2024-09-30. Getting changes means polling `get_expenses?updated_after=` (or `get_notifications`).

## Implications for Budgie's model

Per [ADR 0002](../adr/0002-budget-records-are-source-agnostic.md), a Splitwise expense would be an external record in its own table, filed as a Deposit, Spent or Refund, or ignored.

1. **Connection per user.** Budgie is multi-user, so it needs OAuth 2 per user. Store each user's access token encrypted, along with their Splitwise user ID, which is needed to pick "my" share out of `users`. There is no refresh token to rotate (community-reported), and there are no scopes. A personal API key is enough for a spike on one account. Registering one app per destination fits the one-callback-URL limit.
2. **What a Splitwise expense record must store**, keyed on `(connection, splitwise_expense_id)` rather than globally, because two Budgie users can share one expense:
   - identity and change tracking: `id`, `updated_at` and `deleted_at`
   - what the user reviews when filing it: `description`, `date`, `cost` and `currency_code`
   - how it's filed: `payment`, plus the user's own `paid_share`, `owed_share` and `net_balance`
   - context for display: `group_id` or `friendship_id` and the category name
   - optionally the raw `users` and `repayments` as JSON, for display and for re-deriving the user's share.

   Parse amounts as `BigDecimal` from the strings, and never as floats.
3. **Filing the user's share.** The user's real cost is `owed_share`. There are two common cases:
   - **Someone else paid** (`paid_share` 0, `owed_share` > 0). No bank transaction exists yet, so the Splitwise record is filed as Spent of `owed_share` from an envelope. The later settle up is money leaving the bank for a cost already counted, so its bank transaction should be ignored or linked, not filed as Spent again.
   - **The user paid** (`paid_share` = `cost`). The bank transaction already filed the whole `cost` as Spent. The Splitwise record says `net_balance` of that is owed back, so it's filed as a Refund of `net_balance` to the same envelope, or the user files only `owed_share` in the first place. Either way, a friend's repayment arriving in the bank later must not count as a Deposit on top.

   Which of these Budgie adopts is a modelling decision for the map. The data needed for either is `owed_share` and `net_balance`.
4. **Detecting repayments.** A settle up is `payment: true`. The user's share shows the direction: paying out gives `paid_share` > 0, receiving gives `owed_share` > 0 (inferred). Payment records are the natural match for the corresponding bank transaction (same amount, nearby date), which Budgie can then ignore or link rather than file. `transaction_confirmed` flags payments made through an integrated service.
5. **Sync by polling.** There are no webhooks, so run a background job or an on-demand refresh that calls `get_expenses?updated_after=<last seen updated_at, with some overlap>` and pages with `limit`/`offset` until a page comes back short. Upsert by ID:
   - An expense whose `deleted_at` is set, or whose shares changed, after it was filed has to flag or undo the budget record it created. Deletes can be undone, so treat them as a state, not a tombstone.
   - Handle `429` with back-off.
6. **Currency.** A Budget has one currency, and Splitwise expenses can be in any currency (including non-ISO codes). A record whose `currency_code` isn't the budget's can't be filed directly: store it and flag or skip it. Group currency conversions can change it later.
7. **Dates.** `date` is a UTC timestamp (for example `…T13:00:00Z`), and Budgie's records are dated by day. Choose how to convert it, for example to the user's time zone, and check it against real data.
8. **Scope noise.** `get_expenses` returns "the current user's expenses", which may include group expenses where the user's share is 0 (unverified). Skip, or mark as ignored, any expense where the user has no share or where `paid_share` and `owed_share` are both 0.
9. **Terms.** Budgie is non-commercial, so the Self-Serve API fits. The connect flow needs explicit consent and a privacy-policy note. Disconnecting, and `user:delete`, should delete the stored Splitwise data (`dependent: :destroy`). The API could come to require Splitwise Pro.

## Open questions to settle with a live call

- Does `get_expenses` return deleted expenses by default, and does it accept `visible`?
- What sort order does it use, and what is the maximum `limit`?
- What exact share layout does a `payment: true` expense have?
- Does `updated_after` catch deletions and currency conversions (that is, do they bump `updated_at`)?
- Are group expenses where the user has no share included?
- How does `date` look for an expense entered with only a day: always a fixed time, or midnight in some time zone?
- Does the token response ever include `expires_in` or `refresh_token`?
