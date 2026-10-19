# Accounts: what is built, and the plan for the rest

One Palmy account (a Supabase auth user) owns several identities
(`public.identities`). This note records how the account side works today and
designs, without building, the parts that are not there yet: recovery,
passkeys, two-step verification, where the backend runs, and signing in to the
machine itself with the account.

## What is built

| piece | where |
| --- | --- |
| schema, RPCs, hook | `cloud/supabase/migrations/20261019110000_accounts.sql` |
| pgTAP (70 assertions) | `cloud/supabase/tests/accounts_*.sql` |
| local stack | `cloud/dev/` (`up.sh`, `test.sh`, `smoke.sh`) |
| Odin client | `apps/cloudkit/` |
| app and CLI | `apps/accounts/` (`accounts <verb> --json`) |

### Scoped sessions

The contract fixes the claim (`palm_identity`) and leaves the minting to
accounts. A scoped session is an ordinary GoTrue session that the database
has bound to one identity:

1. The person's own, unscoped session calls
   `mint_scoped_session(identity, name, kind, expires_in_seconds)`. It refuses
   a scoped caller (no widening, and no copying of a scope either), an identity
   the caller does not own, and an archived one.
2. In one transaction it inserts a row into `auth.sessions`, a refresh token
   into `auth.refresh_tokens` in GoTrue's own format, and a `public.devices`
   row naming the identity. It returns the refresh token once.
3. Whoever holds the token exchanges it at
   `/auth/v1/token?grant_type=refresh_token`. GoTrue calls
   `public.custom_access_token_hook` for every token it issues; the hook finds
   the device row by `session_id` and writes `palm_identity`. A session with no
   device row has the claim removed, so a claim cannot arrive any other way.
   Every later refresh goes through the hook again, so the scope is permanent
   for the life of the session.
4. Revoking deletes the GoTrue session (its refresh tokens go with it), and
   `public.palm_pre_request`, which PostgREST runs before every request,
   refuses a token whose session no longer exists. Revocation is therefore
   immediate rather than "within the hour". Archiving an identity ends every
   session scoped to it.

The invariant the scope rests on: a scoped session never exists without its
device row. Both are created together before any token can be issued, the
device's identity and session cannot be changed, and deleting a device row
deletes its session.

What GoTrue does not know about identities, the gateway says: a token carrying
`palm_identity` may refresh, sign out and read `/auth/v1/user`, and nothing
else under `/auth/v1` (`cloud/dev/kong.yml.in`). Without that, an assistant
holding a scoped token could change the account's password and come back
unscoped.

On the client, `PALM_IDENTITY=<handle>` selects the session this machine holds
for that identity (`scoped/<handle>.json`); there is no fallback to the
person's session. `accounts switch` creates that session; `accounts delegate`
mints one to hand to an assistant, stored apart under `delegated/` and given to
it as `PALM_CLOUD_SESSION=<file>`.

### Account-level data

Devices and sessions are account information, not an identity's. They are
read and changed only through security-definer functions that refuse scoped
callers (`list_sessions`, `end_session`, `mint_scoped_session`,
`revoke_device`), which is the same rule the contract's `identities_insert`
policy uses. `public.devices` itself is identity-scoped and read through
`can_access_identity`, as the contract requires.

## Account recovery

Recovery is the place an attacker goes once passwords are hard, so the design
starts from what must not happen: recovery must not be easier than signing in,
and it must not route through an identity's own mail, because the person may
have lost exactly that identity (a job ends; the work mailbox goes with it).

- **Recovery email outside Palmy.** The account's GoTrue email is the
  recovery address and is deliberately *not* one of the identities'
  `@palm.test` addresses; sign-up asks for an outside address. GoTrue's
  `/recover` sends the link. This is the baseline and needs only SMTP
  configured (planned through Resend, like outbound mail).
- **Recovery codes.** Ten single-use codes generated when two-step
  verification is enrolled, shown once, stored hashed (argon2id) in an
  account-level table only a security-definer function reads. A code replaces
  the second factor, never the password.
