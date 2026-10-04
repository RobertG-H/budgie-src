# Local development

Everything runs in Docker Compose, so your machine needs no Ruby, no PostgreSQL and no Node.

- [What you need](#what-you-need)
- [Setting up](#setting-up)
- [Everyday commands](#everyday-commands)
- [Before you push](#before-you-push)
- [Reading email](#reading-email)
- [Debugging](#debugging)
- [Adding a gem](#adding-a-gem)
- [Changing the database](#changing-the-database)
- [Working on the UI](#working-on-the-ui)
- [Editor tooling](#editor-tooling)

## What you need

| | Needed for |
| --- | --- |
| [Docker](https://docs.docker.com/get-started/get-docker/) with Compose v2 | Everything |
| A [Google OAuth client](google-oauth.md) | Signing in. Every page but the sign-in page needs it |
| Node | Playwright MCP only, through `npx`. Skip it unless you're working on the UI |

The specs need neither Google nor Node. Email is never delivered in development, so there's nothing to set
up for it.

## Setting up

**1. Create the databases and install the gems.**

```sh
docker compose run --rm web bin/rails db:prepare
```

The first run takes a few minutes: it builds the development image, installs the gems into the `bundle`
volume, and creates the development and test databases.

**2. Set up a Google OAuth client** and put its credentials in `.env`. Follow
[Google OAuth setup](google-oauth.md) — it's a one-time job, and without it nobody can sign in.

**3. Start the app.**

```sh
docker compose up
```

That runs `web` (Puma, on http://localhost:3000), `css` (the Tailwind watcher) and `db` (PostgreSQL 18).
Code, view and Tailwind changes show up on refresh; nothing needs restarting.

**4. Invite yourself.** Only invited addresses can create an account.

```sh
docker compose run --rm web bin/rails invite:create EMAIL=you@gmail.com
```

The invite email isn't sent — it appears at http://localhost:3000/letter_opener — and you don't need to
open it to sign in.

**5. Sign in** at http://localhost:3000 with Google, as the address you invited. The first time, you choose
your budget's currency, and then you land on the month view.

**6. Optionally, load the sample data.**

```sh
docker compose run --rm web bin/rails db:seed
```

This creates a development user with a budget, a few envelopes and two Paycheck Deposits. It's what [`/dev/sign_in`](#working-on-the-ui)
signs in as, and it only ever runs in development.

## Everyday commands

| Task | Command |
| --- | --- |
| Start the app | `docker compose up` |
| Stop the app | `docker compose down` |
| Set up or migrate the databases | `docker compose run --rm web bin/rails db:prepare` |
| Run the specs | `docker compose run --rm web bin/rspec` |
| Run one file or example | `docker compose run --rm web bin/rspec spec/models/user_spec.rb:12` |
| Lint | `docker compose run --rm web bin/rubocop` |
| Open a Rails console | `docker compose run --rm web bin/rails console` |
| Open a shell in the running `web` container | `docker compose exec web bash` |
| Open a shell without the app running | `docker compose run --rm web bash` |
| Attach to the debugger | `docker compose attach web` |
| Show the routes | `docker compose run --rm web bin/rails routes` |
| Load the sample development data | `docker compose run --rm web bin/rails db:seed` |
| Build the production image | `docker build .` |
| Container status and server logs | `docker compose ps` and `docker compose logs web` |

Other Rails commands work the same way: `docker compose run --rm web bin/rails <command>`. Inside a shell,
the repo is at `/app`, so `bin/rails`, `bin/rspec` and the rest run directly; leave with `exit`.

Commands for invites, users and currencies are in [Operating Budgie](operations.md).

## Before you push

These are the same checks [CI](ci.md) runs, so running them first saves a round trip:

```sh
docker compose run --rm -e CI=true web bin/rspec
docker compose run --rm web bin/rubocop
docker compose run --rm web bin/brakeman --no-pager
docker compose run --rm web bin/bundler-audit
docker compose run --rm web bin/importmap audit
```

`CI=true` eager-loads every file, the way CI does, so a file that fails to load fails there even when a
plain local run passes.

## Reading email

Emails aren't delivered in development. [letter_opener_web](https://github.com/fgrehm/letter_opener_web)
saves them instead, at http://localhost:3000/letter_opener. See [Email](email.md).

## Debugging

Add `debugger` where you want to stop and trigger that code, for example by loading the page. Then run
`docker compose attach web` in a second terminal to reach the `(rdbg)` prompt. Detach with `Ctrl-P`
`Ctrl-Q` — `Ctrl-C` can stop the server.

## Adding a gem

Add it to the `Gemfile` and restart the containers: missing gems are installed into the `bundle` volume
when a container starts, so the image never needs rebuilding. With the app already running, you can install
without a full restart, then restart `web` so it loads the new gem and any initializer:

```sh
docker compose exec -T web bundle install
docker compose restart web
```

Commit the updated `Gemfile.lock`.

## Changing the database

Generate and run migrations as usual:

```sh
docker compose run --rm web bin/rails generate migration AddSomethingToSomething
docker compose run --rm web bin/rails db:migrate
```

Two things to know:

- **The specs load `db/schema.rb`, not the migrations**, so run `db:migrate` after adding one and commit
  the `schema.rb` it writes. Never hand-edit that file — CI rebuilds it from the migrations and fails on
  any difference. See [the schema drift check](ci.md#the-schema-drift-check).
- **Give every new user-owned table a `dependent:` option.** Foreign keys are `ON DELETE RESTRICT`, and
  `user:delete` relies on Rails deleting children first. A table that references envelopes also goes in
  `Budget#delete_envelope_records`, and its envelope refuses deletion while it has records
  (`has_many …, dependent: :restrict_with_error`).

## Working on the UI

[`DESIGN.md`](../DESIGN.md) holds the UI rules — colour, layout, money formatting, components and a "Don't"
list. [daisyUI](daisyui.md) is the component reference.

Two shortcuts exist in development only:

- **`/styleguide`** shows the theme and every base component, without signing in.
- **`GET /dev/sign_in`** starts a session as the seeded development user, once `db:seed` has run.

Both are drawn only when `RAILS_ENV` is `development`, and their controllers refuse outside it as well.

**Playwright MCP** drives a real browser for visual review. `.mcp.json` at the repo root configures it,
project-scoped, pinned to a version and restricted to `http://localhost:3000`; Claude Code asks you to
approve the server the first time. Node is needed on your machine only for its `npx`, and nowhere else —
it's not in the `Gemfile`, in Compose, in the `Dockerfile` or in CI.

After a UI change, screenshot each affected page at **375px** and **1280px**, compare against
[`DESIGN.md`](../DESIGN.md), fix what doesn't match, and screenshot again.

## Editor tooling

Ruby on your machine is only useful for editor tooling such as ruby-lsp or RuboCop. If you want that,
install the Ruby version in `.ruby-version` and run `bundle install`.
