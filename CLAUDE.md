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
- Gems live in the Compose `bundle` volume, not the image. After editing the `Gemfile`, run `docker compose exec -T web bundle install`, then `docker compose restart web` so the server loads new gems and initializers.
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
are namespaced like the rest, and are in the order of the build: CSV formats, then Accounts, Imports and bank transactions, then Undo.

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
answer is the whole page. The sample is read for the request and never kept: saving ignores it, and there's no column or storage for it.
Saving a format needs a sample, so that `column_count` is known; editing without one keeps the format's. Another user's format is a
404, `budget_id` is never a permitted param, and the notices are "CSV format added.", "CSV format updated." and "CSV format deleted.".

The header has a second row of links, `layouts/_sections`, for the pages that aren't a month's: Budget, Accounts and CSV formats now, and
the importer's other pages join it. It's left out until the person has a budget. The "Main" nav stays only Sign out.

#### Accounts, Imports and bank transactions

`Budget::Account` (`budget_accounts`, `budget_id`) is a real bank or card account that bank transactions come from, and has only a
name, unique per budget ignoring case: no balance, currency, kind or last four digits (ADR 0001), and no default CSV format, since
the Import form pre-selects the format of the Account's `latest_import`. `Budget::Import` (`budget_imports`) is one CSV file read
into one Account: `csv_format_id`, `file_name` (the file isn't kept), `duplicates_skipped` and `zero_rows_skipped`, with
`created_at` as when it ran and no `user_id`. `Budget::BankTransaction` (`budget_bank_transactions`) is the bank's record of money
moving: `date`, `description` (as the bank gave it, trimmed), a signed `amount` that's never 0, `import_id` (not null while an
Import is the only way one is made) and `account_id`, and no `budget_id`: it belongs to its budget through its Account, as a Spend
does through its envelope, so `Current.budget.bank_transactions`, `.imports` and `.accounts` (`has_many :through`, for reading
only) find them and another user's is a 404. They're read-only to the person: nothing edits a bank transaction. An Account with
bank transactions can't be deleted (`restrict_with_error`, worded like an envelope's); one with only Imports of nothing but rows of
0 can, and takes them with it. A CSV format that an Import used can't be deleted, but can still be edited. Destroying a Budget
deletes its bank transactions, then Imports, then Accounts and CSV formats in `delete_importer_records`, ahead of its envelopes'
records, and `user:delete`'s confirmation counts them.

**Duplicates (ADR 0010).** A row's `content_key` is a SHA-256 digest of its Account, date, signed amount (as `%.2f`) and
normalised description (squished and case folded), and its `occurrence` numbers the same key's rows in the Account from 1; both are
written once, when the row is made, and never recomputed, and `(account_id, content_key, occurrence)` is unique. For each key an
Import adds `max(0, rows in the file - rows already in the Account)`, whatever has been done with the existing rows, taking the
file's later rows as the new ones and numbering them on from the last occurrence; the rest are `duplicates_skipped`. The
normalised description is also stored, as a generated column (`normalized_description`, `lower(regexp_replace(btrim(description),
'\s+', ' ', 'g'))`, stored), so it follows `description` when bank sync updates it in place and needs no backfill: a Filing rule
(#69) matches it and a Guess (#70) can index it, and the key, which records how a row first looked, is what stays put.

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
page links to for its latest. It's worked out from the Import's own bank transactions in two queries, plus `zero_rows_skipped`, so it
needs nothing else stored: the dates, the count and total of money in and of money out, the first row as it was read (its date
spelled out, and "Money in" or "Money out" in words), and the duplicates and rows of 0 skipped, or "Nothing new was added." The
figures are of what the Import added, which is what Undo would delete. Pages: `/accounts` (add, rename, delete; "Account added.",
"Account updated.", "Account deleted."), an Account's page (`/accounts/:id`: Import, Edit, its latest Import and its bank
transactions newest first, 50 a page through the `Paginated` concern and `components/pager`, with a fixed number of queries), and
`/accounts/:account_id/imports/new`. Accounts are in the header's section links.

### Production

Both hosts run `RAILS_ENV=production` from the one `config/environments/production.rb`; what differs comes from each Kamal destination's env, such as `APP_HOST` and `MAILER_FROM`.
`production.rb` fetches `APP_HOST`, so anything that boots the production environment needs it: the Dockerfile's `assets:precompile` passes a placeholder.
Cloudflare terminates TLS, so `assume_ssl` makes every request count as HTTPS, and `force_ssl` is there for secure cookies. `hsts: false` still sends `Strict-Transport-Security: max-age=0`, which is HSTS off.
`config.hosts` allows only `budgiebuddie.com` and `testing.budgiebuddie.com`; `/up` is exempt from it and from the SSL redirect, for `kamal-proxy`'s health check.

### Specs

Request, model, service and job specs use FactoryBot and shoulda-matchers; there are no system specs yet.
Specs never call Google: `spec/support/omniauth.rb` turns on OmniAuth test mode and provides `google_auth_hash` and `sign_in_with_google`.
In request specs, `sign_in_as(user)` signs in without going through a provider. A user needs a budget to reach any page but setup, so use `create(:user, :with_budget)` or `create(:budget)`. Time helpers such as `travel` are available in every spec.
A Deposit is `create(:budget_deposit, budget:, date:, month:)`, where `month` is the date's unless given, a Spend is `create(:budget_spend, envelope:, date:, amount:)`, a Refund is `create(:budget_refund, envelope:, date:, amount:)`, a Reallocation is `create(:budget_envelope_reallocation, from_envelope:, to_envelope:, date:, amount:)`, between two envelopes of one budget unless given others, and a Reallocation to Ready to Assign is `create(:budget_ready_to_assign_reallocation, envelope:, date:, amount:)`. An Account is `create(:budget_account, budget:)`, an Import `create(:budget_import, account:)` (with a CSV format of the Account's budget unless given another) and a bank transaction `create(:budget_bank_transaction, account:, date:, amount:)` (in a new Import of that Account unless given one). The sample files for the reader are in `spec/fixtures/files/`, one per amount style, and read the same bank transactions. `count_queries { … }` (`spec/support/query_counter.rb`) counts the SQL a block runs.
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
- A bank transaction has a signed amount and is filed as Deposits, Spends and Refunds that add up to it exactly, or ignored (`docs/adr/0009-a-bank-transaction-has-a-signed-amount-and-is-filed-for-its-exact-sum.md`). Duplicate rows are recognised by a content key and an occurrence count (`docs/adr/0010-duplicates-are-recognised-by-content-and-an-occurrence-count.md`), and only an Account's latest Import can be undone, for 24 hours (`docs/adr/0011-undo-reaches-only-the-latest-import-for-24-hours.md`). The importer is built in the order of its tickets, and CSV formats, Accounts, Imports, bank transactions and Undo exist so far, and the rest of its model is the `roadmap` issue #67.
- A Filing rule files a bank transaction as soon as an Import or sync creates it, with no confirmation, while a Guess only suggests (`docs/adr/0012-a-filing-rule-files-immediately-only-a-guess-suggests.md`). A Guess comes from the Budget's own filing history and is never stored (`docs/adr/0013-a-guess-comes-from-the-users-own-filing-history-and-is-never-stored.md`). Neither is built yet: their models are the `roadmap` issues #69 (Filing rules) and #70 (Filing guesses).

## Agent skills

### Issue tracker

GitHub issues in `RobertG-H/budgie-src`, via the `gh` CLI — the same tracker described under "Tickets and product rules" above. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root, both created lazily by `/domain-modeling` rather than upfront. See `docs/agents/domain.md`.
