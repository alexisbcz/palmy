-- The assistant: one per identity, holding a session scoped to it.
-- See cloud/docs/assistant.md for the design and the threat model.
--
-- Two things live here.
--
-- 1. The assistant's own tables — settings, conversations, messages and the
--    action log — each with identity_id and policies through
--    can_access_identity(), as the contract requires.
--
-- 2. The rule that makes "anything outbound needs your yes" a property of the
--    database rather than of a prompt: **a session whose device row says
--    kind = 'assistant' cannot send, share, invite, post, or delete.** Those
--    acts are done by the person's own session after they confirmed the
--    proposal, and the assistant can only propose them. The triggers below
--    sit on other areas' tables; they read nothing of those tables, change
--    nothing for any other kind of session, and are listed in
--    cloud/docs/assistant.md so the owning areas know they are there.
--
-- What "an assistant session" means is decided in one place,
-- assistant_session(): the token's session_id has a devices row with
-- kind = 'assistant'. Only accounts' mint_scoped_session creates device rows,
-- and a device's kind cannot be changed afterwards except by the person
-- (there is no update policy on devices at all), so an assistant cannot
-- promote itself.

--------------------------------------------------------------------------------
-- Who is asking
--------------------------------------------------------------------------------

-- True when the calling session was delegated to an assistant. Security
-- definer because devices' own policy is the contract's, which an assistant
-- passes; the question here is narrower than the policy.
create function public.assistant_session() returns boolean
language sql stable security definer
set search_path = ''
as $$
	select exists (
		select 1 from public.devices d
		where d.session_id = nullif(auth.jwt() ->> 'session_id', '')::uuid
		  and d.kind = 'assistant')
$$;

-- The devices row of the calling assistant session, or null.
create function public.assistant_device() returns uuid
language sql stable security definer
set search_path = ''
as $$
	select d.id from public.devices d
	where d.session_id = nullif(auth.jwt() ->> 'session_id', '')::uuid
	  and d.kind = 'assistant'
$$;

revoke execute on function public.assistant_session(), public.assistant_device() from public, anon;
grant execute on function public.assistant_session(), public.assistant_device() to authenticated, service_role;

--------------------------------------------------------------------------------
-- Settings: off by default, local model by default
--------------------------------------------------------------------------------

-- One row per identity, created when the person first turns the assistant
-- on. No row means off (product §9: "off by default per identity").
--
-- A remote provider is opt-in per identity and needs a timestamp saying when
-- the person opted in; the check makes "remote without a recorded opt-in"
-- unrepresentable. An assistant session may read its settings (it needs the
-- model name) and may change none of them: an assistant that could switch
-- itself to a server model would have built itself a way out.
create table public.assistant_settings (
	identity_id      uuid primary key references public.identities (id) on delete cascade,
	enabled          boolean not null default false,
	model            text not null default 'qwen3:0.6b' check (char_length(model) between 1 and 120),
	provider         text not null default 'local' check (provider in ('local', 'anthropic')),
	remote_model     text check (remote_model is null or char_length(remote_model) between 1 and 120),
	remote_opt_in_at timestamptz,
	updated_at       timestamptz not null default now(),
	check (provider = 'local' or remote_opt_in_at is not null)
);

alter table public.assistant_settings enable row level security;

create policy assistant_settings_select on public.assistant_settings
	for select using (public.can_access_identity(identity_id));
create policy assistant_settings_insert on public.assistant_settings
	for insert with check (public.can_access_identity(identity_id) and not public.assistant_session());
create policy assistant_settings_update on public.assistant_settings
	for update using (public.can_access_identity(identity_id) and not public.assistant_session())
	with check (public.can_access_identity(identity_id) and not public.assistant_session());

--------------------------------------------------------------------------------
-- Conversations and messages
--------------------------------------------------------------------------------

