# Cloudflare: the domain, the tunnels and network isolation

Budgie is reached at `budgiebuddie.com` (production) and `testing.budgiebuddie.com` (testing).
Cloudflare serves both names and reaches each VPS through a Cloudflare Tunnel:

```
browser → Cloudflare edge → tunnel → cloudflared on the host → http://localhost:80 → the app
```

`cloudflared` dials *out* to Cloudflare, so nothing dials in.
Once this is finished, going to a host's IP address gets you nothing at all: no port is open, and no DNS record points at it.

[`script/cloudflare-tunnel.sh`](../script/cloudflare-tunnel.sh) does the part that happens on a host.
This page covers the Cloudflare dashboard steps, which can't be scripted, and the checks that say it works.
Like `provision.sh`, the script never runs from the application checkout: copy it to the host and run it there.

Do [Provisioning the hosts](provisioning.md) first. This assumes two finished hosts, `budgie-testing` and `budgie-production`.

## What lives where

| Thing | Where it's written down |
| --- | --- |
| Installing and running `cloudflared` on a host | `script/cloudflare-tunnel.sh` |
| The domain, the zone settings, the rules, each tunnel's ingress | The Cloudflare dashboard — and, so it can be rebuilt, this page |
| The two tunnel tokens | A password manager, and nowhere else |
| The hostnames | This repo: `config/deploy.testing.yml`, `config/deploy.production.yml` and `config/environments/production.rb` |
| The VPS IP addresses | `TESTING_HOST_IP` and `PRODUCTION_HOST_IP` in the deploy env files, which git ignores, in the matching GitHub environment secret, and the OVH panel. See [Deploying](deployment.md#the-secrets-on-your-laptop) |
| Zedmail's two DNS records | The Cloudflare dashboard, **DNS only**. See [Zedmail's DNS records](#zedmails-dns-records) |

Hostnames are public: they're in DNS and permanently in Certificate Transparency logs the moment Cloudflare issues a certificate, so there's nothing to hide by keeping them out of git.

## 1. Register the domain

In the [Cloudflare dashboard](https://dash.cloudflare.com/), **Domain Registration → Register Domains**, register `budgiebuddie.com`.

Registering at Cloudflare Registrar creates the zone with Cloudflare already authoritative, so there's no nameserver change and no propagation wait.
The zone lands on the **Free** plan, which is everything Budgie needs — check that on the zone's Overview page.

`.com` deliberately, not `.dev` or `.app`: both of those are HSTS-preloaded at the TLD level, which forces HTTPS in every browser permanently and would quietly remove the "HSTS off" choice below.

## 2. Create each tunnel and run the script

Do this twice, once per host. Testing first, so production isn't the one you learn on.

Cloudflare's dashboard for this is **Zero Trust** at [one.dash.cloudflare.com](https://one.dash.cloudflare.com/), under **Networks → Tunnels**.
Two tunnels, not one with two connectors: one tunnel with a connector on each host is Cloudflare's load-balancing shape, and the edge would round-robin between testing and production.
It also keeps the production token off the testing host.

### 2a. Create the tunnel

**Create a tunnel → Cloudflared**, and name it after the host it will run on:

| Host | Tunnel name |
| --- | --- |
| `budgie-testing` | `budgie-testing` |
| `budgie-production` | `budgie-production` |

Save it. The next page offers install commands for various systems — **don't run them.**
They download a `.deb` by URL, which nothing then keeps current.
The only thing you want from that page is the **token**: the long string after `service install` in the Debian command.

### 2b. Run the script on the matching host

Put the token in a file on your laptop and pipe it in over SSH:

```sh
scp script/cloudflare-tunnel.sh deploy@budgie-testing:
ssh deploy@budgie-testing 'sudo bash cloudflare-tunnel.sh' < token.txt
rm token.txt
```

Reading it from stdin keeps the token out of your shell history, out of `ps` on the host and out of any file left behind on it.
Pasting the whole `sudo cloudflared service install <token>` line into the file works too; the script takes the last word.

The script refuses to run on a host that hasn't been provisioned, installs `cloudflared` from Cloudflare's apt repository, registers it as a systemd service with that token, turns the built-in self-updater off, and lets `unattended-upgrades` keep the package current.
It adds no ufw rule: a tunnel needs no inbound port.
It's safe to re-run — on a host already running that tunnel it changes nothing and exits 0.

It prints which repository distribution it picked. Cloudflare publishes one per Debian and Ubuntu codename and hasn't published one for 26.04 yet, so on these hosts it says so and uses `noble`, the most recent LTS that is published.
That's why `apt-cache policy` on a 26.04 host shows `noble` for this one repository, which is correct rather than left over.
If it can't reach `pkg.cloudflare.com` at all it stops rather than guessing — a wrong guess would pin the host to the wrong distribution for as long as nobody looked.

It ends by waiting for the connector to come up. Back in Zero Trust, the tunnel should now show **HEALTHY** with this host as its connector.

Store the token in your password manager now, as *"Cloudflare tunnel token — budgie-testing"*.
Deliberately **not** in `.kamal/secrets`, `.env` or GitHub Actions secrets: nothing in the deploy path ever reads it, and putting it there would imply otherwise.
It's needed once per host, and again only if a host is rebuilt.

One thing to know rather than discover: `cloudflared service install` bakes the token into `/etc/systemd/system/cloudflared.service`, which is world-readable, and it shows up in `ps` while the tunnel runs.
On a host whose only account is `deploy` that's acceptable, and a token can be replaced from the dashboard.
It's also why the checks below grep that file rather than printing it.

### 2c. Route the hostname to the tunnel

On the tunnel's **Public Hostname** tab, add exactly one hostname. These are the values to type; they're the whole of the ingress configuration, and they live in Cloudflare rather than in git, so this table is what rebuilds them:

| Field | `budgie-production` | `budgie-testing` |
| --- | --- | --- |
| Subdomain | *(empty)* | `testing` |
| Domain | `budgiebuddie.com` | `budgiebuddie.com` |
| Path | *(empty)* | *(empty)* |
| Type | `HTTP` | `HTTP` |
| URL | `localhost:80` | `localhost:80` |
| Additional application settings | *untouched* | *untouched* |

`HTTP`, not `HTTPS`: that hop is loopback-only on the same machine, so there's nothing to protect it from, and pointing it at `https` would only create a certificate problem it can't solve.
This is also why `cloudflared` runs as a host service rather than in a container — a containerised one couldn't reach a loopback-bound proxy.

Leave the tunnel's catch-all alone. By default anything you haven't routed gets a 404, which is what you want.

Saving this creates a **proxied** DNS record — a CNAME to `<tunnel-uuid>.cfargotunnel.com`.
Check the orange cloud in **DNS → Records**: a grey-clouded record publishes the origin IP and defeats the whole point.
The only records that are grey on purpose are [Zedmail's two](#zedmails-dns-records), which point at Zedmail rather than at a host.
The apex is fine as a CNAME; Cloudflare flattens it.

## 3. The `www` record and the redirect

`www.budgiebuddie.com` redirects to the apex at the edge, so it needs no origin and no third tunnel record — but it does need to resolve to Cloudflare, or nothing of Cloudflare's ever sees the request.

In **DNS → Records**, add:

| Type | Name | Content | Proxy |
| --- | --- | --- | --- |
| `A` | `www` | `192.0.2.1` | Proxied (orange) |

`192.0.2.1` is TEST-NET-1: an address that can't be routed anywhere. The edge answers and redirects, and never tries to reach it.

Then in **Rules → Redirect Rules**, create:

| Field | Value |
| --- | --- |
| Rule name | `www to apex` |
| When incoming requests match | Custom filter expression: `(http.host eq "www.budgiebuddie.com")` |
| Type | Dynamic |
| Expression | `concat("https://budgiebuddie.com", http.request.uri.path)` |
| Status code | `301` |
| Preserve query string | on |

## 4. `noindex` on testing

Every page in Budgie needs sign-in, but the sign-in page itself is indexable, and there's no reason for the testing one to be in a search index.
Doing it at the edge keeps environment-conditional logic out of the app.

In **Rules → Transform Rules → Modify Response Header**, create:

| Field | Value |
| --- | --- |
| Rule name | `noindex on testing` |
| When incoming requests match | Custom filter expression: `(http.host eq "testing.budgiebuddie.com")` |
| Then | Set static — header `X-Robots-Tag`, value `noindex` |

## 5. Zone settings

These are on the zone, so they apply to both hostnames. Several of them break things at the wrong value, so they're worth setting deliberately rather than leaving at whatever the dashboard offers.

| Setting | Where | Value | Why |
| --- | --- | --- | --- |
| SSL/TLS encryption mode | SSL/TLS → Overview | **Full (strict)** | Belt and braces: tunnel traffic is already encrypted edge-to-`cloudflared`, so this mostly prevents a redirect loop and keeps any future non-tunnel record honest |
| Always Use HTTPS | SSL/TLS → Edge Certificates | **On** | An `http://` request is redirected at the edge instead of reaching the app |
| HSTS | SSL/TLS → Edge Certificates | **Off** | A foot-gun before a setup has settled: the `max-age` sticks in browsers and can't be recalled |
| Bot Fight Mode | Security → Bots | **Off** | It challenges non-browser requests, which reaches Turbo requests and the `/up` health check. Budgie is invite-only already |
| Caching | Caching → Configuration | **Default** | Default caching plus `Set-Cookie` is how one user's page reaches another. Verified below |
| Universal SSL | SSL/TLS → Edge Certificates | **On** (the default) | The certificate both hostnames are served with |

## 6. Prove the isolation

The headline property of all this is that a host answers on its hostname and not on its IP address.
At this stage nothing is listening on port 80, so "the IP doesn't answer" would be true for the boring reason that there's nothing to answer.
A throwaway origin makes the check mean something, and it's easier to do with nothing real in the way.

Run this on **each** host, with its own IP address.

**The control: published on every interface, the IP answers.**

```sh
ssh deploy@budgie-testing 'docker run -d --name origin-test -p 80:80 nginx:alpine'
ssh deploy@budgie-testing 'sudo ss -tlnp | grep :80'
curl -sS -m 10 -o /dev/null -w '%{http_code}\n' http://<testing ip>/
curl -sS -o /dev/null -w '%{http_code}\n' https://testing.budgiebuddie.com/
```

```
LISTEN 0  4096  0.0.0.0:80  0.0.0.0:*  users:(("docker-proxy",...))
200
200
```

That `200` from the raw IP is the part to take seriously: **ufw is active and denying inbound the whole time.**
Docker writes its own iptables rules, so a published port is reachable from the internet while `ufw status` still says `deny (incoming)`.
Kamal 2's `kamal-proxy` publishes 80 and 443 on `0.0.0.0` by default, which is exactly this.

**The check: bound to loopback, the IP doesn't answer and the hostname still does.**

```sh
ssh deploy@budgie-testing 'docker rm -f origin-test'
ssh deploy@budgie-testing 'docker run -d --name origin-test -p 127.0.0.1:80:80 nginx:alpine'
ssh deploy@budgie-testing 'sudo ss -tlnp | grep :80'
curl -sS -m 10 -o /dev/null -w '%{http_code}\n' http://<testing ip>/
curl -sS -o /dev/null -w '%{http_code}\n' https://testing.budgiebuddie.com/
```

```
LISTEN 0  4096  127.0.0.1:80  0.0.0.0:*  users:(("docker-proxy",...))
curl: (28) Connection timed out after 10001 milliseconds
200
```

`-p 127.0.0.1:80:80` is precisely what `proxy.run.bind_ips` in `config/deploy.yml` makes Kamal do for `kamal-proxy`, and [Deploying](deployment.md#verify) runs this check again against the real app.

**Leave the loopback-bound origin running.** Section 7 needs something answering behind each tunnel; section 8 tears it down at the end.

> If the hostname 502s while something *is* listening on `127.0.0.1:80`, the host is resolving `localhost` to `::1` and the proxy is only on IPv4. Change the tunnel's ingress URL to `127.0.0.1:80`.

## 7. Verify

From your laptop, **with the loopback-bound origin from section 6 still running on both hosts**. This is what finished looks like.

Every check below that expects a `200`, a header set by a rule, or a cache status needs a real response coming back through the tunnel.
With nothing behind the tunnel, Cloudflare generates the 502 itself, and a response Cloudflare generates doesn't go through your response-header rules: `x-robots-tag` and `cf-cache-status` come back empty and the redirect checks still pass, which looks like a broken rule and isn't one.

**The names resolve to Cloudflare, and the zone is Cloudflare's.**

```sh
dig +short NS budgiebuddie.com
```

```
ana.ns.cloudflare.com.
bob.ns.cloudflare.com.
```

The two names are whatever Cloudflare assigned the account; what matters is that they're Cloudflare's.

```sh
dig +short budgiebuddie.com
dig +short testing.budgiebuddie.com
```

```
104.21.x.x
172.67.x.x
```

Cloudflare anycast addresses for both, and a VPS address for neither. If a VPS address appears here, that record is grey-clouded.

**Both hostnames are served by Cloudflare over HTTPS.**

```sh
curl -sSI https://budgiebuddie.com/ | grep -iE '^(HTTP|server|cf-ray)'
curl -sSI https://testing.budgiebuddie.com/ | grep -iE '^(HTTP|server|cf-ray)'
```

```
HTTP/2 200
server: cloudflare
cf-ray: 8f0e2b1c0a7e1234-YYZ
```

**With a certificate Cloudflare issued, not one you configured.**

```sh
openssl s_client -connect budgiebuddie.com:443 -servername budgiebuddie.com </dev/null 2>/dev/null |
  openssl x509 -noout -issuer -dates
```

```
issuer=C=US, O=Google Trust Services, CN=WE1
notBefore=...
notAfter=...
```

Universal SSL issues through Google Trust Services or Let's Encrypt, depending on the zone; either is Cloudflare's, which is the point.

**`http://` is redirected, and HSTS is not set.**

```sh
curl -sSI http://budgiebuddie.com/ | grep -iE '^(HTTP|location)'
curl -sSI https://budgiebuddie.com/ | grep -i strict-transport-security
```

```
HTTP/1.1 301 Moved Permanently
location: https://budgiebuddie.com/
```

Against the throwaway origin, the second command prints nothing.
Once the app is deployed it prints `strict-transport-security: max-age=0; includeSubDomains`, which is HSTS turned *off*: Rails always sends the header, and `hsts: false` makes it `max-age=0`. See [Deploying](deployment.md#verify).
Any larger `max-age` means HSTS got turned on somewhere.

**`www` redirects to the apex.**

```sh
curl -sSI https://www.budgiebuddie.com/ | grep -iE '^(HTTP|location)'
```

```
HTTP/2 301
location: https://budgiebuddie.com/
```

**Testing says `noindex`, and production doesn't.**

```sh
curl -sSI https://testing.budgiebuddie.com/ | grep -i x-robots-tag
curl -sSI https://budgiebuddie.com/ | grep -i x-robots-tag
```

```
x-robots-tag: noindex
```

The second prints nothing.

If *both* print nothing, check what the response actually is: `curl -sSI https://testing.budgiebuddie.com/ | head -1`.
On a `502` the throwaway origin isn't running, and Cloudflare's own error page never carries this header however right the rule is.

**Nothing is being cached that shouldn't be.**

```sh
curl -sSI https://testing.budgiebuddie.com/ | grep -i cf-cache-status
```

```
cf-cache-status: DYNAMIC
```

`DYNAMIC` means the edge didn't consider it cacheable at all. [Deploying](deployment.md#verify) checks it again against a real signed-in page, which is the case that actually matters.

**The tunnel is running on both hosts and starts itself at boot.**

```sh
ssh deploy@budgie-testing 'systemctl is-active cloudflared; systemctl is-enabled cloudflared'
```

```
active
enabled
```

In Zero Trust, **Networks → Tunnels** shows both tunnels HEALTHY with one connector each.

**The self-updater is off.**

```sh
ssh deploy@budgie-testing "systemctl show -p ExecStart --value cloudflared | grep -o -- '--no-autoupdate'"
```

```
--no-autoupdate
```

Grep rather than print: the full `ExecStart` has the token in it.
`cloudflared` otherwise checks for updates and restarts itself, unattended, on the one component that makes the host reachable.

**…but apt will still keep it current.**

```sh
ssh deploy@budgie-testing 'apt-config dump | grep -iE "Allowed-Origins|Origins-Pattern"'
```

```
Unattended-Upgrade::Allowed-Origins "";
Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-security";
Unattended-Upgrade::Allowed-Origins:: "${distro_id}ESMApps:${distro_codename}-apps-security";
Unattended-Upgrade::Allowed-Origins:: "${distro_id}ESM:${distro_codename}-infra-security";
Unattended-Upgrade::Origins-Pattern "";
Unattended-Upgrade::Origins-Pattern:: "origin=cloudflared,site=pkg.cloudflare.com";
```

The security pockets from `provision.sh`, plus Cloudflare's repository and nothing else. That repository publishes only `cloudflared`, so allowing it can't drag in an unrelated package.

It has to be an `Origins-Pattern` and not another `Allowed-Origins` line: `pkg.cloudflare.com`'s `Release` file has no `Suite:` field, so apt reports an empty archive for it, and an `origin:archive` pair would match nothing at all while looking perfectly correct.

A `cloudflared` upgrade replaces the binary but doesn't restart the running tunnel. The 04:00 UTC reboot picks it up, or `sudo systemctl restart cloudflared` does.

**The firewall is untouched, and nothing is listening on the web ports.**

```sh
ssh deploy@budgie-testing 'sudo ufw status verbose'
ssh deploy@budgie-testing 'sudo ss -tlnp'
```

`ufw status verbose` is exactly what it was after provisioning — default deny inbound, one rate-limited SSH rule, nothing added.
`ss -tlnp` shows `0.0.0.0:22`, whatever `systemd-resolved` binds on `127.0.0.x:53`, and nothing on `0.0.0.0:80` or `0.0.0.0:443`.

`cloudflared` appears in neither: it makes an *outbound* connection to Cloudflare's edge on TCP and UDP 7844.
If an outbound deny policy is ever added to ufw, it has to allow 7844.

**Re-running the script changes nothing.**

```sh
ssh deploy@budgie-testing 'sudo bash cloudflare-tunnel.sh' < token.txt
```

```
== Summary
   no changes: this host already runs this tunnel
```

**It all survives a reboot.** The host reboots itself at 04:00 UTC when an update needs it, so check now rather than finding out then:

```sh
ssh deploy@budgie-testing 'sudo reboot'
# wait a minute
ssh deploy@budgie-testing 'systemctl is-active cloudflared'
curl -sS -o /dev/null -w '%{http_code}\n' https://testing.budgiebuddie.com/
```

The tunnel is active again with nothing done to it, and the hostname answers.

## 8. Tear the throwaway origin down

Once section 7 passes on both hosts:

```sh
ssh deploy@budgie-testing 'docker rm -f origin-test'
ssh deploy@budgie-testing 'sudo ss -tlnp | grep :80 || echo "nothing on 80"'
curl -sS -o /dev/null -w '%{http_code}\n' https://testing.budgiebuddie.com/
```

```
nothing on 80
502
```

A 502 from the hostname is the correct end state for this page: the tunnel is up and there's nothing behind it yet.
[Deploying](deployment.md) is what puts the app there.

## 9. What the app does because it's behind Cloudflare

Being behind Cloudflare and a tunnel is what several of the app's settings are for. They're listed here so
that the whole arrangement can be read in one place:

- **`kamal-proxy` binds loopback only**, so `cloudflared` reaches it at `http://localhost:80` and the raw
  VPS IP never answers. It's `proxy.run.bind_ips` in [`config/deploy.yml`](../config/deploy.yml) rather than
  `kamal proxy boot_config set --publish-host-ip 127.0.0.1`, which Kamal 2.12 deprecates, so the proxy's
  very first boot is already bound to loopback and there's no per-host step to forget.
  [Deploying](deployment.md#verify) repeats section 6's direct-IP check against the real app.
- **`config.assume_ssl` and `config.force_ssl`** in [`production.rb`](../config/environments/production.rb),
  with `/up` excluded from the redirect through `config.ssl_options`. `ssl_options` also sets `hsts: false`,
  which sends `max-age=0`: HSTS stays off, as section 5 decided.
- **`config.hosts`** pinned to `budgiebuddie.com` and `testing.budgiebuddie.com`, with `/up` excluded from
  host authorization, in [`production.rb`](../config/environments/production.rb).
- **`config.action_mailer.default_url_options`** comes from each destination's `APP_HOST`, so links in
  email point at the hostname that destination is served as.
- **`proxy: { ssl: false }`** in [`config/deploy.yml`](../config/deploy.yml), with each destination's `host`
  in its own file. Kamal issues no certificate: TLS-ALPN-01 needs inbound 443 reaching the host directly,
  which this design deliberately prevents, and HTTP-01 through the edge is fragile and pointless when
  Cloudflare already terminates TLS.
- **Real client IPs, with no app code.** `forward_headers: true` in
  [`config/deploy.yml`](../config/deploy.yml) passes Cloudflare's `X-Forwarded-For` through `kamal-proxy`,
  and Rails' default trusted proxies skip the loopback and Docker addresses the hops add.
  [Deploying](deployment.md#verify) checks a log line against the address Cloudflare saw.
- **One Google OAuth client per environment**, with callbacks on each hostname. See
  [Google OAuth setup](google-oauth.md#testing-and-production).
- **Zedmail's two CNAMEs, DNS only.** See [below](#zedmails-dns-records).

## Zedmail's DNS records

[Zedmail](email.md#production-zedmail) sends Budgie's email from `budgiebuddie.com`, and verifies the domain through two CNAME records it issues when you add the domain.
In **DNS → Records**, add both exactly as Zedmail shows them, with the proxy status **DNS only** (grey cloud):

| Type | Name | Target | Proxy |
| --- | --- | --- | --- |
| `CNAME` | *(Zedmail's first name)* | *(Zedmail's first target)* | DNS only (grey) |
| `CNAME` | *(Zedmail's second name)* | *(Zedmail's second target)* | DNS only (grey) |

**Not proxied.** Every record from the sections above is orange, and the dashboard offers orange by default. A proxied CNAME resolves to Cloudflare's own addresses instead of to Zedmail's target, so Zedmail's verification fails, and DKIM with it.
Grey is safe for these two: they point at Zedmail, not at a host, so they can't reveal an origin IP.

Once Zedmail shows the domain as verified, write the two names and targets into the table above, so the records can be rebuilt from this page like everything else.

## Rebuilding a tunnel

If a host is rebuilt, provision it again and re-run `cloudflare-tunnel.sh` with the same token from your password manager. Nothing in Cloudflare changes: the tunnel, its hostname and its DNS record are all server-side.

If a token needs replacing, the tunnel's page in Zero Trust shows it again and can refresh it; a refreshed token means re-running the script on that host.
Deleting the tunnel and creating a new one also works, but the DNS record has to be pointed at the new tunnel, so prefer refreshing.

Cloudflare's dashboard moves things around from time to time. What matters is the set of values in the tables above, not the path through the menus.
