# The Palmframe cloud contract

The account, mail and drive pieces are built in parallel against this file.
It is short on purpose: what every piece must agree on, and nothing else.

## Layout

```
cloud/
  supabase/            the Supabase project (CLI 2.118.0: npx supabase@2.118.0)
    config.toml        owned by accounts
    migrations/        one timestamp range per area, see below
    tests/             pgTAP tests, one file prefix per area
  mail/                the mail server (owned by mail)
  drive/               the drive service and sync daemon (owned by drive)
  forge/               the git forge server (owned by forge)
  dav/                 the CalDAV/CardDAV server (owned by calendar & contacts)
  docs/                product and design notes (owned by product)
apps/accounts/         sign-in, identities, switcher (owned by accounts)
apps/cloudkit/         Odin client for Supabase: auth, PostgREST, Storage (owned by accounts)
apps/drive/            the drive app (owned by drive)
apps/home/             the unified hub prototype (owned by product)
apps/browser/          the browser, bookmarks synced per identity (owned by browser)
apps/forge/            the forge client (owned by forge)
apps/calendar/         calendar, synced per identity (owned by calendar & contacts)
apps/contacts/         contacts (owned by calendar & contacts)
```

Migration file names are `<timestamp>_<name>.sql`. The ranges are:

| Area     | Timestamps                     | pgTAP prefix |
|----------|--------------------------------|--------------|
| contract | `20261019100000`               | —            |
| accounts | `20261019110000`–`20261019199999` | `accounts_` |
| mail     | `20261019200000`–`20261019299999` | `mail_`     |
| drive    | `20261019300000`–`20261019399999` | `drive_`    |
| browser  | `20261019400000`–`20261019499999` | `browser_`  |
| forge    | `20261019500000`–`20261019599999` | `forge_`    |
| dav      | `20261019600000`–`20261019699999` | `dav_`      |

## Identities

A person has one Supabase auth user and several **identities**
(`public.identities`): personal, work, public, project. Each has a unique
`handle`, which is also its mail local part: `<handle>@<mail domain>`.

**Every table holding a person's data has `identity_id uuid not null
references public.identities` and an RLS policy that goes through
`public.can_access_identity(identity_id)`.** No other access rule. A policy
that checks `auth.uid()` directly, or a table without RLS, is a bug.

`can_access_identity` is true when the caller owns the identity, it is not
archived, and the session is either unscoped or scoped to that identity. A
scoped session carries the JWT claim `palm_identity`: an assistant, or a
device, acting for one identity. **The test the whole design is held to:** a
session scoped to identity A, asking for identity B's rows, gets nothing, and
writing them fails. Each area has a pgTAP test that asserts this for its own
tables.

How scoped tokens are minted (a custom access token hook, a token exchange
endpoint) is the accounts area's to decide; the claim name is fixed.

## Sharing

Crossing between identities is a deliberate act. When an area needs it
(a file shared from work to personal), it is an explicit row in that area's
own share table, created by the source identity, and the policy on the
target side reads that row. There is no ambient cross-identity access.

## Mail

The mail domain is configurable; local development uses `palm.test`.
Delivery between local identities is real. **There is no outbound delivery
to the internet**; outbound and inbound internet mail are planned through
Resend and are designed, not built.

## Running locally

One stack per worktree. Agents working in parallel run a scratch copy of
`cloud/supabase` with its own `project_id` and ports shifted, so the stacks
do not collide; the committed `config.toml` keeps project `palmframe` on the
default ports.