create table public.assistant_conversations (
	id          uuid primary key default gen_random_uuid(),
	identity_id uuid not null references public.identities (id) on delete cascade,
	title       text not null default 'New conversation' check (char_length(title) between 1 and 200),
	model       text not null default '',
	provider    text not null default 'local' check (provider in ('local', 'anthropic')),
	created_at  timestamptz not null default now(),
	updated_at  timestamptz not null default now(),
	unique (identity_id, id)
);

create index assistant_conversations_recent on public.assistant_conversations (identity_id, updated_at desc);

-- role: what the person typed, what the assistant answered, a tool call and
-- its result, or a notice the runtime added (a refusal, a scope reminder).
-- `tainted` marks content that came from outside the person: a mail body, a
-- file, a chat message.
create table public.assistant_messages (
	id              uuid primary key default gen_random_uuid(),
	identity_id     uuid not null references public.identities (id) on delete cascade,
	conversation_id uuid not null,
	seq             integer not null check (seq >= 0),
	role            text not null check (role in ('user', 'assistant', 'tool', 'notice')),
	content         text not null default '' check (char_length(content) <= 200000),
	tool            jsonb,
	tainted         boolean not null default false,
	created_at      timestamptz not null default now(),
	unique (conversation_id, seq),
	-- A message belongs to a conversation of the same identity, even for a
	-- caller who learned another identity's conversation id.
	foreign key (identity_id, conversation_id)
		references public.assistant_conversations (identity_id, id) on delete cascade
);

alter table public.assistant_conversations enable row level security;
alter table public.assistant_messages enable row level security;

create policy assistant_conversations_select on public.assistant_conversations
	for select using (public.can_access_identity(identity_id));
create policy assistant_conversations_insert on public.assistant_conversations
	for insert with check (public.can_access_identity(identity_id));
create policy assistant_conversations_update on public.assistant_conversations
	for update using (public.can_access_identity(identity_id))
	with check (public.can_access_identity(identity_id));
-- Deleting a conversation is the person's, not the assistant's.
create policy assistant_conversations_delete on public.assistant_conversations
	for delete using (public.can_access_identity(identity_id) and not public.assistant_session());

create policy assistant_messages_select on public.assistant_messages
	for select using (public.can_access_identity(identity_id));
create policy assistant_messages_insert on public.assistant_messages
	for insert with check (public.can_access_identity(identity_id));
-- Messages are history: no update, and deletion only with the conversation.

--------------------------------------------------------------------------------
-- The action log
--------------------------------------------------------------------------------

-- Every tool call the assistant made or proposed, per identity. The person
-- reviews it in the app (`ai log`); nothing here is ever deleted.
--
--   class   read     the assistant read something inside its identity
--           draft    it wrote a draft inside its identity (a mail draft, a note)
--           confirm  it proposed an act that needs the person's yes
--
--   status  done      a read or a draft that ran
--           refused   the runtime or the database turned it away
--           failed    it ran and failed
--           proposed  waiting for the person
--           confirmed the person said yes; the person's session runs it next
--           declined  the person said no
--           executed  the person's session ran it
--           expired   nobody answered in time
--
-- The lifecycle is enforced below: an assistant can create rows only in the
-- states an assistant can reach (done, refused, failed, proposed) and can
-- update nothing. Only the person moves a proposal on, and once a row is
-- written its tool, class and arguments cannot change, so what the person
-- confirmed is exactly what runs.
create table public.assistant_actions (
	id              uuid primary key default gen_random_uuid(),
	identity_id     uuid not null references public.identities (id) on delete cascade,
	conversation_id uuid,
	device_id       uuid references public.devices (id) on delete set null,
	tool            text not null check (tool ~ '^[a-z][a-z0-9_]{1,63}$'),
	class           text not null check (class in ('read', 'draft', 'confirm')),
	args            jsonb not null default '{}',
	summary         text not null default '' check (char_length(summary) <= 2000),
	status          text not null check (status in
	                ('done', 'refused', 'failed', 'proposed', 'confirmed', 'declined', 'executed', 'expired')),
	-- Proposed after the assistant had read content from outside the person
	-- (a mail, a file, a chat message), and from which sources.
	tainted         boolean not null default false,
	sources         jsonb not null default '[]',
	-- What the runtime noticed about the arguments, shown with the proposal:
	-- an address the person never typed, a link, a recipient outside the
	-- identity's contacts.
	warnings        jsonb not null default '[]',
	result          jsonb,
	created_at      timestamptz not null default now(),
	decided_at      timestamptz,
	executed_at     timestamptz,
	unique (identity_id, id),
	foreign key (identity_id, conversation_id)
		references public.assistant_conversations (identity_id, id) on delete set null (conversation_id),
	check (class = 'confirm' or status in ('done', 'refused', 'failed')),
	check (class <> 'confirm' or status <> 'done')
);

