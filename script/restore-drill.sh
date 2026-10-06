#!/usr/bin/env bash
#
# Rehearse restoring a destination's newest backup, on the operator's laptop:
# fetch it from R2 with the read-only token, decrypt it with an age private
# key, and pg_restore it into the scratch PostgreSQL that compose.yaml's
# `restore-db` service runs on tmpfs.
#
# Usage, through Compose:
#   docker compose run --rm restore <testing|production> [--keep]
#   op read <the private key> | docker compose run --rm -T restore production
#
# The private key is read from stdin, so it never reaches a file: on a terminal
# it's read without echo, and from a pipe it's the first AGE-SECRET-KEY line.
# The read-only token comes from the gitignored .env.backup, which compose.yaml
# loads. --keep also leaves the decrypted dump in tmp/restore/, for a real
# restore (docs/backups.md), and the operator deletes it afterwards.
#
# This covers three of the drill's five checks: the newest dump is fetched,
# decrypts, and restores with no errors. It prints the row counts for the fifth,
# and the migration check (the fourth) is a command in docs/backups.md. Nothing
# here touches a host. See docs/backups.md.

set -euo pipefail

BUCKET_PREFIX=budgie-backups-
DB_NAME=budgie_production
# The scratch server in compose.yaml. Its password isn't a secret: it's on tmpfs, on a Compose network.
SCRATCH_HOST=restore-db
SCRATCH_USER=budgie
SCRATCH_PASSWORD=restore
KEEP_DIR=/restore
DUMP_PATTERN='^budgie_production-[0-9]{8}T[0-9]{6}Z-(nightly|predeploy)\.dump\.age$'

DESTINATION=''
KEEP=no
WORK=''

usage() {
  cat <<'EOF'
Usage:
  docker compose run --rm restore <testing|production> [--keep]

Restores the destination's newest backup into the scratch database and prints
each table's row count. The age private key is read from stdin: paste it when
asked, or pipe it in with docker compose run --rm -T.

  --keep   also keep the decrypted dump in tmp/restore/, for a real restore
EOF
}

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
pass() { printf '   pass: %s\n' "$*"; }
die()  { printf 'restore-drill.sh: %s\n' "$*" >&2; exit 1; }

parse_arguments() {
  local argument
  for argument in "$@"; do
    case "$argument" in
      -h | --help)
        usage
        exit 0
        ;;
      --keep) KEEP=yes ;;
      testing | production) DESTINATION=$argument ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done
  if [ -z "$DESTINATION" ]; then
    usage >&2
    exit 2
  fi
}

configure_rclone() {
  local prefix endpoint access_key secret_key
  prefix=$(printf '%s' "$DESTINATION" | tr '[:lower:]' '[:upper:]')
  endpoint=$(printenv "${prefix}_BACKUP_R2_ENDPOINT" || true)
  access_key=$(printenv "${prefix}_BACKUP_R2_ACCESS_KEY_ID" || true)
  secret_key=$(printenv "${prefix}_BACKUP_R2_SECRET_ACCESS_KEY" || true)

  if [ -z "$endpoint" ] || [ -z "$access_key" ] || [ -z "$secret_key" ]; then
    die "${prefix}_BACKUP_R2_ENDPOINT, ${prefix}_BACKUP_R2_ACCESS_KEY_ID and ${prefix}_BACKUP_R2_SECRET_ACCESS_KEY aren't all set. They come from .env.backup, which docs/backups.md says how to make."
  fi

  # rclone reads its remote's whole configuration from the environment, as it does on the hosts, and
  # there's no rclone.conf for it to look for.
  export RCLONE_CONFIG=/dev/null
  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID=$access_key
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$secret_key
  export RCLONE_CONFIG_R2_ENDPOINT=$endpoint
  export RCLONE_CONFIG_R2_REGION=auto
  # The token is scoped to one bucket, which can't be asked whether it exists.
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
}

# Reads the age private key from stdin without echoing it, and keeps it only in this process's memory.
read_key() {
  local line silent=()
  if [ -t 0 ]; then
    silent=(-s)
    printf 'Paste the age private key (the AGE-SECRET-KEY-1... line), then press Enter: ' >&2
  fi
  KEY=''
  while IFS= read -r "${silent[@]}" line; do
    if [[ $line =~ ^AGE-SECRET-KEY-1[0-9A-Z]+$ ]]; then
      KEY=$line
      break
    fi
  done
  [ -t 0 ] && printf '\n' >&2
  [ -n "$KEY" ] || die "no AGE-SECRET-KEY-1... line arrived on stdin. Pipe the private key in, or paste it when asked."
}

fetch_newest() {
  local bucket=$BUCKET_PREFIX$DESTINATION
  step "Fetching the newest dump from $bucket"

  NAME=$(rclone lsf --files-only "r2:$bucket" | grep -E "$DUMP_PATTERN" | sort | tail -n 1 || true)
  [ -n "$NAME" ] || die "$bucket has no dump. Is the host job installed and has it run?"
  info "newest: $NAME"

  rclone copyto "r2:$bucket/$NAME" "$WORK/$NAME"
  pass "fetched $(stat -c %s "$WORK/$NAME") bytes with the read-only token"
}

decrypt() {
  step "Decrypting"
  read_key
  # Process substitution hands age the key through a pipe, so it's never written to a file.
  if ! age --decrypt -i <(printf '%s\n' "$KEY") -o "$WORK/dump" "$WORK/$NAME"; then
    die "age couldn't decrypt $NAME with that key. It has to be one of the two whose public halves the host encrypts to."
  fi
  KEY=''
  pass "decrypted with the key from stdin"
}

restore() {
  step "Restoring into the scratch database"
  export PGPASSWORD=$SCRATCH_PASSWORD
  # The same flags a real restore uses (docs/backups.md), so the drill rehearses them. --exit-on-error
  # makes "no errors" something this script can check rather than something to read out of the output.
  pg_restore --host "$SCRATCH_HOST" --username "$SCRATCH_USER" --dbname "$DB_NAME" \
    --clean --if-exists --exit-on-error "$WORK/dump"
  pass "pg_restore finished with no errors"
}

row_counts() {
  step "Row counts in the restored copy"
  psql --host "$SCRATCH_HOST" --username "$SCRATCH_USER" --dbname "$DB_NAME" --no-psqlrc --file /script/row_counts.sql
}

keep_dump() {
  local kept=${NAME%.age}
  [ "$KEEP" = yes ] || return 0
  step "Keeping the decrypted dump"
  [ -d "$KEEP_DIR" ] || die "$KEEP_DIR isn't mounted. Run this through docker compose run --rm restore."
  install -m 0600 "$WORK/dump" "$KEEP_DIR/$kept"
  info "tmp/restore/$kept: plaintext, so delete it once the restore is done"
}

summary() {
  step "Summary"
  info "$NAME decrypted and restored with no errors"
  cat <<'EOF'
   Still to do by hand, from docs/backups.md:
     - the migration check, against the scratch database
     - compare the row counts above with the live database's, which are
       within a day's new entries when the backup is current
EOF
}

main() {
  parse_arguments "$@"
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  configure_rclone
  fetch_newest
  decrypt
  restore
  row_counts
  keep_dump
  summary
}

main "$@"
