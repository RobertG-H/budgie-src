# Backups: R2, the host job and the restore drill

Each host takes a nightly dump of its `budgie_production` database, encrypts it on the host, and uploads it to its own bucket in Cloudflare R2:

```
budgie-db → pg_dump → age, to two public keys → rclone → R2 bucket: budgie-backups-<destination>
              ↑
              a systemd timer at 08:00 UTC, and, on production, a Kamal hook before every deploy
```

Only encrypted bytes leave the host, and the private keys are never on one, so a stolen host or token can't read a dump.
Each bucket is also locked for as long as it keeps a dump, so a stolen host or token can't delete history either.
A lost VPS, a bad migration, a wrong `user:delete` and a compromised host are all in scope, and up to 24 hours of entries can be lost: a restore is measured in hours, and a dump is taken before every production deploy as well.

[`script/backup-setup.sh`](../script/backup-setup.sh) installs the job on a host.
[`script/restore-drill.sh`](../script/restore-drill.sh), behind a `restore` Compose service, proves a dump is restorable.
This page covers the Cloudflare dashboard steps and the keys, which can't be scripted, the drill, a real restore, and the checks that say it works.
Like `cloudflare-tunnel.sh`, `backup-setup.sh` never runs from the application checkout: copy it to the host and run it there.