create index assistant_actions_recent on public.assistant_actions (identity_id, created_at desc);
create index assistant_actions_pending on public.assistant_actions (identity_id) where status in ('proposed', 'confirmed');

alter table public.assistant_actions enable row level security;

create policy assistant_actions_select on public.assistant_actions
	for select using (public.can_access_identity(identity_id));
create policy assistant_actions_insert on public.assistant_actions
	for insert with check (
		public.can_access_identity(identity_id)
		and (not public.assistant_session() or status in ('done', 'refused', 'failed', 'proposed')));
create policy assistant_actions_update on public.assistant_actions
	for update using (public.can_access_identity(identity_id) and not public.assistant_session())
	with check (public.can_access_identity(identity_id) and not public.assistant_session());

create function public.assistant_actions_before_insert() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	-- The device is the database's to say, never the caller's.
	new.device_id := public.assistant_device();
	new.created_at := now();
	new.decided_at := null;
	new.executed_at := null;
	return new;
end
$$;

create trigger assistant_actions_before_insert before insert on public.assistant_actions
	for each row execute function public.assistant_actions_before_insert();

create function public.assistant_actions_before_update() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if (new.identity_id, new.tool, new.class, new.args, new.device_id, new.tainted, new.sources, new.warnings, new.created_at)
	   is distinct from
	   (old.identity_id, old.tool, old.class, old.args, old.device_id, old.tainted, old.sources, old.warnings, old.created_at) then
		raise exception 'an action''s tool, arguments and provenance are permanent' using errcode = '42501';
	end if;
	if new.status <> old.status and not (
		(old.status = 'proposed' and new.status in ('confirmed', 'declined', 'expired')) or
		(old.status = 'confirmed' and new.status in ('executed', 'failed'))) then
		raise exception 'an action cannot go from % to %', old.status, new.status using errcode = '42501';
	end if;
	if new.status in ('confirmed', 'declined', 'expired') and old.status = 'proposed' then
		new.decided_at := now();
	end if;
	if new.status in ('executed', 'failed') and old.status = 'confirmed' then
		new.executed_at := now();
	end if;
	return new;
end
$$;

create trigger assistant_actions_before_update before update on public.assistant_actions
	for each row execute function public.assistant_actions_before_update();

grant select, insert, update on public.assistant_settings to authenticated;
grant select, insert, update, delete on public.assistant_conversations to authenticated;
grant select, insert on public.assistant_messages to authenticated;
grant select, insert, update on public.assistant_actions to authenticated;

--------------------------------------------------------------------------------
-- Outbound acts belong to the person
--------------------------------------------------------------------------------

-- One trigger function, attached below to every table whose insert means
-- something leaves the identity: a mail submitted, a file or document or
-- calendar shared, a link minted, a chat message posted, an invitation sent,
-- a forge comment written. For an assistant session it refuses with 42501
-- (PostgREST answers 403) and a hint the runtime recognises; for every other
-- session it does nothing at all.
create function public.assistant_outbound_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if public.assistant_session() then
		raise exception 'an assistant cannot % by itself: it proposes, and the person confirms and does it', tg_argv[0]
			using errcode = '42501', hint = 'assistant_outbound';
	end if;
	return case when tg_op = 'DELETE' then old else new end;
