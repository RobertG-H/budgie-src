# Provisioning the hosts

Budgie runs on two OVHcloud VPS instances running Ubuntu 26.04 LTS: `budgie-testing` and `budgie-production`.
They're built the same way, from the same script, so that a deploy that works on testing works on production.

[`script/provision.sh`](../script/provision.sh) does everything that can be automated.
This page covers the OVH panel steps that can't be, and the checks that say a host is finished.
The script never runs from the application checkout: copy it to the host and run it there.

## Before you start: the SSH key in 1Password

You log in to both hosts with one SSH key that lives in [1Password](https://1password.com/) and never touches your disk.
When you connect, 1Password's SSH agent signs with it, after asking you to approve the first time an app uses the key.

1. In 1Password, open **Settings → Developer** and turn on **Use the SSH agent**.
2. Create the key: **New Item → SSH Key → Add Private Key → Generate a New Key**, type **Ed25519**, named `Budgie`.
   Keep it in your Personal or Private vault, which are the vaults the agent offers keys from by default.
3. Copy the item's **public key**, and save it where SSH can find it:

   ```sh
   mkdir -p ~/.ssh/budgie
   pbpaste > ~/.ssh/budgie/budgie.pub
   ```

   That's only the public half. SSH reads it to know which of 1Password's keys to ask for; the private key stays in 1Password.

Kamal can't use this key, because it runs in a container that can't reach 1Password. It gets a key of its own: see [Deploying](deployment.md#kamals-ssh-key).

## 1. Order the VPS

Do this twice, once per host, in the [OVHcloud panel](https://www.ovhcloud.com/).

- **Product:** VPS, the **4 GB** tier. Both hosts get the same tier.
  Each one runs Puma, a PostgreSQL container and `cloudflared`, and a deploy that overlaps PostgreSQL is tight on 2 GB.
- **Region:** the same datacenter for both, so testing isn't quietly faster than production.
- **Image:** Ubuntu 26.04 LTS, with no control panel and no extra options.
  Both hosts get the same release. If the panel doesn't offer 26.04 for the region you picked, change both hosts rather than running one release on each — a testing host that doesn't match production is the thing this setup is trying to avoid.
- **SSH key:** paste the `Budgie` public key, the contents of `~/.ssh/budgie/budgie.pub`. It's what gets you in the first time, as the image's `ubuntu` user.
- **Backups and options:** none.

Two things in the panel to leave alone:

- **Don't turn on OVH's network firewall.** All firewall rules live in ufw on the host. Two firewalls in two places means debugging a rule you forgot exists.
- **Don't rename the VPS in the panel** expecting the hostname to follow. The script sets the hostname on the machine.

Note each host's IP address when the install finishes, and give both hosts an entry in your `~/.ssh/config`.
It's what sends SSH to 1Password for these two hosts, and it makes every command below shorter:

```
Host budgie-testing
  HostName <testing ip>

Host budgie-production
  HostName <production ip>

Host budgie-testing budgie-production
  User deploy
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  IdentityFile ~/.ssh/budgie/budgie.pub
  IdentitiesOnly yes
```

- `IdentityAgent` is 1Password's agent, so SSH asks 1Password for keys instead of the macOS agent. The path is quoted because it contains a space.
- `IdentityFile` names the **public** key, which tells the agent which key to sign with. With `IdentitiesOnly yes`, SSH offers these hosts that key and nothing else.
  sshd refuses a connection after six failed keys, so offering every key you have can fail before the right one comes up.
- `HostName` is the IP address, rather than the host's OVH name (`vps-….vps.ovh.ca`), so SSH records each host's key in `~/.ssh/known_hosts` under its IP.
  Kamal connects by IP, and it checks host keys against that file. See [Deploying](deployment.md#before-your-first-deploy).

The last block covers both hosts, so a third host only needs its own `HostName` block and its name added to that `Host` line.
Until the script has created `deploy`, connect as the install-time user by putting it in front of the name, as in `ubuntu@budgie-testing`.

## 2. Run the script

For each host, from your checkout, with the host's install-time user (`ubuntu` on OVH's Ubuntu images):

```sh
scp script/provision.sh ubuntu@budgie-testing:
ssh ubuntu@budgie-testing 'sudo bash provision.sh budgie-testing'
```

and the same for the second host with `budgie-production`. 1Password asks you to approve the key the first time.

The script sets the hostname and UTC timezone, adds a 2 GB swapfile with `vm.swappiness=10`, creates the `deploy` user in the `docker` group with passwordless sudo, turns off password and root SSH logins, enables ufw with only a rate-limited SSH rule, installs Docker from Docker's own apt repository with log rotation, and turns on automatic security upgrades with a 04:00 UTC reboot.
It takes a few minutes, mostly installing Docker.

One detail worth knowing, because it's easy to get backwards: the SSH settings go in `/etc/ssh/sshd_config.d/01-budgie.conf`.
sshd keeps the **first** value it reads for a setting, and `sshd_config` includes that directory before anything else, so the drop-in has to sort *before* cloud-init's `50-cloud-init.conf`, which sets `PasswordAuthentication` itself.
A `99-` file would silently lose, and editing `/etc/ssh/sshd_config` loses to both.
The script reads the settings back with `sshd -T` afterwards and fails loudly if something else won.

It authorises the keys in the invoking user's `~/.ssh/authorized_keys`, which is the 1Password key that just got you in, so you can't provision a host with a key you don't hold.
To authorise another key as well, copy its public half over and pass it as a second argument:

```sh
scp script/provision.sh ~/.ssh/budgie/kamal.pub ubuntu@budgie-testing:
ssh ubuntu@budgie-testing 'sudo bash provision.sh budgie-testing kamal.pub'
```

That's how [Kamal's key](deployment.md#kamals-ssh-key) gets onto a host, and how the GitHub Actions deploy key will in ticket 09.
On a host that's already provisioned, run the same as `deploy`, with `budgie-testing` in place of `ubuntu@budgie-testing`.

The script is safe to re-run. On a host that's already set up it changes nothing and ends with `no changes: this host was already provisioned`.

## 3. Remove the default user

Only after you have opened a **new** terminal and logged in as `deploy`:

```sh
ssh budgie-testing docker ps
```

If that works, the OVH image's `ubuntu` user has nothing left to do:

```sh
scp script/provision.sh budgie-testing:
ssh budgie-testing 'sudo bash provision.sh --remove-default-user'
```

This is a separate step on purpose. Nothing running inside your current SSH session can honestly tell you that you'll be able to log in again; only a fresh connection can.
The script refuses to run it if you're logged in as `ubuntu`, if `deploy` has no authorised keys, or if `ubuntu` still has a session open.

cloud-init only creates the default user on a machine's first boot, so it stays gone after a reboot.

## 4. Verify

Run these from your laptop against each host: as written for `budgie-testing`, then again with `budgie-production`. Everything below is what a finished host looks like.

**You can get in with a key, and not with a password.**

```sh
ssh budgie-testing true
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password budgie-testing
```

The first prints nothing and exits 0. The second is refused:

```
deploy@<testing ip>: Permission denied (publickey).
```

**Root and the default user are gone.**

```sh
ssh root@budgie-testing
ssh budgie-testing id ubuntu
```

```
root@<testing ip>: Permission denied (publickey).
id: 'ubuntu': no such user
```

**sshd really is configured that way**, rather than a drop-in that sorts earlier having won:

```sh
ssh budgie-testing 'sudo sshd -T | grep -E "^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) "'
```

```
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
```

**Docker works without sudo.**

```sh
ssh budgie-testing docker ps
```

```
CONTAINER ID   IMAGE     COMMAND   CREATED   STATUS    PORTS     NAMES
```

**`deploy` can sudo without a password.**

```sh
ssh budgie-testing 'sudo -n true && echo ok'
```

```
ok
```

On 26.04 that's sudo-rs, Ubuntu's Rust implementation, rather than GNU sudo. It parses the `NOPASSWD` drop-in the script writes, and the script validates the file with `visudo -cf` before installing it either way.

**Nothing is listening on the web ports.** Only SSH should be reachable; the [Cloudflare Tunnel](cloudflare.md) dials out instead of listening.

```sh
ssh budgie-testing 'sudo ss -tlnp'
```

Expect `0.0.0.0:22` and `[::]:22`, plus whatever systemd-resolved binds on `127.0.0.x:53`, which is localhost-only.
Nothing on `0.0.0.0:80` or `0.0.0.0:443`.

**The firewall denies everything but rate-limited SSH.**

```sh
ssh budgie-testing 'sudo ufw status verbose'
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
ssh budgie-testing 'hostnamectl; free -h; swapon --show'
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
ssh budgie-testing 'cat /etc/docker/daemon.json'
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
ssh budgie-testing 'systemctl is-active unattended-upgrades; apt-config dump | grep -E "Allowed-Origins|Automatic-Reboot"'
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
ssh budgie-testing 'sudo bash provision.sh budgie-testing'
```

```
== Summary
   no changes: this host was already provisioned
```

**It all survives a reboot.** The host reboots itself at 04:00 UTC when an update needs it, so check that now rather than finding out later:

```sh
ssh budgie-testing 'sudo reboot'
# wait a minute
ssh budgie-testing 'hostnamectl --static; swapon --show; sudo ufw status | head -1; docker ps'
```

The hostname is still `budgie-testing`, the swapfile is back, ufw is active and Docker is running.

## Building another host

Run the same steps with a different hostname. The script is the only place the host's configuration is written down, so a third host is an entry in `~/.ssh/config`, `scp`, one command, and the checks above.

If you change what a host should look like, change the script and re-run it everywhere, rather than editing a machine in place.

## Where the IP addresses go

Kamal needs them to deploy, so they're in `TESTING_HOST_IP` and `PRODUCTION_HOST_IP` in the deploy env files, as well as the OVH panel and the `HostName` lines in your `~/.ssh/config`.
Kamal runs in a container that can't see your `~/.ssh/config`, so the names there are only for you. See [Deploying](deployment.md).

## Two things the script deliberately doesn't do

- **It opens no HTTP or HTTPS port**, and [Cloudflare](cloudflare.md) doesn't either. `cloudflared` makes an outbound connection to Cloudflare's edge, so the tunnel never needs an inbound port. If an outbound deny policy is ever added to ufw, it has to allow TCP and UDP 7844.
- **It doesn't install fail2ban.** With passwords off entirely, it guards a door with no keyhole; ufw's rate limit already drops an IP that opens six connections in thirty seconds.

One thing to keep in mind as containers start arriving: **Docker's published ports bypass ufw**. Docker writes its own iptables rules, so a container published with `-p 80:80` is reachable from the internet even though ufw says deny. Keeping ports unpublished is what keeps the host closed, not the firewall.

That's the next thing to do to a finished host: [Cloudflare](cloudflare.md) puts it behind a tunnel and proves that its IP address answers nothing.
