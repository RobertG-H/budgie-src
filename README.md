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

Every page needs you to sign in, and signing in needs Google OAuth credentials.
Set them up once by following [OAuth setup (Google)](#oauth-setup-google).
The specs run without them.

## OAuth setup (Google)

Budgie has no passwords. People sign in with Google, so the app needs an OAuth client from Google Cloud.
Each environment has its own client; these steps create the one for local development.

### 1. Create the project and consent screen

You only do this once, for all environments.

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project named **Budgie**.
2. Go to **Google Auth Platform** > **Branding** and click **Get started**.
3. Fill in the steps:
   - **App name:** Budgie
   - **User support email:** your email address
   - **Audience:** External
   - **Contact information:** your email address
4. Agree to the Google API Services User Data Policy and click **Create**.

Leave the publishing status on **Testing**.
You don't need to add test users: Google lets any account sign in to a Testing app that only asks for name, email address and profile, which is all Budgie asks for.

### 2. Create the development client

1. Go to **Google Auth Platform** > **Clients** and click **Create client**.
2. Set **Application type** to **Web application** and name it **Budgie development**.
3. Under **Authorized redirect URIs**, add `http://localhost:3000/auth/google_oauth2/callback`.
   No JavaScript origins are needed.
4. Click **Create** and copy the client ID and client secret.
   Google shows the secret only once, so copy it before closing the dialog.

A new redirect URI can take a few minutes to start working.

### 3. Give the credentials to the app

```sh
cp .env.example .env
```

Put the client ID and secret in `.env` as `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`, then restart the app with `docker compose up`.
Compose loads `.env` into the `web` container. Git ignores the file, so the secret stays on your machine.

Until invites arrive, any Google account with a verified email address can sign in, and its first sign-in creates its Budgie user.

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
- Sign-in goes through OmniAuth.
  `config/auth_providers.yml` lists the enabled providers, `config/initializers/omniauth.rb` configures them, and each has a mapper in `app/models/auth_profile/` that turns what the provider returns into an `AuthProfile`.
  `SignInWithIdentity` decides who that profile signs in as, without knowing which provider it came from.

## Editor tooling (optional)

Ruby on your machine is only useful for editor tooling such as ruby-lsp or RuboCop.
If you want that, install the Ruby version in `.ruby-version` and run `bundle install`.
