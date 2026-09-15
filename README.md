# Budgie

An envelope budgeting app built with Rails 8.1, PostgreSQL 18, Tailwind CSS 4 and Hotwire.

## What you need

Budgie has no passwords and is invite-only, so it depends on two outside services: Google for sign-in and an SMTP provider for invite emails.
What you have to set up depends on where it runs.

| | Local development | Production |
| --- | --- | --- |
| [Docker](https://docs.docker.com/get-started/get-docker/) with Compose v2 | Required | Required |
| [Google OAuth client](docs/google-oauth.md) | **Required**: without it nobody can sign in | **Required**, with its own production client |
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

## Production

Production needs everything above plus email delivery:

1. **A production Google OAuth client** with the production callback URL. See [Google OAuth setup](docs/google-oauth.md).
2. **SMTP through Zedmail**: verify the sending domain, get an API key and set the `SMTP_*` and `MAILER_FROM` variables. See [Email](docs/email.md#production-zedmail).
3. **Invite yourself** with `invite:create`, and check the email arrives before inviting anyone else.

## Docs

| Doc | What's in it |
| --- | --- |
| [Development](docs/development.md) | Everyday commands, debugging, adding gems and editor tooling |
| [Google OAuth setup](docs/google-oauth.md) | Creating the Google Cloud project and OAuth client, and giving the credentials to the app |
| [Invites and users](docs/invites.md) | Inviting people, the invite rules, and deleting users |
| [Email](docs/email.md) | Reading email in development and setting up Zedmail for production |
| [Architecture](docs/architecture.md) | How the containers, images and sign-in fit together |
