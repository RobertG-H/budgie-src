# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Budgie is an envelope-budgeting app built with Rails 8.1, PostgreSQL 18, Hotwire, importmap and Tailwind CSS 4 (no Node).
Development runs entirely in Docker Compose (`web`, the `css` Tailwind watcher, and `db`); the host has no Ruby.
The `Dockerfile`'s `development` target is what Compose runs, and its default target is the production image that Kamal deploys.
Compose also has a `kamal` service, in the `deploy` profile, that the operator deploys with.

`docs/architecture.md` is the reader-facing tour of the stack and every integration; `docs/development.md` and `docs/infrastructure.md` are the two setup guides. The Architecture section below is the working detail Claude needs, and the two shouldn't contradict each other — update both when one changes.

## Commands

Use these exact spellings. They match `docs/development.md`, and this checkout's permission rules are written for them.

| Task | Command |
| --- | --- |
| Run all specs | `docker compose run --rm web bin/rspec` |
| Run one file or example | `docker compose run --rm web bin/rspec spec/models/user_spec.rb:12` |
| Lint | `docker compose run --rm web bin/rubocop` |
| Security scans | `docker compose run --rm web bin/brakeman --no-pager` and `docker compose run --rm web bin/bundler-audit` |
| Migrate | `docker compose run --rm web bin/rails db:migrate` |
| Generate | `docker compose run --rm web bin/rails generate ...` |
| Routes | `docker compose run --rm web bin/rails routes` |
| Server logs and container status | `docker compose logs web` and `docker compose ps` |
| Set up the databases, then start the app | `docker compose run --rm web bin/rails db:prepare`, then `docker compose up` |
| Build the production image | `docker build .` |

- Specs load the test schema from `db/schema.rb`, so run `db:migrate` after adding a migration to update it.
- Gems live in the Compose `bundle` volume, not the image. After editing the `Gemfile`, run `docker compose exec -T web bundle install`, then `docker compose restart web` so the server loads new gems and initializers. Restart it after `db:migrate` changes an existing table too: the running server keeps the table's old columns, so a new record of its model fails with `undefined method` for a new column until it restarts.
- CI (`.github/workflows/ci.yml`, see `docs/ci.md`) runs four checks, which a ruleset requires on `main`: `scan_ruby` (Brakeman and bundler-audit), `scan_js` (`bin/importmap audit`), `lint` (RuboCop) and `test`. RuboCop uses the Rails omakase style, including double quotes and spaces inside array brackets (`[ :a, :b ]`).
- `test` runs the specs with `CI=true`, which eager-loads every file, so a file that fails to load fails CI even when the local run passes. Then it rebuilds `db/schema.rb` from the migrations on an empty database and fails if that differs from the committed file, so never hand-edit `schema.rb`: commit the one `db:migrate` writes.

## Blocked commands and secrets

- Permission rules deny these whether they're spelled with `docker compose run` or `exec`: `rails runner`, `console`, `dbconsole`, `credentials` and `encrypted`; destructive database tasks such as `db:drop`, `db:reset`, `db:rollback` and `db:schema:load`; shells inside containers; and `curl`/`wget`. If a task needs one, ask the user rather than getting the same effect another way, such as running `curl` inside the container.
- Provisioning is a manual ops task. `script/provision.sh` configures the OVH VPS hosts (Ubuntu 26.04 LTS) and only ever runs on them; they aren't reachable from this checkout, so Claude edits the script and `docs/provisioning.md` here, and the operator runs it and ticks the verification boxes.
- Cloudflare is manual ops in the same way. `script/cloudflare-tunnel.sh` puts a host behind its Cloudflare Tunnel and only ever runs on that host, and the domain, zone settings, tunnels and rules live in the Cloudflare dashboard. Claude edits the script and `docs/cloudflare.md` here; the operator runs it, works the dashboard and ticks the boxes. Most of the verification is `curl` and `dig` against real hosts, and `curl` is blocked here, so don't try to check any of it from this checkout.
- Deploys run in CI, not by hand: a push to `main` deploys testing once CI passes, and the operator dispatches **Deploy production**, which only accepts a commit testing has already run. See `docs/deployment.md#ci-deploys`. Claude writes the Kamal config (`config/deploy.yml`, `config/deploy.<destination>.yml` and `.kamal/secrets*`), the workflows (`ci.yml`'s `deploy_testing` job and `deploy-production.yml`) and `docs/deployment.md`, and can read runs and logs with `gh run list`/`gh run view` to help debug, but never runs `kamal` and never dispatches or re-runs a deploy — the hosts aren't reachable from this checkout, and permission rules deny `gh workflow run` and `gh run rerun` as well. A break-glass deploy from the laptop still runs through the `kamal` Compose service, as `docker compose run --rm kamal deploy -d testing`. It's the only service with the Docker socket and the SSH agent, and it loads the deploy secrets from `.env.kamal`, `.env.testing` and `.env.production`. `.kamal/secrets*` only ever map names to those variables — locally, or to the `testing`/`production` GitHub environments' secrets in CI — and never hold values.
- The repo is public. The host IP addresses stay out of git: the destination files read them with ERB from `TESTING_HOST_IP` and `PRODUCTION_HOST_IP`, which live in `.env.testing` and `.env.production`.
- Claude's file tools can't read or write `.env` or `.env.*`, including `.env.example`, so ask the user to edit those. Compose loads `.env`, which holds the Google OAuth client secret, into the `web` container, so don't print the container's environment.

## Architecture

### Sign-in

There are no passwords: people sign in through OmniAuth, and only three places know about a specific provider.

- `config/auth_providers.yml` lists the enabled providers. It's loaded into `Rails.configuration.x.auth_providers` and drives both the `/sign_in` buttons and the `:provider` constraint on `/auth/:provider/callback`.
- `config/initializers/omniauth.rb` configures each provider's strategy and sends every failure to `/auth/failure`, in development too.
- `app/models/auth_profile/<provider>.rb` maps that provider's auth hash to an `AuthProfile` value object. `AuthProfile.from_omniauth` picks the mapper by provider name.

`SessionsController#create` hands the `AuthProfile` to `SignInWithIdentity` (`app/services/`), which returns a result holding either a `user` or a `failure_reason`.
It refuses unverified emails, signs a known `[provider, uid]` in as that identity's user (refreshing `Identity.email`, `User.name` and `User.avatar_url`), refuses an unknown identity whose email already belongs to a user, and otherwise creates the `User` and `Identity`.
Creating them needs a pending `Invite` for the email; it's locked and accepted in the same transaction, and without one the reason is `:not_invited`.
Refusals are logged. `SessionsController::REFUSAL_MESSAGES` gives `:not_invited` its own invite-only message; every other reason shows one generic message.

### Invites

`Invite` has one row per email and no status column: `status` (pending / accepted / revoked) comes from `accepted_at` and `revoked_at`, and `created_at` is the invited time.
`Invite.issue!`, `.resend!` and `.revoke!` hold the re-invite and revoke rules and raise `Invite::Refused` with an operator-facing message; `lib/tasks/invite.rake` wraps them.
`InviteMailer#invite` is sent with `deliver_now`. Development delivers to `letter_opener_web` at `/letter_opener`, and production uses SMTP from the `SMTP_*` and `MAILER_FROM` variables.
`lib/tasks/user.rake` has `user:delete EMAIL=`, which asks for the email on stdin before `user.destroy!`. Destroying a user destroys their invite too, so the email can be invited again; give new user-owned records `dependent:` options so it keeps working.
In specs, a Google sign-in that should create a user needs `create(:invite, email: ...)` first. Rake task specs use `type: :task` and `run_task(name, stdin:, **env)` from `spec/support/rake_helpers.rb`.

The `Authentication` concern in `ApplicationController` requires sign-in for every action; opt out with `allow_unauthenticated_access`.
Sessions are database rows referenced by a signed, permanent cookie. They expire after 30 days without use, and `last_active_at` is written at most once an hour.
The page to return to after sign-in is saved only for GET requests that aren't Turbo hover prefetches. `Current.user` is the signed-in user.

### Budget and envelopes

Each user has at most one `Budget` (unique `user_id`), in a currency they choose on first-run setup. There's no app-wide default currency.
`Budget::CURRENCIES` lists the supported two-decimal currencies with their names and display units; add a currency there. Amounts are shown with `money(amount, budget:)` from `ApplicationHelper`, and the currency code appears once, in the header.
The `RequireBudget` concern in `ApplicationController` redirects a signed-in user without a budget to `new_budget_path`; opt out with `allow_missing_budget`.
`budget:currency EMAIL= CURRENCY=` in `lib/tasks/budget.rake` is the only way to change a currency, and it doesn't convert amounts.

Models that belong to a budget are namespaced: `Budget::Envelope` lives in `app/models/budget/envelope.rb` with the table `budget_envelopes`, and `Budget::Deposit`, `Budget::Spend`, `Budget::Refund`, `Budget::EnvelopeReallocation` and `Budget::ReadyToAssignReallocation` follow suit with `budget_deposits`, `budget_spends`, `budget_refunds`, `budget_envelope_reallocations` and `budget_ready_to_assign_reallocations`, as later tables will.
`Budget.use_relative_model_naming?` drops the prefix from routes, params and DOM ids, so it's `envelopes_path`, `params[:envelope]` and `EnvelopesController`.
`Current.budget` is the one way controllers and views find the budget. For now it's the signed-in user's, and Multiple and shared budgets will change how it's picked, so nothing reads `Current.user.budget`. Controllers look records up through it, so another user's record is a 404, and `budget_id` is never a permitted param.

Constraints live in the database as well as the model (check constraints, unique indexes such as `(budget_id, lower(name))`). Foreign keys are `ON DELETE RESTRICT`, and Rails deletes children first through `dependent: :destroy`, so give new budget tables `dependent:` options to keep `user:delete` working.
PostgreSQL reports a restrict violation as `PG::RestrictViolation`, which Rails raises as a plain `ActiveRecord::StatementInvalid`, not `ActiveRecord::InvalidForeignKey`.
An envelope with records can't be deleted: `Budget::Envelope` has `has_many :assignments`, `:spends`, `:refunds`, `:outgoing_reallocations`, `:incoming_reallocations` and `:ready_to_assign_reallocations`, all `dependent: :restrict_with_error`, with the alert's wording, the same for each, in `config/locales/en.yml`, so `EnvelopesController#destroy` redirects to the envelope's page with it, and `ON DELETE RESTRICT` is only the backstop. Destroying a `Budget` deletes its envelopes' records first, in a `before_destroy` with `prepend: true` so it runs ahead of the `has_many :envelopes` callback; `Budget#delete_envelope_records` deletes Assignments, Spends, Refunds and Reallocations (to an envelope, in or out of the envelopes, and to Ready to Assign), and `user:delete`'s confirmation counts them; a new table of records for an envelope joins both, and `Budget::Envelope#dated_after?`, which archiving checks. `Budget#assignments`, `#spends`, `#refunds`, `#envelope_reallocations` (through the envelopes' `outgoing_reallocations`, so each Reallocation once) and `#ready_to_assign_reallocations` are `has_many :through` envelopes, for reading only: never `delete_all` through them, which would delete the envelopes.
An amount in a `decimal(15, 2)` column is validated with `money: true` (any sign) or `money: { positive: true }` (`app/validators/money_validator.rb`): a number under 10**13 with at most 2 decimal places, where more places is an error and never rounded.

