# Deploying with Kamal

[Kamal](https://kamal-deploy.org/) deploys Budgie to the two hosts from [Provisioning the hosts](provisioning.md), behind the tunnels from [Cloudflare](cloudflare.md):

| Destination | Host | Hostname |
| --- | --- | --- |
| `testing` | `budgie-testing` | `testing.budgiebuddie.com` |
| `production` | `budgie-production` | `budgiebuddie.com` |

Kamal builds the `Dockerfile`'s production image, pushes it to GitHub's container registry, and runs it on each host behind `kamal-proxy`, next to that host's own PostgreSQL:

```
browser → Cloudflare → tunnel → cloudflared → kamal-proxy on 127.0.0.1:80 → the app → budgie-db
```

Both hosts run the same image with `RAILS_ENV=production`, from the same `config/environments/production.rb`.
What differs between them comes from each destination's config file and secrets, so testing proves production's configuration rather than a lookalike.

**CI deploys, not your laptop.** A merge to `main` deploys to testing on its own, once CI has passed on that commit on `main` itself. Production only deploys when the operator dispatches **Deploy production**, in GitHub's Actions tab, and only for a commit that testing has already run, using the very image testing built. See [CI deploys](#ci-deploys).
Deploying from your laptop, covered from [Deploying by hand](#deploying-by-hand-break-glass) onward, still works, but it's break-glass only: for the first setup of a destination, for a deploy when Actions itself is down, and for the operator tasks in [Operating Budgie](operations.md), which run through the same `kamal` Compose service.

> **Production holds no real budget data until backups exist.** Its database is on the VPS's own disk and nowhere else, and no restore has been rehearsed, so use production for invites, sign-ins and envelopes you can afford to lose.

## What lives where

| Thing | Where it's written down |
| --- | --- |
| What both destinations share: registry, proxy, database, env, aliases | `config/deploy.yml` |
| What differs: hostname, `APP_HOST`, `MAILER_FROM` and which variable holds the IP address | `config/deploy.testing.yml` and `config/deploy.production.yml` |
| Which secret each variable comes from | `.kamal/secrets-common`, `.kamal/secrets.testing` and `.kamal/secrets.production`: names only |
| The secret values, for a break-glass deploy | `.env.kamal`, `.env.testing` and `.env.production` on your laptop, which git ignores, with the master copy in your password manager |
| The secret values, for CI | The `testing` and `production` GitHub environments' secrets |
| Each host's IP address | `TESTING_HOST_IP` and `PRODUCTION_HOST_IP`, both places above |
| TLS, the allowed hostnames and the host in email links | `config/environments/production.rb` |
| The image | `ghcr.io/robertg-h/budgie`, a private GitHub package, tagged with the commit SHA it was built from |
| The build cache | `ghcr.io/robertg-h/budgie-build-cache`, a private GitHub package |
| The database | `/home/deploy/budgie-db/data` on each host, and nowhere else yet |
| The workflows that deploy | `.github/workflows/ci.yml`'s `deploy_testing` job, and `.github/workflows/deploy-production.yml` |
| The SSH key you log in with | 1Password, with its public half in `~/.ssh/budgie/budgie.pub` |
| The SSH key Kamal deploys with, for a break-glass deploy | `~/.ssh/budgie/kamal` on your laptop, loaded into the macOS agent |
| The SSH keys Kamal deploys with, in CI | `kamal-ci-testing` and `kamal-ci-production`, one per destination, each only in its own GitHub environment's secrets |
| The host keys Kamal trusts, for a break-glass deploy | Your Mac's `~/.ssh/known_hosts` |
| The host keys Kamal trusts, in CI | `TESTING_SSH_KNOWN_HOSTS` and `PRODUCTION_SSH_KNOWN_HOSTS`, in the matching GitHub environment's secrets |

## CI deploys

The normal path. A push to `main` runs [`ci.yml`](../.github/workflows/ci.yml)'s `deploy_testing` job once `scan_ruby`, `scan_js`, `lint` and `test` pass and `supersede_check` confirms the commit is still main's tip (see [CI](ci.md)); it builds the image, pushes `ghcr.io/robertg-h/budgie:<sha>`, and runs `bin/kamal deploy -d testing` on the runner itself, natively, since GitHub's runners are already amd64.
Promoting that commit to production is [`deploy-production.yml`](../.github/workflows/deploy-production.yml), dispatched by hand from the Actions tab (**Actions → Deploy production → Run workflow**), or `gh workflow run deploy-production.yml -f sha=<sha>` from a terminal that isn't this checkout — Claude never dispatches it. Left blank, `sha` defaults to main's tip, and an abbreviated SHA works too. Its `guard` job runs first, with no environment and no secrets: it resolves the input to a full SHA, and refuses before any SSH unless that commit is reachable from `main` and its `deploy_testing` check run concluded `success`; only then does `deploy`, with `environment: production`, check out that commit and run `bin/kamal deploy -d production --skip-push`, which pulls the image `deploy_testing` already pushed rather than building it again.

### The environments

**Settings → Environments** has `testing` and `production`, each with **Deployment branches and tags** limited to `main`, so a dispatch against any other branch is refused before the job's secrets are even loaded — that's what refuses a `sha` input on a branch other than `main`. Neither has required reviewers or a wait timer: dispatching production is already a deliberate act, and a reviewer gate would add a second click to the operator's own deploy.
`deploy_testing` declares `environment: testing`; `deploy-production.yml`'s `deploy` job declares `environment: production`. `guard` declares neither, so a bad `sha` input is refused without ever touching a credential.

### The keys and known_hosts

Each destination deploys with its own SSH key, `kamal-ci-testing` and `kamal-ci-production`, both ed25519 with no passphrase, so that a leak from the `testing` environment's secrets can't reach production. Each is authorised on its own host only, the same way [Kamal's own key](#kamals-ssh-key) is: as `provision.sh`'s extra-key argument. See [Provisioning the hosts](provisioning.md#2-run-the-script).
Both keys are root-equivalent on their host, the same as the laptop's key, because `deploy` has passwordless sudo and is in the `docker` group.

A job's own step starts an `ssh-agent` and loads the destination's key into it, with no third-party action. The step's `env:` hands it the environment secret as `SSH_PRIVATE_KEY`:

```sh
export SSH_AUTH_SOCK="$RUNNER_TEMP/ssh-agent.sock"
ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null
echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" >> "$GITHUB_ENV"
ssh-add - <<< "$SSH_PRIVATE_KEY"
```

A fresh runner's `~/.ssh/known_hosts` is empty, so without pinning the host key, Kamal would accept whatever key answers at that IP address the first time. `TESTING_SSH_KNOWN_HOSTS` and `PRODUCTION_SSH_KNOWN_HOSTS` each hold that host's `known_hosts` lines, keyed by its IP address the way [the laptop already records them](#each-hosts-key-under-its-ip-address), from `ssh-keygen -F <ip>`. A step appends the secret to `~/.ssh/known_hosts` before Kamal runs. Running `ssh-keyscan` at run time was rejected on purpose: it trusts whatever answers, which is the exact check this is meant to prevent.

### The environment secrets

Each environment has nine secrets, named the same way `.env.testing` and `.env.production` are, because `.kamal/secrets-common` and `.kamal/secrets.<destination>` read the same names either way — see [the laptop's copy](#the-secrets-on-your-laptop) for what each one is:

| Secret | What it is |
| --- | --- |
| `TESTING_HOST_IP` / `PRODUCTION_HOST_IP` | That host's IP address |
| `TESTING_SSH_PRIVATE_KEY` / `PRODUCTION_SSH_PRIVATE_KEY` | That destination's Kamal deploy key, private half |
| `TESTING_SSH_KNOWN_HOSTS` / `PRODUCTION_SSH_KNOWN_HOSTS` | That host's `known_hosts` lines |
| `TESTING_SECRET_KEY_BASE` / `PRODUCTION_SECRET_KEY_BASE` | That destination's Rails `secret_key_base` |
| `TESTING_BUDGIE_DATABASE_PASSWORD` / `PRODUCTION_BUDGIE_DATABASE_PASSWORD` | That destination's PostgreSQL password |
| `TESTING_GOOGLE_CLIENT_ID` / `PRODUCTION_GOOGLE_CLIENT_ID` | That destination's Google OAuth client ID |
| `TESTING_GOOGLE_CLIENT_SECRET` / `PRODUCTION_GOOGLE_CLIENT_SECRET` | That destination's Google OAuth client secret |
| `TESTING_SMTP_USERNAME` / `PRODUCTION_SMTP_USERNAME` | The Zedmail login email address |
| `TESTING_SMTP_PASSWORD` / `PRODUCTION_SMTP_PASSWORD` | That destination's Zedmail API key |

`KAMAL_REGISTRY_PASSWORD` isn't one of the nine: each deploy job sets it directly in its `env:` from `secrets.GITHUB_TOKEN`, the run's own built-in token, rather than storing it. `deploy_testing` has `packages: write`, so Kamal can push; `deploy`'s `packages: read` only lets it pull. Kamal logs each host in to `ghcr.io` with it too, so the credential that ends up in `/home/deploy/.docker/config.json` expires with the job rather than being a long-lived token.

### Recreating one

- **A compromised or rotated deploy key:** generate a new `ed25519` key pair, authorise the public half with `provision.sh`'s extra-key argument on that key's own host, replace `TESTING_SSH_PRIVATE_KEY` or `PRODUCTION_SSH_PRIVATE_KEY` in that environment's secrets, then remove the old key's line from the host's `authorized_keys` the way [revoking Kamal's own key](#kamals-ssh-key) works.
- **A rebuilt host:** see [Rebuilding a host](#rebuilding-a-host). Both the `_HOST_IP` and `_SSH_KNOWN_HOSTS` secrets change.
- **Any of the other six:** update the value in **Settings → Environments → (testing or production) → Environment secrets**, the same value you'd put in `.env.testing` or `.env.production`. Update your password manager's copy too, since it's still the master copy.

## Deploying by hand (break-glass)

Kamal runs in the `kamal` Compose service rather than on your Mac, so the host still needs no Ruby:

```sh
docker compose run --rm kamal deploy -d testing
```

- It runs the `kamal` gem from `Gemfile.lock`, the same version [CI](ci.md) installs through `ruby/setup-ruby`.
- It builds and pushes with Docker Desktop's daemon, through its socket, and reaches the hosts with [its own SSH key](#kamals-ssh-key), through Docker Desktop's forward of the macOS SSH agent.
- It's in the `deploy` profile, so `docker compose up` never starts it. It's the only service that gets the Docker socket or the SSH agent.
- Every command needs `-d testing` or `-d production`. `config/deploy.yml` sets `require_destination`, because the servers are only in the destination files.

The first run builds the service's image, which takes a few minutes.

**Kamal deploys commits, not your working tree.** It builds from a fresh git clone of `HEAD` and tags the image with that commit's SHA, so commit first. Uncommitted changes are never deployed, and Kamal lists the ones it's leaving out in yellow.

The hosts are amd64, so an arm64 Mac builds under QEMU, and a build without a warm cache takes a while.
`Missing compatible builder, so creating a new one first` on every run is expected: the container starts without buildx's list of builders, but the builder's container and its cache stay in Docker Desktop between runs.

### Before your first deploy

Two things on your Mac, once: an SSH key for Kamal, and each host's key recorded under its IP address.

#### Kamal's SSH key

You log in to the hosts with the 1Password key from [Provisioning the hosts](provisioning.md#the-ssh-key-in-1password), but Kamal can't use it.
The `kamal` container only gets the SSH agent that Docker Desktop forwards, which is the macOS one, and neither `~/.ssh/config` nor 1Password's agent can reach the container.
So Kamal gets a key of its own, kept in the macOS agent and authorised for `deploy` on both hosts.
Without it, `kamal setup` fails with `Net::SSH::AuthenticationFailed` for `deploy@<ip>`, because the container offers the hosts only keys they don't accept.

**1. Create it**, and give it a passphrase when `ssh-keygen` asks:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/budgie/kamal -C kamal-laptop
```

**2. Authorise it on both hosts.** `provision.sh` adds it next to the 1Password key, and changes nothing else on a host that's already provisioned:

```sh
scp script/provision.sh ~/.ssh/budgie/kamal.pub budgie-testing:
ssh budgie-testing 'sudo bash provision.sh budgie-testing kamal.pub'
scp script/provision.sh ~/.ssh/budgie/kamal.pub budgie-production:
ssh budgie-production 'sudo bash provision.sh budgie-production kamal.pub'
```

Each run's only change is the new key:

```
   changed: authorised a key from kamal.pub (kamal-laptop)
...
   1 change(s) applied
```

**3. Load it into the agent that Docker Desktop forwards**, and check that the container can see it:

```sh
ssh-add --apple-use-keychain ~/.ssh/budgie/kamal
docker compose run --rm --entrypoint ssh-add kamal -l
```

The second command lists `kamal-laptop` among the agent's keys.
`--apple-use-keychain` keeps the passphrase in your Keychain. The agent forgets its keys when the Mac restarts, so after a restart, run `ssh-add --apple-load-keychain` before you deploy.

Kamal offers the hosts every key in that agent in turn, and sshd refuses a connection after six failed keys, so keep the macOS agent to a few keys. `ssh-add -l` lists them.

The key can do anything `deploy` can, including `sudo`, so look after it as carefully as the 1Password key.
It needs no backup: if the laptop is lost, the 1Password key can authorise a new one. To revoke it, delete its line on both hosts:

```sh
ssh budgie-testing 'sed -i "/ kamal-laptop$/d" ~/.ssh/authorized_keys'
ssh budgie-production 'sed -i "/ kamal-laptop$/d" ~/.ssh/authorized_keys'
```

#### Each host's key, under its IP address

Kamal connects to each host's IP address, from [`TESTING_HOST_IP` and `PRODUCTION_HOST_IP`](#the-secrets-on-your-laptop), and the container checks each host's key against your `~/.ssh/known_hosts`, mounted read-only.
If your `~/.ssh/config` uses the IP addresses as `HostName`, as [Provisioning the hosts](provisioning.md) sets it up, logging in as `budgie-testing` and `budgie-production` has already recorded them.
Check with each host's address from the OVH panel or your `~/.ssh/config`:

```sh
ssh-keygen -F <testing ip>
ssh-keygen -F <production ip>
```

Each prints a `# Host <ip> found` line and the host's key. If one prints nothing, connect to that address once.
Kamal's key is in the macOS agent, so this works without going through `~/.ssh/config`:

```sh
ssh deploy@<testing ip> true
```

If ssh asks whether to trust the key, it also lists the other names it already trusts that key under. Answer yes only if one of them is that host's name from your `~/.ssh/config`.
If it says the key has *changed*, stop and find out why: refusing that connection is the point of the check.

Because the file is read-only, a host the container has never seen isn't refused, just not remembered. Recording each IP address is what turns the check into a real one.

## The secrets on your laptop

This is the break-glass copy. [CI's own copy](#the-environment-secrets) lives in the `testing` and `production` GitHub environments instead, under the same names.

Deploys read their secrets from three files in the repo root, next to your development `.env`:

| File | What's in it |
| --- | --- |
| `.env.kamal` | The registry token, which both destinations share |
| `.env.testing` | Testing's six secrets and its host's IP address, each named `TESTING_...` |
| `.env.production` | Production's six secrets and its host's IP address, each named `PRODUCTION_...` |

Git ignores all three, as it does `.env`, but they're separate from it.
`.env` is development's, holding the development Google client from [Google OAuth setup](google-oauth.md), and only the `web` container loads it.
The `kamal` service loads these three and never `.env`, so a deploy secret put in `.env` wouldn't reach a deploy. Leave `.env` as it is.

Every file is loaded into every run, which is why each destination's names carry its prefix.
`.kamal/secrets-common` and `.kamal/secrets.<destination>` then map each variable the app gets to one of these by name. They're committed, and they contain no values.

**1. Create the files.** From the repo root:

```sh
(
  set -C
  printf '%s\n' "KAMAL_REGISTRY_PASSWORD=" > .env.kamal
  printf '%s\n' \
    "TESTING_HOST_IP=" \
    "TESTING_SECRET_KEY_BASE=$(openssl rand -hex 64)" \
    "TESTING_BUDGIE_DATABASE_PASSWORD=$(openssl rand -hex 32)" \
    "TESTING_GOOGLE_CLIENT_ID=" \
    "TESTING_GOOGLE_CLIENT_SECRET=" \
    "TESTING_SMTP_USERNAME=" \
    "TESTING_SMTP_PASSWORD=" > .env.testing
  printf '%s\n' \
    "PRODUCTION_HOST_IP=" \
    "PRODUCTION_SECRET_KEY_BASE=$(openssl rand -hex 64)" \
    "PRODUCTION_BUDGIE_DATABASE_PASSWORD=$(openssl rand -hex 32)" \
    "PRODUCTION_GOOGLE_CLIENT_ID=" \
    "PRODUCTION_GOOGLE_CLIENT_SECRET=" \
    "PRODUCTION_SMTP_USERNAME=" \
    "PRODUCTION_SMTP_PASSWORD=" > .env.production
  chmod 600 .env.kamal .env.testing .env.production
)
```

It fills in the values that are only random: each destination's `SECRET_KEY_BASE`, the same kind of value `bin/rails secret` prints, and its database password. Everything else starts empty, and only you can read the files.
`set -C` makes it refuse to overwrite a file that already exists. That matters once a destination is running: a new `SECRET_KEY_BASE` signs everyone out, and a new database password locks the app out of its database.

**2. Fill in the rest** in your editor, as each one becomes available:

| Variable | Value |
| --- | --- |
| `KAMAL_REGISTRY_PASSWORD` | [A GitHub token](#the-github-token) |
| `TESTING_HOST_IP` and `PRODUCTION_HOST_IP` | That host's IP address, from the OVH panel. It isn't a secret, but the destination files read it from here so that the public repo doesn't list it. See [Cloudflare](cloudflare.md) |
| `TESTING_GOOGLE_CLIENT_ID` and `TESTING_GOOGLE_CLIENT_SECRET` | The **Budgie testing** OAuth client, not the development one in `.env`. See [Google OAuth setup](google-oauth.md#testing-and-production) |
| `PRODUCTION_GOOGLE_CLIENT_ID` and `PRODUCTION_GOOGLE_CLIENT_SECRET` | The **Budgie production** OAuth client |
| `TESTING_SMTP_USERNAME` and `PRODUCTION_SMTP_USERNAME` | The email address you log in to Zedmail with, the same in both files. See [Email](email.md#the-settings) |
| `TESTING_SMTP_PASSWORD` and `PRODUCTION_SMTP_PASSWORD` | That environment's Zedmail API key, which starts with `ses_` |

Write values without quotes, unless one contains a `$`: Compose expands `$` in unquoted and double-quoted values, so that one needs single quotes.

**3. Copy every value into your password manager**, the generated ones too. It holds the master copy, and the files are a working copy of it, so a new laptop gets them back from there.

**4. Check that nothing is empty.** An unset variable deploys as an empty value without a word from Kamal:

```sh
docker compose run --rm -T kamal secrets print -d testing | grep -E '^[A-Z_]+=$'
docker compose run --rm -T kamal secrets print -d production | grep -E '^[A-Z_]+=$'
```

Both print nothing. A line names a secret that's empty, usually because of a typo in its env file.
The pipe keeps the values themselves off your screen.
The IP addresses aren't secrets, so this doesn't list them. If one isn't set, every command for that destination stops with `key not found` and the variable's name.

Each destination has its own `SECRET_KEY_BASE`, so a cookie or signed ID from one is useless on the other.
`RAILS_MASTER_KEY` isn't deployed at all. The credentials file holds nothing but a `secret_key_base`, which `SECRET_KEY_BASE` takes precedence over, and nothing else in the app reads credentials.

PostgreSQL only reads the database password the first time it starts with an empty data directory. To change it later, change the role's password in the database too, with `ALTER ROLE budgie PASSWORD '...'` in `dbc`, or the app can no longer connect.

### The GitHub token

GitHub's container registry only accepts classic tokens. In GitHub, go to **Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token (classic)**:

- **Note:** `Budgie Kamal (laptop)`
- **Expiration:** your choice. When it runs out, deploys fail at `docker login`.
- **Scopes:** `write:packages`. GitHub ticks `repo` along with it; untick `repo`, since the token only needs the registry.

Kamal also logs in to `ghcr.io` on each host with this token so that the host can pull, which leaves it in `/home/deploy/.docker/config.json` on both hosts. That's the reason for the narrow scope.

The first push creates `ghcr.io/robertg-h/budgie` as a **private** package. Check it under **Your profile → Packages** on GitHub, and leave it private.

## First deploy of a destination

Testing first. Deploy production only once testing passes [the checks](#verify).

**1. Everything outside the repo is done.**

- The host is [provisioned](provisioning.md) and behind its [tunnel](cloudflare.md), with the throwaway origin torn down, so nothing holds port 80.
- The destination's [Google OAuth client](google-oauth.md#testing-and-production) exists.
- [Zedmail](email.md#setting-it-up) has verified `budgiebuddie.com`, and the host passes the check that it can reach Zedmail's relay.
- [The secrets](#the-secrets-on-your-laptop) are in place, with nothing empty.
- [Kamal's SSH key](#kamals-ssh-key) is authorised on the host and loaded into the agent, and the host's key is recorded under its IP address.

**2. Set it up.**

```sh
docker compose run --rm kamal setup -d testing
```

`setup` checks Docker on the host, builds and pushes the image, starts `kamal-proxy` and PostgreSQL, then starts the app and waits for `/up` to answer.
The app's entrypoint runs `db:prepare`, which creates the cache, queue and cable databases next to `budgie_production` the first time.
It ends with:

```
Finished all in 612.3 seconds
```

For production, add `--skip-push`:

```sh
docker compose run --rm kamal setup -d production --skip-push
```

That pulls the image testing built from the same commit instead of building it again, so production runs exactly what testing ran.
If it fails to pull with `manifest unknown`, testing hasn't deployed this commit yet.

**3. The proxy binds loopback only, from its very first start.** There's no separate step for this.
`proxy.run.bind_ips` in `config/deploy.yml` puts `127.0.0.1` into the `docker run` that first creates `kamal-proxy`, so it never listens on `0.0.0.0`, even once.
It's not `kamal proxy boot_config set --publish-host-ip 127.0.0.1`, which Kamal 2.12 deprecates in favour of `proxy.run`, and which a rebuilt host would need someone to remember.

`kamal deploy` starts the existing proxy container as it is, so a change under `proxy.run` only takes effect with a reboot, which is a brief outage:

```sh
docker compose run --rm kamal proxy reboot -d testing
```

**4. It answers through Cloudflare.**

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://testing.budgiebuddie.com/up
```

```
200
```

**5. Deploy once more.** This is what every later deploy looks like:

```sh
docker compose run --rm kamal deploy -d testing
```

Then work through [Verify](#verify).

## Everyday deploys

1. Merge to `main`. CI deploys it to testing on its own, once `scan_ruby`, `scan_js`, `lint`, `test` and `supersede_check` all pass — no command to run.
2. Check testing, once `deploy_testing` is green: `https://testing.budgiebuddie.com/up` returns `200`, and whatever you changed works there.
3. Dispatch **Deploy production** (**Actions → Deploy production → Run workflow**, or `gh workflow run deploy-production.yml`), leaving `sha` blank to deploy main's tip.

Migrations run when the new container starts, because the entrypoint runs `db:prepare`, while the old container is still serving. A migration has to work with the code that's still running, and rolling back the code doesn't roll back a migration.

A break-glass deploy from the laptop looks the way it always did: see [Deploying by hand](#deploying-by-hand-break-glass).

## If a deploy fails

**Read the log.** `gh run view <run id> --log-failed` prints just the failed steps; drop the flag for the whole log. `deploy_testing` and `deploy` end with Kamal's own error, the same one a break-glass deploy would show.

**Re-running.** Once the cause is fixed, the operator re-runs the failed run from the Actions tab, or `gh run rerun <run id> --failed` — Claude never dispatches or re-runs a deploy; see `CLAUDE.md`. Re-running `deploy_testing` redeploys whatever commit that run was for, even if `main` has since moved on; re-running `deploy-production.yml` redeploys whatever `sha` that dispatch resolved to.

**A stale lock.** A job killed partway through a deploy, by its timeout or a manual cancel, can leave Kamal's lock on the host, and the next deploy — from CI or the laptop — fails until it's released:

```sh
docker compose run --rm kamal lock release -d testing
```

CI never releases a stale lock itself: a killed job can't tell whether something else is still mid-deploy, and releasing the lock automatically would hide a real overlap with a break-glass deploy from the laptop. It's safe to release once you're sure nothing else is still deploying to that destination — check the Actions tab for another run in progress, and confirm nobody's running a break-glass deploy by hand.

## Operator tasks

Invites, deleting a user and changing a budget's currency all run on a host through Kamal's `task` alias,
as do the `console`, `logs`, `dbc` and `shell` aliases. See [Operating Budgie](operations.md).

## Rollback

**Dispatch an older commit.** `gh run list --workflow CI --branch main --event push` lists main's history; find a `sha` whose `deploy_testing` succeeded, and dispatch **Deploy production** with it. `guard` accepts any commit reachable from `main` whose `deploy_testing` concluded `success`, not only the newest, so this is a real deploy through the normal path, with a record in the Actions tab of who ran it and which commit.
Migrations don't roll back: one that ran on a newer commit stays applied, so rolling back past a migration the older code can't handle breaks it.

**From the laptop (break-glass).** Kamal keeps the containers of the last five versions on each host:

```sh
docker compose run --rm kamal app containers -d testing
```

Each one is named `budgie-web-testing-<version>`, where the version is a commit SHA. The running one is `Up`, and the rest have exited. To go back to one:

```sh
docker compose run --rm kamal rollback <version> -d testing
```

It runs that version again from its image, which is still on the host, and points the proxy at it, without building, pulling or any of dispatching's SSH setup — faster than the CI path, since the old image is already there. To come forward again, deploy as usual. Migrations don't roll back here either.

## Verify

Check each item on **both** destinations unless it says otherwise. This is what finished looks like.

**It answers through Cloudflare.**

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://testing.budgiebuddie.com/up
curl -sS -o /dev/null -w '%{http_code}\n' https://budgiebuddie.com/up
```

```
200
200
```

**The IP address still answers nothing.** This is [the direct-IP check](cloudflare.md#6-prove-the-isolation) again, against the real app this time:

```sh
curl -sS -m 10 -o /dev/null -w '%{http_code}\n' http://<testing ip>/
curl -sS -m 10 -o /dev/null -w '%{http_code}\n' -k https://<testing ip>/
ssh deploy@budgie-testing 'sudo ss -tlnp | grep -E ":(80|443) "'
```

```
curl: (28) Connection timed out after 10002 milliseconds
curl: (28) Connection timed out after 10001 milliseconds
LISTEN 0  4096  127.0.0.1:443  0.0.0.0:*  users:(("docker-proxy",...))
LISTEN 0  4096  127.0.0.1:80   0.0.0.0:*  users:(("docker-proxy",...))
```

`kamal-proxy`'s two ports are on `127.0.0.1` only, and nothing is on `0.0.0.0:80` or `0.0.0.0:443`.

**Invite, email, sign-in and an envelope, end to end.**

1. `docker compose run --rm kamal task invite:create EMAIL=<address> -d testing`, which prints `Invited <address>.`
2. The invite arrives, and the Zedmail dashboard shows it as delivered. Its link goes to `https://testing.budgiebuddie.com/sign_in`.
3. Sign in with Google as that address. You land on budget setup; choose a currency.
4. Create an envelope. It's saved and listed.

On **production**, do this with an address that **isn't** the Google Cloud project's owner: that's what proves the consent screen is really In production.
If that address isn't one of Zedmail's verified test addresses, it also needs Zedmail to have moved the account out of sandbox mode.

**Each destination has its own database.** After testing's end-to-end check:

```sh
docker compose run --rm kamal task invite:list -d testing
docker compose run --rm kamal task invite:list -d production
```

Testing's list has the address you invited there, as `accepted`, and production's doesn't: it lists only what you've invited on production, or says `No invites.`

**A signed-in page isn't cached, and the session cookie is `Secure`.** Signed in, open the browser's developer tools and reload the envelopes page:

- In **Network**, the page's own request has `cf-cache-status: DYNAMIC` in its response headers, or no `cf-cache-status` at all.
- Under the site's cookies (**Application** in Chrome, **Storage** in Firefox and Safari), `session_id` has **Secure** ticked, and so does every other Budgie cookie.

**`http://` redirects, HSTS stays off, and `/up` is exempt.**

```sh
curl -sSI http://testing.budgiebuddie.com/ | grep -iE '^(HTTP|location)'
curl -sSI https://testing.budgiebuddie.com/up | grep -iE '^(HTTP|strict-transport-security)'
```

```
HTTP/1.1 301 Moved Permanently
location: https://testing.budgiebuddie.com/
HTTP/2 200
strict-transport-security: max-age=0; includeSubDomains
```

The redirect is Cloudflare's Always Use HTTPS. With `assume_ssl`, Rails counts every request as HTTPS, so its own redirect never fires.

`max-age=0` is HSTS turned *off*. Rails' `force_ssl` always sends the header, and `hsts: false` in `production.rb` makes it `max-age=0`, which tells a browser to forget any HSTS it had for the site.
Any larger `max-age` means HSTS got turned on somewhere. Turning it on is one decision, taken in `production.rb` and at Cloudflare together.

`/up` has to answer the way `kamal-proxy`'s health check asks: over plain HTTP, without a public hostname. Check from inside the app container:

```sh
docker compose run --rm kamal app exec --reuse -d testing 'curl -s -o /dev/null -w "%{http_code}\n" http://localhost/up'
docker compose run --rm kamal app exec --reuse -d testing 'curl -s -o /dev/null -w "%{http_code}\n" http://localhost/'
```

Among Kamal's output, the first prints `200` and the second `403`: `/up` answers any hostname without redirecting, and every other path refuses a hostname that isn't one of the two.

**The logs show the real client IP.** On production:

```sh
curl -s https://budgiebuddie.com/cdn-cgi/trace | grep '^ip='
curl -s -o /dev/null https://budgiebuddie.com/sign_in
docker compose run --rm kamal app logs -d production --since 5m --grep 'Started GET "/sign_in"'
```

```
ip=203.0.113.7
...
2026-09-26T14:02:11.123456789Z [4f9c...] Started GET "/sign_in" for 203.0.113.7 at 2026-09-26 14:02:11 +0000
```

`/cdn-cgi/trace` is Cloudflare saying which address it saw, and the log line should show the same one: your public address, not `127.0.0.1` or a `172.x` address.
No app code does this. Cloudflare sets `X-Forwarded-For`, `cloudflared`, `kamal-proxy` (with `forward_headers: true`) and Thruster pass it on, and Rails skips the loopback and private addresses those hops add.

**Rollback works.** Testing only, while nothing real depends on it, so that the first real rollback isn't the first rollback. It needs two versions on the host, so deploy a newer commit first if `app containers` lists only one:

```sh
docker compose run --rm kamal app containers -d testing
docker compose run --rm kamal rollback <an older version> -d testing
docker compose run --rm kamal app version -d testing
docker compose run --rm kamal deploy -d testing
docker compose run --rm kamal app version -d testing
```

The first `app version` prints the older version, and the second prints the current commit again, which `git rev-parse HEAD` shows. `/up` answers `200` after each step.

**Everything comes back after a reboot.** The host reboots itself at 04:00 UTC when an update needs it, so check now rather than then:

```sh
ssh deploy@budgie-testing 'sudo reboot'
# wait a minute
ssh deploy@budgie-testing 'docker ps --format "{{.Names}}: {{.Status}}"'
curl -sS -o /dev/null -w '%{http_code}\n' https://testing.budgiebuddie.com/up
```

```
budgie-web-testing-6b672903c9d2f30b991cd59d6194282b4941034b: Up 48 seconds
kamal-proxy: Up 52 seconds
budgie-db: Up 52 seconds
200
```

Docker restarts all three itself, since Kamal starts them with `--restart unless-stopped`. The app may restart once or twice while PostgreSQL starts, until `db:prepare` can connect.

**No secret is committed.** From the repo root:

```sh
cat .env.kamal .env.testing .env.production | grep -E '^[A-Z_]+=.' | while IFS= read -r line; do
  git grep -qF -e "${line#*=}" $(git rev-list --all) && echo "in git: ${line%%=*}"
done; echo checked
```

```
checked
```

An `in git:` line names a variable whose value is somewhere in the history. `.kamal/secrets*` should only ever hold `$NAME` references.
The exception is `TESTING_HOST_IP` and `PRODUCTION_HOST_IP`. They show up until the hosts have new addresses, because commits from before the addresses moved out of the destination files still hold them.

## Rebuilding a host

A rebuilt host has a new IP address and a new host key:

1. Forget the old host key with `ssh-keygen -R <old ip>`, and put the new IP address in that destination's `_HOST_IP` variable and your password manager, as that host's `HostName` in `~/.ssh/config`, and in its `_HOST_IP` GitHub environment secret.
2. Provision it, passing `kamal.pub` as the extra key so that [Kamal's key](#kamals-ssh-key) is authorised from the start. Then provision it a second time, passing that destination's CI deploy key's public half, so [its CI key](#the-keys-and-known_hosts) is authorised too. See [Provisioning the hosts](provisioning.md).
3. Put it behind its tunnel again. See [Cloudflare](cloudflare.md).
4. `docker compose run --rm kamal setup -d <destination>`, with `--skip-push` for production.
5. Record the new host's key under its new IP address, the way [the laptop already does](#each-hosts-key-under-its-ip-address), and update that destination's `_SSH_KNOWN_HOSTS` GitHub environment secret with `ssh-keygen -F <new ip>`'s output.

Its database starts empty: there's no backup to restore.
