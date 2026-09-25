#!/usr/bin/env bash
#
# Put a Budgie host behind a Cloudflare Tunnel: install cloudflared from
# Cloudflare's apt repository, register it as a systemd service with the
# tunnel's token, and let unattended-upgrades keep it current.
#
# Usage:
#   sudo bash cloudflare-tunnel.sh < token.txt
#
# The token comes from the tunnel's page in Cloudflare Zero Trust and is read
# from stdin, so it stays out of the shell history and out of ps, and no copy
# of it is left on the host. The host must already be provisioned by
# provision.sh.
#
# The script opens no port and adds no ufw rule: cloudflared dials out to
# Cloudflare's edge on TCP/UDP 7844. It is safe to re-run: on a host already
# running this tunnel it changes nothing and exits 0.
#
# See docs/cloudflare.md for the Cloudflare dashboard steps and the
# verification checklist. This script is never run from the application
# checkout.

set -euo pipefail

DEPLOY_USER=deploy
KEYRING=/etc/apt/keyrings/cloudflare-main.gpg
KEYRING_URL=https://pkg.cloudflare.com/cloudflare-main.gpg
REPO_URL=https://pkg.cloudflare.com/cloudflared
REPO_LIST=/etc/apt/sources.list.d/cloudflared.list
# Cloudflare publishes one distribution per Debian and Ubuntu codename, but a
# new Ubuntu release takes a while to appear. This is the most recent LTS it
# does publish, used only when the host's own codename is missing.
FALLBACK_SUITE=noble
UU_DROPIN=/etc/apt/apt.conf.d/53-budgie-cloudflared
# Both halves come straight from pkg.cloudflare.com's Release file and the
# host it is served from; see configure_unattended_upgrades.
UU_PATTERN='origin=cloudflared,site=pkg.cloudflare.com'
UNIT=/etc/systemd/system/cloudflared.service
UNIT_DROPIN_DIR=/etc/systemd/system/cloudflared.service.d
UNIT_DROPIN=$UNIT_DROPIN_DIR/10-budgie-no-autoupdate.conf

CHANGES=0
APT_UPDATED=no
WARNINGS=''
TOKEN=''
TUNNEL_ID=''
RESTART_SERVICE=no

usage() {
  cat <<'EOF'
Usage:
  sudo bash cloudflare-tunnel.sh < token.txt

Reads a Cloudflare Tunnel token on stdin and puts this host behind that
tunnel. The token is on the tunnel's page in Zero Trust, in the install
command it shows: it's the long string after "service install". Either the
token on its own or the whole command works.

From your laptop:

  ssh deploy@budgie-testing 'sudo bash cloudflare-tunnel.sh' < token.txt

The host must already be provisioned by provision.sh. No ufw rule is added.
EOF
}

