# Email

Budgie sends email immediately rather than through a background job, so whoever triggered it sees whether sending worked.
The only email so far is the [invite](invites.md#the-invite-email).

## Development

Emails aren't delivered. [letter_opener_web](https://github.com/fgrehm/letter_opener_web) saves them instead, and you can read them at http://localhost:3000/letter_opener.
The sender is `MAILER_FROM` if it's set, otherwise `no-reply@localhost`.

## Production (Zedmail)

Testing and production send through SMTP, configured with `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` and `MAILER_FROM`.
The settings are generic SMTP, so switching providers only means changing those variables.

Budgie uses [Zedmail](https://zedmail.com/)'s SMTP relay, with one account and one sending domain, `budgiebuddie.com`, for both environments.
The Zedmail dashboard shows the relay's settings under **SMTP Relay** (its Option 2; Budgie doesn't use Zedmail's own API).

### The settings

| Zedmail's setting | Value | Where it goes |
| --- | --- | --- |
| Host | `mail.zedmail.com` | `SMTP_ADDRESS` in `config/deploy.yml`, already set |
| Port | `2587`, with STARTTLS | `SMTP_PORT` in `config/deploy.yml`, already set |
| Username | The email address you log in to Zedmail with | `TESTING_SMTP_USERNAME` in `.env.testing` and `PRODUCTION_SMTP_USERNAME` in `.env.production`, the same address in both |
| Password | An API key, which starts with `ses_` | `TESTING_SMTP_PASSWORD` in `.env.testing` and `PRODUCTION_SMTP_PASSWORD` in `.env.production` |

The sender, `MAILER_FROM`, is set per destination: `Budgie Testing <no-reply@budgiebuddie.com>` in `config/deploy.testing.yml` and `Budgie <no-reply@budgiebuddie.com>` in `config/deploy.production.yml`.
It has to be an address on the verified domain, and the app refuses to send without it.

**Port 2587, not 465.** Zedmail offers two ports, and Budgie uses the STARTTLS one.
The SMTP settings in `config/environments/production.rb` connect in plain text, switch to TLS with STARTTLS before logging in, and refuse to send if the server doesn't offer it, so nobody in between can make them send in the clear.
Port 465 is TLS from the first byte instead, which would need `tls: true` in place of `enable_starttls: true` there.
Zedmail's dashboard lists neither 587, the usual submission port, nor 25, so don't use either.

The username and the keys go in the gitignored env files, like every other secret, rather than in `config/deploy.yml`.
The username is only your login address, but it's personal, so it stays out of git with the keys.

### Setting it up

1. [Create a Zedmail account](https://zedmail.com/register.php).
2. Add `budgiebuddie.com` as the sending domain, and publish the two CNAME records Zedmail gives you in Cloudflare as **DNS only**. See [Cloudflare](cloudflare.md#zedmails-dns-records): a proxied record breaks Zedmail's verification.
   Zedmail handles DKIM, SPF and DMARC from those records. Wait for the dashboard to show the domain as verified.
3. Generate an API key per environment, one for testing and one for production. Each starts with `ses_`, and it's that environment's SMTP password.
   Separate keys mean a leaked testing key can be revoked without breaking production's mail.
   If Zedmail only allows one key per account, both environments use it, and revoking it stops both.
4. Add the username and keys to the env files, and to your password manager. See [Deploying](deployment.md#the-secrets-1) for the files, and the same section for the matching GitHub environment secret CI reads instead.

   ```
   # .env.testing
   TESTING_SMTP_USERNAME=<your Zedmail login email>
   TESTING_SMTP_PASSWORD=<the testing key, ses_...>

   # .env.production
   PRODUCTION_SMTP_USERNAME=<your Zedmail login email>
   PRODUCTION_SMTP_PASSWORD=<the production key, ses_...>
   ```

5. New accounts start in sandbox mode, which only delivers to verified test addresses. Ask Zedmail to move the account to production before inviting anyone but yourself.
6. Check that each host can reach the relay on port 2587, and that the relay's certificate checks out:

   ```sh
   ssh deploy@budgie-testing 'openssl s_client -starttls smtp -connect mail.zedmail.com:2587 -verify_hostname mail.zedmail.com -brief </dev/null'
   ssh deploy@budgie-production 'openssl s_client -starttls smtp -connect mail.zedmail.com:2587 -verify_hostname mail.zedmail.com -brief </dev/null'
   ```

   Each prints a few lines about the connection, including:

   ```
   CONNECTION ESTABLISHED
   Verification: OK
   ```

7. Once the destination is [deployed](deployment.md), send yourself an invite, and confirm it shows as delivered in the Zedmail dashboard:

   ```sh
   docker compose run --rm kamal task invite:create EMAIL=you@example.com -d testing
   ```

   ```
   Invited you@example.com.
   ```

### When sending fails

The task stops with the SMTP error. The invite is saved before the email is sent, so once the problem is fixed, send it with `invite:resend`, since `invite:create` refuses an address with a pending invite.

| Error | Cause |
| --- | --- |
| `Net::SMTPAuthenticationError` with `535` | The username or the key is wrong |
| `Net::OpenTimeout` or `OpenSSL::SSL::SSLError` | The host can't reach the relay properly. Run the check in step 6 |
| `Net::SMTPFatalError` about the sender | `MAILER_FROM` isn't on a verified domain, or the domain isn't verified yet |
| Delivered for you, but not for anyone else | The account is still in sandbox mode |

A fixed env file only reaches the app when it's deployed again, because Kamal uploads the secrets with every deploy: `docker compose run --rm kamal deploy -d testing`, with `--skip-push` for production.
A redeploy of the same commit restarts the app with the new values.
