-- Mail: deleting an identity (or the auth user that owns it) with mail in it.
--
-- The delete cascades from public.identities to every mail table, and each
-- row the cascade removes fires mail_log_change, which wrote a 'destroyed'
-- row into mail_changes for the identity being deleted. That row referenced
-- an identity the same statement had already removed, so the whole delete
-- failed on mail_changes_identity_id_fkey: an account with mail could not be
-- deleted at all.
--
-- The change log exists so a client of *that identity* can ask what changed
-- since its last state. When the identity itself is gone there is no such
-- client and nothing to sync, and its existing log rows go with it through
-- the same cascade. So the log is skipped for an identity that no longer
-- exists. Making the foreign key deferrable would not help (the row would
-- still name a missing identity at commit), and dropping it would leave
-- orphans. For every live identity the log is written exactly as before.

create or replace function public.mail_log_change() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
	t text := tg_argv[0];
begin
	if tg_op = 'DELETE' then
		if exists (select 1 from public.identities i where i.id = old.identity_id) then
			insert into public.mail_changes (identity_id, type, object_id, kind)
			values (old.identity_id, t, old.id, 'destroyed');
		end if;
		return old;
	end if;
	insert into public.mail_changes (identity_id, type, object_id, kind)
	values (new.identity_id, t, new.id, case tg_op when 'INSERT' then 'created' else 'updated' end);
	return new;
end
$$;

revoke execute on function public.mail_log_change() from public, anon, authenticated;