- **A recovery contact.** Another Palmy account the person names in
  advance. A recovery request notifies the person on every live session and
  waits (72 hours by default) before the contact can approve it; the person
  can cancel from any session in that window. This is the answer for someone
  who has lost the password, the device and the outside email at once.
- **What recovery resets.** The password, every unscoped session, and the
  second factor. Delegated scoped sessions survive by default (an assistant
  should not stop because its owner forgot a password) but are listed for
  review on first sign-in afterwards, with "revoke all" one click away.

## Passkeys

GoTrue 2.19x has WebAuthn behind `[auth.passkey]` (off in config.toml). The
browser half of WebAuthn is the hard part on a desktop with no browser, so the
plan is:

- **Security keys** over CTAP2 on `hidraw`: a small Odin implementation of the
  CTAP2 `makeCredential`/`getAssertion` exchange, beside cloudkit. The
  relying-party id is the account domain (`palmy.org` or the self-hosted
  one), never `localhost`.
- **A platform passkey** for the machine itself: a key generated in the TPM
  (`/dev/tpmrm0`) when present, otherwise in the vault app's store sealed by
  the login password. It signs WebAuthn assertions the same way a security
  key does, so the server cannot tell them apart and needs nothing special.
- The **greeter** is the natural place to use it (below).
- cloudkit gains `passkey_register` and `passkey_sign_in`; Accounts' Security
  page lists keys with their last use, and removing the last one requires the
  password.

## Two-step verification

GoTrue's TOTP factors (`[auth.mfa.totp]`) raise a session from `aal1` to
`aal2`. The plan:

- Enrolment from Accounts: QR code drawn by palmy, the secret also shown as
  text, recovery codes generated at the same moment.
- **The full account requires aal2 once a factor exists.** Account-level
  functions check `auth.jwt() ->> 'aal' = 'aal2'` when the user has a verified
  factor. Identity data does not: a scoped session is aal1 by construction.
- `mint_scoped_session` requires aal2 when a factor exists, so delegation is
  always done from a fully verified session. A scoped session is then a
  bounded delegation of an aal2 decision, which is what we want an assistant
  to hold, not a way around the second factor.
- The gateway already refuses `/auth/v1/factors` to scoped tokens, so an
  assistant cannot enrol or remove a factor.

## Hosted Supabase or self-hosted

Everything here runs unchanged on either, with three caveats, all in the
accounts migration:

1. `mint_scoped_session` writes to `auth.sessions` and `auth.refresh_tokens`.
   The hosted platform has been restricting what the `postgres` role may do in
   the `auth` schema; DML on these tables works today and is what seed scripts
   rely on, but it is the most fragile dependency here. The fallback is an
   edge function holding the service key that calls GoTrue's admin API, or a
   GoTrue fork with a token-exchange grant (see open questions).
2. `alter role authenticator set pgrst.db_pre_request` is allowed on hosted
   projects; it is how Supabase documents pre-request functions.
3. **The gateway rule cannot be expressed on hosted Supabase**, which has no
   configurable gateway. This was checked, not assumed: under the stock CLI
   gateway (`supabase start`, same migrations) `cloud/dev/smoke.sh` passes
   21 of 25, and the four failures are this hole. A freshly minted scoped
   token's `PUT /auth/v1/user {"password": ...}` returns 200, changes the
   account password and signs the person out everywhere.
   `secure_password_change = true` (now on in config.toml) does not close it
   alone, because GoTrue skips reauthentication for sessions created in the
   last 24 hours, which a just-minted session always is. Measured on the CLI
   stack: with the minted session's `created_at` backdated by 25 hours, the
   same request gets `400 reauthentication_needed`, and an email change
   only starts the double confirmation (`double_confirm_changes`), which
   needs the old, outside address. So hosted needs either a thin proxy in
   front (a Cloudflare Worker, or this Lua on a Kong we run), or
   `mint_scoped_session` backdating `auth.sessions.created_at`. The second
   works today but leans on a GoTrue internal and on no session timebox
   being configured. The proxy is the recommended fix.