### Archiving envelopes

`budget_envelopes.archived_at` is null while an envelope is in use and the time it was archived otherwise, the way an Invite's status comes from its timestamps; it's the table's only nullable column and has no default. `Budget::Envelope` has `archived?` and the scopes `active` and `archived`. Names stay unique across archived envelopes (the `(budget_id, lower(name))` index is unchanged), so creating "Car" while an archived "Car" exists is refused, with an error that says so.
`Budget::Envelope#archive!` is judged against today's month (`Date.current`, Eastern), whichever month's page it's asked from, inside `budget.with_lock` (the lock `start_new_months` takes, so the monthly copy can't land on an envelope as it's archived). It raises `Budget::Envelope::Refused`, as `Invite::Refused` carries its message, with a message of its own unless Available is 0 in the current month and nothing is dated after it: no Assigned for a later month and no Spend, Refund or Reallocation of either kind, on either side, dated after the end of it. An archived envelope stays as it is. `#unarchive` clears `archived_at` with no precondition and gives no Assigned. `EnvelopeArchivesController` (`resource :archive` under `envelopes`, `POST` archives and `DELETE` unarchives) goes back to the envelope's page for the month the button was on, with the notice "Envelope archived." or "Envelope unarchived.", and a refusal is the alert, as Delete's is.
An archived envelope takes no new records. `DatedEnvelopeRecord.refuse_archived_envelopes` is declared on Spend, Refund and both Reallocations (From and To, for one between envelopes), and puts "is archived" on the envelope field when a record is added to one or moved into one; a record already in one stays editable and deletable. Its Assigned is read-only: `Budget::Envelope#assign` and `Budget::Assignment#assign` refuse a new amount, a changed one and clearing one in any month, and `Budget::Assignment` refuses to be saved for an archived envelope, with the reason on `errors` as for any refused amount. `Budget#copy_assignments` reads only active envelopes' Assigned. Ready to Assign still counts what was assigned, so nothing about the formulas changes. Renaming one and changing its Starting balance are allowed.
Pickers use `envelope_options(keeping:)` (`ApplicationHelper`): the budget's envelopes in use, and the ids in `keeping`, which is a saved record's own envelope so an edit form keeps it. `?envelope=` for an archived envelope is no envelope on the Spend, Refund and Reallocate forms, though the controllers' return paths still find it, since a record in an archived envelope is edited from its page.
`Budget::Month#envelopes` returns the lines to show: every envelope in use, and an archived one only in a month where one of its figures (Carried over, Assigned, Spent, Refunded, Reallocated) isn't zero (`EnvelopeLine#shown?`), so hiding is by figures and not by date. The figures are worked out for every envelope as before, so the query count is the same; `envelope_line(id)` finds any of the budget's envelopes, archived ones included, and `archived_envelopes` lists all of them. The month view gives an archived row an "Archived" badge (`components/archived_badge`) and its Assigned as plain text, lists every archived envelope in an "Archived envelopes" `<details>` below the table, each linking to its page for the month viewed, and says "All your envelopes are archived." instead of "You don't have any envelopes yet." when the table is empty and the budget has archived envelopes. An archived envelope's page has the badge by its title and Unarchive in place of Archive, and no New spend, New refund or Reallocate.

### The month view and balances

