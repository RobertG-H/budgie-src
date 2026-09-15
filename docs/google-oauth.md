# Google OAuth setup

Budgie has no passwords. People sign in with Google, so the app needs an OAuth client from Google Cloud.
Each environment has its own client; these steps create the one for local development.

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

Leave the publishing status on **Testing**.
You don't need to add test users: Google lets any account sign in to a Testing app that only asks for name, email address and profile, which is all Budgie asks for.

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

## Production

Production needs its own client.
Repeat step 2 with the name **Budgie production** and the redirect URI `https://<production host>/auth/google_oauth2/callback`, then set `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` in the production environment.
Production also needs [SMTP set up](email.md#production-zedmail), or invites can't be sent.
