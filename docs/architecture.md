# Architecture

## Containers and images

- `compose.yaml` runs three services: `web` (Puma), `css` (the Tailwind watcher) and `db` (PostgreSQL 18).
  The repo is bind-mounted at `/app`, and gems and database data live in named volumes.
- The `Dockerfile` has two targets.
  `development` is what Compose runs.
  The default target is the production image, which is also what Kamal deploys.

## Sign-in

- Sign-in goes through OmniAuth.
  `config/auth_providers.yml` lists the enabled providers, `config/initializers/omniauth.rb` configures them, and each has a mapper in `app/models/auth_profile/` that turns what the provider returns into an `AuthProfile`.
- `SignInWithIdentity` decides who that profile signs in as, without knowing which provider it came from.
  It only creates a user for an email with a pending `Invite` (see [Invites and users](invites.md)).
