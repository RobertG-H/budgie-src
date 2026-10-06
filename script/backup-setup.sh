#!/usr/bin/env bash
#
# Set up a Budgie host's nightly database backup: install age and rclone from
# Ubuntu's apt, write the backup job and its systemd units, keep the R2 token and
# the age recipients in a root-only env file, and start the daily timer.
#
# Usage:
#   sudo bash backup-setup.sh <testing|production> \
#     --recipient age1... --recipient age1... < r2.env
#
# r2.env is three lines, from the bucket's Object Read & Write token in
# Cloudflare:
#   R2_ACCESS_KEY_ID=...
#   R2_SECRET_ACCESS_KEY=...
#   R2_ENDPOINT=https://<account id>.r2.cloudflarestorage.com
#
# The token is read from stdin, so it stays out of the shell history and out of
# ps, and the only copy left on the host is /etc/budgie-backup.env, which only
# root can read. The recipients are age public keys, so they're arguments.
#
# Run it once per host, after `kamal setup` has created the budgie-db container:
# the job dumps that container's database. It is safe to re-run, which is also
# how a token or a recipient is replaced: on a host already set up this way it
# changes nothing and exits 0.
#
# See docs/backups.md for the Cloudflare steps, the keys and the verification
# checklist. This script is never run from the application checkout.

set -euo pipefail

DEPLOY_USER=deploy
DB_CONTAINER=budgie-db
BUCKET_PREFIX=budgie-backups-
ENV_FILE=/etc/budgie-backup.env
JOB=/usr/local/sbin/budgie-backup
SERVICE=/etc/systemd/system/budgie-backup@.service
TIMER=/etc/systemd/system/budgie-backup.timer
TIMER_NAME=budgie-backup.timer

CHANGES=0
APT_UPDATED=no
UNITS_CHANGED=no
DESTINATION=''
BUCKET=''
RECIPIENTS=()
ACCESS_KEY_ID=''
SECRET_ACCESS_KEY=''
ENDPOINT=''

usage() {
  cat <<'EOF'
Usage:
  sudo bash backup-setup.sh <testing|production> \
    --recipient age1... --recipient age1... < r2.env

Sets up this host's nightly database backup to the destination's R2 bucket,
budgie-backups-<destination>. r2.env holds the bucket's Object Read & Write
token, and is read from stdin so that it stays out of the shell history and ps:

  R2_ACCESS_KEY_ID=...
  R2_SECRET_ACCESS_KEY=...
  R2_ENDPOINT=https://<account id>.r2.cloudflarestorage.com

The two --recipient arguments are the age public keys every dump is encrypted
to: the 1Password key's and the offline recovery key's.

From your laptop:

  scp script/backup-setup.sh deploy@budgie-testing:
  ssh deploy@budgie-testing 'sudo bash backup-setup.sh testing --recipient age1... --recipient age1...' < r2.env

The host must already be provisioned by provision.sh and have run kamal setup.
EOF
}

step()    { printf '\n== %s\n' "$*"; }
info()    { printf '   %s\n' "$*"; }
changed() { CHANGES=$((CHANGES + 1)); printf '   changed: %s\n' "$*"; }
die()     { printf 'backup-setup.sh: %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run this with sudo: sudo bash backup-setup.sh <testing|production> --recipient ... --recipient ... < r2.env"
}

check_os() {
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || die "this script targets Ubuntu, but /etc/os-release says ID=${ID:-unknown}"
  [ "${VERSION_ID:-}" = "26.04" ] || info "warning: expected Ubuntu 26.04 LTS, found ${VERSION_ID:-unknown}"
}

# Writes stdin to a file, and reports whether it had to. Returns 1 when the
# file already has exactly this content, so callers can skip follow-up work
# such as reloading a daemon.
write_file() {
  local path=$1 mode=$2 tmp
  tmp=$(mktemp)
  cat >"$tmp"
  # The mode counts too, so a re-run puts back a 0600 file that somebody loosened.
  if [ -e "$path" ] && cmp -s "$tmp" "$path" && [ "$(stat -c %a "$path")" = "${mode#0}" ]; then
    rm -f "$tmp"
    return 1
  fi
  install -o root -g root -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  changed "wrote $path"
  return 0
}

# Ubuntu runs apt itself on a fresh boot, and two apt processes deadlock.
apt_wait() {
  local waited=0
  command -v fuser >/dev/null 2>&1 || return 0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ||
    fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    [ "$waited" -eq 0 ] && info "waiting for another apt process to finish"
    [ "$waited" -ge 300 ] && die "apt is still locked after five minutes"
    sleep 5
    waited=$((waited + 5))
  done
}