Do [Provisioning the hosts](provisioning.md), [Cloudflare](cloudflare.md) and the [first deploy](deployment.md#first-deploy-of-a-destination) of the destination first.
The job dumps the `budgie-db` container, which only `kamal setup` creates, and the script refuses a host without one.
Testing first, so production isn't the one you learn on: the testing host runs the same job, and the drill proves the same key path production relies on.

> **Production holds no real budget data until [the checks below](#before-production-holds-real-data) are ticked.** Until then, use it for invites, sign-ins and envelopes you can afford to lose.

- [What's backed up, and what isn't](#whats-backed-up-and-what-isnt)
- [What lives where](#what-lives-where)
- [1. Cloudflare R2](#1-cloudflare-r2)
- [2. The age keys](#2-the-age-keys)
- [3. The laptop's copy of the read-only tokens](#3-the-laptops-copy-of-the-read-only-tokens)
- [4. Installing the host job](#4-installing-the-host-job)
- [5. GitHub: the freshness check](#5-github-the-freshness-check)
- [6. The pre-deploy hook](#6-the-pre-deploy-hook)
- [7. Verify](#7-verify)
- [The restore drill](#the-restore-drill)
- [A real restore](#a-real-restore)
- [Key custody and rotation](#key-custody-and-rotation)
- [Retention and deleted users](#retention-and-deleted-users)
- [Before production holds real data](#before-production-holds-real-data)

## What's backed up, and what isn't

**Backed up:** `budgie_production`, the primary database, on both hosts. Testing is backed up the same way, so the job is proven there before production depends on it.

**Not backed up, on purpose:**

- **The cache, queue and cable databases** (`budgie_production_cache`, `_queue` and `_cable`). Nothing in `app/` broadcasts, invites are sent with `deliver_now`, and the only jobs are the two in `config/recurring.yml`, which Solid Queue registers again at boot. Sessions are rows in the primary. A restore into an empty `db` accessory followed by `db:prepare` creates the other three empty, which is all they need. Don't add them to the job out of caution: it would only make every restore bigger.
- **The `budgie` role.** The `postgres:18` image creates it from `POSTGRES_USER`, so there's no `pg_dumpall --globals`.
- **A host's configuration and secrets.** They're rebuilt from `provision.sh`, `cloudflare-tunnel.sh` and the master copies in 1Password.
- **The `budgie_storage` volume.** Nothing uses Active Storage.

**How much can be lost:** up to 24 hours of entries, from the nightly dump. Production also takes a restore point before every deploy, which is when a migration could destroy data.
There's no WAL archiving or point-in-time recovery. Revisit that if Bank sync means a day's data can't be imported again.

**Where the job runs:** a systemd timer on each host, not a Kamal accessory, a CI workflow or a Solid Queue job. It uses the `postgres:18` image's own `pg_dump`, because the app image's client is older than the server and `pg_dump` refuses a newer one. It keeps running when a deploy is broken or half-done, which is when a backup matters, and the R2 token never goes in the app's environment.

## What lives where

| Thing | Where it's written down |
| --- | --- |
| Installing the job on a host | `script/backup-setup.sh`, which writes the rest of this column's host files |
| The job, its units and its env file | `/usr/local/sbin/budgie-backup`, `/etc/systemd/system/budgie-backup@.service` and `budgie-backup.timer`, and `/etc/budgie-backup.env` (root only, `0600`), all on the host |
| The buckets, their lock and lifecycle rules, the four tokens | The Cloudflare dashboard — and, so it can be rebuilt, [section 1](#1-cloudflare-r2) |
| The host's read-write token | `/etc/budgie-backup.env` on that host, and the master copy in 1Password. Nowhere else |
| The read-only tokens | 1Password (master), `.env.backup` on your laptop, and each destination's GitHub environment secrets |
| The age private keys | 1Password (primary) and offline (recovery). Never on a host, in GitHub or in the repo |
| The age public keys | [Below](#the-two-recipients), and each host's `/etc/budgie-backup.env` |
| The freshness check and the quarterly reminder | `.github/workflows/backup-checks.yml` |
| The pre-deploy restore point | `.kamal/hooks/pre-deploy` |
| The drill | `script/restore-drill.sh`, `Dockerfile.restore` and the `restore` and `restore-db` services in `compose.yaml` |
| When the last drill passed | [Below](#before-production-holds-real-data) |

### The names

Every name is prefixed by its destination, as the deploy secrets are in [Deploying](deployment.md#the-secrets-on-your-laptop).

| Name | What it is | Where it lives |
| --- | --- | --- |
| `budgie-backups-testing`, `budgie-backups-production` | The two buckets. One each, so a leaked testing token can't upload a fake "latest" dump into production's | Cloudflare |
| `budgie-backup-testing-write`, `budgie-backup-production-write` | An Object Read & Write token scoped to that one bucket. R2 has no write-only token, so this one can delete: the lock rule is what stops it | That host's `/etc/budgie-backup.env`, and 1Password |
| `budgie-backup-testing-read`, `budgie-backup-production-read` | An Object Read only token scoped to that one bucket. It can only fetch ciphertext | 1Password, `.env.backup`, and that destination's GitHub environment |
| `TESTING_BACKUP_R2_ENDPOINT`, `_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY` | The testing read-only token's three values | `.env.backup`, and the `testing` GitHub environment's secrets |
| `PRODUCTION_BACKUP_R2_ENDPOINT`, `_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY` | The production read-only token's three values | `.env.backup`, and the `production` GitHub environment's secrets |

The names in `.env.backup` and the GitHub secrets are the same, as with `.env.testing`, so `restore-drill.sh` and `backup-checks.yml` read them the same way.

## 1. Cloudflare R2

In the [Cloudflare dashboard](https://dash.cloudflare.com/), under **Storage & databases → R2 object storage**.
Cloudflare's dashboard moves things around from time to time, and the exact labels shift with it. What matters is the set of values in the tables below, not the path through the menus.

### 1a. Turn R2 on

Open **R2 object storage → Overview** and subscribe. It may need a payment method on file.
It costs $0 under the free tier: 10 GB of storage a month, a million writes and ten million reads, and no charge for egress, which is why restore drills are free. A nightly dump of a database this size is tiny.
The free tier covers **Standard** storage only, so don't choose Infrequent Access.

Check **R2 → Overview** shows the plan as free, and **Billing** shows no R2 line.

### 1b. Create the two buckets

**Create bucket**, twice:

| Field | `budgie-backups-testing` | `budgie-backups-production` |
| --- | --- | --- |
| Bucket name | `budgie-backups-testing` | `budgie-backups-production` |
| Location | Automatic | Automatic |
| Default storage class | **Standard** | **Standard** |

Leave public access off. Neither bucket ever needs a public URL or a custom domain.

Don't choose a jurisdiction such as EU unless you mean to: it changes the S3 endpoint to `https://<account id>.eu.r2.cloudflarestorage.com`, which `backup-setup.sh` accepts and the tokens' pages show.

### 1c. The lock and lifecycle rules

On each bucket's **Settings**, two rules, both for the same number of days. That number is the retention: 7 for testing and 90 for production. One flat window, and the host never deletes anything.

| Setting | `budgie-backups-testing` | `budgie-backups-production` |
| --- | --- | --- |
| **Bucket lock** → Add rule, name | `keep for 7 days` | `keep for 90 days` |
| Prefix | *(empty: every object)* | *(empty: every object)* |
| Rule condition | Prevent deletion for a specified period: **7 days** | Prevent deletion for a specified period: **90 days** |
| **Object lifecycle rules** → Add rule, name | `expire after 7 days` | `expire after 90 days` |
| Prefix | *(empty)* | *(empty)* |
| Action | **Delete uploaded objects** after **7 days** | **Delete uploaded objects** after **90 days** |

The lock is what makes a stolen host or token harmless: for the retention period, an object can be neither deleted nor overwritten, by anyone, whatever token they hold. The lifecycle rule then removes the dump once it's old enough to be unlocked.
That's also why the job always writes a new, timestamped key and never replaces one.
Cloudflare's documentation doesn't say whether a read-write token can override a lock, so [Verify](#7-verify) proves it rather than assuming.

Add nothing to either rule that isn't in the table. A shorter lock leaves recent dumps deletable; a longer lifecycle rule keeps dumps for longer than the retention this page promises.

### 1d. The four tokens

**R2 object storage → Manage API tokens → Create API token**, four times. For each: **Permissions** as in the table, **Specify bucket(s)** → *Apply to specific buckets only* → that bucket, **TTL** *Forever*, and no client IP filtering, since the freshness check runs from GitHub's changing addresses.

| Token name | Permissions | Bucket |
| --- | --- | --- |
| `budgie-backup-testing-write` | **Object Read & Write** | `budgie-backups-testing` |
| `budgie-backup-testing-read` | **Object Read only** | `budgie-backups-testing` |
| `budgie-backup-production-write` | **Object Read & Write** | `budgie-backups-production` |
| `budgie-backup-production-read` | **Object Read only** | `budgie-backups-production` |

Not the **Admin** permissions, and not account-wide: a token that can create buckets or reach the other one defeats having two.

Each token's page shows an **Access Key ID**, a **Secret Access Key** and the **endpoint**, `https://<account id>.r2.cloudflarestorage.com`. **The secret is shown once.** Put all three, labelled with the token's name, in 1Password straight away.
The endpoint is the same for all four, and it's not a secret, but the account ID in it isn't something to publish, so it travels with the tokens and stays out of git.

Don't use the "Account API token" bearer value that follows them: it isn't what an S3 client takes.

## 2. The age keys

Every dump is encrypted to two public keys, and either private key decrypts it:

- **The primary key**, held in 1Password. The drill and a real restore use it.
- **The recovery key**, kept offline somewhere other than 1Password: on paper, or on a USB stick in a safe place. It's for the day 1Password is the thing that's lost.

Both destinations use the same two, so the testing drill proves the key path production relies on.
Losing both private keys makes every backup unreadable, which is the reason there are two. See [Key custody and rotation](#key-custody-and-rotation).

The `restore` Compose service has `age-keygen`. Build it once, which takes a minute:

```sh
docker compose --profile restore build restore
```

**1. Generate the primary key** and put it on the clipboard, without ever printing it:

```sh
docker compose run --rm --no-deps -T --entrypoint age-keygen restore | pbcopy
```

In 1Password, create a **Secure Note** named `Budgie backup key (primary)` and paste: three lines, a comment with the creation time, one with the public key and the `AGE-SECRET-KEY-1...` line.

**2. Print its public half**, which is the part the hosts take:

```sh
pbpaste | docker compose run --rm --no-deps -T --entrypoint age-keygen restore -y
```

```
age1x0xuxdcahramjcdutkh7jkzddnuf3gn5jfaneq7dna7w382scdcsu5w257
```

Note it. Then clear the clipboard: `pbcopy < /dev/null`.

**3. Do it again for the recovery key**, which has to be a different key, and this time keep it somewhere other than 1Password:

```sh
docker compose run --rm --no-deps -T --entrypoint age-keygen restore | pbcopy
pbpaste | docker compose run --rm --no-deps -T --entrypoint age-keygen restore -y
```

Paste the clipboard into a new document, print it or save it to the USB stick, then delete the document, empty the trash and clear the clipboard again with `pbcopy < /dev/null`. A second copy somewhere else is worth having. Name it `Budgie backup key (recovery)`.

### The two recipients

Write both public keys here, so that what the hosts encrypt to can be read back and checked:

| Key | Public half (`age1...`) |
| --- | --- |
| Primary, in 1Password | *(fill in)* |
| Recovery, offline | *(fill in)* |

They're public, so committing them is fine.

## 3. The laptop's copy of the read-only tokens

The drill reads each destination's bucket with its read-only token, from a gitignored `.env.backup`, which Compose loads into the `restore` service only. Git ignores it like `.env.testing`, and the `kamal` service never loads it.

From the repo root:

```sh
(
  set -C
  printf '%s\n' \
    "TESTING_BACKUP_R2_ENDPOINT=" \
    "TESTING_BACKUP_R2_ACCESS_KEY_ID=" \
    "TESTING_BACKUP_R2_SECRET_ACCESS_KEY=" \
    "PRODUCTION_BACKUP_R2_ENDPOINT=" \
    "PRODUCTION_BACKUP_R2_ACCESS_KEY_ID=" \
    "PRODUCTION_BACKUP_R2_SECRET_ACCESS_KEY=" > .env.backup
  chmod 600 .env.backup
)
```

Fill each value in from 1Password in your editor: the **read-only** token's, for the matching destination, with no quotes. The private keys are never in this file; the drill takes one on stdin.

## 4. Installing the host job

Do this once per host, testing first, and only after `kamal setup` has created its `budgie-db`.

**1. Write the host's token to a file on your laptop, outside the checkout**, so the repo, which is public, can never pick it up. Use `~/budgie-r2.env`, from the `…-write` token for that host, with the endpoint from its page:

```
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_ENDPOINT=https://<account id>.r2.cloudflarestorage.com
```

Then `chmod 600 ~/budgie-r2.env`.

**2. Run the script**, with both public keys, passing the token on stdin:

```sh
scp script/backup-setup.sh budgie-testing:
ssh budgie-testing 'sudo bash backup-setup.sh testing --recipient age1<primary> --recipient age1<recovery>' < ~/budgie-r2.env
rm ~/budgie-r2.env
```

Reading the token from stdin keeps it out of your shell history, out of `ps` on the host and out of any file left behind on it: the only copy on the host is `/etc/budgie-backup.env`, which only root can read. That's different from `cloudflared`, whose token ends up in a world-readable unit.

The script refuses to run on a host that hasn't been provisioned or that has no running `budgie-db`, installs `age` and `rclone` from Ubuntu's apt so that `unattended-upgrades` keeps them current, checks that the token can list the bucket before it changes anything, then writes the job, its two units and the env file, and enables the timer.
It's safe to re-run, which is also how a token or a recipient is replaced: on a host already set up this way it changes nothing and exits 0.
It ends with `Take the first dump now`:

```sh
ssh budgie-testing 'sudo systemctl start budgie-backup@nightly; sudo journalctl -u budgie-backup@nightly -n 6 --no-pager'
```

```
budgie-backup: dumping budgie_production (nightly)
budgie-backup: uploading budgie_production-20261006T141502Z-nightly.dump.age (41233 bytes) to budgie-backups-testing
budgie-backup: done: budgie_production-20261006T141502Z-nightly.dump.age is in budgie-backups-testing
```

Then do production the same way, with `production` and its own token.

**What a run does,** under `set -euo pipefail`: dump with the `postgres:18` image's own `pg_dump` into a `0700` temporary directory that's removed afterwards; check that `pg_restore --list` can read the archive; encrypt to both recipients; refuse to upload anything under 10 KB; upload with `rclone`; and check that R2 reports the size that was sent. Any failure leaves the unit failed and uploads nothing, and [the freshness check](#5-github-the-freshness-check) notices the missing dump.
The unit is templated, `budgie-backup@.service`, and its instance is the reason for the dump: the timer starts `@nightly` at 08:00 UTC, which is after the 04:00 UTC reboot and after Eastern midnight has rolled the month, and `Persistent=true` makes a host that was down at 08:00 take it when it boots.
The job runs as root: `deploy` is root-equivalent through sudo and Docker, and CI's deploy keys log in as `deploy`, so a less privileged user would protect nothing.

**The size floor** is 10 KB, in `MIN_BYTES` in the job and `min_bytes` in `backup-checks.yml`. It's deliberately low. After the first real dump on production, set both to something sensible, such as a tenth of its size, and re-run the script on both hosts.

## 5. GitHub: the freshness check

[`.github/workflows/backup-checks.yml`](../.github/workflows/backup-checks.yml) runs at 12:00 UTC every day, for each destination in turn. It lists the destination's bucket with that destination's read-only token and fails if the newest dump is older than 12 hours or under 10 KB. It checks the artifact in the bucket and not the host's claim, so it also notices a host that's gone silent, and GitHub emails the failure to whoever last edited the schedule.

On the first of January, April, July and October it also opens a **Restore drill due** issue, so the reminder lives in the tracker.

In the repo's **Settings → Environments**, open `testing`, then `production`, and add that destination's three **Environment secrets**, with the read-only token's values from 1Password:

| In the `testing` environment | In the `production` environment |
| --- | --- |
| `TESTING_BACKUP_R2_ENDPOINT` | `PRODUCTION_BACKUP_R2_ENDPOINT` |
| `TESTING_BACKUP_R2_ACCESS_KEY_ID` | `PRODUCTION_BACKUP_R2_ACCESS_KEY_ID` |
| `TESTING_BACKUP_R2_SECRET_ACCESS_KEY` | `PRODUCTION_BACKUP_R2_SECRET_ACCESS_KEY` |

Each environment now has twelve secrets: the nine in [Deploying](deployment.md#the-environment-secrets), and these three.
The read-only token can only fetch ciphertext, and the age private keys are never in GitHub.

One known limit: GitHub disables a scheduled workflow after 60 days without repository activity, and then the alert and the reminder stop together. The repo is active and GitHub emails a warning first, so this is accepted.

## 6. The pre-deploy hook

[`.kamal/hooks/pre-deploy`](../.kamal/hooks/pre-deploy) runs before every production deploy, from wherever Kamal runs, and starts `budgie-backup@predeploy` on the host over SSH. It waits for it, and it's fail-closed: no dump, no deploy.
A migration that destroys data is the one case where losing up to 24 hours is worse than it needs to be, and every production deploy runs `db:prepare` when the new container starts.

- **Production only.** Testing deploys on every merge, so a hook there would be noise: the hook exits at once for any other destination.
- **A rollback skips it**, since no migration runs.
- **A first `kamal setup` and a rebuild skip hooks** with `--skip-hooks` (`-H`), because the backup unit doesn't exist yet and the database is empty anyway:

  ```sh
  docker compose run --rm kamal setup -d production --skip-push --skip-hooks
  ```

  A hook that fails open when the unit is missing was rejected on purpose: it would fail open exactly when someone forgot a step.
- **R2 being unreachable blocks a production deploy.** A CI deploy waits on it. If a deploy can't wait, a break-glass `docker compose run --rm kamal deploy -d production --skip-push --skip-hooks` skips the restore point deliberately, and it's worth taking one by hand first: `ssh budgie-production 'sudo systemctl start budgie-backup@predeploy'`.

The dump it takes is named `…-predeploy.dump.age`, in the same bucket, and is retained for the same 90 days.

## 7. Verify

Check each item on **both** destinations unless it says otherwise. This is what finished looks like.

**The timer is installed, and a dump appears in the bucket as ciphertext.**

```sh
ssh budgie-testing 'systemctl list-timers budgie-backup.timer --no-pager'
```

```
NEXT                        LEFT     LAST PASSED UNIT                ACTIVATES
Wed 2026-10-07 08:00:00 UTC 17h left -    -      budgie-backup.timer budgie-backup@nightly.service
```

In the Cloudflare dashboard, the bucket's **Objects** lists `budgie_production-<timestamp>-nightly.dump.age`. Download it and look at its first bytes:

```sh
head -c 21 ~/Downloads/budgie_production-*-nightly.dump.age; echo
```

```
age-encryption.org/v1
```

That's an age file, not a PostgreSQL archive (those start `PGDMP`), and it doesn't open without a private key. [The drill](#the-restore-drill) is what proves it opens with one.

**A forced failure leaves the unit failed and uploads nothing.** Stop the database, run the job and start it again:

```sh
ssh budgie-testing 'docker stop budgie-db'
ssh budgie-testing 'sudo systemctl start budgie-backup@nightly; systemctl is-failed budgie-backup@nightly'
ssh budgie-testing 'docker start budgie-db'
```

```
Job for budgie-backup@nightly.service failed because the control process exited with error code.
failed
```

The bucket's **Objects** list has the same dumps as before. On production this stops the app for as long as the database is down, which is a few seconds while nothing real depends on it.
Run a good dump afterwards, `sudo systemctl start budgie-backup@nightly`, so the unit isn't left failed.

**The host's token fails to delete a locked dump, and the lock behaves as Cloudflare documents it.** On the host, as root, load that host's own token the way the unit does and try both things the lock is for:

```sh
ssh budgie-testing
sudo -i
set -a; . /etc/budgie-backup.env; set +a
export RCLONE_CONFIG=/dev/null
name=$(rclone lsf --files-only "r2:$BACKUP_BUCKET" | sort | tail -n 1)
rclone deletefile "r2:$BACKUP_BUCKET/$name"
rclone copyto /etc/hostname "r2:$BACKUP_BUCKET/$name"
rclone lsf --files-only "r2:$BACKUP_BUCKET"
exit
```

Both the delete and the overwrite fail, with an error that says the object is locked or access is denied, and the last command still lists the dump.
If either one succeeds, the lock isn't doing its job: stop, fix the rule in [1c](#1c-the-lock-and-lifecycle-rules), and don't put real data on that destination. A successful delete takes a dump with it, so do this on a dump you can afford to lose.

Then read the bucket's two rules back in the dashboard: both say the same number of days as the retention, 7 for testing and 90 for production, and the lock covers every object, with no prefix.

**The freshness check runs green, and is seen failing.** In **Actions → Backup checks → Run workflow**, run it as it is: both jobs, `freshness (testing)` and `freshness (production)`, pass, and each job's summary names the newest dump and its age.
Then run it again with **max_age_hours** set to `0`. Every dump is older than that, so both jobs fail, with `the newest dump … is … hours old, over the limit of 0`. That's the check failing for real, and what a missed night looks like.
The quarterly step is tested by a third run with **open_drill_issue** ticked: it opens a `Restore drill due: <year> Q<n>` issue. Close that issue, and open it again at the real quarter.

**A drill passes with all five criteria, from the destination's own bucket,** once decrypting with the 1Password key and once with the recovery key. See [the restore drill](#the-restore-drill).

**Production only: the pre-deploy hook ran on a real deploy.** Dispatch **Deploy production** and look in the bucket for a `…-predeploy.dump.age` newer than the nightly one. The run's **Deploy to production** step shows `pre-deploy: restore point taken on <ip>` before Kamal boots anything.

The hook's failure path is shown once, by running it by hand against **testing** with the backup unit failing, which must exit non-zero. The hook only acts for `production`, so tell it that, with testing's address:

```sh
ssh budgie-testing 'docker stop budgie-db'
docker compose run --rm -e KAMAL_DESTINATION=production -e KAMAL_COMMAND=deploy -e KAMAL_HOSTS=<testing ip> --entrypoint .kamal/hooks/pre-deploy kamal
echo "exit=$?"
ssh budgie-testing 'docker start budgie-db'
```

```
pre-deploy: taking a restore point on <testing ip>
pre-deploy: the backup on <testing ip> failed, so this deploy is stopped. Its last log lines:
...
exit=1
```

Run it once more with `budgie-db` started: it ends `restore point taken` and `exit=0`, and a `-predeploy` dump is in testing's bucket.

**Testing only: a CI deploy of testing is unaffected by the hook.** Merge anything to `main`. `deploy_testing` goes green, and its log has no `pre-deploy:` line.

**Testing only: testing's own latest dump is restored into its running accessory, and the app works.** See [A real restore](#a-real-restore).

**After a reboot the timer is active again.**

```sh
ssh budgie-testing 'sudo reboot'
# wait a minute
ssh budgie-testing 'systemctl is-enabled budgie-backup.timer; systemctl is-active budgie-backup.timer'
```

```
enabled
active
```

**No secret is committed.** [The check in Deploying](deployment.md#verify) covers `.env.backup` as well, and finds nothing: no token and no private key is in git, and `.kamal/secrets*` still only map names.

**No claim that production has no backups remains.**

```sh
git grep -n -i -E "no backup[s]|nowhere else ye[t]|there's no backu[p]"
```

It prints nothing. [Before production holds real data](#before-production-holds-real-data) is where the real status is kept.

## The restore drill

A backup nobody has restored is a hope. The drill proves the newest dump in a destination's bucket is whole, readable with a key you hold, and restorable.

**When:** quarterly, which the **Restore drill due** issue reminds you of, and after any change to the backup script, either age key or the PostgreSQL major version.

**Where:** on your laptop, through the `restore` Compose service. It's a small image with `age`, `rclone` and `pg_restore`, next to a scratch `postgres:18` on tmpfs, with no Docker socket and no SSH agent. The default `Dockerfile` target is still the production image.
It doesn't run on the testing host, because that would put production data and a production token on testing and break the isolation between the two destinations; and it doesn't run in CI, because that would put a private key in GitHub and real data on a runner of a public repo.

**A pass means all five:**

1. The newest dump is fetched with the read-only token from 1Password.
2. It decrypts with the private key from 1Password.
3. `pg_restore` into the scratch `postgres:18` finishes with no errors.
4. `bin/rails db:migrate:status` against it shows no missing migrations.
5. Per-table row counts are within a day's new entries of the live database's, compared through `kamal dbc`.

**1 to 3**, and the counts for 5, are one command. Run it for the destination, and paste the private key when it asks. Nothing is echoed, and the key is never written to a file:

```sh
docker compose run --rm restore production
```

```
== Fetching the newest dump from budgie-backups-production
   newest: budgie_production-20261006T080001Z-nightly.dump.age
   pass: fetched 41233 bytes with the read-only token

== Decrypting
Paste the age private key (the AGE-SECRET-KEY-1... line), then press Enter:
   pass: decrypted with the key from stdin

== Restoring into the scratch database
   pass: pg_restore finished with no errors

== Row counts in the restored copy
 table_name | row_count
...
```

Or pipe the key in from 1Password's CLI, which needs `-T`: `op read "op://Private/Budgie backup key (primary)/notesPlain" | docker compose run --rm -T restore production`. The first `AGE-SECRET-KEY-1...` line on stdin is the key.

**4. No missing migrations**, against the restored database, which is still running:

```sh
docker compose run --rm -e DATABASE_URL=postgres://budgie:restore@restore-db/budgie_production web bin/rails db:migrate:status | grep -E '^\s+down'
```

It prints nothing. A `down` line is a migration this checkout has and the dump doesn't. If it's one that was deployed *since* the dump was taken, that's expected: compare its timestamp with the dump's. Anything else is a failed drill.
Run it from a checkout of the commit production runs, or `main`'s tip.

**5. Row counts,** for the live database, through Kamal. Put the query on the clipboard and paste it into `dbc`, which asks for the destination's database password:

```sh
pbcopy < script/row_counts.sql
docker compose run --rm kamal dbc -d production
```

The tables and their counts are what the drill printed for the restored copy, and each is the same or a little higher, by no more than a day's entries: a few rows in `sessions`, `budget_spends` and `budget_deposits`, and the like. A table that's empty in the copy and not in the live database, or a count that's far lower, is a failed drill.

**Both keys.** Run it twice, once with each private key, to prove each decrypts a dump: the 1Password key first, then the recovery key, from wherever it's kept. Running it again just restores over the scratch copy.

**Clean up** when you're done. The scratch database is on tmpfs, so it holds a copy of real data until you do this:

```sh
docker compose --profile restore rm -sf restore-db
```

Then write the date in [Before production holds real data](#before-production-holds-real-data), and close the issue.

## A real restore

The drill proves the dump. A real restore has a different target: the host's own `budgie-db`, over SSH. Nothing on the host decrypts anything, which is why there's no restore script there: it would need the private key piped to the host, and a host never holds one.

`restore-drill.sh` has `--keep`, which leaves the decrypted dump in `tmp/restore/`, a gitignored directory. It's plaintext, so delete it when you're done.

```sh
docker compose run --rm restore testing --keep
```

```
== Keeping the decrypted dump
   tmp/restore/budgie_production-20261006T080001Z-nightly.dump: plaintext, so delete it once the restore is done
```

Then stream it into the accessory. `--clean --if-exists` replaces what's there, and `--exit-on-error` stops at the first problem instead of carrying on:

```sh
ssh budgie-testing 'docker exec -i budgie-db pg_restore -U budgie -d budgie_production --clean --if-exists --exit-on-error' < tmp/restore/<the dump>
rm tmp/restore/*
```

### Proving it once, on testing

This isn't part of the quarterly drill. It's done once, so the first real restore isn't the first rehearsal.

1. **Stop the app,** so nothing writes while it's replaced:

   ```sh
   docker compose run --rm kamal app stop -d testing
   ```

2. **Keep the dump and restore it,** as above, with testing's own latest dump.
3. **Start the app again,** and check it works:

   ```sh
   docker compose run --rm kamal app start -d testing
   curl -sS -o /dev/null -w '%{http_code}\n' https://testing.budgiebuddie.com/up
   ```

   `/up` answers `200`. Sign in, and the month view shows what was there when the dump was taken.

4. **Delete the dump.** `rm tmp/restore/*`.

### Rebuilding a host from a backup

When a host is lost, its new database starts empty, and the order is different, because `kamal setup` would otherwise create an empty schema:

1. Do the first three steps of [Rebuilding a host](deployment.md#rebuilding-a-host): its new address, provisioning it and putting it behind its tunnel.
2. **Boot only the `db` accessory:**

   ```sh
   docker compose run --rm kamal accessory boot db -d production
   ```

3. **Restore into it,** as above, with `--keep` and the `ssh … pg_restore` line, for the destination's latest dump. Delete the dump.
4. **Set it up, skipping hooks,** because the backup unit doesn't exist on the new host:

   ```sh
   docker compose run --rm kamal setup -d production --skip-push --skip-hooks
   ```

   `setup` finds the accessory already running and leaves it alone, and `db:prepare` finds the migrations current.
5. **Install the backup job again,** as [section 4](#4-installing-the-host-job) says, with the same token and the same two public keys.

The restored database is as old as its dump, so entries since are gone. Whoever used the app since then will have to enter them again.

## Key custody and rotation

- **Two private keys, never on a host.** The primary is in 1Password; the recovery key is offline, somewhere else. The hosts hold only public keys, so a compromised host or a stolen token can't read a dump, old or new. The private keys are never in GitHub or the repo.
- **Losing both makes every backup unreadable.** Check once a year that the recovery key can be found and read.
- **Rotating a key.** Generate a new one as in [section 2](#2-the-age-keys), then re-run `backup-setup.sh` on both hosts with the new recipient list: dumps from then on are encrypted to it, and the dumps already in the buckets stay encrypted to the old one. **Keep the old private key until the last dump it encrypted has expired:** 90 days for production, 7 for testing. Then run [the drill](#the-restore-drill) with the new key, and update [the table of recipients](#the-two-recipients).
- **Rotating a host token.** Create a new `…-write` token, re-run `backup-setup.sh` with a new `~/budgie-r2.env` (it checks the token reaches the bucket before it changes anything), then delete the old token in Cloudflare. If it leaked, do this at once: the lock protects the history, but not the bucket from a flood of junk uploads, which would fill the free tier.
- **Rotating a read-only token.** Create a new `…-read` token, replace it in 1Password, `.env.backup` and that destination's GitHub environment secrets, then delete the old one.

## Retention and deleted users

Every dump is kept for the retention and then removed by the lifecycle rule: 90 days for production, 7 for testing.

**A deleted user stays in the backups until their dump expires,** up to 90 days on production. `user:delete` removes them from the live database only, see [Operating Budgie](operations.md#deleting-a-user). If that matters for someone, that's how long it takes, and there's no way to remove one early: the lock is what makes the backups safe.

## Before production holds real data

Production's database used to be on its VPS's own disk and nowhere else. **It holds no real budget data until every box here is ticked.** The operator ticks them, on [the ticket](https://github.com/RobertG-H/budgie-src/issues/15), as [Verify](#7-verify) is worked through:

- [ ] A dump exists in `budgie-backups-production`, locked and ciphertext only
- [ ] The host's token fails to delete it
- [ ] The freshness check has run green on production and has been seen failing
- [ ] A drill has passed from production's own bucket, decrypting with the primary key and again with the recovery key
- [ ] The pre-deploy hook has run on a real production deploy
- [ ] The live restore on testing has worked

**Last restore drill passed:** *not yet*

Write the date here when a drill passes, which is also what the quarterly issue asks for.
