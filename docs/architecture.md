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
supervisor inside Puma, because invite mail is sent with `deliver_now` and the only recurring job is an
hourly clear-out of finished jobs.

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
with the table `budget_envelopes`, and `Budget::Deposit` has `budget_deposits`. `Budget.use_relative_model_naming?`
drops the prefix from routes, params and DOM ids, so it's `envelopes_path` and `EnvelopesController`.
`Current.budget` is the one way controllers and views find the budget — for now the signed-in user's — and
controllers look records up through it, so another user's record is a 404.

Constraints live in the database as well as in the models — check constraints, unique indexes, and
`ON DELETE RESTRICT` foreign keys with Rails deleting children first through `dependent: :destroy`. An amount
is validated as a number under 10¹³ with at most two decimal places, and more places is an error rather than
being rounded.

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
