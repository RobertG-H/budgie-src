# Research: Plaid Link in a Rails app with importmap and no Node

Answers [#144](https://github.com/RobertG-H/budgie-src/issues/144), part of the map [#141](https://github.com/RobertG-H/budgie-src/issues/141): how Plaid Link fits Budgie's front end (Rails 8.1, Hotwire, importmap, no Node, Turbo).

Researched 2026-11-19. Primary sources are Plaid's own docs at [plaid.com/docs](https://plaid.com/docs/): [Link overview](https://plaid.com/docs/link/), [Link web SDK](https://plaid.com/docs/link/web/), [`/link/token/create`](https://plaid.com/docs/api/link/#linktokencreate), [`/item/public_token/exchange`](https://plaid.com/docs/api/items/#itempublic_tokenexchange), [update mode](https://plaid.com/docs/link/update-mode/), [OAuth guide](https://plaid.com/docs/link/oauth/), [Link customization](https://plaid.com/docs/link/customization/), [duplicate Items](https://plaid.com/docs/link/duplicate-items/), [Hosted Link](https://plaid.com/docs/link/hosted-link/) and [`/accounts/get`](https://plaid.com/docs/api/accounts/). For Turbo and Rails the sources are the [Turbo handbook](https://turbo.hotwired.dev/handbook/building), Turbo's own source ([`src/util.js`](https://github.com/hotwired/turbo/blob/main/src/util.js), [`src/core/drive/page_renderer.js`](https://github.com/hotwired/turbo/blob/main/src/core/drive/page_renderer.js)), the [importmap-rails README](https://github.com/rails/importmap-rails) and the [Rails security guide](https://guides.rubyonrails.org/security.html#content-security-policy-header). Anything not stated by a source is marked **inferred**.

## Summary

- **The flow** is three steps across two servers: Budgie's server creates a `link_token`, the browser opens Link with it and gets a `public_token` in `onSuccess`, and Budgie's server exchanges that for a permanent `access_token` and `item_id`. Only the token create and the exchange need Plaid keys, and both are server-side.
- **`link-initialize.js` must come from `cdn.plaid.com`**: Plaid forbids bundling or self-hosting it, and it isn't versioned. So it is a plain `<script src>` tag, not an importmap pin. With a later Content Security Policy it needs `cdn.plaid.com` in `script-src` and `frame-src`, Plaid's API host in `connect-src`, and a nonce on the tag, which Rails and Turbo already handle.
- **Turbo** appends a new `<head>` script on navigation but doesn't wait for it to load, so a Stimulus controller can connect before `window.Plaid` exists. The controller has to wait for it, and should `destroy()` the handler when it disconnects.
- **Update mode** (Reconnect) is a `link_token` made with the Item's `access_token` and no products. The `access_token` doesn't change, so there's no exchange afterwards. Adding or removing accounts on an Item is update mode with `update.account_selection_enabled: true`, which works for Canadian institutions that don't use OAuth.
- **No redirect URI is needed.** Plaid says Canadian institutions don't use OAuth, and on desktop and mobile web OAuth works without one anyway. Leaving `redirect_uri` unset means localhost, testing and production need nothing registered in Plaid's dashboard and nothing new at Cloudflare.
- **Examples:** Plaid's own Quickstart has a Ruby backend (with a React front end), and there's an official `plaid` gem. No Hotwire or Stimulus example from Plaid or Hotwire was found, so Budgie writes its own small Stimulus controller.

## 1. The link-token flow, end to end

### The steps

Plaid's [Link overview](https://plaid.com/docs/link/) lays out the flow:

1. "Call `/link/token/create` to create a `link_token` and pass the temporary token to your app's client."
2. The client opens Link with that token. "In the `onSuccess` callback, Link will provide a temporary `public_token`."
3. The backend calls `/item/public_token/exchange` to swap the `public_token` for a permanent `access_token` and `item_id`.
4. Store the `access_token` and use it for product requests for that Item.

### `/link/token/create`

From the [API reference](https://plaid.com/docs/api/link/#linktokencreate). The endpoint "creates a `link_token`, which is required as a parameter when initializing Link."

| Field | Required | What Plaid says | For Budgie |
| --- | --- | --- | --- |
| `client_name` | yes | "The name of your application, as it should be displayed in Link. Maximum length of 30 characters." | `"Budgie"`. |
| `language` | yes | "The language that Link should be displayed in." Supported languages include "French (`'fr'`)". It must match any Link customization. | `"en"`. |
| `country_codes` | yes | ISO-3166-1 alpha-2 codes that must be ones the account is enabled for; `CA` is a listed value. [`/institutions/get`](https://plaid.com/docs/api/institutions/) says Production access is limited to the US and Canada by default. | `["CA"]`. A customization only applies when `country_codes` match it exactly ([customization](https://plaid.com/docs/link/customization/)). |
| `user.client_user_id` | yes (unless `user_id` is given) | "A unique ID representing the end user." "Personally identifiable information, such as an email address or phone number, should not be used in the `client_user_id`." | The Budget's id (or the User's), never an email. **Inferred**: the Budget's id fits, since connections belong to a Budget. |
| `products` | needed for a new Item; omitted in update mode | "List of Plaid product(s) that the linked Item must support." | `["transactions"]`. The [Transactions guide](https://plaid.com/docs/transactions/): "The `products` array should include `transactions`." |
| `transactions.days_requested` | no | Default 90, range 1 to 730, and "Once Transactions has been added to an Item, this value cannot be updated." | Decide once, at link time. It matters for the "date to read from" question in #141. |
| `webhook` | no | "The destination URL to which any webhooks should be sent." "In update mode, this field will not have an effect." | Leave unset: webhooks are out of scope in #141. |
| `redirect_uri` | no | "should not contain any query parameters"; "When used in Production, must be an https URI"; "must also be added to the Allowed redirect URIs list". | Leave unset. See [section 4](#4-redirect-uri-and-oauth-for-canadian-institutions). |
| `access_token` | update mode only | "The `access_token` associated with the Item to update or reference." "Used when launching Link in update mode." | Reconnect. |
| `update.account_selection_enabled` | no | Enables update mode with Account Select "for institutions in the US and Canada that do not use OAuth." Default `false`. | Adding or removing accounts. |
| `account_filters` | no | "You can further limit the accounts shown in Link by using `account_filters`." "Any account type for which a filter is not specified will be entirely omitted from Link." | **Inferred**: filter to depository and credit, so Wealthsimple's investment accounts aren't offered (investment holdings are out of scope in #141). |
| `link_customization_name` | no | "The name of the Link customization from the Plaid Dashboard to be applied to Link." "If not specified, the `default` customization will be used." | The Account Select setting lives in the customization. See [section 3](#account-selection-in-link). |

The response's `expiration`: by default a token for a new Item "expires after 4 hours", and one created for an existing Item (update mode) "after 30 minutes" ([API reference](https://plaid.com/docs/api/link/#linktokencreate)).

### `onSuccess` metadata

From the [web SDK](https://plaid.com/docs/link/web/#onsuccess). `onSuccess(public_token, metadata)` "is called when a user successfully links an Item."

- `institution`: an object with `name` and `institution_id`. It "will be `null`" only "if the Item was created via Same-Day Micro-deposit verification", which Transactions doesn't use.
- `accounts`: each has `id`, `name`, `mask`, `type`, `subtype` and `verification_status`. **"If Account Select is enabled via the developer dashboard, `accounts` will only include selected accounts."**
- `link_session_id`: "A unique identifier associated with a user's actions and events through the Link flow."
- `onExit(err, metadata)` "is called when a user exits Link without successfully linking an Item". Plaid's example says to create a new link token when `err.error_code` is `INVALID_LINK_TOKEN`.

### `/item/public_token/exchange`

From the [Items API](https://plaid.com/docs/api/items/#itempublic_tokenexchange):

- "The `public_token` is ephemeral and expires after 30 minutes."
- The response is an `access_token` and an `item_id`, and the `item_id` "should be stored with the `access_token`."
- "An `access_token` does not expire, but can be revoked by calling `/item/remove`." For Transactions, calling `/item/remove` is required to stop billing unless the user revoked access. That is what Disconnect should call.
- Under `/item/access_token/invalidate`, Plaid says the token "should be stored in a persistent, secure manner." Budgie's `encrypts :access_token` on `budget_bank_connections` already does this.

### Duplicate Items: check before exchanging

From [Preventing duplicate Items](https://plaid.com/docs/link/duplicate-items/). A duplicate is created "if the end user logs into the same institution with the same credentials", and duplicates "may cause you to be charged multiple times for the same Item." Plaid says to "compare a combination of the accounts' `institution_id`, account `name`, and account `mask`" from `onSuccess` metadata against the user's existing Items, and "Do not exchange a public token for an access token if you detect a duplicate Item." Use update mode instead.

That matters for the Trial's 10-Item cap in #141. It means the browser should send `institution.institution_id` and each account's `name` and `mask` along with the `public_token`, so the server can refuse a duplicate before it exchanges. **Inferred**: browser-supplied metadata is only trusted to *skip* an exchange. What gets stored comes from Plaid's own API after the exchange.

## 2. Loading `link-initialize.js`

### It must come from Plaid's CDN

From the [web SDK](https://plaid.com/docs/link/web/#installation):

- "Include the Plaid Link initialize script on each page of your site."
- "It must always be loaded directly from `https://cdn.plaid.com`, rather than included in a bundle or hosted yourself."
- The URL is `https://cdn.plaid.com/link/v2/stable/link-initialize.js`, and "the JavaScript web SDK is not versioned; `cdn.plaid.com` will automatically provide the latest available SDK."
- npm only comes up for React (`react-plaid-link`). The plain web SDK is a script tag that defines a global `Plaid` with `Plaid.create`.

### Not through importmap

importmap-rails "downloads and vendors your npm package dependencies via JavaScript CDNs", and it is built for "JavaScript libraries made for ES modules (ESM)" ([README](https://github.com/rails/importmap-rails)). `bin/importmap pin` vendoring the file is exactly the self-hosting Plaid forbids. A pin straight to the CDN URL would load it as a module, and Plaid documents it only as a classic script that defines a global. **Inferred**: so `link-initialize.js` is a plain `<script src>` tag, and the importmap stays for Budgie's own Stimulus controller, which reads `window.Plaid`.

"Each page of your site" is what Plaid recommends so that Link can pre-initialize. **Inferred**: Budgie only needs it on the pages that open Link (Connect a bank, and an Account's Reconnect). It goes in `<head>` through the layout's existing `yield :head` (`content_for :head`), so a third-party script isn't on every page.

### How it behaves across Turbo navigations

- On a full page load, the browser evaluates the script as usual.
- On a Turbo Drive visit, "Turbo Drive looks for any `<script>` elements in the new page's `<head>` which aren't present on the current page" and appends them, so the browser loads and runs them. A script that's already on the page isn't added again ([handbook: Working with Script Elements](https://turbo.hotwired.dev/handbook/building#working-with-script-elements)). So Plaid's script runs once per full page load, however many times the Connect page is visited after that.
- "Turbo Drive evaluates `<script>` elements in a page's `<body>` each time it renders the page" (same section). That's a reason to put it in the head and not the body.
- **Turbo doesn't wait for a new head script to load before rendering.** `PageRenderer#mergeHead` awaits new stylesheets (`await newStylesheetElements`), but `this.copyNewHeadScriptElements()` is called without an await ([`page_renderer.js`](https://github.com/hotwired/turbo/blob/main/src/core/drive/page_renderer.js)). The appended element is created with `createdScriptElement.async = false` ([`util.js`](https://github.com/hotwired/turbo/blob/main/src/util.js)), which keeps scripts in order but doesn't block rendering. **Inferred consequence**: after a Turbo visit, a Stimulus controller on the Connect page can `connect()` before `window.Plaid` is defined. The controller has to wait for it, for example by awaiting the script element's `load` event or a short check for `window.Plaid`, before calling `Plaid.create`.
- **Handler lifecycle.** "It is recommended to call `Plaid.create` when initializing the view that is responsible for loading Plaid", so that `open()` is fast. Calls to `open()` "prior to the `onLoad` callback will be delayed until the module is fully loaded." `destroy()` "allows you to destroy the Link handler instance, properly removing any DOM artifacts", and "calling destroy will clean up the iframe" ([web SDK](https://plaid.com/docs/link/web/#create)). **Inferred**: the Stimulus controller calls `Plaid.create` in `connect()` (once Plaid is there) and `handler.destroy()` in `disconnect()`.
- **Turbo's cache.** Turbo snapshots the page before rendering the next one, and says to "Listen for the `turbo:before-cache` event if you need to prepare the document before Turbo Drive caches it", for example to tear down third-party widgets. `<meta name="turbo-cache-control" content="no-cache">` makes a page always come from the network, even on Back ([handbook: Understanding Caching](https://turbo.hotwired.dev/handbook/building#understanding-caching)). **Inferred**: the Connect page should be `no-cache`. A link token rendered into the page then never comes back from the cache once it has expired (4 hours, or 30 minutes in update mode), and Link's iframe is never captured in a snapshot. The page also shouldn't opt into morph refreshes (`turbo_refreshes_with method: :morph`), which would compare the body to the server's and could remove an iframe the server never rendered.

### With a later Content Security Policy

Budgie has no CSP yet: `config/initializers/content_security_policy.rb` is all comments. Its layout already has `csp_meta_tag`, and its one inline script is `javascript_tag nonce: true`. Plaid's [CSP section](https://plaid.com/docs/link/web/#content-security-policy) gives the directives. The nonce variant, for organizations that don't allow `unsafe-inline`, is:

```
default-src https://cdn.plaid.com/;
script-src 'nonce-<PAGE_RESPONSE_NONCE>' https://cdn.plaid.com/link/v2/stable/link-initialize.js;
style-src 'nonce-<PAGE_RESPONSE_NONCE>';
style-src-elem 'nonce-<PAGE_RESPONSE_NONCE>';
style-src-attr 'unsafe-inline';
frame-src https://cdn.plaid.com/;
connect-src https://production.plaid.com/;
```

The script tag in that variant also carries the nonce. "If using Sandbox instead of Production, make sure to update the `connect-src` directive" to `https://sandbox.plaid.com`. Plaid's list is Link's own needs, to be merged into Budgie's policy, not a policy in its own right. Even the nonce variant keeps `style-src-attr 'unsafe-inline'`.

How Rails and Turbo fit:

- Rails applies nonces to `script-src` and `style-src` when a generator is set, and `javascript_include_tag` takes `nonce: true` the same way `javascript_tag` does ([security guide](https://guides.rubyonrails.org/security.html#adding-a-nonce)). So the tag is `javascript_include_tag "https://cdn.plaid.com/link/v2/stable/link-initialize.js", nonce: true` inside `content_for :head`.
- `csp_meta_tag` writes a `csp-nonce` meta tag ([same guide](https://guides.rubyonrails.org/security.html#adding-a-nonce)). When Turbo re-creates a head script during a visit, `activateScriptElement` sets `createdScriptElement.nonce = cspNonce` from `getCspNonce()`, which reads that meta tag, unless the element already has one ([`util.js`](https://github.com/hotwired/turbo/blob/main/src/util.js)). So Plaid's script passes the policy whether it arrives on a full load or a Turbo visit, as long as the nonce generator gives a value that's valid across visits. **Inferred**: Rails' commented-out default, `request.session.id.to_s`, is one such value. With a per-request nonce, a script that a Turbo visit appends would carry a later response's nonce. The policy in force is still the one the document was first loaded with, so that nonce wouldn't match.
- **Inferred**: `connect-src` differs by environment (Sandbox in development and testing, Production in production), so the policy should read the Plaid environment rather than hard-code one host.

## 3. Update mode and account selection

### Reconnecting an Item

From [update mode](https://plaid.com/docs/link/update-mode/):

- Update mode is for when an Item needs user input, such as re-authentication: `ITEM_LOGIN_REQUIRED`, `PENDING_EXPIRATION` and `PENDING_DISCONNECT`. For `NEW_ACCOUNTS_AVAILABLE`, Plaid "has detected new accounts that you may want to ask your users to share."
- Create the link token with the Item's `access_token`. "No products should be added to the `products` array." The exceptions (Assets, Statements, Income, Consumer Report) don't apply to Transactions.
- "An Item's `access_token` does not change when using Link in update mode." Plaid's sample `onSuccess` for update mode doesn't exchange anything. So Reconnect sends nothing secret back. The browser tells the server it finished, and the server clears needs-reconnect after checking with Plaid (**inferred**: for example, `/accounts/get` succeeding).
- An update-mode link token expires after 30 minutes ([API reference](https://plaid.com/docs/api/link/#linktokencreate)).
- After an Item comes back from `ITEM_LOGIN_REQUIRED`, Plaid fills in what was missed. If it was broken for more than 24 hours, Plaid checks for new transactions right after update mode finishes.
- Sandbox: `/sandbox/item/reset_login` forces an Item into `ITEM_LOGIN_REQUIRED` to test it.
- Plaid says to use update mode "to refresh the Item instead of creating a new Item" ([duplicate Items](https://plaid.com/docs/link/duplicate-items/)). That's important because an `account_id` "will not change unless Plaid can't reconcile the account with the data returned by the financial institution", but it can change if the `access_token` is deleted and the same credentials are later used to create a new one ([`/accounts/get`](https://plaid.com/docs/api/accounts/#accounts-get-response-accounts-account-id)). Re-linking instead of updating would break `external_account_id` on Budgie's Accounts.

### Adding or removing accounts on an existing Item

- Set `update.account_selection_enabled: true` on the update-mode link token. `link_customization_name` controls the Account Select pane, and `account_filters` can only be set when account selection is enabled ([update mode](https://plaid.com/docs/link/update-mode/)).
- It is "for institutions in the US and Canada that do not use OAuth" ([API reference](https://plaid.com/docs/api/link/#linktokencreate)), so it fits Wealthsimple, CIBC and TD (see section 4).
- `onSuccess`'s `accounts` then holds "all selected accounts", which is the user's whole current selection, not a difference. Accounts the user de-selects "will no longer be shared with you", data comes only for the selected accounts from then on, and Plaid recommends removing data tied to de-selected accounts ([update mode](https://plaid.com/docs/link/update-mode/)). **Inferred**: under Budgie's rules a de-selected Account's bank transactions stay, as a disconnected Splitwise Account's do, and the Account stops syncing.
- New accounts at the bank: "listen for the `NEW_ACCOUNTS_AVAILABLE` webhook and then use Link's update mode" ([`/accounts/get`](https://plaid.com/docs/api/accounts/)). Webhooks are out of scope in #141. **Inferred**: Budgie offers "Choose accounts" (update mode with account selection) on demand instead.

### Account selection in Link

- The Account Select pane "can be configured to allow for single account selection, multi account selection, or all accounts preselected" ("Single select", "Multi select", "Require all"), in the Dashboard's Link customization ([customization](https://plaid.com/docs/link/customization/)). Plaid suggests "Require all" may suit personal financial management. **Inferred**: "Multi select" suits Budgie better, so a person can leave out accounts they don't budget from, together with `account_filters`.
- Language and countries are set on the customization too, and must "exactly match" the token's `language` and `country_codes` for the customization to apply ([customization](https://plaid.com/docs/link/customization/)).
- The accounts are chosen **inside Link**. Link can't know Budgie's Accounts, so matching each selected Plaid account to a new or existing Budgie Account happens on a Budgie page after `onSuccess`. **Inferred**: so does refusing an account in another currency, from `/accounts/get`'s `balances.iso_currency_code` ([`/accounts/get`](https://plaid.com/docs/api/accounts/)).

## 4. Redirect URI and OAuth for Canadian institutions

- Plaid's OAuth guide: OAuth connections "are not currently used by financial institutions in Canada" ([OAuth](https://plaid.com/docs/link/oauth/)). Its list of OAuth institutions is US banks. The "TD Bank" there is listed under "In the US", so it isn't TD Canada Trust. The live answer for a given institution is `/institutions/get` with `options.oauth`, where each institution's `oauth` boolean "indicates that the institution has an OAuth login flow" ([institutions](https://plaid.com/docs/api/institutions/)). That is a call for the operator, since it needs keys.
- Even for OAuth banks on the web, "OAuth flows will function properly on web even if you don't set up a redirect URI". Desktop and mobile web open the bank's site in a pop-up window when possible, or in a new tab. A redirect URI is required only for webviews and for the web SDK inside a mobile app ([OAuth](https://plaid.com/docs/link/oauth/)).
- If a redirect URI were ever set, it must use HTTPS. Only in Sandbox "redirect URIs pointing to localhost are allowed over HTTP". It must be on the Dashboard's allowed list (subdomain wildcards are allowed there, but never in `/link/token/create`), and it can have no query parameters and no `#` ([OAuth](https://plaid.com/docs/link/oauth/)). The redirect page re-initializes Link with the *same* link token (kept in `localStorage` or server-side) and `receivedRedirectUri: window.location.href`.
- **So for Budgie**: don't set `redirect_uri`. Localhost (Sandbox), `testing.budgiebuddie.com` (Sandbox) and `budgiebuddie.com` (Production) then need no redirect page and no Dashboard allowlist. With webhooks out of scope too, Plaid never calls Budgie's hosts, so Cloudflare needs no new rule (**inferred**). The browser talks to `cdn.plaid.com` and Plaid's API directly, and to Budgie only through Budgie's own requests. If Canadian banks move to OAuth under the open-banking rules ([#37's research](bank-sync-aggregators.md)), desktop and mobile web still work through the pop-up. A redirect URI only becomes necessary if Budgie is ever wrapped in a mobile app.
- OAuth in Production also needs Production access, the MSA and a security questionnaire for US and Canadian banks (deferred on a Trial plan) ([OAuth](https://plaid.com/docs/link/oauth/)). That's moot while Canadian banks don't use OAuth.

### The redirect-free alternative: Hosted Link

[Hosted Link](https://plaid.com/docs/link/hosted-link/) sends the person to a Plaid-hosted page (`hosted_link: {}` in `/link/token/create` returns a `hosted_link_url`) and back to an optional `completion_redirect_uri`. The `public_token` comes from the `SESSION_FINISHED` webhook or from `/link/token/get` (`results.item_add_results`). This is the same shape as Splitwise's redirect flow, and it needs no JavaScript. But Plaid says "Hosted Link should be used *only* when Plaid Link SDKs cannot be used". Its recommended uses are webviews, links sent by SMS or QR code, and iframes the app doesn't control. Without webhooks, Budgie would have to call `/link/token/get` on return. **Inferred**: use the web SDK, as Plaid recommends for the web. Hosted Link is the fallback if the SDK ever proves unworkable with Turbo.

## 5. Examples of Plaid Link in Rails or Hotwire

- **Plaid's Quickstart** ([plaid/quickstart](https://github.com/plaid/quickstart)) has a Ruby backend among Node, Python, Go and Java, but its front end is React. In [`ruby/app.rb`](https://github.com/plaid/quickstart/blob/master/ruby/app.rb), `/api/create_link_token` builds `Plaid::LinkTokenCreateRequest` with `user: { client_user_id: ... }`, `client_name`, `products`, `country_codes`, `language: 'en'` and `redirect_uri` only when `PLAID_REDIRECT_URI` is set. `/api/set_access_token` calls `item_public_token_exchange`. The README says "you should set `PLAID_REDIRECT_URI=http://localhost:3000/`" for Sandbox OAuth testing, and that a redirect URI isn't required for OAuth in general.
- **The official Ruby client** is the `plaid` gem ([plaid/plaid-ruby](https://github.com/plaid/plaid-ruby), "The official Ruby bindings for the Plaid API"). It's generated from Plaid's OpenAPI schema and updated about monthly. **Inferred**: as with Splitwise's plain `Net::HTTP` client, Budgie can either use the gem or call the few endpoints it needs itself, behind one `Plaid.client` seam with a `PlaidFake` in specs (#141's Notes).
- **No Hotwire or Stimulus example from Plaid or the Hotwire team was found.** Third-party examples exist but are secondary. The [DEV Community post "Adding Plaid to your Rails application"](https://dev.to/duartemartins/adding-plaid-to-your-rails-application-2f8f) (2024) puts the CDN `<script>` on the page, fetches a link token from a Rails action on click, and POSTs the `public_token` with the `X-CSRF-Token` header from `csrf_meta_tags`, using inline JavaScript with no Turbo or Stimulus. The [`plaid_rails`](https://rubydoc.info/gems/plaid_rails/0.9.0) engine is old and uses `javascript_include_tag` for the CDN script.

## Implications for Budgie

- **A `plaid-link` Stimulus controller** on the Connect page and on Reconnect: it waits for `window.Plaid`, calls `Plaid.create({ token, onSuccess, onExit })` in `connect()`, opens on the button's click and calls `destroy()` in `disconnect()`. `onSuccess` fills hidden fields (`public_token`, `institution_id`, and each selected account's `id`, `name` and `mask`) in an ordinary Rails form and calls `requestSubmit()`. Turbo then submits it with the CSRF token and follows the redirect, and the page needs no `fetch` (**inferred**). `onExit` with `INVALID_LINK_TOKEN` reloads the page for a fresh token.
- **The script tag** goes in `content_for :head` on those pages only: `javascript_include_tag "https://cdn.plaid.com/link/v2/stable/link-initialize.js", nonce: true`. It is never an importmap pin and never vendored. Those pages also get `<meta name="turbo-cache-control" content="no-cache">` and no morph refresh.
- **The server** creates the link token when it renders the page (Plaid's latency advice; a token lives 4 hours) with `client_name: "Budgie"`, `language: "en"`, `country_codes: ["CA"]`, `user.client_user_id` the Budget's id, `products: ["transactions"]`, a chosen `transactions.days_requested`, `account_filters` for depository and credit, and no `webhook` and no `redirect_uri`. On submit it refuses a duplicate Item by `institution_id` plus account `name` and `mask` *before* exchanging. Then it exchanges, stores the `access_token` (encrypted) and `item_id` on `budget_bank_connections`, and reads `/accounts/get` for the truth.
- **Choosing accounts is two steps.** Link's Account Select pane (set to "Multi select" in the Dashboard customization, by the operator) picks which bank accounts are shared. A Budgie page after it maps each one to a new or existing Account and refuses one in another currency. "Choose accounts" later is update mode with `account_selection_enabled`.
- **Reconnect is update mode**, never a new Link. Its token is made with the `access_token` and no products and lives 30 minutes, and there's no exchange afterwards. A new Item would mint new `account_id`s and use another of the Trial's 10 Items.
- **Disconnect** calls `/item/remove` (it stops Transactions billing) as well as forgetting the token.
- **A later CSP** adds `https://cdn.plaid.com` to `script-src` and `frame-src`, `https://sandbox.plaid.com` or `https://production.plaid.com` to `connect-src` by environment, and `style-src-attr 'unsafe-inline'`. It keeps a nonce generator that's stable across Turbo visits (session-based).
- **No redirect URI, no webhook, no Dashboard allowlist and no Cloudflare change** for localhost, testing or production. The operator's one check is `/institutions/get` confirming `oauth: false` for Wealthsimple, CIBC and TD, recorded in a `docs/plaid.md` box.

## Open questions (for the operator, with keys)

- [ ] `/institutions/get` (`country_codes: ["CA"]`) returns `oauth: false` and `transactions` among `products` for Wealthsimple, CIBC and TD Canada Trust.
- [ ] Link in Sandbox, with the Dashboard customization set to "Multi select" and `country_codes: ["CA"]`, shows the Account Select pane and returns only the chosen accounts in `onSuccess`.
- [ ] Update mode with `account_selection_enabled` on a Sandbox Item lets accounts be added and removed, and `/accounts/get` afterwards shows the new selection with unchanged `account_id`s for the accounts that stayed.
