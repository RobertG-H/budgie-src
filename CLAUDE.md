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

Models that belong to a budget are namespaced: `Budget::Envelope` lives in `app/models/budget/envelope.rb` with the table `budget_envelopes`, and later tables follow suit (`Budget::Deposit`, …).
`Budget.use_relative_model_naming?` drops the prefix from routes, params and DOM ids, so it's `envelopes_path`, `params[:envelope]` and `EnvelopesController`.
Controllers look records up through `Current.user.budget`, so another user's record is a 404, and `budget_id` is never a permitted param.

Constraints live in the database as well as the model (check constraints, unique indexes such as `(budget_id, lower(name))`). Foreign keys are `ON DELETE RESTRICT`, and Rails deletes children first through `dependent: :destroy`, so give new budget tables `dependent:` options to keep `user:delete` working.
PostgreSQL reports a restrict violation as `PG::RestrictViolation`, which Rails raises as a plain `ActiveRecord::StatementInvalid`, not `ActiveRecord::InvalidForeignKey`.

### Production

Both hosts run `RAILS_ENV=production` from the one `config/environments/production.rb`; what differs comes from each Kamal destination's env, such as `APP_HOST` and `MAILER_FROM`.
`production.rb` fetches `APP_HOST`, so anything that boots the production environment needs it: the Dockerfile's `assets:precompile` passes a placeholder.
Cloudflare terminates TLS, so `assume_ssl` makes every request count as HTTPS, and `force_ssl` is there for secure cookies. `hsts: false` still sends `Strict-Transport-Security: max-age=0`, which is HSTS off.
`config.hosts` allows only `budgiebuddie.com` and `testing.budgiebuddie.com`; `/up` is exempt from it and from the SSL redirect, for `kamal-proxy`'s health check.

### Specs

Request, model and service specs use FactoryBot and shoulda-matchers; there are no system specs yet.
Specs never call Google: `spec/support/omniauth.rb` turns on OmniAuth test mode and provides `google_auth_hash` and `sign_in_with_google`.
In request specs, `sign_in_as(user)` signs in without going through a provider. A user needs a budget to reach any page but setup, so use `create(:user, :with_budget)` or `create(:budget)`. Time helpers such as `travel` are available in every spec.

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
- User-facing budgeting copy may only use these terms: Budget, Envelope, Deposit, Assigned, Spend, Spent, Refund, Available, Overspent, Ready to Assign, Carried over, and Starting balance (the amount already in an envelope before Budgie tracked it). Other forms of a listed term count as that term, such as Deposited, Refunded or Assign. Internal field names stay out of the UI.
- Envelopes never reset at month end: leftover money and overspending both carry into the next month.

## Agent skills

### Issue tracker

GitHub issues in `RobertG-H/budgie-src`, via the `gh` CLI — the same tracker described under "Tickets and product rules" above. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root, both created lazily by `/domain-modeling` rather than upfront. See `docs/agents/domain.md`.
