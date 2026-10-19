# cloud/dev — the local Supabase stack

This directory runs the images Supabase CLI 2.118.0 uses, every one with
`network_mode: host`, each bound to `127.0.0.1` on a port derived from one
base. It needs no CLI and no Docker bridge network. It was written while
bridge networking was broken on the development host: the CLI's containers
could not reach each other and `supabase start` failed with
`DbConnectError`. That turned out to be the VPN's firewall, not ufw, and it
has since been fixed. `npx supabase@2.118.0 start` works now too, and the
migrations and pgTAP tests pass under it (70 of 70). This stack is still the
one that carries the gateway rule (see the end of this file).

```sh
cloud/dev/up.sh                        # project palmy, API 54321, DB 54322
cloud/dev/test.sh                      # every pgTAP file in cloud/supabase/tests
cloud/dev/test.sh accounts_            # only files starting accounts_
cloud/dev/psql.sh                      # psql as postgres
cloud/dev/down.sh                      # stop, keep data
cloud/dev/down.sh --volumes            # stop and forget everything
cloud/dev/up.sh --reset                # fresh database, then migrate
```

Every script takes `--name X` and `--port-base N`, and they must match
between `up`, `test` and `down` for the same stack. One stack per worktree:

```sh
cloud/dev/up.sh   --name mail --port-base 55521
cloud/dev/test.sh --name mail --port-base 55521 mail_
cloud/dev/down.sh --name mail
```

`PALM_NAME` and `PALM_PORT_BASE` in the environment work as well as the flags.

## Ports

| offset | service | default |
| --- | --- | --- |
| +0 | API gateway (kong): `/auth/v1`, `/rest/v1`, `/storage/v1` | 54321 |
| +1 | Postgres | 54322 |
| +10 | GoTrue | 54331 |
| +11 | PostgREST | 54332 |
| +12 | PostgREST admin | 54333 |
| +13 | Storage | 54334 |
| +14 | Storage admin | 54335 |

A stack occupies base..base+19. `up.sh` refuses to start if any of its ports
is already taken, because with host networking a clash would otherwise only
show up as a container restarting forever.

## What up.sh does

1. Writes `.state/<name>/kong.yml` from `kong.yml.in` with the ports filled in.
2. Starts Postgres (`public.ecr.aws/supabase/postgres:17.6.1.171`). On first
   boot the image runs its own init, then `schema.sql` here, which sets the
   service roles' passwords to `postgres` exactly as the CLI does.
3. Starts GoTrue `v2.197.0`, PostgREST `v16.3`, Storage `v1.77.0` and Kong
   `2.8.1`, and waits for each one's health endpoint. GoTrue and Storage
   create their own schemas as they start.
4. Applies `cloud/supabase/migrations/*.sql` in file-name order, each in one
   transaction, as `postgres`, recording the version in
   `supabase_migrations.schema_migrations`. Re-running applies only new ones.
   Editing an applied migration does nothing; use `--reset`.
5. Tells PostgREST to reload its schema cache and config.

It prints the API URL and the keys. They are the well-known local ones the
CLI prints (JWT secret `super-secret-jwt-token-with-at-least-32-characters-long`,
HS256), so tokens from a CLI-run stack are valid here and vice versa.

## Tests

`test.sh` installs `pgtap` if needed and runs each file in its own `psql`
session. A file should look like:

```sql
begin;
select plan(3);
-- ...
select * from finish();
rollback;
```

A file passes when psql exits 0, every line is `ok`, and the count matches
the plan. Tests impersonate a caller the way PostgREST does:

```sql
set local role authenticated;
set local request.jwt.claims = '{"sub":"<uuid>","role":"authenticated"}';
-- and for a session scoped to one identity:
set local request.jwt.claims = '{"sub":"<uuid>","role":"authenticated","palm_identity":"<uuid>"}';
```

## Differences from `supabase start`

- No Studio, Realtime, Inbucket, edge runtime, analytics or pooler.
  Mail is the mail agent's own server, not Inbucket.
- Email confirmation is off (`GOTRUE_MAILER_AUTOCONFIRM`), as in config.toml.
- GoTrue runs the `custom_access_token_hook` from the accounts migrations,
  matching `[auth.hook.custom_access_token]` in config.toml. A stack built
  from only the contract migration still starts; sign-in then fails until
  the accounts migrations are applied.
- The gateway carries one rule GoTrue cannot: a token scoped to one identity
  (`palm_identity` claim) may only refresh, sign out and read `/user` under
  `/auth/v1`. See `kong.yml.in`.
- `config.toml` remains the description of the hosted and CLI project; when
  the two disagree, `config.toml` is what production should look like and
  this directory should be fixed.