Cost, from Supabase's published pricing as last checked (verify before
deciding): the Free tier pauses projects after a week without traffic and is
not usable for a product; Pro is about $25 per month per organisation with
roughly 100k monthly active users, 8 GB of database and 100 GB of file
storage included, then usage-based (file storage around $0.02 per GB-month,
egress around $0.09 per GB). Drive is the line that grows: at 50 GB per person,
storage dominates every other cost from the first few hundred users. Compute
upgrades are separate and are needed well before the MAU limit, since mail
and drive both write heavily.

Self-hosted (the same images as `cloud/dev`, on a dedicated server at roughly
€40–80 per month for 8–16 cores, 64 GB RAM and 1–2 TB NVMe at Hetzner or OVH)
is cheaper per GB by an order of magnitude and makes the gateway rule
trivial, at the price of running Postgres: backups with point-in-time
recovery (WAL-G to object storage), major-version upgrades, GoTrue and Kong
security updates, and an on-call person.

Data residency: a hosted project lives in one region chosen at creation
(Frankfurt, London, Paris, Stockholm and Zurich in Europe, among others), and
all of it lives there. Per-person residency means one project per region with
the account pinned to one at sign-up; identities cannot then span regions,
which matches the product (an identity belongs to one account). Self-hosting
gives the same choice with any provider, including one in the person's own
jurisdiction.

**Recommendation:** develop and run the beta on hosted Pro in an EU region
with a small proxy in front for the gateway rule; plan the move to self-hosted
before Drive has real users, because storage cost decides it, and because the
contract's whole claim is enforced by our own Postgres policies, which move
with a `pg_dump`.

## Signing in to the machine with the account

Today the greeter (`apps/greeter`) talks to greetd, which authenticates a
local Unix user through PAM. The plan keeps that shape and adds the account
underneath it, offline-first:

- **Binding.** Accounts offers "Use this account to sign in to this machine".
  It stores, root-owned under `/var/lib/palm/accounts/<user>`, the account id,
  an argon2id verifier of the account password, and the cloud URL. The local
  Unix password is set to the same password, so nothing about PAM's existing
  modules changes.
- **`pam_palm`**, a PAM module (Odin, `-build-mode:shared`), sits after
  `pam_unix`. When the network is up it verifies the password with GoTrue's
  password grant, updates the verifier if the password changed elsewhere, and
  hands the resulting session to the user's session through a root-owned,
  single-use handoff file that a user service moves into
  `~/.local/share/palm/cloud` after login. Offline it accepts the cached
  verifier, and the cloud session is established later by Accounts.
- **Password changed on another machine.** The next online login with the old
  password fails at GoTrue, `pam_palm` reports it in the greeter's banner, and
  the new password is accepted once GoTrue confirms it, updating both the
  verifier and the local Unix password.
- **Passkey at the greeter.** With the platform passkey above, the greeter can
  offer "Sign in with this machine's key": an assertion verified locally
  against the bound public key unlocks the session offline, and against
  GoTrue online. This is the end state; the password path comes first.
- **First boot.** The installer offers "Sign in with a Palmy account",
  creates the local user from the account (name from the personal identity,
  login name from its handle) and does the binding in one step.
- **What the greeter itself never does:** it never holds a token. It runs as
  the greeter user and only relays the password to greetd, as it does now.

## Contract questions (raised, not changed)

- **Account-level tables.** The contract says every table holding a person's
  data has `identity_id`. Sessions, recovery codes and passkeys belong to the
  account, not an identity. Accounts keeps them behind security-definer
  functions that refuse scoped sessions; the contract could say so explicitly
  ("account-level data: unscoped sessions only, through functions").
- **Handles are permanent.** Accounts makes `handle` immutable, because it is
  the mail address. Mail may want an alias mechanism instead of renames.
- **The gateway rule** is part of what makes scoped sessions safe, but lives
  outside the database. The contract should name it, so hosted deployments do
  not silently drop it.