The home page is the month view: `/` is the current month and `/months/YYYY-MM` any other, and anything else is a 404. Navigation isn't bounded: a year has four to six digits, because a date field takes up to 275760, though there's no month before 0001-01, as PostgreSQL has no year 0. Everything hangs off a month: `/months/YYYY-MM/deposits` lists the Deposits behind Ready to Assign, and `/months/YYYY-MM/envelopes/:id` is an envelope's page for it. Adding, editing and deleting records stay on flat routes (`/deposits`, `/envelopes`, `/spends`, `/refunds`, `/reallocations`), except an Assignment, which has no id of its own: it's the one figure for an envelope in a month, so it's a singular resource under both.
`config.time_zone` is Eastern Time (US & Canada) for everyone. Records store dates, not times, so it only decides "today": which month `/` opens and what a date field starts as.
`Budget::Month` (`app/models/budget/month.rb`) is the only place a balance is computed, so views and controllers do no arithmetic on balances. `Budget::Month.new(budget, date)` works on the calendar month containing `date` and exposes `ready_to_assign` (with its `carried_over`, `deposited`, `assigned` and `reallocated`, and `over_assigned?` for when it's below zero), `envelopes` (alphabetical, and an archived envelope only in a month where it has a figure, each with its `carried_over`, `assigned`, `spent`, `refunded`, `reallocated` and `available`), `envelope_line(id)`, `previous` and `next`. It runs a fixed number of grouped `SUM … FILTER` queries, split into "before the month" and "in the month", so the query count doesn't grow with months of history or with envelopes, and `spec/models/budget/month_spec.rb` checks that. It uses BigDecimal throughout and stores nothing: no table has a balance column, and a `Budget::Month` remembers the figures it has worked out only for as long as it lives, which is one request. A new figure is added there, in grouped queries of the same kind.
Assigned (`Budget::Assignment`, `budget_assignments`) is one figure per envelope per month: Available(M) is the Starting balance plus every Assignment with month <= M (less every Spend, plus every Refund and net of every Reallocation, below), Carried over(M) is Available(M - 1), and Ready to Assign(M) is the Deposits for months <= M less the Assignments with month <= M, plus the Reallocations to Ready to Assign dated on or before the end of M (below). One grouped query gives each envelope's "before" and "in the month" sums, and the budget's own Assigned is added up from those rows, so a page costs three queries however many envelopes or months there are, Spent adds a fourth, Refunded a fifth, and Reallocated three more (out by From, in by To, and to Ready to Assign). Changing a past month's Assigned changes every later month's balances, and can leave one's Ready to Assign negative.
Assigned is set in place on the month view. Each envelope's Assigned cell is a Turbo Frame that `AssignmentsController` swaps between the amount (`show`) and an input (`edit`), a singular resource under `/months/:month/envelopes/:envelope_id/assignment`. `Budget::Envelope#assign(month, amount)` does the work: a positive amount creates or changes the Assignment, blank or 0 deletes it, and it takes a row lock on the envelope so a double submit can't hit the unique index. Saving goes back to the page the form was opened from (`ReturnsToOrigin`), and the month view refreshes in place with `turbo_refreshes_with method: :morph, scroll: :preserve`, keeping the scroll position. Turbo only does that for the address it's already at, and the current month is at `/` as well as `/months/YYYY-MM`, so the home page is a page name of its own (`home`).
Each month starts with the previous month's Assigned. When a month begins, `Budget#start_new_months` gives every envelope with an Assigned amount in the month before and none in the new month the same amount, so an amount entered ahead is kept and an envelope with nothing the month before gets nothing. A copy is an ordinary `Budget::Assignment` that nothing marks as copied, and it ignores Ready to Assign, which can go negative. It inserts with one `insert_all`, `unique_by` `(envelope_id, month)`, so the query count is fixed however many envelopes there are. `budgets.assignments_copied_through` (a first-of-month date, with a check constraint) is the latest month copied into: a new budget sets it to its first month, which gets no copy, and `start_new_months` copies into each month after it up to the current one, in order and inside `with_lock`, so each month is copied into once, an amount the user clears or changes afterwards stays as they left it, and a month missed while the host was down is caught up by the next run. A month begins at midnight Eastern on the 1st (`Date.current`, from `config.time_zone`), and one that hasn't begun shows only what was entered ahead for it. `StartNewMonthsJob` calls it for each budget in `Budget.with_months_to_start`; a budget that raises is logged with its id and doesn't hold up the ones after it (its month rolls back, so the next run tries again), and the job raises the first failure once the rest are done, so the run shows as failed; `config/recurring.yml` runs it every hour in production, which is testing as well, so a month begins within an hour of midnight, and `bin/rails budget:start_months` runs it now, which is how to try it in development, where recurring tasks don't run.
A Deposit counts toward Ready to Assign in its `month`, not the month of its `date`: the month of its date or the month after, chosen per Deposit and defaulting to the date's.
Spent (`Budget::Spend`, `budget_spends`) is money paid out of one envelope on a `date`, and an envelope's Spends in a month add up to its Spent: Available(M) is the Starting balance plus every Assignment with month <= M less every Spend dated on or before the end of M, and Ready to Assign doesn't change, since money spent was already assigned. A Spend has no `budget_id`: it belongs to its budget through its envelope, so `Current.budget.spends` finds it and another user's Spend is a 404. `SpendsController` never takes `envelope_id` as given: it looks the id up in `Current.budget.envelopes`, so another budget's envelope is a validation error on the envelope field, and an update that names no envelope leaves it. A Spend is listed on its envelope's page for the month of its date (`Budget::Spend.dated_in`), and saving, deleting or cancelling goes back to the month of its date, and to the page of its envelope, which may have changed, for `from=envelope`. An envelope's page starts a Spend with that envelope chosen through `?envelope=<id>`.
Refunded (`Budget::Refund`, `budget_refunds`) is money coming back to one envelope on a `date`, such as a store refund, a friend paying you back or an insurance payout, and an envelope's Refunds in a month add up to its Refunded: Available(M) is the Starting balance plus every Assignment with month <= M less every Spend, plus every Refund, dated on or before the end of M. A Refund lands in its envelope and never in Ready to Assign, which doesn't change, and it isn't linked to any particular Spend. It follows a Spend's rules, which the two models share through `DatedEnvelopeRecord` and their form through `application/_envelope_record_form`: no `budget_id`, found through `Current.budget.refunds`, `RefundsController` looks `envelope_id` up in `Current.budget.envelopes`, it's listed on its envelope's page for the month of its date and saving, deleting or cancelling goes back to the page the form was opened from. The month view has a Refunded column from `sm:` up only and no "New refund"; an envelope's page has "New refund" with that envelope chosen, its Refunded, and a Refunds section only when the month has some. Spent and Refunded each add one grouped query to a page, so with Refunds the core month view is complete and every balance on it comes from `Budget::Month`.
Reallocated (`Budget::EnvelopeReallocation`, `budget_envelope_reallocations`) is money moved out of one envelope into another on a `date`, such as covering an Overspent envelope: an envelope's Reallocated in a month is the Reallocations into it dated in the month less those out of it, and Available(M) is the Starting balance plus every Assignment with month <= M, less every Spend, plus every Refund, plus every Reallocation into the envelope, less every Reallocation out of it, dated on or before the end of M. Ready to Assign doesn't change for a Reallocation between envelopes, since money moved between envelopes nets to zero, and a Reallocation isn't linked to any Spend, Refund or Assigned amount. Its amount is always positive: `from_envelope_id` and `to_envelope_id` say which way the money moved, they must differ (a check constraint and a validation) and be the same budget's, and nothing checks the From envelope's Available, so one can leave it Overspent. It has no `budget_id`: it belongs to its budget through its From envelope (`Current.budget.envelope_reallocations`), and `DatedEnvelopeRecord` gives it a Spend's description, date, amount, notes, `dated_in` and `newest_first`, while each model declares its own `belongs_to`. Its envelopes are looked up in `Current.budget.envelopes`, so another budget's is a validation error on From or To ("can't be blank", as for a Spend). `Budget::Month` adds two grouped queries, out by From and in by To (a third, for Reallocations to Ready to Assign, is below), and `EnvelopeLine#reallocated` is the net of all three. The Reallocate form is one endpoint, `/reallocations/new` and `POST /reallocations` (`ReallocationsController`), whose To decides the table, so its fields are under one `reallocation` param key and To's first option is Ready to Assign, sent as `Reallocating::READY_TO_ASSIGN` (`ready-to-assign`) where an envelope sends its id; edit, update and delete are per table because ids repeat, at `/reallocations/to-envelope/:id` (`EnvelopeReallocationsController`) and `/reallocations/to-ready-to-assign/:id` (`ReadyToAssignReallocationsController`), and once saved To can't change: an update that sends one leaves it. No URL or param key spells `ready_to_assign`, which `spec/requests/vocabulary_spec.rb` rejects in the markup of the envelope page and a month's Deposits page; `edit_polymorphic_path` picks the edit page by the Reallocation's table. All three controllers share `Reallocating`: a Reallocation is on both its envelopes' pages, so a form opened from an envelope's page carries that envelope as `envelope`, and saving, deleting or cancelling goes back to its page while the Reallocation is still in or out of it, and to the From envelope's page otherwise. The month view has a Reallocated column from `sm:` up only, between Refunded and Available, and no "Reallocate" (Assigned stays the plan and Reallocated is money moved, never merged); an envelope's page has "Reallocate" with that envelope as From, its Reallocated, and a Reallocations section only when the month has some, each row read from that envelope's side ("To Groceries" with a negative amount, or "From Dining out" with a positive one).
Reallocated to Ready to Assign (`Budget::ReadyToAssignReallocation`, `budget_ready_to_assign_reallocations`) is money moved out of one envelope back into Ready to Assign on a `date`, such as unspent holiday money; money going from Ready to Assign into an envelope is still Assigned. It's shaped like a Spend: `envelope_id` (the form's From, so `config/locales/en.yml` names it From), description, date, a positive amount and notes, no `budget_id` and no `month`, and it includes `DatedEnvelopeRecord` and declares its own `belongs_to :envelope`. It counts toward Ready to Assign in the month of its `date`, with no "month after" choice as a Deposit has: Ready to Assign(M) adds every one dated on or before the end of M, and Available(M) takes it off its envelope, so Ready to Assign plus every envelope's Available is the same with and without it. `Budget::Month::ReadyToAssign#reallocated` is this month's, with the earlier months' in `carried_over`, added up from each envelope's rows as Assigned is, and the same grouped query is subtracted from each envelope's Reallocated, so it adds one query by envelope. The Ready to Assign card's description gains "Reallocated $X" after Assigned only when it isn't zero, and a month's Deposits page (`/months/YYYY-MM/deposits`, which the card links to) has a Reallocations section below its Deposits, only when the month has some, listing them from every envelope, each "From Dining out", and linking to the edit page with `from=deposits`. An envelope's page lists them in its Reallocations section as "To Ready to Assign", with the ones between envelopes. Lowering a month's Assigned and a Reallocation to Ready to Assign can give the same balances, which is accepted: Assigned corrects the plan for the month, Reallocated moves money that's already there, and they stay in separate figures.
Every form carries `from` (`home`, `month`, `deposits` or `envelope`) and `month` as hidden fields (`application/_origin_fields`), so saving, deleting or cancelling goes back to the page it was opened from (`ReturnsToOrigin`). `from` is a page name and never a URL, so it can't become an open redirect. `home` is the month view at `/`: it goes back there for the current month, and to that month's own address for any other. `MonthScoped` reads `month` ("2026-09") from a month's URL and from those forms.

