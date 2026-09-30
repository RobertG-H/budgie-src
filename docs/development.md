# Development

Everything runs in Docker Compose. See the [README](../README.md#getting-started) for first-time setup.

## Commands

| Task | Command |
| --- | --- |
| Set up or migrate the databases | `docker compose run --rm web bin/rails db:prepare` |
| Start the app | `docker compose up` |
| Stop the app | `docker compose down` |
| Run the specs | `docker compose run --rm web bin/rspec` |
| Open a Rails console | `docker compose run --rm web bin/rails console` |
| Open a shell in the running `web` container | `docker compose exec web bash` |
| Open a shell in a new `web` container (when the app isn't running) | `docker compose run --rm web bash` |
| Attach to the debugger | `docker compose attach web` |
| Lint | `docker compose run --rm web bin/rubocop` |
| Build the production image | `docker build .` |
| Load the sample development data (dev user, budget, envelopes) | `docker compose run --rm web bin/rails db:seed` |

Other Rails commands work the same way: `docker compose run --rm web bin/rails <command>`.
Inside a shell, the repo is at `/app` and you can run `bin/rails`, `bin/rspec` and the rest directly. Leave with `exit`.
Commands for invites and users are in [Invites and users](invites.md).

## Reading email

Emails aren't delivered in development. Open http://localhost:3000/letter_opener to read them.
See [Email](email.md) for more.

## Debugging

Add `debugger` where you want to stop and trigger that code, for example by loading the page.
Then run `docker compose attach web` in a second terminal to reach the `(rdbg)` prompt.
Detach with `Ctrl-P` `Ctrl-Q`. `Ctrl-C` can stop the server.

## Adding a gem

Add it to the `Gemfile` and restart the containers.
Missing gems are installed into the `bundle` volume when a container starts, so the image never needs rebuilding.
Commit the updated `Gemfile.lock`.

## Frontend and Playwright MCP

Node on your machine is only for Playwright MCP's `npx`, and only there — it's not in the `Gemfile`, in
Compose, in the `Dockerfile` or in CI, and there's no `package.json`. `.mcp.json` at the repo root configures
it, pinned to a version and restricted to `http://localhost:3000`; Claude Code asks you to approve the
project-scoped server the first time you use it.

`/styleguide` shows the theme and base components without signing in. `GET /dev/sign_in` starts a session for
the seeded development user, once the seed above is loaded. Both exist only when `RAILS_ENV` is
`development` — see `CLAUDE.md`'s Frontend section and `DESIGN.md` for the rules they're checked against.

## Editor tooling (optional)

Ruby on your machine is only useful for editor tooling such as ruby-lsp or RuboCop.
If you want that, install the Ruby version in `.ruby-version` and run `bundle install`.
