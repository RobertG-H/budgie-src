# Provisioning the hosts

Budgie runs on two OVHcloud VPS instances running Ubuntu 26.04 LTS: `budgie-testing` and `budgie-production`.
They're built the same way, from the same script, so that a deploy that works on testing works on production.

[`script/provision.sh`](../script/provision.sh) does everything that can be automated.
This page covers the OVH panel steps that can't be, and the checks that say a host is finished.
The script never runs from the application checkout: copy it to the host and run it there.

## 1. Order the VPS

Do this twice, once per host, in the [OVHcloud panel](https://www.ovhcloud.com/).

- **Product:** VPS, the **4 GB** tier. Both hosts get the same tier.
  Each one runs Puma, a PostgreSQL container and `cloudflared`, and a deploy that overlaps PostgreSQL is tight on 2 GB.
- **Region:** the same datacenter for both, so testing isn't quietly faster than production.
- **Image:** Ubuntu 26.04 LTS, with no control panel and no extra options.
  Both hosts get the same release. If the panel doesn't offer 26.04 for the region you picked, change both hosts rather than running one release on each — a testing host that doesn't match production is the thing this setup is trying to avoid.
- **SSH key:** select your laptop's public key during the install. It's what you'll use to get in the first time.
- **Backups and options:** none.

Two things in the panel to leave alone:

- **Don't turn on OVH's network firewall.** All firewall rules live in ufw on the host. Two firewalls in two places means debugging a rule you forgot exists.
- **Don't rename the VPS in the panel** expecting the hostname to follow. The script sets the hostname on the machine.

Note each host's IP address when the install finishes. Adding them to your `~/.ssh/config` makes everything below shorter:

```
Host budgie-testing
  HostName <testing ip>
  User deploy

Host budgie-production
  HostName <production ip>
  User deploy
```

## 2. Run the script

For each host, from your checkout, with the host's install-time user (`ubuntu` on OVH's Ubuntu images):

```sh
scp script/provision.sh ubuntu@<ip>:
ssh ubuntu@<ip> 'sudo bash provision.sh budgie-testing'
```

and the same for the second host with `budgie-production`.

The script sets the hostname and UTC timezone, adds a 2 GB swapfile with `vm.swappiness=10`, creates the `deploy` user in the `docker` group with passwordless sudo, turns off password and root SSH logins, enables ufw with only a rate-limited SSH rule, installs Docker from Docker's own apt repository with log rotation, and turns on automatic security upgrades with a 04:00 UTC reboot.
It takes a few minutes, mostly installing Docker.

One detail worth knowing, because it's easy to get backwards: the SSH settings go in `/etc/ssh/sshd_config.d/01-budgie.conf`.
sshd keeps the **first** value it reads for a setting, and `sshd_config` includes that directory before anything else, so the drop-in has to sort *before* cloud-init's `50-cloud-init.conf`, which sets `PasswordAuthentication` itself.
A `99-` file would silently lose, and editing `/etc/ssh/sshd_config` loses to both.
The script reads the settings back with `sshd -T` afterwards and fails loudly if something else won.

It authorises the keys in the invoking user's `~/.ssh/authorized_keys` — the key that just got you in, so you can't provision a host with a key you don't hold.
To authorise another key at the same time, pass a file holding it:

```sh
ssh ubuntu@<ip> 'sudo bash provision.sh budgie-testing extra-key.pub'
```

That's how the GitHub Actions deploy key gets added later, in ticket 09.

The script is safe to re-run. On a host that's already set up it changes nothing and ends with `no changes: this host was already provisioned`.

## 3. Remove the default user

Only after you have opened a **new** terminal and logged in as `deploy`:

```sh
ssh deploy@<ip> docker ps
```

If that works, the OVH image's `ubuntu` user has nothing left to do:

```sh
scp script/provision.sh deploy@<ip>:
ssh deploy@<ip> 'sudo bash provision.sh --remove-default-user'
```

This is a separate step on purpose. Nothing running inside your current SSH session can honestly tell you that you'll be able to log in again; only a fresh connection can.
The script refuses to run it if you're logged in as `ubuntu`, if `deploy` has no authorised keys, or if `ubuntu` still has a session open.

cloud-init only creates the default user on a machine's first boot, so it stays gone after a reboot.

## 4. Verify

Run these from your laptop against each host. Everything below is what a finished host looks like.

**You can get in with a key, and not with a password.**

```sh
ssh deploy@<ip> true
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password deploy@<ip>
```

The first prints nothing and exits 0. The second is refused:

```
deploy@<ip>: Permission denied (publickey).
```