step()    { printf '\n== %s\n' "$*"; }
info()    { printf '   %s\n' "$*"; }
changed() { CHANGES=$((CHANGES + 1)); printf '   changed: %s\n' "$*"; }
warn()    { WARNINGS="${WARNINGS}$*"$'\n'; printf '   warning: %s\n' "$*"; }
die()     { printf 'cloudflare-tunnel.sh: %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run this with sudo: sudo bash cloudflare-tunnel.sh < token.txt"
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
  if [ -e "$path" ] && cmp -s "$tmp" "$path"; then
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

require_provisioned() {
  step "The host"

  if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    die "there's no $DEPLOY_USER user, so this host hasn't been provisioned. Run provision.sh first; see docs/provisioning.md."
  fi
  if ! command -v docker >/dev/null 2>&1; then
    die "docker isn't installed, so this host hasn't been provisioned. Run provision.sh first; see docs/provisioning.md."
  fi
  if ! docker info >/dev/null 2>&1; then
    die "docker is installed but isn't responding. Fix that before putting the host behind a tunnel."
  fi

  info "provisioned: the $DEPLOY_USER user exists and docker is responding"
}

read_token() {
  local raw decoded
  step "The tunnel token"

  if [ -t 0 ]; then
    die "the tunnel token is read from stdin: sudo bash cloudflare-tunnel.sh < token.txt"
  fi

  raw=$(cat)
  # Take the last whitespace-separated word, so pasting the whole
  # "sudo cloudflared service install <token>" line from the dashboard works
  # as well as the token on its own.
  TOKEN=$(printf '%s\n' "$raw" | tr -s '[:space:]' '\n' | grep -v '^$' | tail -n 1 || true)

  if [ -z "$TOKEN" ]; then
    die "nothing arrived on stdin. Redirect the token file in: sudo bash cloudflare-tunnel.sh < token.txt"
  fi
  if ! [[ $TOKEN =~ ^[A-Za-z0-9+/=_.-]{40,}$ ]]; then
    die "that doesn't look like a tunnel token. Copy the string after 'service install' from the tunnel's page in Zero Trust."
  fi

  # The token is base64 of {"a":<account>,"t":<tunnel id>,"s":<secret>}. The
  # id is worth printing so the summary can be matched against the dashboard;
  # the secret is never printed or logged.
  decoded=$(printf '%s' "$TOKEN" | base64 -d 2>/dev/null || true)
  TUNNEL_ID=$(printf '%s' "$decoded" | sed -n 's/.*"t":"\([0-9a-f-]\{36\}\)".*/\1/p')

  if [ -n "$TUNNEL_ID" ]; then
    info "read a token for tunnel $TUNNEL_ID"
  else
    info "read a token"
  fi
}

# The distribution to point apt at: the host's own codename when Cloudflare
# publishes one, and $FALLBACK_SUITE when it answers a definite 404.
#
# Anything else (a timeout, a 5xx, no answer at all) is not an answer, and
# quietly falling back on one would pin the host to the wrong distribution
# for as long as nobody looked. Returns 1 in that case and lets the caller
# decide.
choose_suite() {
  local codename=$1 status tries=3
  while [ "$tries" -gt 0 ]; do
    tries=$((tries - 1))
    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$REPO_URL/dists/$codename/Release" 2>/dev/null)
    case "$status" in
      2??)
        printf '%s' "$codename"
        return 0
        ;;
      404)
        printf '%s' "$FALLBACK_SUITE"
        return 0
        ;;
    esac
    if [ "$tries" -gt 0 ]; then
      sleep 2
    fi
  done
  return 1
}

install_cloudflared() {
  local arch codename suite version tmp
  step "cloudflared"
  apt_install ca-certificates curl

  if [ -s "$KEYRING" ]; then
    info "Cloudflare's apt key is already installed"
  else
    # Downloaded to a temporary file first, so a failed download can't leave a
    # truncated keyring behind for the next run to mistake for a good one.
    install -m 0755 -d /etc/apt/keyrings
    tmp=$(mktemp)
    if curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --max-time 60 "$KEYRING_URL" -o "$tmp"; then
      install -o root -g root -m 0644 "$tmp" "$KEYRING"
      rm -f "$tmp"
      changed "installed Cloudflare's apt key"
    else
      rm -f "$tmp"
      die "couldn't download Cloudflare's apt key from $KEYRING_URL. Check this host's outbound connectivity and run this again."
    fi
  fi

  arch=$(dpkg --print-architecture)
  # shellcheck disable=SC1091
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  if suite=$(choose_suite "$codename"); then
    if [ "$suite" != "$codename" ]; then
      info "pkg.cloudflare.com publishes nothing for $codename yet, so using $suite"
    fi
  elif [ -e "$REPO_LIST" ]; then
    suite=$(awk '/^deb /{ print $(NF - 1); exit }' "$REPO_LIST")
    info "couldn't reach pkg.cloudflare.com; keeping the $suite repository already configured here"
  else
    die "couldn't reach pkg.cloudflare.com to find out which distribution to use. Check this host's outbound connectivity and run this again."
  fi

  if write_file "$REPO_LIST" 0644 <<EOF
deb [arch=$arch signed-by=$KEYRING] $REPO_URL $suite main
EOF
  then
    APT_UPDATED=no
  else
    info "$REPO_LIST is already in place ($suite)"
  fi

  apt_install cloudflared
  version=$(cloudflared --version 2>/dev/null | awk 'NR == 1 { print $3 }')
  info "cloudflared ${version:-installed}"
}

