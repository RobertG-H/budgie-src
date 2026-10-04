# Architecture

Budgie is an envelope-budgeting app for a handful of invited people: one Rails 8.1 application, one
PostgreSQL database, and no other moving parts. There's no API, no mobile client, and no service running
beside the app. Everything on this page exists to serve that one application safely.

- [The stack](#the-stack)
- [The request path](#the-request-path)
- [Inside the application](#inside-the-application)
- [Application integrations](#application-integrations) — what the running app talks to
- [Infrastructure integrations](#infrastructure-integrations) — what runs and delivers it
- [Where configuration lives](#where-configuration-lives)

## The stack

| Layer | What Budgie uses |
| --- | --- |
| Language and framework | Ruby 3.4, Rails 8.1 |
| Database | PostgreSQL 18 |
| Frontend | Hotwire (Turbo and Stimulus), importmap, Tailwind CSS 4, daisyUI |
| Cache, queue and cable | Solid Cache, Solid Queue and Solid Cable, all in PostgreSQL |
| Web server | Puma behind Thruster |
| Local development | Docker Compose |
| Deployment | Kamal, onto two VPS hosts behind Cloudflare |

**There is no Node in the application.** Tailwind is compiled by `tailwindcss-rails`, JavaScript is served
as ES modules through importmap, and there's no `package.json` and no bundler step. Node is only ever
needed on a developer's own machine, for Playwright MCP's `npx`.

**There is no separate worker process on the hosts.** `SOLID_QUEUE_IN_PUMA` runs the Solid Queue
supervisor inside Puma, because invite mail is sent with `deliver_now` and the only recurring jobs are hourly: a
clear-out of finished jobs and the start of each new month's Assigned (see
[The month view and balances](#the-month-view-and-balances)).

## The request path

**In development**, Docker Compose runs three containers. `web` (Puma) is published on
`127.0.0.1:3000` only, so it's reachable from your machine and nowhere else:

```
browser → 127.0.0.1:3000 → web (Puma) → db (PostgreSQL 18)
                             ↑
                           css (the Tailwind watcher, writing app/assets/builds/tailwind.css)
```

**In production**, both hosts run the same image, with `RAILS_ENV=production`, and neither host answers on
its own IP address. `cloudflared` dials *out* to Cloudflare, so nothing dials in, and `kamal-proxy`
publishes its ports on `127.0.0.1` only:

```
browser → Cloudflare edge → tunnel → cloudflared → kamal-proxy on 127.0.0.1:80 → the app → budgie-db
```

Cloudflare terminates TLS, so the app sets `assume_ssl` and counts every request as HTTPS; `force_ssl` is
there for secure cookies rather than for the redirect, which Cloudflare does at the edge. `/up` is exempt
from both the SSL redirect and `config.hosts`, because `kamal-proxy`'s health check sends no public
hostname.

Testing and production differ only in their configuration. Both run the same `config/environments/production.rb`;
what changes comes from each Kamal destination's env and secrets, so testing exercises production's
configuration rather than a lookalike of it.

| Destination | Host | Hostname |
| --- | --- | --- |
| `testing` | `budgie-testing` | `testing.budgiebuddie.com` |
| `production` | `budgie-production` | `budgiebuddie.com` |

## Inside the application

### Sign-in

There are no passwords. People sign in through OmniAuth, and only three places know about a specific
provider:

- `config/auth_providers.yml` lists the enabled providers. It drives both the `/sign_in` buttons and the
  `:provider` constraint on `/auth/:provider/callback`.
- `config/initializers/omniauth.rb` configures each strategy and sends every failure to `/auth/failure`.
- `app/models/auth_profile/<provider>.rb` maps that provider's auth hash to an `AuthProfile` value object.

`SessionsController#create` hands the `AuthProfile` to `SignInWithIdentity`, which returns either a `user`
or a `failure_reason`. It refuses unverified emails, signs a known `[provider, uid]` in as that identity's
user, refuses an unknown identity whose email already belongs to a user, and otherwise creates the `User`
and `Identity` — but only against a pending `Invite`, which it locks and accepts in the same transaction.

Sessions are database rows referenced by a signed, permanent cookie. They expire after 30 days without
use, and `last_active_at` is written at most once an hour. The `Authentication` concern requires sign-in
for every action; `allow_unauthenticated_access` opts out.

### Invites

Budgie is invite-only, and there's no admin page: invites are rake tasks. `Invite` has one row per email
and no status column — pending, accepted and revoked come from `accepted_at` and `revoked_at`.
`InviteMailer#invite` is sent with `deliver_now`, so whoever runs the task sees whether delivery worked.
See [Operating Budgie](operations.md).

### Budget and envelopes

Each user has at most one `Budget`, in a currency chosen during first-run setup; there's no app-wide
default currency. The `RequireBudget` concern redirects a signed-in user without one to budget setup.

Models that belong to a budget are namespaced: `Budget::Envelope` lives in `app/models/budget/envelope.rb`
with the table `budget_envelopes`, and `Budget::Deposit`, `Budget::Spend`, `Budget::Refund`, `Budget::EnvelopeReallocation` and `Budget::ReadyToAssignReallocation` have `budget_deposits`, `budget_spends`, `budget_refunds`, `budget_envelope_reallocations` and `budget_ready_to_assign_reallocations`. `Budget.use_relative_model_naming?`
drops the prefix from routes, params and DOM ids, so it's `envelopes_path` and `EnvelopesController`.
`Current.budget` is the one way controllers and views find the budget — for now the signed-in user's — and
controllers look records up through it, so another user's record is a 404.

Constraints live in the database as well as in the models — check constraints, unique indexes, and
`ON DELETE RESTRICT` foreign keys with Rails deleting children first through `dependent: :destroy`. An amount
is validated as a number under 10¹³ with at most two decimal places, and more places is an error rather than
being rounded.

An envelope with records, such as Assigned amounts, Spends, Refunds or Reallocations (in or out of it, or to Ready to Assign), can't be deleted. The model refuses and its page says why,
with `ON DELETE RESTRICT` as the backstop, and destroying a whole budget (which is what `user:delete` does) deletes its
envelopes' records first so the envelopes can follow.

### The month view and balances

The home page is the month view: `/` is the current month and `/months/YYYY-MM` is any other. Everything
hangs off a month — `/months/YYYY-MM/deposits` lists the Deposits behind Ready to Assign, and
`/months/YYYY-MM/envelopes/:id` is an envelope's page for that month. The time zone is Eastern Time (US &
Canada) for everyone. Records store dates, not times, so it only decides what "today" is: which month `/`
opens on, and what a date field starts as.

Every balance is worked out in one place, `Budget::Month` (`app/models/budget/month.rb`), which views and
controllers only ask. It works on one calendar month of a budget and runs a fixed number of grouped `SUM`
queries, split into "before the month" and "in the month", so the number of queries doesn't grow with the
months of history or with the number of envelopes. Nothing is stored, and no table has a balance column; a
month only remembers the figures it has worked out for as long as the request that asked for them.

A Deposit counts toward Ready to Assign in its `month`, which is the month of its date or the month after it,
so someone living on last month's money can mark each paycheck for next month. Every form remembers the page
it was opened from, as a page name rather than a URL, and goes back there when it's saved, deleted or
cancelled.

Assigned is money moved from Ready to Assign into one envelope for one month, one figure per envelope per month. It is
worked into the same calculator: an envelope's Available is its Starting balance plus everything assigned up to the
month (less everything spent, plus everything refunded and net of everything reallocated, below), and Ready to Assign is the Deposits for the months up to it less everything assigned in them (plus everything reallocated to it, below), still in a fixed
number of grouped queries. Changing an earlier month's Assigned therefore changes every later month. It's set in place on
the month view: each envelope's Assigned cell is a Turbo Frame that swaps between the amount and an input, and saving
refreshes the month view in place with Turbo's morphing, keeping the scroll position. Turbo only refreshes the address it's
already at, and the current month is at `/` as well as `/months/YYYY-MM`, so the home page is a page name of its own, and
saving goes back to whichever one the form was opened from.

Each month starts with the previous month's Assigned, so most envelopes need no entry at all: when a month begins, every
envelope with an Assigned amount the month before and none yet in the new month gets the same amount, and the user changes
only what differs. A copy is an ordinary Assigned amount that nothing marks as copied, and it ignores Ready to Assign, so
if the month's Deposits fall short the card says more was assigned than deposited. Each month keeps its own Assigned:
changing a month that has already begun changes only that month, and the balances after it follow. A month that hasn't
begun shows only what was entered ahead for it, and that is kept when it does.

`budgets.assignments_copied_through` is the latest month copied into. A new budget starts at its first month, which gets no
copy, and `Budget#start_new_months` copies into each month after it, up to the current one, in order. It holds the budget's
row lock and inserts with `unique_by` on `(envelope_id, month)`, so a month is copied into once, an amount the user clears or
changes afterwards stays as they left it, and the number of queries doesn't grow with the number of envelopes. A month
begins at midnight Eastern on the 1st. `StartNewMonthsJob` runs every hour in production through `config/recurring.yml`, so
a month begins within an hour of that and a month missed while the host was down is caught up by the next run. A budget
that can't be started doesn't hold up the others: the job logs it with its id, carries on, and raises the first failure at
the end so the run shows as failed. Its month rolls back whole, so the next run tries it again. Testing and production
both run it, as both are `RAILS_ENV=production`. [Operating Budgie](operations.md#starting-new-months) has
`budget:start_months`, which runs it on demand.

Spent is money paid out of one envelope, recorded as a Spend with a date, and an envelope's Spends in a month add up to
its Spent. It's worked into the same calculator: Available is the Starting balance plus everything assigned up to the
month, less every Spend dated on or before the end of it, in one more grouped query. Ready to Assign doesn't change,
since money spent was already assigned. Like an Assigned amount, a Spend belongs to its budget through its envelope and
has no budget of its own, so it's found through the budget's envelopes and another user's Spend is a 404. The envelope a
Spend is saved against is looked up in the budget's own envelopes rather than taken from the form, so choosing another
budget's envelope is a validation error and nothing is saved. A Spend is listed on its envelope's page for the month of
its date, and an envelope's page starts a new Spend with that envelope chosen.

Refunded is money that comes back to one envelope, such as a store refund, a friend paying you back or an insurance
payout, recorded as a Refund with a date. An envelope's Refunds in a month add up to its Refunded, and Available is the
Starting balance plus everything assigned up to the month, less every Spend and plus every Refund dated on or before
the end of it. A Refund lands in its envelope and never touches Ready to Assign, and it isn't tied to any particular
Spend. It is handled like a Spend, and the two models share their validations and scopes in `DatedEnvelopeRecord` and
their form in `application/_envelope_record_form`: it belongs to its budget through its envelope, the envelope it's saved
against is looked up in the budget's own envelopes, and it's listed on its envelope's page for the month of its date. The month view
shows a Refunded column from `sm:` up (and Reallocated, below) and has no "New refund", since Refunds are rarer than Spends; an envelope's page
has "New refund" beside "New spend", its Refunded, and a Refunds section when the month has any. With Refunds, the core
of the month view is complete, and every balance on it, in a fixed number of grouped queries, comes from `Budget::Month`.

A Reallocation moves money that's already in an envelope into another envelope, such as covering an Overspent envelope
or shifting what's left of one purpose to another, and is recorded with a date. An envelope's Reallocated in a month is
what was moved into it less what was moved out of it, dated in the month, and Available adds every Reallocation into the
envelope and takes off every one out of it, dated on or before the end of the month. It's two more grouped queries (a third, for Reallocations to Ready to Assign, is below), out
by the From envelope and in by the To envelope, so the number of queries still doesn't grow. Ready to Assign doesn't change,
since money moved between envelopes nets to zero, and nothing checks that the From envelope has enough: like a Spend, a
Reallocation can leave it Overspent. Money going from Ready to Assign into an envelope is Assigned, never a Reallocation.
The amount is always positive, because the From and To columns say which way the money moved. A Reallocation belongs to
its budget through its From envelope, both envelopes must be the budget's own (the controller looks them up in the
budget's envelopes), and it shares its description, date, amount and notes rules with Spends and Refunds in
`DatedEnvelopeRecord`. It's made on one Reallocate form at `/reallocations/new`, whose To decides the table (an envelope,
or Ready to Assign, below), so both kinds share the form's fields; editing and deleting are per table, since ids
repeat across them, at `/reallocations/to-envelope/:id` and `/reallocations/to-ready-to-assign/:id`, and once saved its To can't change. It is listed on both of its
envelopes' pages for the month of its date, each row read from that envelope's side ("To Groceries" and negative, or "From
Dining out" and positive), so a form opened from an envelope's page carries that envelope and goes back to its page for as
long as the Reallocation is still in or out of it. The month view shows a Reallocated column from `sm:` up and no
"Reallocate": Assigned stays the plan, set in place, and Reallocated is money moved, and they're never merged. An envelope's
page has "Reallocate" with that envelope as From, its Reallocated, and a Reallocations section when the month has any.

A Reallocation can also move money out of an envelope back into Ready to Assign, such as what's left of a holiday once it's
over. It's the second table of ADR 0007, `budget_ready_to_assign_reallocations`, shaped like a Spend: one envelope (the
form's From), a description, a date, a positive amount and notes, and no budget or month of its own. It counts toward Ready
to Assign in the month of its date, and in every month after, since the money is already in hand and there's no "month
after" choice as a Deposit has. Ready to Assign is then the Deposits less everything assigned plus everything reallocated to
it, and the envelope's Available takes it off, so Ready to Assign plus every envelope's Available is the same with and
without it; its Reallocated is net of it, as of the ones between envelopes. It adds one more grouped query by envelope, and
the budget's own figure is added up from those rows as Assigned is. The Ready to Assign card's description adds
"Reallocated $X" after Assigned when it isn't zero, and a month's Deposits page, which the card links to, has a
Reallocations section below its Deposits when the month has some, listing them from every envelope ("From Dining out"), so
everything behind the card's figures is on that page. An envelope's page lists them with the others, as "To Ready to Assign".
Lowering a month's Assigned and reallocating to Ready to Assign can give the same balances; that overlap is accepted,
and the two stay separate figures: Assigned is the plan for the month, Reallocated is money moved.

### Archiving envelopes

An envelope that's finished with can be archived, which keeps its history and takes it out of use
([ADR 0008](adr/0008-an-archived-envelope-shows-only-where-it-has-figures.md)). It's a nullable `archived_at` on
`budget_envelopes`, null while the envelope is in use, and unarchiving clears it. Archiving is judged against the current
month whichever month's page it's done from, and holds the budget's row lock, as starting a new month does: it's refused,
with a message that says what's wrong and what to do, unless Available is 0 in the current month and nothing for the
envelope is dated after it (no Assigned for a later month, and no Spend, Refund or Reallocation of either kind, on either
side). Unarchiving has no precondition and gives the envelope no Assigned.

An archived envelope takes no new records: the Spend, Refund and Reallocation models refuse to add one to it or to move
one into it, and the pickers offer only envelopes in use, plus a record's own, so an edit form keeps it. A record that's
already in one can still be changed and deleted. Its Assigned is read-only in every month, the monthly copy of last month's
Assigned skips it, and its name stays reserved. Nothing about the formulas changes, so Ready to Assign still counts what it
had assigned, in the months it had it.

The month view shows an archived envelope's row, with an "Archived" badge and its Assigned as plain text, only in a month
where one of its figures isn't zero, so past months still add up and the envelope is gone from the months where it has
nothing to say. Every envelope's figures are still worked out in the same grouped queries, so the query count doesn't
change. Below the table, an "Archived envelopes" section lists every archived envelope, each linking to its page for the
month viewed. An archived envelope's page has Unarchive in place of Archive and no New spend, New refund or Reallocate.

### Importing

A person can import the CSV their bank lets them download into an Account, and file each row as the Deposits, Spends and
Refunds it was, or ignore it. The model is the `roadmap` issue
[#67](https://github.com/RobertG-H/budgie-src/issues/67), built in slices, and these are the parts that exist so far: CSV
formats, then Accounts, Imports and bank transactions.

**CSV formats.** A CSV format (`budget_csv_formats`) says how one bank lays out its download: how many rows to skip, which
columns hold the date and the description, how the date is written, and which of three ways the amount is given: one signed
column, separate money in and money out columns, or one unsigned column with another that says which way it went. There are no
presets, so a person builds each one from a sample of their own file, which is shown as a numbered grid with a live preview of
how its first rows would be read. Money in is always positive and money out negative once a file is read, whatever the bank's
convention ([ADR 0009](adr/0009-a-bank-transaction-has-a-signed-amount-and-is-filed-for-its-exact-sum.md)), and the preview
spells out the date and says "Money in" or "Money out" in words, so a wrong sign or a swapped day and month is noticed before
anything is imported.

**One reader.** `Budget::CsvFormat#read` reads a file with a format into rows of a date, a description and a signed amount, or
refuses it, naming the first bad row by its line and giving the reason, and nothing is read from a file with anything wrong with
it. The preview and every Import use that one reader, so a file can't preview one way and import another. It keeps to the
core's money rule (at most 2 decimal places, never rounded), and to limits that keep a request small: UTF-8, 2 MB and 5,000
rows. A row of 0 is skipped and counted, not refused.

**The sample isn't kept.** The builder sends the sample file with the form each time a choice changes, and the server answers
with the grid and the preview, so the sample only exists for a request, and there's no reader written in JavaScript to keep
in step with the real one. Saving a format never imports the sample: the person uploads the file again to import it.

**Accounts, Imports and bank transactions.** An Account is a real bank or card account, with only a name: Budgie doesn't track what's
in it ([ADR 0001](adr/0001-budgie-does-not-track-account-balances.md)). A person imports a CSV file into one with a CSV format,
and each row becomes a bank transaction, which is the bank's record of money moving in or out, with a signed amount. Bank
transactions are read-only, and are found through their Account, as a Spend is through its envelope. The file isn't kept, only its
name, and the Import commits straight away: a file that can't be read creates nothing, and says which row and why.

**Overlapping files** are the normal case, so a row is recognised by what it is, not by an ID the bank doesn't give it
([ADR 0010](adr/0010-duplicates-are-recognised-by-content-and-an-occurrence-count.md)). Each row has a content key, a digest of its
Account, date, signed amount and description (trimmed, whitespace collapsed, case folded), and an occurrence number for each time
the same key is in the Account. For each key an Import adds as many rows as the file has beyond those the Account already has, so
two identical coffees on one day both come in, while the same file again, or one that overlaps, adds only what's new. The key and
occurrence are written when the row is made and never recomputed, because they record how it first looked. The description as a
Filing rule reads it is a separate, generated column that follows the description, which bank sync will update in place.

**One request, one Import.** It runs in the request, holds the Account's row lock and inserts every row at once, so it makes the same
number of queries for 10 rows as for 1,000, a double submit imports once, and there's no job to wait for. Its summary is a page of
its own, worked out from the rows it added: the dates, the money in and money out, and the first row as it was read, so a wrong
sign or a swapped day and month, which both read without error, is noticed straight away. An Account's page lists its bank
transactions a page at a time, since one Import can bring in 5,000.

The header has a second row of links to the pages that aren't a month's: the budget, Accounts and CSV formats so far.

### Frontend

One daisyUI theme, `budgie`, defined by two vendored plugin files pinned to a release rather than fetched
live. `@theme { --color-*: initial; }` in `app/assets/tailwind/application.css` makes Tailwind's raw palette
classes produce nothing, so a stray `bg-gray-200` fails loudly instead of drifting in. Reusable markup lives
in `app/views/components/`. [`DESIGN.md`](../DESIGN.md) has the rules.

### Development-only surfaces

`/styleguide`, `GET /dev/sign_in`, the seeded development user and Playwright MCP exist to build and view
the UI on a developer's own machine. They must never be reachable in `test`, on the testing host or on the
production host. Testing and production both run `RAILS_ENV=production`, so every guard checks
`Rails.env.development?`, never `!Rails.env.production?` — the routes are drawn only in development *and*
the controllers refuse outside it, so a routing mistake alone can't expose them. Specs prove both.

## Application integrations

What the running application depends on. Everything here is reached from the app process itself.

| Integration | What it does | Configured by | Without it |
| --- | --- | --- | --- |
| [Google OAuth 2.0](google-oauth.md) | The only way to sign in. One OAuth client per environment, in one Google Cloud project | `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` | Nobody can sign in |
| [Zedmail SMTP relay](email.md) | Delivers invite email from `budgiebuddie.com` on testing and production | `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` and `MAILER_FROM` | Invites can't be sent, so nobody new can join |
| `letter_opener_web` | Catches mail in development at `/letter_opener` instead of delivering it | Mounted in development only | — |
| PostgreSQL 18 | The primary database, plus the cache, queue and cable databases next to it | `DB_HOST` and `BUDGIE_DATABASE_PASSWORD`; `config/database.yml` | The app won't boot |
| Tailwind CSS 4 and daisyUI | All styling. daisyUI is vendored as two plugin files pinned to a release | `app/assets/tailwind/`; see [daisyUI](daisyui.md) | No styles |
| Hotwire and importmap | Turbo and Stimulus, served as ES modules with no build step | `config/importmap.rb` | No interactivity |

The SMTP settings are generic, so switching mail providers means changing those variables and nothing else.

## Infrastructure integrations

What builds, runs and delivers the application. None of this is reachable from the app process.

| Integration | What it does | Where it's set up |
| --- | --- | --- |
| Docker and Compose | Runs everything locally, and builds the production image from the same `Dockerfile` | [Local development](development.md) |
| [OVHcloud](provisioning.md) | Two VPS instances on Ubuntu 26.04 LTS, `budgie-testing` and `budgie-production`, built from one script | `script/provision.sh` |
| [Cloudflare](cloudflare.md) | Registrar, DNS, TLS and edge rules for `budgiebuddie.com`, plus one Tunnel per host so neither answers on its IP | The Cloudflare dashboard and `script/cloudflare-tunnel.sh` |
| [Kamal](deployment.md) | Builds, pushes and runs the image on each host, with PostgreSQL as an accessory | `config/deploy*.yml` and `.kamal/secrets*` |
| GitHub Actions | Runs the checks on every pull request, deploys testing on every merge, and deploys production on dispatch | [CI](ci.md) and [Deploying](deployment.md) |
| GitHub Container Registry | Holds the private image `ghcr.io/robertg-h/budgie` and its build cache | `config/deploy.yml` |
| GitHub environments | Holds each destination's deploy secrets and restricts deploys to `main` | [Deploying](deployment.md#the-environment-secrets) |
| Dependabot | Weekly pull requests for gems and Actions, which run the same required checks | `.github/dependabot.yml` |
| 1Password | Holds the SSH key you log in to the hosts with, and the master copy of every secret | [Provisioning](provisioning.md#the-ssh-key-in-1password) |

## Where configuration lives

| Thing | Where |
| --- | --- |
| Local containers and volumes | `compose.yaml` |
| The images | `Dockerfile` — `development` is what Compose runs; the default target is the production image Kamal deploys |
| Enabled sign-in providers | `config/auth_providers.yml` |
| Production behaviour: TLS, allowed hosts, SMTP, mailer links | `config/environments/production.rb` |
| What both destinations share | `config/deploy.yml` |
| What differs per destination | `config/deploy.testing.yml` and `config/deploy.production.yml` |
| Which secret each variable comes from | `.kamal/secrets-common` and `.kamal/secrets.<destination>` — names only, never values |
| Secret values, for a break-glass deploy | `.env.kamal`, `.env.testing` and `.env.production`, all gitignored |
| Secret values, for CI | The `testing` and `production` GitHub environments |
| Development secrets | `.env`, gitignored, loaded into the `web` container |
| The checks and the deploys | `.github/workflows/ci.yml` and `.github/workflows/deploy-production.yml` |
| UI rules | [`DESIGN.md`](../DESIGN.md) |

The repository is public, so the host IP addresses stay out of git: the destination files read them from
`TESTING_HOST_IP` and `PRODUCTION_HOST_IP`. Hostnames are public either way — they're in DNS and in
Certificate Transparency logs — so they're committed.