apt_update() {
  [ "$APT_UPDATED" = yes ] && return 0
  apt_wait
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  APT_UPDATED=yes
}

# dpkg -s is also true for a package that was removed but left its config
# files behind, so ask for the status explicitly.
package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

apt_install() {
  local missing=() package
  for package in "$@"; do
    package_installed "$package" || missing+=("$package")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  apt_update
  apt_wait
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    -o Dpkg::Options::=--force-confold "${missing[@]}" >/dev/null
  changed "installed ${missing[*]}"
}

parse_arguments() {
  case "${1:-}" in
    testing | production) DESTINATION=$1 ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --recipient)
        [ "$#" -ge 2 ] || die "--recipient needs an age public key after it"
        RECIPIENTS+=("$2")
        shift 2
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done

  BUCKET=$BUCKET_PREFIX$DESTINATION
}

validate_recipients() {
  local recipient
  step "The age recipients"

  [ "${#RECIPIENTS[@]}" -eq 2 ] ||
    die "give exactly two --recipient arguments: the 1Password key's public half and the offline recovery key's. Either one decrypts every dump, which is why there are two."
  for recipient in "${RECIPIENTS[@]}"; do
    [[ $recipient =~ ^age1[0-9a-z]{58}$ ]] ||
      die "'$recipient' doesn't look like an age public key. It starts with age1 and is 62 characters long: the line 'age-keygen -y' prints, not the AGE-SECRET-KEY one."
  done
  [ "${RECIPIENTS[0]}" != "${RECIPIENTS[1]}" ] ||
    die "both --recipient arguments are the same key, which is one key and not two. The recovery key has to be a different one, kept somewhere other than 1Password."

  info "two different recipients: either decrypts every dump, and this host holds neither private key"
}

require_provisioned() {
  step "The host"

  if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    die "there's no $DEPLOY_USER user, so this host hasn't been provisioned. Run provision.sh first; see docs/provisioning.md."
  fi
  if ! command -v docker >/dev/null 2>&1; then
    die "docker isn't installed, so this host hasn't been provisioned. Run provision.sh first; see docs/provisioning.md."
  fi
  if ! docker info >/dev/null 2>&1; then
    die "docker is installed but isn't responding. Fix that before setting up backups."
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null || true)" != true ]; then
    die "there's no running $DB_CONTAINER container. The job dumps its database, so run kamal setup for this destination first; see docs/deployment.md."
  fi

  info "provisioned: the $DEPLOY_USER user exists, docker is responding and $DB_CONTAINER is running"
}

