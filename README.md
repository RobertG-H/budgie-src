# Budgie

An envelope-budgeting app built with Rails 8.1, PostgreSQL 18, Tailwind CSS 4 and Hotwire.

Budgie is invite-only and has no passwords: people sign in with Google, and only an invited address can
create an account. Money is organised into envelopes, which never reset at month end — leftover money and
overspending both carry into the next month.

It runs as one Rails application against one PostgreSQL database, in Docker locally and on two small VPS
hosts in production. [Architecture](docs/architecture.md) is the tour.

## Setting up

Two guides, depending on what you're setting up:

- **[Local development](docs/development.md)** — running Budgie on your own machine. You need Docker and a
  Google OAuth client; everything else runs in containers, so there's no Ruby, PostgreSQL or Node to
  install.
- **[Infrastructure from scratch](docs/infrastructure.md)** — the ordered path from nothing to two running
  hosts: the domain, the servers, the tunnels, the secrets and the first deploys.

The short version of the first one:

```sh
docker compose run --rm web bin/rails db:prepare
docker compose up
docker compose run --rm web bin/rails invite:create EMAIL=you@gmail.com
```

Then open http://localhost:3000. Signing in needs a [Google OAuth client](docs/google-oauth.md) first.

## How it runs in production

Budgie is served at `budgiebuddie.com`, with a testing copy at `testing.budgiebuddie.com`. Both run the
same image with the same `RAILS_ENV=production`; only their configuration differs, so testing exercises
production's setup rather than a lookalike of it.

```
browser → Cloudflare edge → tunnel → cloudflared → kamal-proxy on 127.0.0.1:80 → the app → budgie-db
```

Neither host answers at its IP address: `cloudflared` dials out to Cloudflare, so nothing dials in.
Deploys run in CI — a merge to `main` deploys testing once the checks pass, and the operator dispatches
**Deploy production** to promote a commit testing has already run.

> **Production holds no real budget data until [Backups](docs/backups.md#before-production-holds-real-data) says it can.** Each host's database is dumped nightly, encrypted, to Cloudflare R2, and that page has the checklist and the date the last restore drill passed.

## Docs

| Doc | What's in it |
| --- | --- |
| [Architecture](docs/architecture.md) | The stack, the request path, and every application and infrastructure integration |
| [Local development](docs/development.md) | Setting up your machine, everyday commands, debugging and UI work |
| [Infrastructure from scratch](docs/infrastructure.md) | The ordered path from nothing to two running hosts |
| [Operating Budgie](docs/operations.md) | Invites, deleting users, changing a currency, and reaching a running host |
| [Google OAuth setup](docs/google-oauth.md) | The Google Cloud project, the consent screen and one OAuth client per environment |
| [Splitwise setup](docs/splitwise.md) | One Splitwise app per environment, the keys a connection's token is kept under, and checking Connect Splitwise works |
| [Email](docs/email.md) | Reading mail in development, and Zedmail's SMTP relay in testing and production |
| [Provisioning the hosts](docs/provisioning.md) | Ordering the OVHcloud VPS instances, `script/provision.sh` and the checks |
| [Cloudflare](docs/cloudflare.md) | The domain, the zone settings, the tunnels, and keeping the hosts off the public internet |
| [Backups](docs/backups.md) | The nightly encrypted dump to Cloudflare R2, the quarterly restore drill, and a real restore |
| [Deploying](docs/deployment.md) | Kamal and the deploy workflows: secrets, first deploys, rollback, break-glass deploys and the checks |
| [CI](docs/ci.md) | The checks on every pull request, running them locally, the schema drift check and the ruleset |
| [Design](DESIGN.md) | The UI rules: colour, layout, money formatting and components |
| [daisyUI](docs/daisyui.md) | The component reference, and how the vendored plugin is pinned |

## License

The source is public to read, but all rights are reserved: see [LICENSE](LICENSE).
