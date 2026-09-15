# Email

Budgie sends email immediately rather than through a background job, so whoever triggered it sees whether sending worked.
The only email so far is the [invite](invites.md#the-invite-email).

## Development

Emails aren't delivered. [letter_opener_web](https://github.com/fgrehm/letter_opener_web) saves them instead, and you can read them at http://localhost:3000/letter_opener.
The sender is `MAILER_FROM` if it's set, otherwise `no-reply@localhost`.

## Production (Zedmail)

Production sends through SMTP, configured with `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` and `MAILER_FROM`.
The settings are generic SMTP, so switching providers only means changing those variables.

Budgie uses [Zedmail](https://zedmail.com/)'s SMTP relay.
Its public site doesn't document the relay's hostname or username, so copy those from the Zedmail dashboard.

1. [Create a Zedmail account](https://zedmail.com/register.php).
2. Add Budgie's sending domain and publish the two CNAME records Zedmail gives you. Zedmail handles DKIM, SPF and DMARC from those.
3. Generate an API key in the dashboard. It's also the SMTP password.
4. New accounts start in sandbox mode, which only delivers to verified test addresses. Ask Zedmail to move the account to production before inviting anyone else.
5. Set the production environment variables:
   - `SMTP_ADDRESS`: the relay hostname from the dashboard
   - `SMTP_PORT`: `587` (the default). Budgie requires STARTTLS on it.
   - `SMTP_USERNAME`: the relay username from the dashboard
   - `SMTP_PASSWORD`: the API key. Keep it secret.
   - `MAILER_FROM`: an address on the verified domain, such as `Budgie <no-reply@yourdomain.ca>`. Production refuses to send without it.
6. Send yourself an invite with `invite:create` and confirm it shows as delivered in the Zedmail dashboard.
