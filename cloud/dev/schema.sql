-- Runs once, at the end of the image's own init (its migrate.sh looks for
-- /etc/postgresql.schema.sql). It does what the Supabase CLI does: give every
-- service role the local password and record the JWT settings.
\set pgpass `echo "$POSTGRES_PASSWORD"`
\set jwt_secret `echo "$JWT_SECRET"`
\set jwt_exp `echo "$JWT_EXP"`

alter database postgres set "app.settings.jwt_secret" to :'jwt_secret';
alter database postgres set "app.settings.jwt_exp" to :'jwt_exp';

alter user postgres with password :'pgpass';
alter user authenticator with password :'pgpass';
alter user pgbouncer with password :'pgpass';
alter user supabase_auth_admin with password :'pgpass';
alter user supabase_storage_admin with password :'pgpass';
alter user supabase_replication_admin with password :'pgpass';
alter user supabase_read_only_user with password :'pgpass';

create schema if not exists _realtime;
alter schema _realtime owner to postgres;

-- Where up.sh records which migrations it applied, as the CLI does.
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
	version    text primary key,
	name       text,
	statements text[]
);
alter schema supabase_migrations owner to postgres;
alter table supabase_migrations.schema_migrations owner to postgres;
