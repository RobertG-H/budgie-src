# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Budgie is an envelope-budgeting app built with Rails 8.1, PostgreSQL 18, Hotwire, importmap and Tailwind CSS 4 (no Node).
Development runs entirely in Docker Compose (`web`, the `css` Tailwind watcher, and `db`); the host has no Ruby.
The `Dockerfile`'s `development` target is what Compose runs, and its default target is the production image that Kamal deploys.
Compose also has a `kamal` service, in the `deploy` profile, that the operator deploys with.

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
- `json` is pinned below 3 in the `Gemfile`: with json 3, Rails 8.1.3.1 raises on every cookie read, including the session.
- CI (`.github/workflows/ci.yml`) runs RuboCop, Brakeman, bundler-audit and `bin/importmap audit`, but not the specs yet. RuboCop uses the Rails omakase style, including double quotes and spaces inside array brackets (`[ :a, :b ]`).

## Blocked commands and secrets

- Permission rules deny these whether they're spelled with `docker compose run` or `exec`: `rails runner`, `console`, `dbconsole`, `credentials` and `encrypted`; destructive database tasks such as `db:drop`, `db:reset`, `db:rollback` and `db:schema:load`; shells inside containers; and `curl`/`wget`. If a task needs one, ask the user rather than getting the same effect another way, such as running `curl` inside the container.
- Provisioning is a manual ops task. `script/provision.sh` configures the OVH VPS hosts (Ubuntu 26.04 LTS) and only ever runs on them; they aren't reachable from this checkout, so Claude edits the script and `docs/provisioning.md` here, and the operator runs it and ticks the verification boxes.
- Cloudflare is manual ops in the same way. `script/cloudflare-tunnel.sh` puts a host behind its Cloudflare Tunnel and only ever runs on that host, and the domain, zone settings, tunnels and rules live in the Cloudflare dashboard. Claude edits the script and `docs/cloudflare.md` here; the operator runs it, works the dashboard and ticks the boxes. Most of the verification is `curl` and `dig` against real hosts, and `curl` is blocked here, so don't try to check any of it from this checkout.
- Deploys are manual ops like provisioning. Claude writes the Kamal config (`config/deploy.yml`, `config/deploy.<destination>.yml` and `.kamal/secrets*`) and `docs/deployment.md`, but never runs `kamal`, because the hosts aren't reachable from this checkout. The operator runs it through the `kamal` Compose service, as `docker compose run --rm kamal deploy -d testing`. It's the only service with the Docker socket and the SSH agent, and it loads the deploy secrets from `.env.kamal`, `.env.testing` and `.env.production`. `.kamal/secrets*` only ever map names to those variables and never hold values.
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

## Tickets and product rules

- Work is tracked as GitHub issues in `RobertG-H/budgie-src` titled `[NN] ...`, where the number is the build order. An issue's Decisions, Build and Done when sections are the spec, and they're more detailed than the plan linked from issue #1.
- User-facing budgeting copy may only use these terms: Budget, Envelope, Deposit, Assigned, Spent, Refund, Available, Overspent, Ready to Assign, Carried over, and Starting balance (the amount already in an envelope before Budgie tracked it). Internal field names stay out of the UI.
- Envelopes never reset at month end: leftover money and overspending both carry into the next month.
