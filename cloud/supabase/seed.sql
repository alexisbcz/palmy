-- Development seed, loaded after the migrations by `supabase db reset` and by
-- cloud/dev/up.sh. Production sets its own rows. Idempotent.

-- Mail: the local domain every identity's address is on (<handle>@palm.test).
insert into public.mail_domains (domain, is_default) values ('palm.test', true)
on conflict (domain) do nothing;
