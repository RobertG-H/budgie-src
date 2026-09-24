#!/usr/bin/env bash
#
# Provision an OVH VPS running Ubuntu 26.04 LTS to run Budgie: hostname, swap,
# a deploy user, SSH hardening, ufw, Docker and automatic security upgrades.
#
# Usage:
#   sudo bash provision.sh <hostname> [extra_pubkey_file]
#   sudo bash provision.sh --remove-default-user [username]
#
# The hosts are budgie-testing and budgie-production. The script is safe to
# re-run: on a configured host it changes nothing and exits 0.
#
# See docs/provisioning.md for the OVH panel steps and the verification
# checklist. This script is never run from the application checkout.

set -euo pipefail

DEPLOY_USER=deploy
DEFAULT_USER=ubuntu
SWAPFILE=/swapfile
SWAPSIZE=2G
SSHD_DROPIN=/etc/ssh/sshd_config.d/01-budgie.conf
SUDOERS_DROPIN=/etc/sudoers.d/90-budgie-deploy
DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
DOCKER_LIST=/etc/apt/sources.list.d/docker.list

CHANGES=0
APT_UPDATED=no

usage() {
  cat <<'EOF'
Usage:
  sudo bash provision.sh <hostname> [extra_pubkey_file]
  sudo bash provision.sh --remove-default-user [username]

  <hostname>           budgie-testing or budgie-production
  [extra_pubkey_file]  an additional public key to authorise, on top of the
                       keys the invoking user already has
  --remove-default-user
                       delete the image's default user (default: ubuntu) and
                       its home directory. Run this only after logging in as
                       deploy from your laptop in a separate session.
EOF
}