**Root and the default user are gone.**

```sh
ssh root@<ip>
ssh deploy@<ip> id ubuntu
```

```
root@<ip>: Permission denied (publickey).
id: 'ubuntu': no such user
```

**sshd really is configured that way**, rather than a drop-in that sorts earlier having won:

```sh
ssh deploy@<ip> 'sudo sshd -T | grep -E "^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) "'
```

```
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
```

**Docker works without sudo.**

```sh
ssh deploy@<ip> docker ps
```

```
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

**`deploy` can sudo without a password.**

```sh
ssh deploy@<ip> 'sudo -n true && echo ok'
```

```
ok
```

On 26.04 that's sudo-rs, Ubuntu's Rust implementation, rather than GNU sudo. It parses the `NOPASSWD` drop-in the script writes, and the script validates the file with `visudo -cf` before installing it either way.

**Nothing is listening on the web ports.** Only SSH should be reachable; the tunnel from ticket 06 dials out instead of listening.

```sh
ssh deploy@<ip> 'sudo ss -tlnp'
```

Expect `0.0.0.0:22` and `[::]:22`, plus whatever systemd-resolved binds on `127.0.0.x:53`, which is localhost-only.
Nothing on `0.0.0.0:80` or `0.0.0.0:443`.

**The firewall denies everything but rate-limited SSH.**

```sh
ssh deploy@<ip> 'sudo ufw status verbose'
```

```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
22/tcp (OpenSSH)           LIMIT IN    Anywhere
22/tcp (OpenSSH (v6))      LIMIT IN    Anywhere (v6)
```

**Hostname, timezone and swap.**

```sh
ssh deploy@<ip> 'hostnamectl; free -h; swapon --show'
```

```
 Static hostname: budgie-testing
       Time zone: UTC (UTC, +0000)
...
Swap:          2.0Gi          0B        2.0Gi
NAME      TYPE SIZE USED PRIO
/swapfile file   2G   0B   -2
```

**Docker's logs are capped.**

```sh
ssh deploy@<ip> 'cat /etc/docker/daemon.json'
```

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

**Security updates install themselves and the host reboots at 04:00 UTC.**

```sh
ssh deploy@<ip> 'systemctl is-active unattended-upgrades; apt-config dump | grep -E "Allowed-Origins|Automatic-Reboot"'
```

```
active
Unattended-Upgrade::Allowed-Origins "";
Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-security";
Unattended-Upgrade::Allowed-Origins:: "${distro_id}ESMApps:${distro_codename}-apps-security";
Unattended-Upgrade::Allowed-Origins:: "${distro_id}ESM:${distro_codename}-infra-security";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

The `-security` pockets and nothing else: an unrelated package upgrade shouldn't break a deploy with nobody watching.

**Re-running the script changes nothing.**

```sh
ssh deploy@<ip> 'sudo bash provision.sh budgie-testing'
```

```
== Summary
   no changes: this host was already provisioned
```

**It all survives a reboot.** The host reboots itself at 04:00 UTC when an update needs it, so check that now rather than finding out later:

```sh
ssh deploy@<ip> 'sudo reboot'
# wait a minute
ssh deploy@<ip> 'hostnamectl --static; swapon --show; sudo ufw status | head -1; docker ps'
```

The hostname is still `budgie-testing`, the swapfile is back, ufw is active and Docker is running.

## Building another host

Run the same two steps with a different hostname. The script is the only place the host's configuration is written down, so a third host is `scp`, one command, and the checks above.

If you change what a host should look like, change the script and re-run it everywhere, rather than editing a machine in place.

## Where the IP addresses go

Not in this repo. They live in your `~/.ssh/config` and in the OVH panel for now.
Kamal needs them to deploy, and ticket 07 is what puts them in `config/deploy.yml`; `config/deploy.yml` is still the stock Rails scaffold until then.

## Two things the script deliberately doesn't do

- **It opens no HTTP or HTTPS port**, and ticket 06 doesn't either. `cloudflared` makes an outbound connection to Cloudflare's edge, so the tunnel never needs an inbound port. If an outbound deny policy is ever added to ufw, it has to allow TCP and UDP 7844.
- **It doesn't install fail2ban.** With passwords off entirely, it guards a door with no keyhole; ufw's rate limit already drops an IP that opens six connections in thirty seconds.

One thing to keep in mind as containers start arriving: **Docker's published ports bypass ufw**. Docker writes its own iptables rules, so a container published with `-p 80:80` is reachable from the internet even though ufw says deny. Keeping ports unpublished is what keeps the host closed, not the firewall.