configure_unattended_upgrades() {
  local release
  step "Automatic upgrades for cloudflared"

  if ! package_installed unattended-upgrades; then
    warn "unattended-upgrades isn't installed, which provision.sh does. Skipping $UU_DROPIN."
    return 0
  fi

  # Origins-Pattern rather than the more familiar Allowed-Origins, for two
  # reasons. pkg.cloudflare.com's Release file has no Suite: field, so apt
  # reports an empty archive for the repository and an "origin:archive" pair
  # silently matches nothing. And Origins-Pattern is a separate list from
  # Allowed-Origins, so this doesn't depend on being read after the #clear in
  # provision.sh's 52-budgie-unattended-upgrades.
  if write_file "$UU_DROPIN" 0644 <<EOF
// Budgie: let unattended-upgrades keep cloudflared current. A stale
// cloudflared eventually stops connecting, and the tunnel is the only way
// into this host.
//
// Origins-Pattern, not Allowed-Origins: pkg.cloudflare.com's Release file
// has no Suite:, so apt reports an empty archive for it and an
// "origin:archive" pair would match nothing at all. This repository
// publishes only cloudflared, so allowing it can't pull in anything else.
Unattended-Upgrade::Origins-Pattern {
        "$UU_PATTERN";
};
EOF
  then
    info "unattended-upgrades may now upgrade $UU_PATTERN"
  else
    info "$UU_DROPIN already allows $UU_PATTERN"
  fi

  # The pattern above is fixed, so check that apt still reports the origin it
  # matches on rather than trusting it to stay that way.
  release=$(apt-cache policy | awk '/pkg\.cloudflare\.com/ { getline; print; exit }')
  case "$release" in
    *o=cloudflared*)
      info "apt agrees:${release#*release}"
      ;;
    *)
      warn "apt reports '${release:-nothing}' for pkg.cloudflare.com, which $UU_PATTERN may no longer match. Check $UU_DROPIN."
      ;;
  esac

  info "an upgrade replaces the cloudflared binary but doesn't restart the tunnel;"
  info "the 04:00 UTC reboot, or sudo systemctl restart cloudflared, picks it up"
}

disable_self_updater() {
  # cloudflared's own "service install" writes --no-autoupdate into ExecStart.
  # If a future version stops doing that, turn the self-updater off the other
  # way rather than letting the one component that makes this host reachable
  # update and restart itself unattended.
  if systemctl show -p ExecStart --value cloudflared 2>/dev/null | grep -q -- '--no-autoupdate'; then
    info "the self-updater is off: --no-autoupdate is in the unit's ExecStart"
    if [ -e "$UNIT_DROPIN" ]; then
      rm -f "$UNIT_DROPIN"
      rmdir --ignore-fail-on-non-empty "$UNIT_DROPIN_DIR" 2>/dev/null || true
      systemctl daemon-reload
      changed "removed $UNIT_DROPIN, which the unit no longer needs"
      RESTART_SERVICE=yes
    fi
    return 0
  fi

  install -d -m 0755 "$UNIT_DROPIN_DIR"
  if write_file "$UNIT_DROPIN" 0644 <<'EOF'
[Service]
# Budgie: this cloudflared's generated unit has no --no-autoupdate in its
# ExecStart, so turn the self-updater off through its environment variable
# instead. An unattended cloudflared restarting itself is restarting the only
# way into this host.
Environment=NO_AUTOUPDATE=true
EOF
  then
    systemctl daemon-reload
    RESTART_SERVICE=yes
  else
    info "$UNIT_DROPIN already turns the self-updater off"
  fi
}

