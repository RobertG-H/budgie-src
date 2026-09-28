# CI

Every pull request and every push to `main` runs [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) on GitHub's runners.
It has seven jobs, and each is its own check, so it's obvious which part failed:

| Check | What it runs | Runs on | Locally |
| --- | --- | --- | --- |
| `scan_ruby` | Brakeman, then bundler-audit | Every PR and push | `docker compose run --rm web bin/brakeman --no-pager` and `docker compose run --rm web bin/bundler-audit` |
| `scan_js` | `bin/importmap audit` | Every PR and push | `docker compose run --rm web bin/importmap audit` |
| `lint` | RuboCop | Every PR and push | `docker compose run --rm web bin/rubocop` |
| `test` | The specs, then [the schema drift check](#the-schema-drift-check) | Every PR and push | `docker compose run --rm -e CI=true web bin/rspec`, and [the drift check](#running-it-locally) |
| `build` | Builds the production image, without pushing it | Every PR | `docker build .` |
| `supersede_check` | Compares the commit with main's current tip | Push to `main` only | — |
| `deploy_testing` | Deploys the commit to testing with Kamal | Push to `main` only, when `supersede_check` says it's still main's tip | `docker compose run --rm kamal deploy -d testing` |

A [ruleset](#the-ruleset) on `main` requires the first five to pass before a pull request can merge.
`supersede_check` and `deploy_testing` only do real work on a push to `main`; their `if:` condition skips them on a pull request, where they show up as **Skipped** checks rather than not appearing at all. Neither is ever a required check, so a pull request can still merge while they show skipped.
[Deploying](deployment.md#ci-deploys) covers `deploy_testing`'s environment, secrets and keys, and what to do when it fails.

## What lives where

| Thing | Where it's written down |
| --- | --- |
| The checks | `.github/workflows/ci.yml`, the only definition of CI |
| Which checks `main` requires | The `main` ruleset, in the repo's **Settings → Rules → Rulesets**, and [below](#the-ruleset) so it can be rebuilt |
| What Dependabot proposes | `.github/dependabot.yml` |

## How the jobs run

- **`scan_ruby`, `scan_js`, `lint` and `test` run on the runner, not through Compose.** `ruby/setup-ruby` installs the Ruby from `.ruby-version` and the gems from `Gemfile.lock`, and caches the gems between runs.
- **`build` and `deploy_testing` build the `Dockerfile`'s production image directly with Docker**, the way `docker build .` or Kamal would, rather than through Compose.
- **`test` gets PostgreSQL 18** as a service container, the same major version as Compose and the hosts. The job sets `DB_HOST=localhost`, so `database.yml` connects as `postgres`/`postgres`, as it does in Compose.
- **No secrets, except in `deploy_testing`.** The specs use OmniAuth's test mode instead of Google, and the test environment makes its own `secret_key_base`, so a pull request from a fork runs `scan_ruby`, `scan_js`, `lint`, `test` and `build` exactly like one from this repo, with a token that can read the repo and nothing else. `deploy_testing` is the exception: it only ever runs on `main` itself, never on a pull request, so a fork never sees the `testing` environment's secrets.
- **`build` only validates; it never pushes.** It builds with `push: false` and reads the registry build cache, but a fork's or Dependabot's pull request that can't log in to the private cache still builds, just without it. See [Deploying](deployment.md#ci-deploys).
- **`supersede_check` and `deploy_testing` read the commit that's still main's tip.** A merge can be followed quickly by another, and pushes to `main` run in parallel with each other (see the concurrency note below), so `supersede_check` asks the GitHub API for main's current tip and compares it with the commit this run is testing. `deploy_testing` only deploys when they match; otherwise it shows as **Skipped**, so testing never regresses to an older commit. See [Deploying](deployment.md#ci-deploys) for `deploy_testing` itself.
- **Eager loading is on.** GitHub sets `CI=true`, and `config/environments/test.rb` eager-loads the app when it's set, so a file that fails to load fails `test` even if no spec uses it. A local run without `-e CI=true` only loads the files the specs touch.
- **Tailwind isn't built.** The layout's `stylesheet_link_tag :app` links whichever stylesheets exist, so the missing `tailwind.css` doesn't fail a spec. It also means CI doesn't prove the CSS builds.
- **Every job has its own timeout**, so a hung job fails quickly instead of running for GitHub's default six hours: 10 minutes for `scan_ruby`, `scan_js`, `lint` and `test`, 15 for `build`, 5 for `supersede_check`, and 20 for `deploy_testing`, since a build without a warm cache takes several.
- **A new push to a pull request cancels the run for the previous one.** Runs on `main` are never cancelled, even when two merges land close together, so every commit on `main` keeps a result — which is what lets `supersede_check` compare them, and what a superseded commit's **Skipped** `deploy_testing` costs: if the newer commit's own checks then fail, the older commit never reaches testing, and you fix forward.
- **Docs-only changes run everything.** Skipping the workflow for them would leave a required check that never reports, and the pull request would wait forever on "Expected — Waiting for status to be reported".

### Reading a failure

- `lint` annotates the offending lines in the pull request's **Files changed** tab.
- `test` prints plain RSpec output. Its log ends with the failures, each with a `rspec ./spec/...:NN` line; run that locally as `docker compose run --rm web bin/rspec spec/...:NN`.
- If the specs pass but `test` fails at **Check that db/schema.rb matches the migrations**, see the next section.

## The schema drift check

The specs load `db/schema.rb`, not the migrations, and `maintain_test_schema!` only notices a migration that hasn't run.
So after the specs, `test` rebuilds `schema.rb` from the migrations alone and fails if the result differs from the committed file. That catches:

- a migration edited after it had already run, so that `schema.rb` still shows what it used to do
- a `schema.rb` edited by hand
- a merge that combined two branches' `schema.rb` badly

The job deletes `db/schema.rb`, runs `bin/rails db:create db:migrate` in the development environment against the empty service database, then runs `git diff --exit-code db/schema.rb`.
The failing log shows the diff: `-` lines are in the committed file but no migration makes them, and `+` lines are what the migrations make but the committed file lacks.

The delete matters. On a database that's never been migrated, Rails 8.1's `db:migrate` loads `schema.rb` and then runs only the migrations newer than it, so without the delete the check would compare `schema.rb` with itself and always pass.

### Running it locally

This uses a scratch database next to your development one, so it doesn't touch your data:

```sh
rm db/schema.rb
docker compose run --rm -e DATABASE_URL=postgres://postgres:postgres@db/budgie_schema_check web bin/rails db:create db:migrate
git diff db/schema.rb
docker compose run --rm -e DATABASE_URL=postgres://postgres:postgres@db/budgie_schema_check web bin/rails db:drop
```

With `DATABASE_URL` set, `db:create` and `db:drop` only touch `budgie_schema_check`, and leave the development and test databases alone.

No diff means the check passes. Otherwise the rebuilt `schema.rb` is what the migrations really produce:

- **A migration edited after it ran:** commit the rebuilt file. Your development database still has what the migration used to do, and `db:migrate` won't run it again, so redo it with `docker compose run --rm web bin/rails db:migrate:redo VERSION=<its timestamp>`.
- **A hand edit:** `git checkout db/schema.rb`, then make the change with a migration instead.
- **A bad merge:** commit the rebuilt file.

## The ruleset

A repository ruleset on `main` enforces the checks. The operator creates or updates it by hand, and only once the pull request that adds a new required check has merged: until the check is on `main`, no pull request can report it, so requiring it would block them all.
That's why `build` joins the ruleset only after the pull request that added it merges, the same way `test` did.

In GitHub, go to the repo's **Settings → Rules → Rulesets → New ruleset → New branch ruleset** (or open the existing `main` ruleset to add `build` to it):

- **Ruleset name:** `main`
- **Enforcement status:** **Active**
- **Bypass list:** **Add bypass → Repository admin**, set to **Always allow**. It's the only bypass, and it's for emergencies.
- **Target branches:** **Add target → Include default branch**
- **Rules:**
  - **Restrict deletions:** ticked
  - **Require a pull request before merging:** ticked, with **Required approvals** at `0`, since there's one developer
  - **Require status checks to pass:** ticked, with **Require branches to be up to date before merging** unticked. Under **Add checks**, add `scan_ruby`, `scan_js`, `lint`, `test` and `build`, and choose **GitHub Actions** as the source of each, so that nothing else can report a check by the same name.
  - **Block force pushes:** ticked

Leave every other rule unticked, and **Create** (or **Save**) it.
The page doesn't make a missing check obvious, and **Require status checks to pass** with no checks added blocks nothing, so read the checks back with the first item in [Verify](#verify).

`supersede_check` and `deploy_testing` are never added here: they only run on a push to `main`, so a pull request can never report them, and requiring them would block every merge forever.

"Up to date" stays off because it would mean rebasing every open Dependabot pull request after each merge.
Two pull requests that each pass but break when combined are caught instead by the `push` run on `main` straight after the second merge.

The admin bypass, or a direct push, can still land a commit on `main` that never passed. That's why `deploy_testing` checks this workflow's result on `main` itself, through `supersede_check`, rather than trusting that the pull request was green.

## Dependabot

Dependabot's pull requests run the same checks — the four required from the start, plus `build` once it joins the ruleset — and the ruleset blocks them the same way, so a bump that breaks the app can't merge.
`build`'s registry-cache login is best-effort, so a Dependabot pull request builds without the cache: see [How the jobs run](#how-the-jobs-run).

## Verify

Check each item once. This is what finished looks like.

**The ruleset requires all five checks, from GitHub Actions.**

```sh
gh api repos/RobertG-H/budgie-src/rules/branches/main --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[] | "\(.context) \(.integration_id)"'
```

```
scan_ruby 15368
scan_js 15368
lint 15368
test 15368
build 15368
```

`15368` is GitHub Actions. A check missing from the list isn't required, and `null` in place of the number means any app could report it.

**A pull request shows five green checks.**

```sh
gh pr checks <number>
```

It lists `scan_ruby`, `scan_js`, `lint`, `test` and `build`, each passing, plus `supersede_check` and `deploy_testing` as skipped.

**The run on `main` after a merge is green, including `deploy_testing`.**

```sh
gh run list --workflow CI --branch main --event push --limit 1
gh run view <run id>
```

The run shows the merge commit, completed with success, and its job list shows `deploy_testing` completed with success too. See [Deploying](deployment.md#ci-deploys) for what that job does, its secrets and keys, and what a superseded commit's **Skipped** `deploy_testing` looks like.

**A spec failure fails `test`, and blocks the merge.** Open a throwaway pull request, not a draft, that changes one expectation in a spec so it fails.
In its `test` log, **Run the specs** fails, and the pull request's merge button says the ruleset blocks it. Then close it.

**The drift check fails a hand-edited `schema.rb`.** Open a throwaway draft pull request that adds a column to a table in `db/schema.rb` and changes nothing else.
In its `test` log, **Run the specs** passes and **Check that db/schema.rb matches the migrations** fails, with the added line shown as `-`. Then close it.

**A new push cancels the superseded run.** Push a commit to a pull request, then another while its checks are still running.
The first run shows as cancelled in the **Actions** tab, and the pull request's checks come from the second.
