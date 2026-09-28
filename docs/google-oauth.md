# Google OAuth setup

Budgie has no passwords. People sign in with Google, so the app needs an OAuth client from Google Cloud.
Each environment has its own client in the same Google Cloud project: **Budgie development**, **Budgie testing** and **Budgie production**.

## 1. Create the project and consent screen

You only do this once, for all environments.

1. In the [Google Cloud console](https://console.cloud.google.com/), create a project named **Budgie**.
2. Go to **Google Auth Platform** > **Branding** and click **Get started**.
3. Fill in the steps:
   - **App name:** Budgie
   - **User support email:** your email address
   - **Audience:** External
   - **Contact information:** your email address
4. Agree to the Google API Services User Data Policy and click **Create**.
5. Go to **Google Auth Platform** > **Audience** and click **Publish app**, then confirm. The publishing status changes from **Testing** to **In production**.

While the status is Testing, Google only lets the accounts listed as test users sign in. Budgie's invites decide who gets in, so the app is published instead of keeping a second list of people in Google.
Publishing doesn't send the app to Google for verification, because Budgie only asks for `openid email profile` and has no logo. Keep it that way: adding a logo or a broader scope would.

## 2. Create the development client

1. Go to **Google Auth Platform** > **Clients** and click **Create client**.
2. Set **Application type** to **Web application** and name it **Budgie development**.
3. Under **Authorized redirect URIs**, add `http://localhost:3000/auth/google_oauth2/callback`.
   No JavaScript origins are needed.
4. Click **Create** and copy the client ID and client secret.
   Google shows the secret only once, so copy it before closing the dialog.

A new redirect URI can take a few minutes to start working.

## 3. Give the credentials to the app

```sh
cp .env.example .env
```

Put the client ID and secret in `.env` as `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`, then restart the app with `docker compose up`.
Compose loads `.env` into the `web` container. Git ignores the file, so the secret stays on your machine.

Budgie is invite-only, so invite yourself before your first sign-in. See [Invites and users](invites.md).

## Testing and production

Each deployed environment has its own client, so each one accepts only its own callback URL, and a secret leaked from one environment can be revoked without touching the others.

1. Under **Google Auth Platform** > **Branding**, add `budgiebuddie.com` to **Authorized domains**. Google requires a domain used in a client's redirect URIs to be registered there first.
2. Repeat step 2 twice:

   | Name | Authorized redirect URI |
   | --- | --- |
   | Budgie testing | `https://testing.budgiebuddie.com/auth/google_oauth2/callback` |
   | Budgie production | `https://budgiebuddie.com/auth/google_oauth2/callback` |

3. Put each client's ID and secret in your password manager, in the deploy env files: `TESTING_GOOGLE_CLIENT_ID` and `TESTING_GOOGLE_CLIENT_SECRET` in `.env.testing`, and `PRODUCTION_GOOGLE_CLIENT_ID` and `PRODUCTION_GOOGLE_CLIENT_SECRET` in `.env.production`, and in the matching GitHub environment secret CI reads instead.
   See [Deploying](deployment.md#the-secrets-1).

Only a sign-in by someone who isn't the project's owner proves the publishing status, since the owner may be let in either way. [Deploying](deployment.md#verify) checks it on production with an invited account that isn't yours.

Deployed environments also need [SMTP set up](email.md#production-zedmail), or invites can't be sent.
