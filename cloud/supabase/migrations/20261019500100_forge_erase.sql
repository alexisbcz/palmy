-- Forge: deleting an identity (or the auth user that owns it).
--
-- Authorship columns (forge_issues.author_identity_id and the others) are
-- `on delete set null`, so an identity's issues and comments in someone
-- else's repository stay, unattributed. But forge_issue_guard refuses any
-- change to author_identity_id, including the null the foreign key itself
-- writes, so deleting a person who had opened an issue failed with "that
-- column is fixed once an issue exists".
--
-- The guard is for clients. The one change it now lets through is the
-- foreign key's: author set to null, from inside another trigger (the
-- referential action runs as one), for an author that no longer exists.

-- Whether an identity row exists, whoever asks: public.identities is
-- readable only by its owner, and the guard must see past that. Answers
-- nothing but yes or no for one id.
create function public.forge_identity_exists(p_id uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
	select exists (select 1 from public.identities i where i.id = p_id)
$$;

revoke execute on function public.forge_identity_exists(uuid) from public, anon, authenticated;

create or replace function public.forge_issue_guard() returns trigger
language plpgsql
as $$
begin
	if new.repo_id <> old.repo_id or new.number <> old.number or new.is_pull <> old.is_pull then
		raise exception 'that column is fixed once an issue exists' using errcode = '42501';
	end if;
	if new.author_identity_id is distinct from old.author_identity_id then
		if new.author_identity_id is not null or pg_trigger_depth() < 2 then
			raise exception 'that column is fixed once an issue exists' using errcode = '42501';
		end if;
		if public.forge_identity_exists(old.author_identity_id) then
			raise exception 'that column is fixed once an issue exists' using errcode = '42501';
		end if;
	end if;
	if new.state <> old.state then
		new.closed_at := case when new.state = 'closed' then now() end;
	end if;
	return new;
end
$$;