# Reads KEY=value lines without sourcing them, so nothing in the input is ever run, and never prints a value.
read_credentials() {
  local line key value
  step "The R2 token"

  if [ -t 0 ]; then
    die "the R2 token is read from stdin: sudo bash backup-setup.sh $DESTINATION --recipient ... --recipient ... < r2.env"
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      '' | '#'*) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    # Tolerate a value pasted with quotes around it.
    value=${value#[\"\']}
    value=${value%[\"\']}
    case "$key" in
      R2_ACCESS_KEY_ID) ACCESS_KEY_ID=$value ;;
      R2_SECRET_ACCESS_KEY) SECRET_ACCESS_KEY=$value ;;
      R2_ENDPOINT) ENDPOINT=$value ;;
      *) die "unexpected line in the R2 token input: only R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY and R2_ENDPOINT are read" ;;
    esac
  done

  [ -n "$ACCESS_KEY_ID" ] && [ -n "$SECRET_ACCESS_KEY" ] && [ -n "$ENDPOINT" ] ||
    die "r2.env needs all three of R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY and R2_ENDPOINT. See docs/backups.md."
  [[ $ACCESS_KEY_ID =~ ^[0-9a-f]{32}$ ]] ||
    die "R2_ACCESS_KEY_ID doesn't look like an R2 access key ID (32 hex characters). Copy it from the token's page in Cloudflare."
  [[ $SECRET_ACCESS_KEY =~ ^[0-9a-f]{64}$ ]] ||
    die "R2_SECRET_ACCESS_KEY doesn't look like an R2 secret access key (64 hex characters). Cloudflare shows it only once, when the token is created."
  [[ $ENDPOINT =~ ^https://[0-9a-f]{32}(\.(eu|fedramp))?\.r2\.cloudflarestorage\.com$ ]] ||
    die "R2_ENDPOINT should be https://<account id>.r2.cloudflarestorage.com, with no bucket name and no trailing slash."

  info "read a token for $BUCKET"
}

install_tools() {
  local age_version rclone_version
  step "age and rclone"
  apt_install age rclone ca-certificates

  age_version=$(age --version 2>/dev/null || true)
  rclone_version=$(rclone --version 2>/dev/null | awk 'NR == 1 { print $2 }')
  info "age ${age_version:-installed}, rclone ${rclone_version:-installed}; unattended-upgrades keeps both current with Ubuntu's security updates"
}

# Proves the token reaches the bucket before anything is written, so a typo
# leaves the host as it was rather than with a timer that fails every night.
check_bucket() {
  step "The bucket"

  if RCLONE_CONFIG=/dev/null \
    RCLONE_CONFIG_R2_TYPE=s3 \
    RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
    RCLONE_CONFIG_R2_ACCESS_KEY_ID=$ACCESS_KEY_ID \
    RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$SECRET_ACCESS_KEY \
    RCLONE_CONFIG_R2_ENDPOINT=$ENDPOINT \
    RCLONE_CONFIG_R2_REGION=auto \
    RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
    rclone lsf --max-depth 1 "r2:$BUCKET" >/dev/null 2>&1; then
    info "the token can list $BUCKET"
  else
    die "that token can't list $BUCKET. Check that it's the Object Read & Write token for this bucket, and that R2_ENDPOINT is the account's. Nothing has been changed on this host."
  fi
}

write_env_file() {
  step "The environment file"

  # Quoted, because systemd's EnvironmentFile and a shell both read the value as one word that way.
  if write_file "$ENV_FILE" 0600 <<EOF
# Budgie backups: written by backup-setup.sh and read by budgie-backup@.service.
# Only root can read this file: it holds the bucket's R2 token. Re-run
# backup-setup.sh to change anything here rather than editing it. See docs/backups.md.
BACKUP_DESTINATION=$DESTINATION
BACKUP_BUCKET=$BUCKET
BACKUP_AGE_RECIPIENTS="${RECIPIENTS[0]} ${RECIPIENTS[1]}"
RCLONE_CONFIG_R2_TYPE=s3
RCLONE_CONFIG_R2_PROVIDER=Cloudflare
RCLONE_CONFIG_R2_ACCESS_KEY_ID=$ACCESS_KEY_ID
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$SECRET_ACCESS_KEY
RCLONE_CONFIG_R2_ENDPOINT=$ENDPOINT
RCLONE_CONFIG_R2_REGION=auto
RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
EOF
  then
    info "mode 0600, owned by root"
  else
    info "$ENV_FILE already holds this token, bucket and these recipients"
  fi
}

# The job. It's embedded so that this one file is all that has to be copied to a host.
install_job() {
  step "The backup job"

  if write_file "$JOB" 0755 <<'JOB_EOF'
#!/usr/bin/env bash
#
# Take one encrypted backup of budgie_production and upload it to R2. Run by
# budgie-backup@<reason>.service, where the reason is nightly (the timer) or
# predeploy (production's Kamal pre-deploy hook), with the environment from
# /etc/budgie-backup.env. Written by script/backup-setup.sh: edit it there.
#
# Only encrypted bytes leave the host. Any failure leaves the unit failed and
# uploads nothing, and the freshness check in GitHub notices the missing dump.

set -euo pipefail
umask 077

# The remote is configured entirely by RCLONE_CONFIG_R2_* in the environment, so there's no rclone.conf.
export RCLONE_CONFIG=/dev/null

DB_CONTAINER=budgie-db
DB_USER=budgie
DB_NAME=budgie_production
# The smallest an encrypted dump of a real database can be. Tuned after the first real dump.
MIN_BYTES=10240

reason=${1:-}
case "$reason" in
  nightly | predeploy) ;;
  *)
    echo "usage: budgie-backup <nightly|predeploy>" >&2
    exit 2
    ;;
esac

log() { printf 'budgie-backup: %s\n' "$*"; }
fail() { printf 'budgie-backup: %s\n' "$*" >&2; exit 1; }

: "${BACKUP_BUCKET:?BACKUP_BUCKET isn't set: run this through budgie-backup@.service}"
: "${BACKUP_AGE_RECIPIENTS:?BACKUP_AGE_RECIPIENTS isn't set}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

name="${DB_NAME}-$(date -u +%Y%m%dT%H%M%SZ)-${reason}.dump.age"

# The postgres image's own pg_dump, which is never older than the server. No --clean and no --no-owner:
# the same role restores it.
log "dumping $DB_NAME ($reason)"
docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -Fc "$DB_NAME" >"$work/dump"

