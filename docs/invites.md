# Invites and users

Only invited email addresses can create an account.
Google proves who someone is, and a pending invite for that exact address lets their first sign-in create their Budgie user.
The address is compared after trimming and lowercasing only, so Gmail dot and plus aliases don't match.
There's no admin page: manage invites and users with these tasks.

## Managing invites

| Task | Command |
| --- | --- |
| Invite someone and email them | `docker compose run --rm web bin/rails invite:create EMAIL=someone@example.com` |
| Send a pending invite again | `docker compose run --rm web bin/rails invite:resend EMAIL=someone@example.com` |
| Revoke a pending invite | `docker compose run --rm web bin/rails invite:revoke EMAIL=someone@example.com` |
| List invites | `docker compose run --rm web bin/rails invite:list`, optionally with `STATUS=pending`, `accepted` or `revoked` |

Each task prints what it did, or exits non-zero with the reason it refused.
The same operations are available in `bin/rails console` as `Invite.issue!`, `Invite.resend!` and `Invite.revoke!`.

## Invite rules

- An invite is **pending** until its address signs in for the first time, when it becomes **accepted**. Pending invites never expire.
- `invite:create` refuses an address with a pending invite (use `invite:resend`) and an address that's already a user.
  For a revoked address it invites them again, as if newly invited.
- Only pending invites can be revoked. Revoking doesn't remove an existing user's access; [delete the user](#deleting-a-user) instead.
- Invites are only checked when an account would be created, so existing users sign in whatever their invite's state.

## The invite email

The invite email links to the sign-in page and asks the person to sign in with that exact address.
In development it isn't delivered: read it at http://localhost:3000/letter_opener.
See [Email](email.md) for how it's sent in production.

## Deleting a user

```sh
docker compose run --rm web bin/rails user:delete EMAIL=someone@example.com
```

The task shows what it will delete and asks you to type the email to confirm.
It permanently deletes the user, their identities, their sessions (which signs them out), their budget and its envelopes, and their invite, so the address can be invited again with `invite:create`.
This is handy for testing invites with an account you've already signed in with.