end
$$;

create trigger assistant_guard before insert on public.mail_submissions
	for each row execute function public.assistant_outbound_guard('send mail');
create trigger assistant_guard before insert on public.mail_outbox
	for each row execute function public.assistant_outbound_guard('send mail');
create trigger assistant_guard before insert on public.drive_shares
	for each row execute function public.assistant_outbound_guard('share a file');
create trigger assistant_guard before insert on public.drive_links
	for each row execute function public.assistant_outbound_guard('make a link to a file');
create trigger assistant_guard before insert on public.rtc_messages
	for each row execute function public.assistant_outbound_guard('post to chat');
create trigger assistant_guard before insert on public.rtc_invites
	for each row execute function public.assistant_outbound_guard('invite someone to chat');
create trigger assistant_guard before insert on public.dav_itip
	for each row execute function public.assistant_outbound_guard('send a calendar invitation');
create trigger assistant_guard before insert on public.dav_grants
	for each row execute function public.assistant_outbound_guard('share a calendar');
create trigger assistant_guard before insert on public.collab_grants
	for each row execute function public.assistant_outbound_guard('share a document');
create trigger assistant_guard before insert on public.collab_links
	for each row execute function public.assistant_outbound_guard('make a link to a document');
create trigger assistant_guard before insert on public.forge_comments
	for each row execute function public.assistant_outbound_guard('comment on the forge');
create trigger assistant_guard before insert on public.forge_collaborators
	for each row execute function public.assistant_outbound_guard('add a collaborator');

-- Deleting is the person's too: mail, files, events.
create trigger assistant_guard_delete before delete on public.mail_messages
	for each row execute function public.assistant_outbound_guard('delete mail');
create trigger assistant_guard_delete before delete on public.drive_items
	for each row execute function public.assistant_outbound_guard('delete a file');
create trigger assistant_guard_delete before delete on public.dav_objects
	for each row execute function public.assistant_outbound_guard('delete an event');

-- Trashing a file is an update, not a delete.
create function public.assistant_trash_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if new.trashed_at is not null and old.trashed_at is null and public.assistant_session() then
		raise exception 'an assistant cannot delete a file by itself: it proposes, and the person confirms and does it'
			using errcode = '42501', hint = 'assistant_outbound';
	end if;
	return new;
end
$$;

create trigger assistant_trash_guard before update on public.drive_items
	for each row execute function public.assistant_trash_guard();

-- Into a mailbox an assistant may put drafts and nothing else: a message it
-- stores must be in the identity's Drafts mailbox only and carry $draft.
-- Without this, mail_import would let it plant a message in the Inbox that
-- looks as though somebody sent it.
create function public.assistant_mail_guard() returns trigger
language plpgsql
set search_path = ''
as $$
declare
	drafts uuid;
begin
	if not public.assistant_session() then
		return new;
	end if;
	select b.id into drafts from public.mail_mailboxes b
	where b.identity_id = new.identity_id and b.role = 'drafts';
	if tg_op = 'INSERT' then
		if drafts is null or new.mailbox_ids <> array[drafts] or not ('$draft' = any (new.keywords)) then
			raise exception 'an assistant may only write drafts into the Drafts mailbox'
				using errcode = '42501', hint = 'assistant_outbound';
		end if;
	elsif new.mailbox_ids is distinct from old.mailbox_ids then
		raise exception 'an assistant cannot move mail between mailboxes by itself'
			using errcode = '42501', hint = 'assistant_outbound';
	end if;
	return new;
end
$$;

create trigger assistant_mail_guard before insert or update on public.mail_messages
	for each row execute function public.assistant_mail_guard();