### Importing

A person imports the CSV their bank lets them download into an Account (see the `roadmap` issue #67 for the whole model and its
sliced build tickets); each row becomes a bank transaction that they file as Deposits, Spends and Refunds, or ignore. The tables
are namespaced like the rest, and are in the order of the build: CSV formats, then Accounts, Imports and bank transactions, then Undo, then filing and ignoring, then splits, then Filing rules.

#### CSV formats and the reader

`Budget::CsvFormat` (`budget_csv_formats`, `budget_id`, never `user_id`) is how one bank's download is laid out. There are no
presets: a person builds every one from a sample file. Columns are numbered from 1, as the builder's grid numbers them, and
`column_count` is the sample's, so every column a format names is within it (a model validation and a check constraint).
`description_columns` is an integer array, joined with a space. `amount_style` is `signed` (one column, negative for money out),
`in_and_out` (`money_in_column` and `money_out_column`) or `direction` (one unsigned `amount_column`, a `direction_column` and
the `money_in_value` that means money in, anything else being money out); the columns a style doesn't use are null, which
`before_validation` makes true and one check constraint per style requires. `invert_sign` is for files where money out is
positive. Names are unique per budget, ignoring case. Destroying a Budget deletes its CSV formats (`has_many :csv_formats,
dependent: :destroy`), and `user:delete`'s confirmation counts them. Importer tables may have nulls where absence is real, which
departs from the core's no-nulls rule.

`Budget::CsvFormat#read(file)` (`Budget::CsvFormat::Reader`) is the one reader: the builder's preview and every Import use it, so a
file can't preview one way and import another. `file` is anything that reads, such as an uploaded file, or its text. It returns a
`Reading` with `rows` (each a `Row` of `line`, `date`, `description` and a signed `amount`, positive for money in per ADR 0009),
`zero_rows` (rows of 0, which are skipped and counted, never refused) and `refusal`, the first thing wrong with the file, which
has `line` (none for the whole file) and `message` ("Line 7: the date ... isn't a date in the DD/MM/YYYY format."). A refusal means
no rows. `Budget::CsvFormat::Source` holds what a file is before a format reads it (UTF-8 and at most 2 MB, BOM stripped, rows with
the physical line each started on), and `Sample` and `Preview` use it too. The refusals are a wrong column count, an unparseable
date, an unparseable amount (including more than 2 decimal places, never rounded), a date more than a day after today
(`Date.current`, Eastern) or before 1990, a blank description, and in the `in_and_out` style a row with both columns filled; in
this reader's own judgement a row with neither, a direction that's blank on a row that isn't 0, a file that isn't valid CSV, an empty
one and one over 5,000 data rows are too. An amount may have a sign, one currency symbol (`$`, `€`, `£`) and thousands separators
in groups of three, so a European `12,50` is refused and not read as 1250. A money in or money out column holds a size, and which
column it's in says which way the money went. Blank lines and rows with nothing in them are skipped: they count as rows when the first `rows_to_skip` are skipped, as the grid shows them as rows, but not towards the row limit. The delimiter is always a comma.