# A dump that pg_restore can't read is worth nothing, so find that out now rather than at a restore.
docker exec -i "$DB_CONTAINER" pg_restore --list <"$work/dump" >/dev/null ||
  fail "pg_restore can't read the dump, so nothing was uploaded"

# $BACKUP_AGE_RECIPIENTS is two public keys, split on the space between them on purpose.
recipient_args=()
for recipient in $BACKUP_AGE_RECIPIENTS; do
  recipient_args+=(-r "$recipient")
done
[ "${#recipient_args[@]}" -eq 4 ] || fail "BACKUP_AGE_RECIPIENTS has to hold exactly two recipients"

age "${recipient_args[@]}" -o "$work/$name" "$work/dump"
rm -f "$work/dump"

size=$(stat -c %s "$work/$name")
[ "$size" -gt "$MIN_BYTES" ] || fail "the encrypted dump is only $size bytes, under $MIN_BYTES, so nothing was uploaded"

# Always a new, timestamped key and never an overwrite: the bucket's lock rule refuses one anyway.
log "uploading $name ($size bytes) to $BACKUP_BUCKET"
rclone copyto --immutable "$work/$name" "r2:$BACKUP_BUCKET/$name"

remote_size=$(rclone lsf --format s --files-only --include "/$name" "r2:$BACKUP_BUCKET")
[ "$remote_size" = "$size" ] || fail "R2 holds ${remote_size:-nothing} bytes for $name, not the $size that were sent"

log "done: $name is in $BACKUP_BUCKET"
JOB_EOF
  then
    info "installed $JOB"
  else
    info "$JOB is already up to date"
  fi
}

install_units() {
  step "The systemd units"

  # The instance is the reason a dump was taken: nightly from the timer, predeploy from the Kamal hook.
  if write_file "$SERVICE" 0644 <<'EOF'
[Unit]
Description=Budgie database backup (%i)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
EnvironmentFile=/etc/budgie-backup.env
ExecStart=/usr/local/sbin/budgie-backup %i
# A dump of a database this size takes seconds. This is for a hung upload, not for a slow one.
TimeoutStartSec=20min
Nice=10
PrivateTmp=yes
EOF
  then
    UNITS_CHANGED=yes
  else
    info "$SERVICE is already up to date"
  fi

  # 08:00 UTC is after the 04:00 UTC unattended-upgrades reboot, and after Eastern midnight has rolled the
  # month. Persistent=true runs a dump the host slept through at its next boot.
  if write_file "$TIMER" 0644 <<'EOF'
[Unit]
Description=Nightly Budgie database backup

[Timer]
OnCalendar=*-*-* 08:00:00 UTC
Persistent=true
Unit=budgie-backup@nightly.service

[Install]
WantedBy=timers.target
EOF
  then
    UNITS_CHANGED=yes
  else
    info "$TIMER is already up to date"
  fi

  if [ "$UNITS_CHANGED" = yes ]; then
    systemctl daemon-reload
  fi
}

enable_timer() {
  step "The timer"

  if systemctl is-enabled --quiet "$TIMER_NAME" 2>/dev/null; then
    info "$TIMER_NAME starts at boot"
  else
    systemctl enable "$TIMER_NAME" >/dev/null 2>&1
    changed "enabled $TIMER_NAME"
  fi

  if systemctl is-active --quiet "$TIMER_NAME"; then
    info "$TIMER_NAME is running"
  else
    systemctl start "$TIMER_NAME"
    changed "started $TIMER_NAME"
  fi

  info "next run: $(systemctl show -p NextElapseUSecRealtime --value "$TIMER_NAME" 2>/dev/null || echo unknown)"
}

summary() {
  step "Summary"
  if [ "$CHANGES" -eq 0 ]; then
    info "no changes: this host's backups were already set up this way"
  else
    info "$CHANGES change(s) applied"
  fi
  info "$DESTINATION backs up to $BUCKET, encrypted to two age recipients"
}

next_steps() {
  step "Next"
  cat <<'EOF'
   Take the first dump now rather than waiting for 08:00 UTC:

     sudo systemctl start budgie-backup@nightly
     sudo journalctl -u 'budgie-backup@nightly' -n 20 --no-pager

   It ends with "done:" and the dump's name. Then work through the
   verification checklist in docs/backups.md.
EOF
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
  esac

  require_root
  parse_arguments "$@"
  check_os
  validate_recipients
  require_provisioned
  read_credentials
  install_tools
  check_bucket
  write_env_file
  install_job
  install_units
  enable_timer
  summary
  next_steps
}

main "$@"
