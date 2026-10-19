-- Chat and calls: deleting an identity (or the auth user that owns it).
--
-- Every rtc foreign key to public.identities was a plain reference with no
-- delete action, so an identity that had ever made or joined a space could
-- not be deleted: deleting the person failed on rtc_members_identity_id_fkey
-- (or whichever rtc table the cascade reached first).
--
-- What deletion means here, by what the column says:
--
--   * the identity's own spaces go, with everything in them (the space is
--     its owner's, as a mailbox is);
--   * rows that *are* the identity in someone else's space go: membership,
--     channel membership (the rtc_member_removed trigger does what leaving
--     does), reactions, read cursors, presence, call participation, and
--     invites to or from it;
--   * rows the identity *made* in someone else's space stay and lose the
--     link: messages keep the author's name, handle and colour as the space
--     saw them (as they do when someone leaves), and a channel, call or
--     recording keeps existing for the people still in it. Those columns
--     become nullable and are set to null.
--
-- Nothing can insert a null author: every insert policy checks
-- can_access_identity(identity_id) or rtc_identity_can_post(channel_id,
-- identity_id), and both are false for null.

alter table public.rtc_spaces
	drop constraint rtc_spaces_identity_id_fkey,
	add constraint rtc_spaces_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete cascade;

alter table public.rtc_members
	drop constraint rtc_members_identity_id_fkey,
	add constraint rtc_members_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete cascade;

alter table public.rtc_channel_members
	drop constraint rtc_channel_members_identity_id_fkey,
	add constraint rtc_channel_members_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete cascade;

alter table public.rtc_invites
	drop constraint rtc_invites_identity_id_fkey,
	add constraint rtc_invites_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete cascade,
	drop constraint rtc_invites_invitee_id_fkey,
	add constraint rtc_invites_invitee_id_fkey foreign key (invitee_id)
		references public.identities (id) on delete cascade;

alter table public.rtc_reactions
	drop constraint rtc_reactions_identity_id_fkey,
	add constraint rtc_reactions_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete cascade;

alter table public.rtc_reads
	drop constraint rtc_reads_identity_id_fkey,
	add constraint rtc_reads_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete cascade;

alter table public.rtc_presence
	drop constraint rtc_presence_identity_id_fkey,
	add constraint rtc_presence_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete cascade;

alter table public.rtc_call_participants
	drop constraint rtc_call_participants_identity_id_fkey,
	add constraint rtc_call_participants_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete cascade;

-- Made by the identity, kept for the others.
alter table public.rtc_channels
	alter column identity_id drop not null,
	drop constraint rtc_channels_identity_id_fkey,
	add constraint rtc_channels_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete set null;

alter table public.rtc_messages
	alter column identity_id drop not null,
	drop constraint rtc_messages_identity_id_fkey,
	add constraint rtc_messages_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete set null;

alter table public.rtc_calls
	alter column identity_id drop not null,
	drop constraint rtc_calls_identity_id_fkey,
	add constraint rtc_calls_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete set null;

alter table public.rtc_recordings
	alter column identity_id drop not null,
	drop constraint rtc_recordings_identity_id_fkey,
	add constraint rtc_recordings_identity_id_fkey foreign key (identity_id)
		references public.identities (id) on delete set null;

-- The set-null above is an update of each message, and every update took a
-- new rev, which locks and bumps the channel's last_seq. For a message in a
-- space the same delete is removing that touched a channel whose space was
-- already gone. Unlinking a deleted author changes nothing a client shows
-- (the name is the snapshot), so that one update, made by the foreign key
-- from inside a trigger, takes no rev and announces nothing. Otherwise the
-- function is unchanged.
create or replace function public.rtc_message_update() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
	if pg_trigger_depth() > 1 and new.identity_id is null and old.identity_id is not null
	   and not exists (select 1 from public.identities i where i.id = old.identity_id) then
		return new;
	end if;
	if pg_trigger_depth() = 1 then
		if old.deleted_at is not null then
			raise exception 'that message was deleted' using errcode = '22023';
		end if;
		if new.channel_id <> old.channel_id or new.identity_id is distinct from old.identity_id
		   or new.thread_root is distinct from old.thread_root or new.seq <> old.seq
		   or new.replies <> old.replies or new.attachment is distinct from old.attachment
		   or new.created_at <> old.created_at then
			raise exception 'only the body of a message can be changed' using errcode = '42501';
		end if;
		if new.deleted_at is not null then
			new.deleted_at := now();
			new.body := '';
			new.attachment := null;
		elsif new.body is distinct from old.body then
			if btrim(new.body) = '' then
				raise exception 'an edit needs some text' using errcode = '22023';
			end if;
			new.edited_at := now();
		end if;
	end if;
	new.rev := public.rtc_next_seq(new.channel_id);
	return new;
end
$$;
