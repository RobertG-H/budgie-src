# Setting up the infrastructure from scratch

The ordered path from nothing to two running hosts. Each step links to the page that covers it in full;
this page is the order they go in and what has to be true before the next one starts.

Everything here is a one-time job, done by the operator from their own machine. Once it's finished,
deploys happen in CI and nobody touches a host to ship a change.

## What you end up with

```
browser → Cloudflare edge → tunnel → cloudflared → kamal-proxy on 127.0.0.1:80 → the app → budgie-db
```

Two OVHcloud VPS hosts, built from one script, neither reachable at its IP address. Cloudflare serves both
hostnames and reaches each host through a tunnel that dials out from it. Kamal runs the app on each host
next to its own PostgreSQL. GitHub Actions deploys testing on every merge to `main`, and production on a
dispatch. See [Architecture](architecture.md) for how the pieces fit.

| Destination | Host | Hostname |
| --- | --- | --- |
| `testing` | `budgie-testing` | `testing.budgiebuddie.com` |
| `production` | `budgie-production` | `budgiebuddie.com` |

## What you need first

| | For |
| --- | --- |
| [OVHcloud](https://www.ovhcloud.com/) account | The two VPS hosts |
| [Cloudflare](https://dash.cloudflare.com/) account | The domain, DNS, TLS, the tunnels, and R2 for the database backups |
| [Google Cloud](https://console.cloud.google.com/) account | The OAuth clients people sign in with |
| [Zedmail](https://zedmail.com/) account | Sending invite email |
| GitHub account with admin on the repo | CI, the image registry and the deploy secrets |
| [1Password](https://1password.com/) (or another password manager) | The SSH key you log in with, and the master copy of every secret |
| Docker on your machine | Break-glass deploys and operator tasks run through the `kamal` Compose service |

## 1. Register the domain

[Cloudflare → the domain](cloudflare.md#1-register-the-domain). Registering at Cloudflare Registrar creates
the zone with Cloudflare already authoritative, so there's no nameserver change and no propagation wait.

Do this first: the hostnames it gives you are used by the OAuth clients, the mail domain and the Kamal
destination files.

## 2. Create the SSH key you log in with

[The SSH key in 1Password](provisioning.md#the-ssh-key-in-1password). One key for both hosts, held in
1Password's SSH agent and never written to disk. You'll paste its public half into the OVH order.

## 3. Order and provision the two hosts

[Provisioning the hosts](provisioning.md). Order two VPS instances, run `script/provision.sh` on each, then
remove the image's default user and work through that page's checks.

At the end of this step each host has a `deploy` user, Docker, a firewall that allows only rate-limited
SSH, automatic security upgrades, and nothing at all listening on the web ports.

## 4. Put each host behind its tunnel

[Cloudflare](cloudflare.md), sections 2 to 8. Create one tunnel per host, run
`script/cloudflare-tunnel.sh` on the matching host, route the hostname to it, set the zone settings and
the two rules, then prove that the host answers on its hostname and not on its IP address.

That page's isolation check uses a throwaway origin, because there's nothing behind the tunnel yet. Tear it
down at the end, as section 8 says: a `502` from the hostname is the correct state to leave this step in.

## 5. Create the Google OAuth clients

[Google OAuth setup](google-oauth.md#testing-and-production). One Google Cloud project, one client per
environment, and the consent screen published so that people who aren't the project's owner can sign in.

## 6. Set up mail

[Email](email.md#setting-it-up). Verify `budgiebuddie.com` with Zedmail, publish its two CNAME records in
Cloudflare as **DNS only**, generate an API key per environment, and check that each host can reach the
relay. Ask Zedmail to move the account out of sandbox mode before you invite anyone but yourself.

## 7. Put the secrets in place

Two copies, under the same names:

- **On your laptop**, for break-glass deploys and operator tasks: [the secrets](deployment.md#the-secrets-on-your-laptop)
  creates `.env.kamal`, `.env.testing` and `.env.production`, generates the values that are only random, and
  checks that nothing is left empty.
- **In GitHub**, for CI: [the environments and their secrets](deployment.md#ci-deploys). Create the `testing`
  and `production` environments, limit both to the `main` branch, and add each one's nine secrets. The three more
  for backups come with [step 11](#11-set-up-backups).

The master copy of every value lives in your password manager. The repository is public, so the host IP
addresses live in these files too rather than in the destination configs.

## 8. Create the deploy keys

Three SSH keys, each authorised on its own host with `provision.sh`'s extra-key argument:

| Key | Used by | Authorised on |
| --- | --- | --- |
| [`kamal`](deployment.md#kamals-ssh-key) | Break-glass deploys from your laptop | Both hosts |
| `kamal-ci-testing` | CI's `deploy_testing` job | `budgie-testing` |
| `kamal-ci-production` | The **Deploy production** workflow | `budgie-production` |

Then record each host's key under its IP address, [on your laptop](deployment.md#each-hosts-key-under-its-ip-address)
and in that destination's `_SSH_KNOWN_HOSTS` GitHub secret. Pinning the host key is what stops a deploy
trusting whatever answers at that address.

## 9. Deploy testing by hand, once

[First deploy of a destination](deployment.md#first-deploy-of-a-destination):

```sh
docker compose run --rm kamal setup -d testing
```

`setup` is the only deploy that runs from a laptop as a matter of course. It installs `kamal-proxy` and
PostgreSQL on the host and starts the app; every later deploy to testing comes from CI.

Then work through [Verify](deployment.md#verify) for testing.

## 10. Deploy production by hand, once

Only after testing passes its checks:

```sh
docker compose run --rm kamal setup -d production --skip-push --skip-hooks
```

`--skip-push` pulls the image testing already built from the same commit, so production runs exactly what
testing ran. `--skip-hooks` skips the pre-deploy backup hook, which has nothing to back up yet and no job to
call. Then work through [Verify](deployment.md#verify) again for production, including the sign-in
with an address that isn't the Google Cloud project's owner.

## 11. Set up backups

[Backups](backups.md). Production's database is on its VPS's own disk until this step, so do it before anyone
puts real data in. Testing first, so the job is proven where nothing depends on it:

1. [Turn on R2](backups.md#1-cloudflare-r2), create the two buckets with their lock and lifecycle rules, and
   create the four tokens.
2. [Generate the two age keys](backups.md#2-the-age-keys): the primary into 1Password, the recovery key offline.
3. [Make `.env.backup`](backups.md#3-the-laptops-copy-of-the-read-only-tokens) and add each destination's three
   read-only secrets to its [GitHub environment](backups.md#5-github-the-freshness-check).
4. [Run `script/backup-setup.sh`](backups.md#4-installing-the-host-job) on each host, now that `kamal setup` has
   created its `budgie-db`.
5. Work through [Verify](backups.md#7-verify): a drill from each bucket, the live restore on testing, and the
   rest of the checklist. Production's [no-real-data rule](backups.md#before-production-holds-real-data) lifts
   only once every box on that page is ticked.

From here on, a production deploy takes a restore point first, through a Kamal hook.

## 12. Require the checks on `main`

[The ruleset](ci.md#the-ruleset). Until it exists, a pull request can merge with failing checks, and a
merge deploys testing regardless.

## 13. Hand over to CI

From here the [everyday path](deployment.md#everyday-deploys) is: merge to `main`, CI deploys testing on
its own, and the operator dispatches **Deploy production** to promote a commit testing has already run.

Finish by inviting yourself on each destination and confirming the mail arrives:

```sh
docker compose run --rm kamal task invite:create EMAIL=you@example.com -d testing
docker compose run --rm kamal task invite:create EMAIL=you@example.com -d production
```

See [Operating Budgie](operations.md) for the rest of the tasks.

> **Production holds no real budget data until [Backups](backups.md#before-production-holds-real-data) says it can.**
> That page's checklist is what step 11 works through, and it has the date the last restore drill passed.

## Rebuilding

Nothing here has to be done twice in full:

- **A rebuilt host** keeps its tunnel and its Cloudflare configuration; it needs provisioning again, the
  tunnel script re-run with the same token, a new IP address and host key in both copies of the secrets, the
  database restored from its newest backup, `kamal setup`, and the backup job installed again. See
  [Rebuilding a host](deployment.md#rebuilding-a-host).
- **A third host** is an entry in `~/.ssh/config`, one `provision.sh` run and one tunnel. The script is the
  only place a host's configuration is written down.
- **A rotated key or secret** is covered by [Recreating one](deployment.md#recreating-one).