step()    { printf '\n== %s\n' "$*"; }
info()    { printf '   %s\n' "$*"; }
changed() { CHANGES=$((CHANGES + 1)); printf '   changed: %s\n' "$*"; }
die()     { printf 'provision.sh: %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run this with sudo: sudo bash provision.sh $*"
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

apt_install() {
  local missing=() package
  for package in "$@"; do
    dpkg -s "$package" >/dev/null 2>&1 || missing+=("$package")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  apt_update
  apt_wait
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    -o Dpkg::Options::=--force-confold "${missing[@]}" >/dev/null
  changed "installed ${missing[*]}"
}

configure_hostname() {
  local want=$1 hosts
  step "Hostname"

  if [ "$(hostnamectl --static)" = "$want" ]; then
    info "already $want"
  else
    hostnamectl set-hostname "$want"
    changed "hostname set to $want"
  fi

  if grep -qE "^127\.0\.1\.1[[:space:]]+${want}([[:space:]]|\$)" /etc/hosts; then
    info "/etc/hosts already maps 127.0.1.1 to $want"
  elif grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    # Rewritten in place rather than with sed -i, which can't rename over a
    # bind-mounted /etc/hosts.
    hosts=$(mktemp)
    sed -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${want}/" /etc/hosts >"$hosts"
    cat "$hosts" >/etc/hosts
    rm -f "$hosts"
    changed "/etc/hosts now maps 127.0.1.1 to $want"
  else
    printf '127.0.1.1\t%s\n' "$want" >>/etc/hosts
    changed "/etc/hosts now maps 127.0.1.1 to $want"
  fi

  # Without this, cloud-init sets the hostname back from OVH's metadata on the
  # next boot.
  if [ -d /etc/cloud/cloud.cfg.d ]; then
    write_file /etc/cloud/cloud.cfg.d/99-budgie.cfg 0644 <<'EOF' || info "cloud-init already told to keep the hostname"
# Budgie: keep the hostname this host was provisioned with.
preserve_hostname: true
EOF
  fi
}

configure_timezone() {
  step "Timezone"
  if [ "$(timedatectl show --property=Timezone --value)" = "UTC" ]; then
    info "already UTC"
  else
    timedatectl set-timezone UTC
    changed "timezone set to UTC"
  fi
}

configure_swap() {
  step "Swap"

  if [ ! -e "$SWAPFILE" ]; then
    fallocate -l "$SWAPSIZE" "$SWAPFILE" 2>/dev/null ||
      dd if=/dev/zero of="$SWAPFILE" bs=1M count=2048 status=none
    changed "created $SWAPFILE ($SWAPSIZE)"
  fi
  chmod 600 "$SWAPFILE"

  if ! swaplabel "$SWAPFILE" >/dev/null 2>&1; then
    mkswap "$SWAPFILE" >/dev/null
    changed "formatted $SWAPFILE as swap"
  fi

  if swapon --show=NAME --noheadings | grep -x "$SWAPFILE" >/dev/null; then
    info "$SWAPFILE is already in use"
  else
    swapon "$SWAPFILE"
    changed "enabled $SWAPFILE"
  fi

  if grep -qE "^${SWAPFILE}[[:space:]]" /etc/fstab; then
    info "/etc/fstab already mounts $SWAPFILE"
  else
    printf '%s none swap sw 0 0\n' "$SWAPFILE" >>/etc/fstab
    changed "added $SWAPFILE to /etc/fstab"
  fi

  if write_file /etc/sysctl.d/99-budgie.conf 0644 <<'EOF'
# Budgie: 4 GB of RAM, so swap is a cushion for deploy-time spikes, not a
# place to run from.
vm.swappiness=10
EOF
  then
    sysctl -q -w vm.swappiness=10
  else
    info "vm.swappiness already set to 10"
  fi
}

# Copies every key in $1 that $2 doesn't already have.
add_keys_from() {
  local src=$1 dest=$2 line
  [ -r "$src" ] || die "can't read the public keys in $src"
  if [ "$(readlink -f "$src")" = "$(readlink -f "$dest")" ]; then
    info "keys already live in $dest"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | \#*) continue ;; esac
    grep -qxF "$line" "$dest" && continue
    printf '%s\n' "$line" >>"$dest"
    changed "authorised a key from $src (${line##* })"
  done <"$src"
}

configure_deploy_user() {
  local extra_key=$1 invoking_user invoking_home source_keys dest_keys tmp
  step "The $DEPLOY_USER user"

  if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    info "user $DEPLOY_USER already exists"
  else
    useradd --create-home --shell /bin/bash "$DEPLOY_USER"
    changed "created the $DEPLOY_USER user"
  fi

  if getent group docker >/dev/null; then
    info "the docker group already exists"
  else
    groupadd docker
    changed "created the docker group"
  fi

  if id -nG "$DEPLOY_USER" | tr ' ' '\n' | grep -x docker >/dev/null; then
    info "$DEPLOY_USER is already in the docker group"
  else
    usermod -aG docker "$DEPLOY_USER"
    changed "added $DEPLOY_USER to the docker group"
  fi

  tmp=$(mktemp)
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEPLOY_USER" >"$tmp"
  visudo -cf "$tmp" >/dev/null || die "the generated sudoers drop-in is invalid; nothing was installed"
  if [ -e "$SUDOERS_DROPIN" ] && cmp -s "$tmp" "$SUDOERS_DROPIN"; then
    info "$SUDOERS_DROPIN is already in place"
  else
    install -o root -g root -m 0440 "$tmp" "$SUDOERS_DROPIN"
    changed "wrote $SUDOERS_DROPIN"
  fi
  rm -f "$tmp"

  invoking_user=${SUDO_USER:-root}
  invoking_home=$(getent passwd "$invoking_user" | cut -d: -f6)
  [ -n "$invoking_home" ] || die "can't find the home directory of $invoking_user"
  source_keys="$invoking_home/.ssh/authorized_keys"
  dest_keys="/home/$DEPLOY_USER/.ssh/authorized_keys"

  install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" -m 700 "/home/$DEPLOY_USER/.ssh"
  [ -e "$dest_keys" ] || : >"$dest_keys"

  if [ -r "$source_keys" ]; then
    add_keys_from "$source_keys" "$dest_keys"
  elif [ -n "$extra_key" ]; then
    info "$invoking_user has no authorized_keys; using only $extra_key"
  else
    die "no keys to copy: $source_keys doesn't exist and no extra key file was given"
  fi
  [ -n "$extra_key" ] && add_keys_from "$extra_key" "$dest_keys"

  chown "$DEPLOY_USER:$DEPLOY_USER" "$dest_keys"
  chmod 600 "$dest_keys"

  grep -qE '^[^#[:space:]]' "$dest_keys" ||
    die "$dest_keys has no keys in it; refusing to harden SSH and lock you out"
}

configure_sshd() {
  local tmp backup setting value
  step "SSH"

  # Ubuntu's cloud images configure sshd through /etc/ssh/sshd_config.d, and
  # 50-cloud-init.conf sets PasswordAuthentication there. sshd keeps the first
  # value it reads, and sshd_config includes the directory before anything
  # else, so this drop-in has to sort *before* cloud-init's, not after it, and
  # editing /etc/ssh/sshd_config would lose to both.
  install -d -m 0755 /etc/ssh/sshd_config.d
  tmp=$(mktemp)
  cat >"$tmp" <<'EOF'
# Budgie. Sorts before cloud-init's 50-cloud-init.conf, and sshd keeps the
# first value it reads, so these win.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF

  if [ -e "$SSHD_DROPIN" ] && cmp -s "$tmp" "$SSHD_DROPIN"; then
    rm -f "$tmp"
    info "$SSHD_DROPIN is already in place"
  else
    backup=$(mktemp)
    if [ -e "$SSHD_DROPIN" ]; then
      cp "$SSHD_DROPIN" "$backup"
    else
      rm -f "$backup"
    fi

    install -o root -g root -m 0644 "$tmp" "$SSHD_DROPIN"
    rm -f "$tmp"

    if ! sshd -t; then
      if [ -e "$backup" ]; then
        install -o root -g root -m 0644 "$backup" "$SSHD_DROPIN"
        rm -f "$backup"
      else
        rm -f "$SSHD_DROPIN"
      fi
      die "sshd rejected the new configuration; the old one is back in place"
    fi
    rm -f "$backup"
    changed "wrote $SSHD_DROPIN"

    # Under socket activation a new sshd reads the config per connection, so
    # there is nothing to reload.
    if systemctl is-active --quiet ssh; then
      systemctl reload ssh
      info "reloaded ssh"
    else
      info "ssh is socket-activated; new connections pick this up on their own"
    fi
  fi

  # Another drop-in sorting earlier would silently win, so check what sshd
  # actually ends up with rather than trusting the file.
  if ! sshd -T >/dev/null 2>&1; then
    info "warning: couldn't read back the effective sshd configuration"
    return 0
  fi
  for setting in passwordauthentication kbdinteractiveauthentication permitrootlogin; do
    value=$(sshd -T 2>/dev/null | awk -v key="$setting" '$1 == key { print $2 }')
    [ "$value" = "no" ] ||
      die "sshd still has $setting=$value; something in /etc/ssh/sshd_config.d sorts before $(basename "$SSHD_DROPIN")"
  done
  info "sshd refuses passwords, keyboard-interactive and root logins"
}

configure_firewall() {
  local ssh_rule
  step "Firewall"
  apt_install ufw

  if grep -q '^DEFAULT_INPUT_POLICY="DROP"' /etc/default/ufw; then
    info "inbound is already denied by default"
  else
    ufw default deny incoming >/dev/null
    changed "default inbound policy is now deny"
  fi

  if grep -q '^DEFAULT_OUTPUT_POLICY="ACCEPT"' /etc/default/ufw; then
    info "outbound is already allowed by default"
  else
    ufw default allow outgoing >/dev/null
    changed "default outbound policy is now allow"
  fi

  if ufw app info OpenSSH >/dev/null 2>&1; then
    ssh_rule=OpenSSH
  else
    ssh_rule=22/tcp
  fi

  if ufw show added | grep -E "limit (OpenSSH|22/tcp)" >/dev/null; then
    info "SSH is already rate-limited"
  else
    ufw limit "$ssh_rule" >/dev/null
    changed "rate-limited SSH ($ssh_rule)"
  fi

  if ufw status | grep '^Status: active' >/dev/null; then
    info "ufw is already active"
  else
    ufw --force enable >/dev/null
    changed "enabled ufw"
  fi
}

install_docker() {
  local arch codename repo desired
  step "Docker"
  apt_install ca-certificates curl gnupg

  if [ -s "$DOCKER_KEYRING" ]; then
    info "Docker's apt key is already installed"
  else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$DOCKER_KEYRING"
    chmod a+r "$DOCKER_KEYRING"
    changed "installed Docker's apt key"
  fi

  arch=$(dpkg --print-architecture)
  # shellcheck disable=SC1091
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  repo="deb [arch=$arch signed-by=$DOCKER_KEYRING] https://download.docker.com/linux/ubuntu $codename stable"
  if write_file "$DOCKER_LIST" 0644 <<EOF
$repo
EOF
  then
    APT_UPDATED=no
  else
    info "$DOCKER_LIST is already in place"
  fi

  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Docker's default json-file driver has no size limit, and a chatty
  # container will fill the disk.
  install -d -m 0755 /etc/docker
  desired=$(mktemp)
  cat >"$desired" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
  if [ -e /etc/docker/daemon.json ] && ! cmp -s "$desired" /etc/docker/daemon.json; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
    info "backed up the existing /etc/docker/daemon.json"
  fi
  if write_file /etc/docker/daemon.json 0644 <"$desired"; then
    systemctl restart docker
    info "restarted docker"
  else
    info "/etc/docker/daemon.json is already in place"
  fi
  rm -f "$desired"

  if systemctl is-enabled --quiet docker && systemctl is-active --quiet docker; then
    info "docker is enabled and running"
  else
    systemctl enable --now docker >/dev/null 2>&1
    changed "enabled and started docker"
  fi
}

configure_unattended_upgrades() {
  step "Automatic security upgrades"
  apt_install unattended-upgrades

  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF' || info "apt is already told to run unattended-upgrades"
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  # Allowed-Origins is a list, and apt appends to lists, so the shipped
  # 50unattended-upgrades entries have to be cleared before ours are set.
  # Otherwise this file adds security origins instead of restricting to them.
  write_file /etc/apt/apt.conf.d/52-budgie-unattended-upgrades 0644 <<'EOF' || info "the upgrade policy is already in place"
// Budgie: security updates only, and reboot if one needs it.
#clear Unattended-Upgrade::Allowed-Origins;
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

  if systemctl is-enabled --quiet unattended-upgrades; then
    info "unattended-upgrades is already enabled"
  else
    systemctl enable --now unattended-upgrades >/dev/null 2>&1
    changed "enabled unattended-upgrades"
  fi
}

remove_default_user() {
  local user=$1 dest_keys="/home/$DEPLOY_USER/.ssh/authorized_keys"
  step "Removing the default user"

  [ "${SUDO_USER:-}" = "$user" ] &&
    die "you are logged in as $user. Log in as $DEPLOY_USER and run this again."

  if ! id -u "$user" >/dev/null 2>&1; then
    info "$user doesn't exist; nothing to do"
    return 0
  fi

  id -u "$DEPLOY_USER" >/dev/null 2>&1 || die "$DEPLOY_USER doesn't exist; run the main provisioning first"
  if ! [ -r "$dest_keys" ] || ! grep -qE '^[^#[:space:]]' "$dest_keys"; then
    die "$DEPLOY_USER has no authorised keys; refusing to delete $user"
  fi
  [ -e "$SUDOERS_DROPIN" ] || die "$SUDOERS_DROPIN is missing; refusing to delete $user"

  if pgrep -u "$user" >/dev/null 2>&1; then
    die "$user still has processes running. Close its sessions and run this again."
  fi

  userdel --remove "$user"
  changed "deleted $user and its home directory"

  # cloud-init's grant for the default user, dead once the user is gone.
  if [ -e /etc/sudoers.d/90-cloud-init-users ] &&
    ! grep -vE '^[[:space:]]*(#|$)' /etc/sudoers.d/90-cloud-init-users |
      grep -vE "^${user}[[:space:]]" >/dev/null; then
    rm -f /etc/sudoers.d/90-cloud-init-users
    changed "removed /etc/sudoers.d/90-cloud-init-users"
  fi
}

summary() {
  step "Summary"
  if [ "$CHANGES" -eq 0 ]; then
    info "no changes: this host was already provisioned"
  else
    info "$CHANGES change(s) applied"
  fi
}

next_steps() {
  local address
  address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk 'NR == 1 { print $7 }') || address=''
  [ -n "$address" ] || address='<ip>'

  step "Next"
  cat <<EOF
   From your laptop, in a new terminal, check that you can get in as $DEPLOY_USER:

     ssh $DEPLOY_USER@$address docker ps

   Only once that works, remove the image's default user:

     scp script/provision.sh $DEPLOY_USER@$address:
     ssh $DEPLOY_USER@$address 'sudo bash provision.sh --remove-default-user'

   Then work through the verification checklist in docs/provisioning.md.
EOF
}

main() {
  local host extra_key

  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    --remove-default-user)
      require_root "$@"
      check_os
      remove_default_user "${2:-$DEFAULT_USER}"
      summary
      exit 0
      ;;
    '' | -*)
      usage >&2
      exit 2
      ;;
  esac

  host=$1
  extra_key=${2:-}

  [[ $host =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    die "'$host' is not a valid hostname"
  [ -z "$extra_key" ] || [ -r "$extra_key" ] || die "can't read the key file $extra_key"

  require_root "$@"
  check_os

  configure_hostname "$host"
  configure_timezone
  configure_swap
  configure_deploy_user "$extra_key"
  configure_sshd
  configure_firewall
  install_docker
  configure_unattended_upgrades
  summary
  next_steps
}

main "$@"