wait_for_tunnel() {
  local waited=0
  # The generated unit is Type=notify, so systemd calls it active only once
  # cloudflared has registered with Cloudflare's edge.
  while [ "$waited" -lt 30 ]; do
    if systemctl is-active --quiet cloudflared; then
      info "the tunnel is up: cloudflared is active"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  warn "cloudflared isn't active after 30s. Look at: sudo journalctl -u cloudflared -n 50 --no-pager"
}

install_service() {
  step "The tunnel service"

  if [ -e "$UNIT" ] && grep -qF -- "$TOKEN" "$UNIT"; then
    info "cloudflared is already installed with this token"
  else
    if [ -e "$UNIT" ]; then
      info "a different tunnel token is installed here; replacing it"
      systemctl stop cloudflared >/dev/null 2>&1 || true
      cloudflared service uninstall >/dev/null 2>&1 ||
        systemctl disable cloudflared >/dev/null 2>&1 || true
      rm -f "$UNIT"
      systemctl daemon-reload
    fi
    # The token is an argument here, so it is briefly visible in ps, and
    # cloudflared bakes it into the unit file, which is world-readable. See
    # docs/cloudflare.md; on a host whose only account is deploy that is
    # acceptable, and the token can be rotated from the dashboard.
    cloudflared service install "$TOKEN" >/dev/null
    changed "installed the cloudflared service"
  fi

  disable_self_updater

  if systemctl is-enabled --quiet cloudflared 2>/dev/null; then
    info "cloudflared starts at boot"
  else
    systemctl enable cloudflared >/dev/null 2>&1
    changed "enabled cloudflared at boot"
  fi

  if [ "$RESTART_SERVICE" = yes ]; then
    systemctl restart cloudflared
    info "restarted cloudflared"
  elif ! systemctl is-active --quiet cloudflared; then
    systemctl start cloudflared
    changed "started cloudflared"
  fi

  wait_for_tunnel
}

report_firewall() {
  local status
  step "Firewall"
  info "no ufw rule was added or changed: cloudflared makes an outbound"
  info "connection to Cloudflare's edge on TCP/UDP 7844, so a tunnel needs no"
  info "inbound port. The host stays closed apart from SSH."
  if command -v ufw >/dev/null 2>&1; then
    status=$(ufw status 2>/dev/null | head -1)
    info "ufw: ${status:-unknown}"
  fi
}

summary() {
  step "Summary"
  if [ "$CHANGES" -eq 0 ]; then
    info "no changes: this host already runs this tunnel"
  else
    info "$CHANGES change(s) applied"
  fi
  if [ -n "$TUNNEL_ID" ]; then
    info "tunnel $TUNNEL_ID"
  fi
  if [ -n "$WARNINGS" ]; then
    printf '\n'
    printf '%s' "$WARNINGS" | while IFS= read -r line; do
      printf '   unresolved: %s\n' "$line"
    done
  fi
}

next_steps() {
  step "Next"
  cat <<'EOF'
   In Zero Trust, Networks > Tunnels should now show this tunnel HEALTHY
   with this host as its connector.

   Nothing is listening on port 80 yet, so the hostname answers 502 until
   ticket 07 deploys the app. To prove the tunnel and the isolation before
   then, run the throwaway-origin test in docs/cloudflare.md and work
   through the verification checklist there.
EOF
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    '') ;;
    *)
      usage >&2
      exit 2
      ;;
  esac

  require_root
  check_os
  require_provisioned
  read_token
  install_cloudflared
  configure_unattended_upgrades
  install_service
  report_firewall
  summary
  next_steps
}

main "$@"