The builder (`CsvFormatsController`, `/csv_formats`) takes a sample file in the same form as the choices, and every change asks
`CsvFormatPreviewsController` (`POST /csv_formats/preview`) how the sample reads, which answers with Turbo Streams that replace
`#csv-format-grid` (the sample's first rows as a numbered grid, and the `column_count` the format takes from it) and
`#csv-format-preview` (the first 5 rows as they'd be imported, with the date spelled out and money in and money out in words, or
the first row that would be refused, or what's still to choose). The Stimulus `csv-format-builder` controller sends the form after a
pause, and shows only the columns the chosen amount style uses; without JavaScript the Preview button posts the same form and the
answer is the whole page. The sample is read for the request and never kept: there's no column or storage for it. The form sends it with
every change and with Save, and Save takes `column_count` from it (`CsvFormatsController#save_with_sample`, whatever the form's hidden
field says, which a form without JavaScript, or one sent before the preview answered, doesn't fill in) and refuses one that can't be read.
Saving a format needs a sample, so that `column_count` is known; editing without one keeps the format's. `column_count` is at most 100
and `rows_to_skip` at most 1000, in the model and in check constraints. Another user's format is a
404, `budget_id` is never a permitted param, and the notices are "CSV format added.", "CSV format updated." and "CSV format deleted.".

The header has a second row of links, `layouts/_sections`, for the pages that aren't a month's: Budget, Accounts, Unfiled, Filing rules and CSV formats now, and
the importer's other pages join it. It's left out until the person has a budget. The "Main" nav stays only Sign out.

#### Accounts, Imports and bank transactions

`Budget::Account` (`budget_accounts`, `budget_id`) is a real bank or card account that bank transactions come from, and has only a
name, unique per budget ignoring case: no balance, currency, kind or last four digits (ADR 0001), and no default CSV format, since
the Import form pre-selects the format of the Account's `latest_import`. `Budget::Import` (`budget_imports`) is one CSV file read
into one Account: `csv_format_id`, `file_name` (the file isn't kept), `duplicates_skipped` and `zero_rows_skipped`, and the figures of the file as it
was read (below), with `created_at` as when it ran and no `user_id`. `Budget::BankTransaction` (`budget_bank_transactions`) is the bank's record of money
moving: `date`, `description` (as the bank gave it, trimmed), a signed `amount` that's never 0, `import_id` (not null while an
Import is the only way one is made) and `account_id`, and no `budget_id`: it belongs to its budget through its Account, as a Spend
does through its envelope, so `Current.budget.bank_transactions`, `.imports` and `.accounts` (`has_many :through`, for reading
only) find them and another user's is a 404. They're read-only to the person: nothing edits a bank transaction. An Account with
bank transactions can't be deleted (`restrict_with_error`, worded like an envelope's); one with only Imports of nothing but rows of
0 can, and takes them with it. A CSV format that an Import used can't be deleted, but can still be edited. Destroying a Budget
deletes its bank transactions, then Imports, then Accounts and CSV formats in `delete_importer_records`, ahead of its envelopes'
records, and `user:delete`'s confirmation counts them.

**Duplicates (ADR 0010).** A row's `content_key` is a SHA-256 digest of its Account, date, signed amount (as `%.2f`) and
normalised description (squished and case folded, by Ruby), and its `occurrence` numbers the same key's rows in the Account from 1; both are
written once, when the row is made, and never recomputed, and `(account_id, content_key, occurrence)` is unique. For each key an
Import adds `max(0, rows in the file - rows already in the Account)`, whatever has been done with the existing rows, taking the
file's later rows as the new ones and numbering them on from the last occurrence; the rest are `duplicates_skipped`. The
normalised description is also stored, as a generated column (`normalized_description`, `lower(regexp_replace(btrim(description),
'\s+', ' ', 'g'))`, stored), so it follows `description` when bank sync updates it in place and needs no backfill: a Filing rule
(#69) used to match it and a Guess (#70) can index it, and the key, which records how a row first looked, is what stays put. Ruby's `squish` and
`downcase(:fold)` (the key's) and SQL's `\s+` and `lower` (the column's) can differ on an unusual space or case fold, so nothing compares one to the other: a
Filing rule matches `BankTransaction#description_for_matching`, which is Ruby's, as the rule's own text is.

`Budget::Import#run(file)` does an Import, and is true when it worked: `file` is read with the CSV format's reader, a refusal creates
nothing and is the first error (by line), and otherwise, holding the Account's row lock so that a double submit imports once and the
second finds every row a duplicate, it counts what's already there with one grouped query, saves the Import and inserts every
bank transaction with one `insert_all!`, so the query count is the same for 10 rows as for 1,000 (a spec checks it). There is no
background job. An Import that adds no bank transactions, such as the same file again, is kept: it's the Account's latest, so
an earlier Import can't be undone from under the rows it skipped, and its summary says what it skipped. The CSV format is only ever
looked up in the budget's own, so another budget's is "CSV format can't be blank", and anything sent as the file that isn't an upload is no file.

**Undo (ADR 0011).** `Budget::Import#undo` takes back an Import: it deletes the Import's bank transactions, straight from the table
(`bank_transactions.delete_all` would only nullify them), then the Import, in one transaction that holds the Account's row lock,
as running one does. It reaches only the Account's latest Import (`created_at` then `id`, which is `latest?`) and only within 24
hours of it running (`undo_window_open?`, so 24 hours of time and not calendar days), and is judged after the lock is held. It raises
`Budget::Import::Refused` with a message otherwise, and `undo_refusal` is the same message, or nil, for a page that wants to say
so: the 24 hours being up comes first, since it's the one that won't change, then a newer Import being there. Once the latest is
undone the one before it is the latest, and can be undone in turn if it's still in time. Importing the same file after an Undo
brings its rows back, since undone rows no longer count as there. `DELETE /imports/:id` (`ImportsController#destroy`) goes back to
the Account with "Import undone."; a refusal is the alert on the Import's summary, where Undo was asked for, with nothing changed.
Undo is offered on the summary, in its header actions, with the reason it can't be shown in its place, and on the Account's page
beside its latest Import; both ask first with `undo_confirmation`, which lists what it deletes ("Undo the Import of sept.csv?
This deletes its 2 bank transactions."). It applies to Imports only: rows bank sync brings in later aren't one.

An Import's summary is a page of its own, `/imports/:id` (`ImportsController#show`), which Importing redirects to and the Account's
page links to for its latest. The file isn't kept, so what it held is worked out when it's read and stored on the Import, in
nullable or defaulted columns with check constraints that tie them together: `earliest_date` and `latest_date`, `money_in_count` and
`money_in_total`, `money_out_count` and `money_out_total`, and `first_row_date`, `first_row_description` and `first_row_amount`, of every
row that isn't of 0 whether it was already in the Account or not, and none of the dates or the first row for a file of nothing but rows of
0. The page shows those (the dates, the count and total of money in and of money out, and the first row as it was read, its date spelled
out and "Money in" or "Money out" in words), `added_count` (counted, the rows of the file less `duplicates_skipped`, which is what Undo would
delete, so what Undo says is what it does), and the duplicates and rows of 0 skipped, with "Nothing new was added." when that's none. Pages: `/accounts` (add, rename, delete; "Account added.",
"Account updated.", "Account deleted."), an Account's page (`/accounts/:id`: Import, Edit, its latest Import and its bank
transactions newest first, 50 a page through the `Paginated` concern and `components/pager`, with a fixed number of queries), and
`/accounts/:account_id/imports/new`. Accounts are in the header's section links.

#### Filing and ignoring a bank transaction

A bank transaction is **unfiled**, **filed** or **ignored**, derived and never stored: ignored if `ignored_at` (a nullable timestamp, the
only column filing adds to it) is set, filed if it has at least one link, otherwise unfiled. It's never both ignored and filed, which
the model refuses (ignoring a filed one, and a link to an ignored one) and specs prove, and never partly filed. There's one link table
per kind, `budget_deposit_links`, `budget_spend_links` and `budget_refund_links` (`Budget::DepositLink`, `SpendLink` and
`RefundLink`, sharing the `BankTransactionLink` concern), each a `bank_transaction_id` and a unique `deposit_id`, `spend_id` or
`refund_id`, so a record comes from at most one bank transaction, with `ON DELETE RESTRICT` foreign keys; the core tables get no
import columns (ADR 0002). `Budget::Deposit`, `Spend` and `Refund` each have `has_one :bank_transaction_link, dependent: :destroy`
(and `has_one :bank_transaction, through:`, both from the `FiledFromBankTransaction` concern), so deleting a record deletes its link and, when it was the last, leaves the bank
transaction unfiled. `Budget::BankTransaction.delete_filed_records(transactions)` deletes the records of a set of bank transactions
and their links straight from the tables, in the order the foreign keys allow, and is what un-filing, Undo and destroying a Budget
use; `Budget#delete_importer_records` runs it first, which is how `delete_envelope_records` and the Deposits never meet a link. Undo
deletes the filed records with their links, then the bank transactions, then the Import, its confirmation counts them by kind
(`Import#filed_record_counts`), and the month view's figures go back. `delete_filed_records`, `filed_record_counts` and `Filing` all go
through `BankTransaction.links_by_record`, the one place the three kinds are listed with their link tables.

**The filing operation** is `Budget::Filing#file(entries)`, which every way of filing calls: it takes `Budget::Filing::Entry`s, each a bank
transaction and its `Budget::Filing::Draft`s (a record as it's asked for, which is what a form sends and what a Filing rule builds, and
what "File as guessed" builds, with `Draft.for(bank_transaction, **overrides)` giving the defaults: the date and description as the bank gave
them, the whole amount as a positive figure, a Spend for money out and a Deposit for money in, no envelope). It's true when every
entry was filed, and when anything is refused nothing at all is created and what's wrong is on the entry (`errors`, for the bank
transaction: the records don't add up, with by how much, already filed, ignored, not in this budget, no records or more than 50) or on
the draft (`errors`, by field: the kind, and whatever the typed-in record would say, with another budget's envelope "can't be blank"
and an archived one "is archived"). Money in is a Deposit or a Refund and money out is a Spend, never a Reallocation, and the records
add up to the bank transaction's amount exactly. It makes a fixed number of queries however many there are: the budget's envelopes
once, every record validated in memory, the bank transactions locked in one query (`FOR UPDATE`, judged once locked, so a double
submit files once), one query per link table to find what's filed, and one `insert_all!` per kind of record and per kind of link.
`BankTransaction#ignore`, `#unignore` and `#unfile` hold the row lock and raise `Budget::BankTransaction::Refused` with a message when the
state doesn't allow them.

Pages: `/unfiled` (`UnfiledBankTransactionsController`, in the header's section links) lists every unfiled bank transaction in the
budget across its Accounts, newest first, 50 a page, each with its Account, date, description and signed amount, and its Guess (see Guesses), opening the filing form;
an Account's page shows each one's state in a word (`bank_transactions/_bank_transaction`): an unfiled one opens the form, a filed one
shows the records it was filed as ("Spend from Groceries", "Refund to Groceries" or "Deposit", each opening where it's edited, with
amounts when there are several) and Un-file, an ignored one says so and has Un-ignore. A filed one whose records no longer add up to its
amount (`adds_up?`, so a typo fixed on a record, or its amount changed, trips it, and blocks nothing) shows a "Doesn't add up" badge in
words and "Its records add up to $X, not $Y." Both lists preload every link and record, so their query counts are fixed. The filing
form (`/bank_transactions/:id/filing/new`, `BankTransactionFilingsController`) is a `filing[records][N][...]` form that holds one record or several, and
a bank transaction can be split ("$60 from Groceries and $40 from Household", or a $3,000 paycheck as a $2,800 Deposit and a $200 Refund): money out is only Spends from
any envelopes, money in any mix of Deposits and Refunds, and together they add up to the amount exactly or nothing is filed, with
by how much it's over or under (`Filing`'s sum check). The `filing-split` Stimulus controller adds a record from the inert
`<template>` (its fields numbered `NEW_RECORD`, replaced by the time, so a later record sorts after earlier ones, which the
controller reads in order by number; it starts with what's left to file), removes one (never the last one), numbers the records
("Record 1", hidden while there's only one) and keeps "Adds up to $60.00 of $100.00, with $40.00 left." up to date (or "...which is
$10.00 over." in the error colour), in the same words `filing_totals` renders on the server, so a refused form comes back with the
records as they were entered and the total as it was sent; there's no JavaScript library and no fallback for adding one without
JavaScript. Each record has its own kind (money out has none to choose: a hidden Spend), envelope (only envelopes in use), description,
date, a Deposit's month choice (`month-choice`) and notes, and the `filing-record` controller shows an envelope for a Refund or Spend
and the month for a Deposit. A split never offers "Always file like this" (see #78). File posts it (`POST .../filing`), Ignore sends the same form to `POST .../ignore`, which only
reads where it was opened from, Un-file is `DELETE .../filing` and Un-ignore `DELETE .../ignore`; the notices are "Bank transaction
filed.", "Bank transaction ignored.", "Bank transaction unfiled." and "Bank transaction un-ignored.", and a refusal is an alert. `from`
gains the pages `unfiled` and `account` in `ReturnsToOrigin` (which also takes no month for them, and goes back to the bank transaction's
Account without one). Another user's bank transaction is a 404. A filed record's edit page says it was filed from a bank transaction, in
which Account, and that deleting it un-files that bank transaction (`application/_bank_transaction_note`).

#### Filing rules

`Budget::FilingRule` (`budget_filing_rules`, `budget_id`, never `user_id`) is a standing instruction, such as "anything from Loblaws goes to Groceries":
an Import files, or ignores, each bank transaction it creates that a rule fits, straight away, with no confirmation, and through the same filing
operation a person uses (ADR 0012). It never acts on one that's already filed or ignored, and never on un-filing, un-ignoring or an edit, or un-filing a
row a rule filed would file it again at once. A rule has `text` (required, at least 3 characters by validation and check constraint, and stored normalised
by `Budget::BankTransaction.normalize_description`, which is Ruby's `squish` and `downcase(:fold)`, not the generated column's SQL, so the table only checks
its length), an optional `account_id`, an optional signed `amount` (never 0, with the `money` validation), an `outcome` and an `envelope_id`. `outcome` is a
string, `spend`, `refund`, `deposit` or `ignore`, which a check constraint says; `envelope_id` is set for `spend` and `refund` and null for the others (a
check constraint, and `before_validation` drops one that's sent with a Deposit or Ignore), and a Spend's amount is negative while a Refund's and a Deposit's is
positive (Ignore takes either). `(budget_id, text, account_id, amount)` is unique with nulls not distinct, and the model's error says what the other rule
does. The Account and envelope must be the budget's own, which is an error on that field, and an archived envelope is refused for a new rule or one moved
to it, as for a Spend. Every foreign key is `ON DELETE RESTRICT`. There's no stored "active" flag: a rule is inactive (`inactive?`, and the `active` scope,
which loads the envelopes) while its envelope is archived, and active again once it's unarchived. `updated_at` is "most recently edited" in the precedence,
so filing never writes to a rule.

**Matching.** `Budget::FilingRule#fits?(bank_transaction)` is the one definition of fit: the text is contained in the bank transaction's
`description_for_matching`, in Ruby with `include?`, so it's text and never a pattern, the Account is the rule's if it has one, the amount is the rule's if it
has one, and the sign suits the outcome (a Spend fits money out, a Refund and a Deposit money in, Ignore either). The description is read the way the text is, by
`BankTransaction.normalize_description` in Ruby (kept for as long as the description is the same, since an Import matches every row against every rule), and not
the database's `normalized_description`, so an unusual space or case fold, such as "ß", can't make the two disagree: the form's untouched default text always fits its own bank
transaction. `Budget::FilingRule::Matcher.new(rules).rule_for(bank_transaction)` picks the winner, skipping
inactive rules: `#specificity` is `[ an exact amount, a pinned Account, the text's length, updated_at, id ]`, greater wins, and `id` makes the order total, so the
newer rule wins a tie. There's no ordering screen.

**Applying them.** `Budget::FilingRule::Applier.new(budget, rules: nil)` loads the active rules once (or takes them), and `#claims(bank_transactions, only: nil)`
is each bank transaction with the rule that wins, as `Claim`s, changing nothing. `#apply(bank_transactions, only: nil)` is one database transaction: it locks the claimed rows,
keeps the ones that are still unfiled (judged once the locks are held, so one filed since it was looked at is left alone), files the Spend, Refund and Deposit
rules through `Budget::Filing` (a `Budget::Filing::Entry` takes the `filing_rule` that's filing it, and a Deposit is filed with its date's month, never "the
month after"), and ignores the rest, and returns `Result(filed:, ignored:)`. A rule never fails the rows that came in with it: if filing one is refused, such as
for an envelope archived since the rules were loaded, it stays unfiled and the others are filed. The records, the links, the note of which rule did it and the
ignoring are each one statement, so the query count is the same for 10 rows as for 1,000 and for 1 rule as for 100 (specs check both).

**Which rule did it.** `budget_bank_transactions.filing_rule_id` (nullable) is the rule that filed or ignored it, written by `Filing#insert` and by the Applier
through `BankTransaction.note_filing_rules` (one `UPDATE`, a `CASE` cast to bigint), null when a person did it, cleared by `unfile` and `unignore`, and only
read through `BankTransaction#filed_by_rule`, which is the rule while the bank transaction is filed or ignored: deleting its last record by hand leaves the value
stale but inert, until the next filing or ignoring writes it again. `FilingRule has_many :bank_transactions, dependent: :nullify`. An Account's page names the
rule on a filed or ignored row, "Filing rule: loblaws → Spend from Groceries" (preload `filing_rule: :envelope`), and the filed record is an ordinary one: no
rule columns on Deposits, Spends or Refunds (ADR 0002).

**In an Import.** `Budget::Import#run` applies the rules to the rows it inserted, inside its one database transaction, and keeps how many were filed and
ignored in `filed_by_rules` and `ignored_by_rules` (as it did then: un-filing a row later doesn't change them), which the summary shows as "Filed by Filing rules" and
"Ignored by Filing rules". Undo deletes what the rules filed like any other filed records. It loads the rows afresh, and not through `bank_transactions`, whose
loaded target `restrict_with_error` would find after Undo deletes them.

**Making a rule from the filing form.** "Always file like this" is `Budget::FilingRule::Offer`: the text starts as the bank transaction's `description_for_matching`,
editable right there, with no Account or amount condition, ticked by default, and not offered for a split (the `filing-split` controller hides and disables its
fieldset while there's more than one record, and the server makes none for more than one record whatever it was sent) or for a description under 3 characters,
which says so instead. The text has to be part of the bank transaction's own description, so the rule fits it. `Offer#file(entry)` and `#ignore` do the filing or
ignoring and save the rule in one database transaction, and neither is done without the other; a rule with identical conditions is updated in place (an Ignore turns a
Spend rule into Ignore and drops its envelope) and the form says "Updates the Filing rule for 'loblaws', which files them as Spend from Groceries now." (`FilingRule#effect`, which the
duplicate-conditions error uses too) The rule made from a
bank transaction doesn't record itself on it: a person filed it. A form that doesn't send the box makes no rule. Ignore is a button on the same form, so a rule that's
refused comes back as the whole filing form, as it was. Two saves of the same conditions can race past the validation, which only the unique index sees:
the loser is told so like any other refusal (`FilingRule::SAVED_A_MOMENT_AGO`), and not with an error page. `FilingFormParams` reads the form for both controllers, looking at one key
of it at a time so the form's others aren't reported as unpermitted.

**Sweeping.** Saving a rule can also file the unfiled bank transactions that are already there, so a rule made after an Import tidies that Import up too.
`Budget::FilingRule::Sweep.new(rule, made_from: nil)` works it out: `#bank_transactions` and `#count` are what it would file or ignore, changing nothing, and `#run`
files and ignores them through the Applier (`only: rule`), in one database transaction and a fixed number of queries. It reads the budget's unfiled bank
transactions (never a filed or ignored one, whatever fits it) and the budget's active rules with this one in place of its saved self, so a rule that's new, or
changed and not yet saved, is counted as a form says before it's saved, and counts as edited now (`#specificity`, as saving it would make it). It sweeps the
bank transactions where this rule *wins*, not every one it fits: one that a more specific rule fits is that rule's, as it would have been in an Import, and the count
is what it files. `#left_to_other_rules` is the ones it fits but a more specific rule files, which the form says ("1 more fits, but a more specific Filing rule files it.", or
"1 other unfiled bank transaction fits, but a more specific Filing rule files it." when that's all there is) so that "No other unfiled bank transactions fit" is never said when
some do. `made_from` is the bank transaction a rule is being made from by hand: it's left out and only ones that went the same way (money in, or out) are swept,
so an Ignore rule, which fits either, doesn't act on the other way's bank transactions, which the person wasn't looking at, and the count is the same for File and Ignore.
On the filing form the second box, `filing[rule][sweep]`, is ticked by default and only there when there's something to sweep; the count follows the text as it's edited:
the `sweep-preview` Stimulus controller sends the form's `filing[rule]` fields, after a pause, to `GET /bank_transactions/:id/filing/rule`
(`BankTransactionRulePreviewsController`, which changes nothing), whose Turbo Frame `#filing-rule-preview` holds the update-in-place note, the count and the box,
and that frame is where the box sits, so its ticked state travels with the request. `Offer` runs the sweep after saving the rule, in the same database transaction, and
the notice says what it did (`Applier::Result#describe`): "Bank transaction filed. The Filing rule also filed 2 other bank transactions." A form that doesn't send the box sweeps
nothing. A text that can't make a rule, which is too short or isn't in the bank transaction's description, has no count, and the frame says why. The frames are `aria-live`.

**The Filing rules page.** `/filing_rules` (`FilingRulesController`, in the header's section links; no `show`) lists every rule grouped by what it sets: one section per envelope that has a
rule, alphabetically as in the month view (an archived envelope's section has the "Archived" badge), then Deposit, then Ignore, each only if it has rules, and each rule a `components/link_row`
to its edit page whose detail (`filing_rule_detail`) says what it does, "Spend from Groceries. In Chequing. Exactly -$82.45. 3 bank transactions filed or ignored.", with an
"Inactive" badge and "Inactive while its envelope is archived." for one on an archived envelope, in words. The count is how many bank transactions it filed or ignored *that still are*
(`BankTransaction.filed_or_ignored`, grouped by `filing_rule_id`), so one un-filed since isn't counted, and the page runs a fixed number of queries however many rules there are. A rule is made from
scratch, edited and deleted there (notices "Filing rule added.", "Filing rule updated." and "Filing rule deleted."); the Account picker has Any account first, the envelope picker is `envelope_options(keeping:)`
(envelopes in use, and a rule's own, even when it's archived), and the form's `filing-record` controller shows the envelope for a Spend or a Refund only. The amount is entered signed, as a bank
transaction shows it (money out negative, such as -82.45), and the model's error says which sign suits the outcome; leaving it blank is any amount. The Account and envelope come from the form as ids and
the model refuses another budget's ("isn't one of this budget's"), and `budget_id` is never a permitted param; another user's rule is a 404. A rule with the same text, Account and amount as another is a
validation error that says what the other one does, and unlike the filing form it doesn't update in place. Saving with the sweep box ticked (the form's `filing_rule[sweep]`) sweeps the
unfiled bank transactions the rule now fits (`FilingRule#save_and_sweep`), in both directions, since there's no bank transaction it's made from, in the same database transaction, and the notice says so: "Filing rule added.
It also filed 2 bank transactions." The count and the box are the Turbo Frame `#filing-rule-sweep`, which `GET /filing_rules/sweep` (`FilingRuleSweepsController`, which changes nothing) answers with for the rule as
it's entered, a new rule or the one being edited (`id`) with the form's changes in place of itself, with no count for a rule that isn't valid yet; the same `sweep-preview` controller as the filing form's
sends the form's `filing_rule` fields. Editing or deleting a rule never changes what it already filed or ignored: deleting nullifies `filing_rule_id` on what it filed, and moving a rule to another envelope
affects what comes in from then on, so fixing past ones means un-filing and filing again. A filed or ignored bank transaction's "Filing rule: loblaws → Spend from Groceries" links to the rule's edit page.

**Deleting.** `Budget::Envelope` and `Budget::Account` have `has_many :filing_rules, dependent: :destroy`, declared after the checks that refuse, so deleting an envelope
with no records, or an Account with no bank transactions, takes its rules with it, and keeps them when it's refused, and the question before deleting says so ("Its 2 Filing rules are deleted with it.", `filing_rules_deleted_with`).
Archiving is never blocked by rules. `Budget#delete_importer_records`
deletes bank transactions, then Filing rules, then Accounts and CSV formats, ahead of the envelopes' records, and `user:delete`'s confirmation counts the rules.

#### Guesses

A Guess (`Budget::Guess`, a value) is what Budgie proposes for an unfiled bank transaction that no active Filing rule fits: the kind and envelope the Budget's similar
bank transactions were filed as, and which one it was like, so it can say why (ADR 0013). It's worked out when it's shown and never stored: no table and no column, so
nothing goes stale, and editing or moving a filed record changes the next Guess. It only suggests: nothing is created from it unless a person files the bank transaction,
and what's filed has no `filing_rule_id` and nothing marking it as guessed, because a Guess isn't a rule. It never proposes Ignore, an archived envelope or a Reallocation,
and has no Deposit month: a Deposit is filed with its date's.

`Budget::Guesser.new(budget)` is the one seam: `#guesses(bank_transactions)` is `{ bank_transaction.id => Budget::Guess }` for the ones that have one, `#guess(bank_transaction)`
is one, and what it asks, in order, is `sources`, which for now is only `Budget::Guesser::History`. A later source, such as an LLM call or a bank-sync provider's category,
is another entry there, as its own `roadmap` issue with its own ADR. A bank transaction an active Filing rule fits has no Guess (`FilingRule::Matcher`, over `budget.filing_rules.active`),
and a rule on an archived envelope is inactive, so a Guess can show for what it would fit. It's for unfiled bank transactions read back from the database: it reads
`normalized_description`, on both sides of every comparison, so it never compares it with Ruby's `description_for_matching`. `Guess#kind`, `#envelope_id`, `#envelope_name`
and `#like` (the description of the bank transaction it was like, as the bank gave it) give `#label`, "Guess: like LOBLAWS #1234 → Groceries", where the part after the arrow is
the envelope's name for a Spend, "Refund to Groceries" for a Refund and "Deposit" for a Deposit (`#destination`), and `#draft_attributes` is what the filing form starts as.

History is the Budget's filed bank transactions of the same sign (money in or money out) from every Account, as they are now: the record's current kind and envelope. Ignored
ones don't count, and neither does a split one (only those filed as exactly one record), and neither does anything in an archived envelope. A description is read as its words:
letters and numbers, leaving out any with a digit in it (store numbers, reference codes) and one-letter words, or the numbers themselves for a description with no other words. The
likeness of two is the weight of the words they share over the weight of all of them, as an exact `Rational`, where a word weighs 1 over how many different outcomes (a kind and an
envelope) it's been filed as in history of the same sign, so money in never changes what a word counts for money out, so "payment" in front of every merchant says little, and a word that's never been filed weighs 1. A Guess needs a likeness of at least 1/2
(`History::THRESHOLD`), so a merchant the Budget has never filed gets none. Its outcome is the one of the most alike bank transactions; equally alike outcomes go to the one filed
most often, then the one filed most recently (by date, then id), so it's never a toss-up. It's worked out in Ruby from one query that counts the history by description and outcome in
the database (a `WITH` over the three link tables from `BankTransaction.links_by_record`), so a page of Guesses runs the same number of queries (the rules and that one) for 5 rows or
100 and for 10 filed bank transactions or 1,000, which `spec/models/budget/guesser_spec.rb` checks; there's no `pg_trgm`, extension or migration.

The Unfiled list shows each unfiled row's Guess, if it has one, in a muted line under the Account ("Guess: like LOBLAWS #1234 → Groceries"), and choosing a row still opens
the filing form, which starts on it. `UnfiledPage` (`app/controllers/concerns/`) loads a page of rows with their Guesses for both `UnfiledBankTransactionsController` and
`GuessedFilingsController`, so a page runs the same number of queries (the rows with their Account and links, the rules and the one history query) however many rows, rules or filed
bank transactions there are, which `spec/requests/unfiled_bank_transactions_spec.rb` checks. An Account's page shows no Guesses: the Unfiled list is where they're worked through.

"File N as guessed" is the one bulk action. When the page being viewed has Guesses, the Unfiled list's header has it (N is the rows on that page that have one, at most 50), and it opens
a review, `GET /unfiled/guessed/new?page=` (`GuessedFilingsController#new`): those rows, each with a ticked checkbox named `guessed[<bank transaction id>]` so any can be left out, and
File as guessed, `POST /unfiled/guessed`. The checkbox's value is the outcome that was reviewed (`Guess#review_value`: "spend:5", "refund:5" or "deposit:"), and `#create` files each ticked row as
it was reviewed and not as its Guess is now, so a Guess that changed in between never files something that wasn't seen, through `Budget::Filing`, all or none, like a person's filing. So what
filing by hand refuses, it refuses: an envelope archived since the review, a row filed since, a kind that doesn't suit the money, or an envelope that isn't the budget's refuse the lot, which
files nothing and goes back to the review (which is then without a Guess for that row) with "Nothing was filed. COSTCO #99: Envelope is archived." Another user's bank transaction is a 404, and
nothing ticked is "Choose at least one bank transaction to file." It makes no Filing rule and notes none (`filing_rule_id` is null, and `filed_by_rule` nothing), because a Guess isn't a rule: only a person
asking for "Always file like this" makes one. It goes back to the Unfiled list's page with "2 bank transactions filed as guessed.", and what it filed is ordinary: Undo deletes it with the rest of the latest
Import, and un-filing puts one back. Nothing is ever filed as guessed without that click, at any likeness.

The filing form (`BankTransactionFilingsController#new`) starts as the Guess: its kind and envelope are chosen, with the label above the records, and "Always file like this" is still
offered. It's only where the form starts, so a form that comes back refused, or ignored, as it was entered has no label, and a record added to split it starts empty.

### Production

Both hosts run `RAILS_ENV=production` from the one `config/environments/production.rb`; what differs comes from each Kamal destination's env, such as `APP_HOST` and `MAILER_FROM`.
`production.rb` fetches `APP_HOST`, so anything that boots the production environment needs it: the Dockerfile's `assets:precompile` passes a placeholder.
Cloudflare terminates TLS, so `assume_ssl` makes every request count as HTTPS, and `force_ssl` is there for secure cookies. `hsts: false` still sends `Strict-Transport-Security: max-age=0`, which is HSTS off.
`config.hosts` allows only `budgiebuddie.com` and `testing.budgiebuddie.com`; `/up` is exempt from it and from the SSL redirect, for `kamal-proxy`'s health check.

### Specs

Request, model, service and job specs use FactoryBot and shoulda-matchers; there are no system specs yet.
Specs never call Google: `spec/support/omniauth.rb` turns on OmniAuth test mode and provides `google_auth_hash` and `sign_in_with_google`.
In request specs, `sign_in_as(user)` signs in without going through a provider. A user needs a budget to reach any page but setup, so use `create(:user, :with_budget)` or `create(:budget)`. Time helpers such as `travel` are available in every spec.
A Deposit is `create(:budget_deposit, budget:, date:, month:)`, where `month` is the date's unless given, a Spend is `create(:budget_spend, envelope:, date:, amount:)`, a Refund is `create(:budget_refund, envelope:, date:, amount:)`, a Reallocation is `create(:budget_envelope_reallocation, from_envelope:, to_envelope:, date:, amount:)`, between two envelopes of one budget unless given others, and a Reallocation to Ready to Assign is `create(:budget_ready_to_assign_reallocation, envelope:, date:, amount:)`. An Account is `create(:budget_account, budget:)`, an Import `create(:budget_import, account:)` (with a CSV format of the Account's budget unless given another) and a bank transaction `create(:budget_bank_transaction, account:, date:, amount:)` (in a new Import of that Account unless given one, with the traits `:filed`, as a Spend or a Deposit of its whole amount, and `:ignored`; a link is `create(:budget_spend_link, bank_transaction:)`, or the Deposit's or Refund's). A Filing rule is `create(:budget_filing_rule, budget:, text:)`, a Spend from a new envelope of its budget unless given another, with the traits `:refund`, `:deposit` and `:ignore`; a spec that matches a rule reads the bank transaction back (`.reload`), since the database works out its normalised description, and a rule needs its own text, since two with the same conditions are refused. History for a Guess is `filed(description, envelope, amount:)`, a bank transaction filed as one record (a Spend, or a Deposit for money in, or a Refund to `envelope`), and `unfiled(description)`, one read back so that its normalised description is there, and `file_in_bulk(numbers, envelope)`, which imports and files that many rows through the real operations for specs that count queries against a lot of history, all from `spec/support/filing_history.rb` (`include FilingHistory`, in a group with `budget` and `account`). The sample files for the reader are in `spec/fixtures/files/`, one per amount style, and read the same bank transactions. `count_queries { … }` (`spec/support/query_counter.rb`) counts the SQL a block runs.
Eastern Time has daylight saving, so `30.days` is a span of calendar days there. A spec a minute either side of such a limit travels from `Time.current` (`travel_to Time.current + 30.days`) rather than with `travel 30.days`, which adds exact hours and fails on some dates. To check "today" itself, `travel_to Time.utc(2026, 10, 1, 0, 30)` is still September 30 in Eastern time.

### Frontend

`DESIGN.md` has the UI rules — colour, layout, money formatting, components and a "Don't" list — and is short enough to read before changing a view. `docs/daisyui.md` is daisyUI's own reference, saved verbatim from its `llms.txt`; read it (by path — it's too big to `@`-import into every session) when adding or changing a daisyUI component.

daisyUI is vendored as two plugin files, `app/assets/tailwind/daisyui.mjs` and `daisyui-theme.mjs`, pinned to a release rather than fetched live; `docs/daisyui.md` has the pinned version and the bump procedure. They define the one theme, `budgie`; `@theme { --color-*: initial; }` in `app/assets/tailwind/application.css` makes Tailwind's raw palette classes (`bg-gray-200`, `text-red-700`, …) produce nothing, so a stray one fails loudly rather than drifting in unnoticed.

> **Local development only.** `/styleguide`, `/dev/sign_in`, the seeded dev user (`db/seeds/development.rb`), `.mcp.json` and Playwright MCP exist to help *view* or *build* the UI on a developer's own machine, and must never be reachable in `test`, on the testing host or on the production host. Testing and production both run `RAILS_ENV=production`, so every guard checks `Rails.env.development?`, never `!Rails.env.production?`. `config/routes.rb` only draws `/styleguide` and `/dev/sign_in` inside `if Rails.env.development?`, and their controllers (`Dev::StyleguideController`, `Dev::SessionsController`, both under `app/controllers/dev/`) refuse outside development too, so a routing mistake alone can't expose them. `spec/requests/development_only_spec.rb` and `spec/controllers/dev/` prove both; `spec/db/seeds_spec.rb` proves `db:prepare` creates no dev user outside development.

#### Visual review

After a UI change:

1. Start the app with `docker compose up` (`web`, `css`, `db`) and use `http://localhost:3000` — not `bin/dev`, which needs host Ruby this checkout doesn't have.
2. Sign in with the dev shortcut, `GET /dev/sign_in` (it needs the seed loaded once: `docker compose run --rm web bin/rails db:seed`), or open `/styleguide`, which doesn't need it.
3. Open each affected page with Playwright MCP and screenshot it at **375px** (mobile) and **1280px** (desktop). Playwright MCP is configured in `.mcp.json`, project-scoped and `npx`-based — Node is needed on the developer's machine only, for that — and restricted to `http://localhost:3000`. Never point it at the testing or production hosts, and never use the `/styleguide` or `/dev/sign_in` shortcuts anywhere else.
4. Compare against `DESIGN.md`, fix what doesn't match, and screenshot again.
5. Only then report the work done. If Docker or Playwright MCP isn't available, say the visual review wasn't done rather than skipping it silently.

## Tickets and product rules

- Work is tracked as GitHub issues in `RobertG-H/budgie-src`. A build ticket has a plain title and the `enhancement` label, and GitHub's blocked-by links give the build order; the `[NN]` in the oldest tickets' titles is a retired build-plan number. An issue's Decisions, Build and Done when sections are the spec.
- In a PR description, put "close", "fixes" or "resolves" next to `#N` only when merging should close `#N`. GitHub matches them mid-sentence ("would close #10" closed #10 on merge), and Dependabot treats its own PR closed that way as dismissed and deletes its branch.
- User-facing budgeting copy may only use these terms: Budget, Envelope, Deposit, Assigned, Spend, Spent, Refund, Reallocation, Archive, Account, Bank transaction, CSV format, Import, File, Filing rule, Guess, Ignore, Available, Overspent, Ready to Assign, Carried over, and Starting balance (the amount already in an envelope before Budgie tracked it). Other forms of a listed term count as that term, such as Deposited, Refunded, Reallocate, Reallocated, Archived, Unarchive, Assign, Filed, Unfiled, Ignored, Imported or Guessed. Internal field names stay out of the UI.
- Envelopes never reset at month end: leftover money and overspending both carry into the next month.
- A Deposit counts toward Ready to Assign in the month of its date or the month after, so a user can live on last month's money (`docs/adr/0005-a-deposit-can-count-toward-next-month.md`).
- Each month starts with the previous month's Assigned amounts (`docs/adr/0006-each-month-starts-with-last-months-assigned.md`). Each month keeps its own Assigned, so changing a past month changes only that month's figure, and the balances after it follow.
- A Reallocation moves money out of an envelope into another envelope or back to Ready to Assign, and is two tables by destination (`docs/adr/0007-a-reallocation-is-two-tables-one-per-destination.md`). Money going from Ready to Assign into an envelope is Assigned, never a Reallocation.
- An envelope can be archived only when its Available is 0 and nothing is dated after the current month for it. An archived envelope shows only in months where it has figures, and takes no new records or Assigned (`docs/adr/0008-an-archived-envelope-shows-only-where-it-has-figures.md`).
- A bank transaction has a signed amount and is filed as Deposits, Spends and Refunds that add up to it exactly, or ignored (`docs/adr/0009-a-bank-transaction-has-a-signed-amount-and-is-filed-for-its-exact-sum.md`). Duplicate rows are recognised by a content key and an occurrence count (`docs/adr/0010-duplicates-are-recognised-by-content-and-an-occurrence-count.md`), and only an Account's latest Import can be undone, for 24 hours (`docs/adr/0011-undo-reaches-only-the-latest-import-for-24-hours.md`). The importer is built in the order of its tickets, and CSV formats, Accounts, Imports, bank transactions, Undo, filing and ignoring, splits, Filing rules and Guesses exist so far, and the rest of its model is the `roadmap` issue #67.
- A Filing rule files a bank transaction as soon as an Import or sync creates it, with no confirmation, while a Guess only suggests (`docs/adr/0012-a-filing-rule-files-immediately-only-a-guess-suggests.md`). A Guess comes from the Budget's own filing history and is never stored (`docs/adr/0013-a-guess-comes-from-the-users-own-filing-history-and-is-never-stored.md`). Filing rules (the `roadmap` issue #69) and Guesses (#70) are built.

## Agent skills

### Issue tracker

GitHub issues in `RobertG-H/budgie-src`, via the `gh` CLI — the same tracker described under "Tickets and product rules" above. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root, both created lazily by `/domain-modeling` rather than upfront. See `docs/agents/domain.md`.
