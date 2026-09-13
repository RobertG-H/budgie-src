# Budgie

An envelope budgeting app built with Rails 8.1, PostgreSQL 18, Tailwind CSS 4 and Hotwire.

## Prerequisites

[Docker](https://docs.docker.com/get-started/get-docker/) with Compose v2. Docker Desktop includes both.
Development runs entirely in containers, so you don't need Ruby or PostgreSQL on your machine.

## Getting started

```sh
docker compose run --rm web bin/rails db:prepare
docker compose up
```

Then open http://localhost:3000.

The first command installs the gems and creates the development and test databases, so it takes a few minutes the first time.
Code, view and Tailwind changes show up on refresh without restarting anything.

## Commands

| Task | Command |
| --- | --- |
| Set up or migrate the databases | `docker compose run --rm web bin/rails db:prepare` |
| Start the app | `docker compose up` |
| Stop the app | `docker compose down` |
| Run the specs | `docker compose run --rm web bin/rspec` |
| Open a Rails console | `docker compose run --rm web bin/rails console` |
| Attach to the debugger | `docker compose attach web` |
| Lint | `docker compose run --rm web bin/rubocop` |
| Build the production image | `docker build .` |

Other Rails commands work the same way: `docker compose run --rm web bin/rails <command>`.

### Debugging

Add `debugger` where you want to stop and trigger that code, for example by loading the page.
Then run `docker compose attach web` in a second terminal to reach the `(rdbg)` prompt.
Detach with `Ctrl-P` `Ctrl-Q`. `Ctrl-C` can stop the server.

### Adding a gem

Add it to the `Gemfile` and restart the containers.
Missing gems are installed into the `bundle` volume when a container starts, so the image never needs rebuilding.
Commit the updated `Gemfile.lock`.

## How it's put together

- `compose.yaml` runs three services: `web` (Puma), `css` (the Tailwind watcher) and `db` (PostgreSQL 18).
  The repo is bind-mounted at `/app`, and gems and database data live in named volumes.
- The `Dockerfile` has two targets.
  `development` is what Compose runs.
  The default target is the production image, which is also what Kamal deploys.

## Editor tooling (optional)

Ruby on your machine is only useful for editor tooling such as ruby-lsp or RuboCop.
If you want that, install the Ruby version in `.ruby-version` and run `bundle install`.
