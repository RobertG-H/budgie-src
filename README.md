# Budgie

An envelope budgeting app built with Rails 8.1, PostgreSQL 18, Tailwind CSS 4 and Hotwire.

## What you need

Budgie has no passwords and is invite-only, so it depends on two outside services: Google for sign-in and an SMTP provider for invite emails.
What you have to set up depends on where it runs.

| | Local development | Production |
| --- | --- | --- |
| [Docker](https://docs.docker.com/get-started/get-docker/) with Compose v2 | Required | Required |
| [Google OAuth client](docs/google-oauth.md) | **Required**: without it nobody can sign in | **Required**, with separate clients for testing and production |
| [SMTP provider (Zedmail)](docs/email.md#production-zedmail) | Not needed: emails are saved to http://localhost:3000/letter_opener instead of being sent | **Required**: without it invites can't be sent, so nobody new can sign up |

Development runs entirely in containers, so you don't need Ruby or PostgreSQL on your machine.
The specs need neither Google nor SMTP.

## Getting started (local development)

1. **Set up the databases and start the app.**

   ```sh
   docker compose run --rm web bin/rails db:prepare
   docker compose up
   ```

   The first command installs the gems and creates the development and test databases, so it takes a few minutes the first time.
   Code, view and Tailwind changes show up on refresh without restarting anything.

2. **Set up Google OAuth.** Every page needs you to sign in, and signing in needs a Google OAuth client.
   Follow [Google OAuth setup](docs/google-oauth.md) once, then restart the app.

3. **Invite yourself.** Only invited addresses can create an account.

   ```sh
   docker compose run --rm web bin/rails invite:create EMAIL=you@gmail.com
   ```

   The invite email isn't sent; it appears at http://localhost:3000/letter_opener. You don't need to open it.

4. **Sign in.** Open http://localhost:3000 and sign in with Google as the address you invited.
   The first time, you choose your budget's currency before reaching your envelopes.

## Changing a budget's currency

There's no page for this. An operator can change a user's currency with:

```sh
docker compose run --rm web bin/rails budget:currency EMAIL=someone@example.com CURRENCY=USD
```

The task shows the current and new currency and asks you to type the email to confirm.
Amounts aren't converted: every amount keeps its number and is shown in the new currency.
The supported currencies are listed in `Budget::CURRENCIES`.

On a deployed host, run it through Kamal instead:

```sh
docker compose run --rm kamal task budget:currency EMAIL=someone@example.com CURRENCY=USD -d production
```

## Production

Budgie runs on two OVHcloud VPS instances running Ubuntu 26.04 LTS, `budgie-testing` and `budgie-production`.
[`script/provision.sh`](script/provision.sh) configures a host from scratch; see [Provisioning the hosts](docs/provisioning.md) for the OVH panel steps and the checks.

Neither host is reachable at its IP address. `budgiebuddie.com` and `testing.budgiebuddie.com` are served by Cloudflare, which reaches each host through a Cloudflare Tunnel that dials out from it.
[`script/cloudflare-tunnel.sh`](script/cloudflare-tunnel.sh) puts a host behind its tunnel; see [Cloudflare](docs/cloudflare.md) for the domain, the dashboard steps and the checks.

[Kamal](https://kamal-deploy.org/) deploys the app, with PostgreSQL running next to it on each host. A merge to `main` deploys testing on its own, once CI passes; the operator dispatches **Deploy production** to promote a commit testing has already run. Deploying from the laptop, through the `kamal` Compose service, is break-glass only. See [Deploying](docs/deployment.md) for CI's setup, the secrets, the first deploy, rollback and the checks.

> **Production holds no real budget data until backups exist.** Its database is only on the VPS's own disk until ticket 16 adds backups and a restore drill.

The two deployed environments need everything above plus email delivery:

1. **Google OAuth clients for testing and production**, with their callback URLs, and the consent screen published. See [Google OAuth setup](docs/google-oauth.md#testing-and-production).
2. **SMTP through Zedmail**: verify the sending domain and get an API key per environment. See [Email](docs/email.md#production-zedmail).
3. **Set up each host by hand, once**, testing first, with `kamal setup`. CI's deploys take over from there. See [Deploying](docs/deployment.md#first-deploy-of-a-destination).
4. **Invite yourself**, and check the email arrives before inviting anyone else:

   ```sh
   docker compose run --rm kamal task invite:create EMAIL=you@gmail.com -d production
   ```

## Docs

| Doc | What's in it |
| --- | --- |
| [Development](docs/development.md) | Everyday commands, debugging, adding gems and editor tooling |
| [CI](docs/ci.md) | The checks on every pull request, running them locally, the schema drift check, the ruleset that requires them on `main`, and how a push to `main` deploys testing |
| [Google OAuth setup](docs/google-oauth.md) | Creating the Google Cloud project and OAuth client, and giving the credentials to the app |
| [Invites and users](docs/invites.md) | Inviting people, the invite rules, and deleting users |
| [Email](docs/email.md) | Reading email in development and setting up Zedmail for production |
| [Architecture](docs/architecture.md) | How the containers, images and sign-in fit together |
| [Provisioning the hosts](docs/provisioning.md) | Ordering the OVH VPS instances, running `script/provision.sh` and checking the result |
| [Cloudflare](docs/cloudflare.md) | The domain, the tunnels that reach the hosts, and keeping the hosts off the public internet |
| [Deploying](docs/deployment.md) | Deploying with Kamal: CI deploys, secrets, first deploys, operator tasks, rollback, break-glass deploys by hand, and the checks |

## License

The source is public to read, but all rights are reserved: see [LICENSE](LICENSE).
