-- Mail: mailboxes, threads, messages, raw message blobs, submissions and the
-- outbound hold queue, all scoped to an identity. See cloud/CONTRACT.md and
-- cloud/docs/mail.md.
--
-- Every table here has `identity_id uuid not null references
-- public.identities`, row-level security, and policies that go through
-- public.can_access_identity(identity_id) and nothing else.
--
-- DECISIONS, stated where they are made:
--
--   Raw RFC 5322 lives in Postgres (`mail_blobs.raw bytea`), not in a Storage
--   bucket. Delivery is then one transaction: the blob, the thread and the
--   message commit together or not at all, so there is no orphaned object and
--   no message pointing at a blob that was never written, and the blob is
--   behind exactly the same RLS policy as the row that names it. Mail is small
--   (the median message is tens of kilobytes) and the SMTP receiver caps a
--   message at 25 MiB. The blob is a separate table so that listing and
--   querying messages never touches TOAST. When large attachments make the
--   database the wrong place, the plan is a `storage_path` column beside
--   `raw`, exactly one of the two set, with the Storage policy keyed on the
--   identity id as the first path segment — see cloud/docs/mail.md.
--
--   Folders and labels are one thing: a mailbox. A message belongs to a SET of
--   mailboxes (`mailbox_ids`), which is JMAP's model (RFC 8621 2): a folder
--   client keeps it to one, a label client uses several.
--
--   Drafts are not a separate table. A draft is a message with the `$draft`
--   keyword in the identity's Drafts mailbox, which is how JMAP (RFC 8621 4.1.1)
--   and IMAP both model it, so a client sees one object type, and sending a
--   draft is a state change of a message rather than a copy between tables.
--
--   The local domain is a row in `mail_domains`, not a constant. Migrations
--   leave it empty; the dev stack seeds `palm.test` (cloud/mail/dev/seed.sql).

-- ---------------------------------------------------------------------------
-- Domains: configuration, not a person's data. RLS is on with no policy, so
-- only definer functions (and the service role) read it.
-- ---------------------------------------------------------------------------

create table public.mail_domains (
	domain      text primary key check (domain = lower(domain) and domain ~ '^[a-z0-9.-]+$'),
	is_default  boolean not null default false,
	created_at  timestamptz not null default now()
);

create unique index mail_domains_one_default on public.mail_domains (is_default) where is_default;

alter table public.mail_domains enable row level security;

-- ---------------------------------------------------------------------------
-- Mailboxes
-- ---------------------------------------------------------------------------

create table public.mail_mailboxes (
	id          uuid primary key default gen_random_uuid(),
	identity_id uuid not null references public.identities (id) on delete cascade,
	parent_id   uuid,
	name        text not null check (length(name) between 1 and 200 and name !~ '[/\x00-\x1f]'),
	-- RFC 8621 2 roles, plus `outbox`, which is where mail for recipients this
	-- server will not deliver to waits, visibly. Clients that do not know the
	-- role still see a mailbox called "Outbox".
	role        text check (role in ('inbox', 'drafts', 'sent', 'archive', 'trash', 'junk', 'outbox')),
	sort_order  integer not null default 0,
	created_at  timestamptz not null default now(),
	unique (identity_id, id),
	foreign key (identity_id, parent_id) references public.mail_mailboxes (identity_id, id) on delete cascade
);

create unique index mail_mailboxes_role on public.mail_mailboxes (identity_id, role) where role is not null;
create unique index mail_mailboxes_name on public.mail_mailboxes
	(identity_id, coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name));

-- ---------------------------------------------------------------------------
-- Threads
-- ---------------------------------------------------------------------------

create table public.mail_threads (
	id          uuid primary key default gen_random_uuid(),
	identity_id uuid not null references public.identities (id) on delete cascade,
	created_at  timestamptz not null default now(),
	unique (identity_id, id)
);

-- ---------------------------------------------------------------------------
-- Raw messages
-- ---------------------------------------------------------------------------

create table public.mail_blobs (
	id          uuid primary key default gen_random_uuid(),
	identity_id uuid not null references public.identities (id) on delete cascade,
	sha256      text not null check (sha256 ~ '^[0-9a-f]{64}$'),
	size        integer not null check (size >= 0 and size <= 26214400),
	raw         bytea not null,
	created_at  timestamptz not null default now(),
	check (octet_length(raw) = size),
	unique (identity_id, id),
	-- Deduplicated within an identity only. Across identities it would leak,
	-- through timing or through an insert that did nothing, that somebody
	-- else holds the same message.
	unique (identity_id, sha256)
);

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

create table public.mail_messages (
	id             uuid primary key default gen_random_uuid(),
	identity_id    uuid not null references public.identities (id) on delete cascade,
	thread_id      uuid not null,
	blob_id        uuid not null,
	mailbox_ids    uuid[] not null check (cardinality(mailbox_ids) >= 1),
	keywords       text[] not null default '{}'
	               check (keywords::text = lower(keywords::text)),
	size           integer not null,
	received_at    timestamptz not null default now(),
	sent_at        timestamptz,
	message_id     text,
	in_reply_to    text[] not null default '{}',
	"references"   text[] not null default '{}',
	subject        text not null default '',
	"from"         jsonb not null default '[]',
	sender         jsonb not null default '[]',
	reply_to       jsonb not null default '[]',
	"to"           jsonb not null default '[]',
	cc             jsonb not null default '[]',
	bcc            jsonb not null default '[]',
	preview        text not null default '',
	has_attachment boolean not null default false,
	created_at     timestamptz not null default now(),
	unique (identity_id, id),
	foreign key (identity_id, thread_id) references public.mail_threads (identity_id, id) on delete cascade,
	foreign key (identity_id, blob_id) references public.mail_blobs (identity_id, id)
);

create index mail_messages_list on public.mail_messages (identity_id, received_at desc);
create index mail_messages_mailboxes on public.mail_messages using gin (mailbox_ids);
create index mail_messages_thread on public.mail_messages (thread_id);
create index mail_messages_msgid on public.mail_messages (identity_id, message_id);

-- A message may only sit in its own identity's mailboxes. An array cannot
-- carry a foreign key, so this is the check that stands in for one.
create function public.mail_check_mailboxes() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
	if (select count(*) from public.mail_mailboxes m
	    where m.id = any (new.mailbox_ids) and m.identity_id = new.identity_id)
	   <> (select count(distinct x) from unnest(new.mailbox_ids) x) then
		raise exception 'mailbox_ids names a mailbox outside this identity'
			using errcode = '23503';
	end if;
	return new;
end
$$;

create trigger mail_messages_mailboxes_check
	before insert or update of mailbox_ids, identity_id on public.mail_messages
	for each row execute function public.mail_check_mailboxes();

-- A destroyed message takes its blob with it when nothing else in the
-- identity still points at it.
create function public.mail_gc_blob() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
	delete from public.mail_blobs b
	where b.id = old.blob_id and b.identity_id = old.identity_id
	  and not exists (select 1 from public.mail_messages m where m.blob_id = old.blob_id);
	delete from public.mail_threads t
	where t.id = old.thread_id
	  and not exists (select 1 from public.mail_messages m where m.thread_id = old.thread_id);
	return null;
end
$$;

create trigger mail_messages_gc
	after delete on public.mail_messages
	for each row execute function public.mail_gc_blob();

-- ---------------------------------------------------------------------------
-- Submissions and the outbound hold queue
--
-- A submission is one act of sending (JMAP's EmailSubmission). Local
-- recipients are delivered inside the same transaction. Every other recipient
-- gets a row in mail_outbox with status `held`: there is no outbound delivery
-- to the internet, and the row says so to the person who sent it rather than
-- pretending the mail left. The Resend worker described in cloud/docs/mail.md
-- would move rows from `queued` onwards; nothing moves them today.
-- ---------------------------------------------------------------------------

create table public.mail_submissions (
	id            uuid primary key default gen_random_uuid(),
	identity_id   uuid not null references public.identities (id) on delete cascade,
	email_id      uuid not null,
	mail_from     text not null,
	rcpt_to       text[] not null,
	delivered     integer not null default 0,
	held          integer not null default 0,
	created_at    timestamptz not null default now(),
	unique (identity_id, id),
	foreign key (identity_id, email_id) references public.mail_messages (identity_id, id) on delete cascade
);

create index mail_submissions_recent on public.mail_submissions (identity_id, created_at desc);

create table public.mail_outbox (
	id            uuid primary key default gen_random_uuid(),
	identity_id   uuid not null references public.identities (id) on delete cascade,
	submission_id uuid not null,
	email_id      uuid not null,
	rcpt          text not null,
	status        text not null default 'held'
	              check (status in ('held', 'queued', 'sending', 'sent', 'bounced', 'complained', 'failed')),
	reason        text not null default 'outbound delivery is not enabled',
	provider_id   text,
	created_at    timestamptz not null default now(),
	updated_at    timestamptz not null default now(),
	foreign key (identity_id, submission_id) references public.mail_submissions (identity_id, id) on delete cascade,
	foreign key (identity_id, email_id) references public.mail_messages (identity_id, id) on delete cascade
);

create index mail_outbox_identity on public.mail_outbox (identity_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Change log, for JMAP state strings and /changes
-- ---------------------------------------------------------------------------

create table public.mail_changes (
	seq         bigserial primary key,
	identity_id uuid not null references public.identities (id) on delete cascade,
	type        text not null check (type in ('Email', 'Mailbox', 'Thread', 'EmailSubmission')),
	object_id   uuid not null,
	kind        text not null check (kind in ('created', 'updated', 'destroyed')),
	at          timestamptz not null default now()
);

create index mail_changes_since on public.mail_changes (identity_id, type, seq);

create function public.mail_log_change() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
	t text := tg_argv[0];
begin
	if tg_op = 'DELETE' then
		insert into public.mail_changes (identity_id, type, object_id, kind)
		values (old.identity_id, t, old.id, 'destroyed');
		return old;
	end if;
	insert into public.mail_changes (identity_id, type, object_id, kind)
	values (new.identity_id, t, new.id, case tg_op when 'INSERT' then 'created' else 'updated' end);
	return new;
end
$$;

create trigger mail_messages_changes after insert or update or delete on public.mail_messages
	for each row execute function public.mail_log_change('Email');
create trigger mail_mailboxes_changes after insert or update or delete on public.mail_mailboxes
	for each row execute function public.mail_log_change('Mailbox');
create trigger mail_threads_changes after insert or update or delete on public.mail_threads
	for each row execute function public.mail_log_change('Thread');
create trigger mail_submissions_changes after insert or update or delete on public.mail_submissions
	for each row execute function public.mail_log_change('EmailSubmission');

-- ---------------------------------------------------------------------------
-- Row-level security. One rule, through can_access_identity.
-- ---------------------------------------------------------------------------

alter table public.mail_mailboxes   enable row level security;
alter table public.mail_threads     enable row level security;
alter table public.mail_blobs       enable row level security;
alter table public.mail_messages    enable row level security;
alter table public.mail_submissions enable row level security;
alter table public.mail_outbox      enable row level security;
alter table public.mail_changes     enable row level security;

-- Mailboxes, threads, blobs and messages are the person's to read and change.
create policy mail_mailboxes_all on public.mail_mailboxes for all
	using (public.can_access_identity(identity_id)) with check (public.can_access_identity(identity_id));
create policy mail_threads_all on public.mail_threads for all
	using (public.can_access_identity(identity_id)) with check (public.can_access_identity(identity_id));
create policy mail_blobs_all on public.mail_blobs for all
	using (public.can_access_identity(identity_id)) with check (public.can_access_identity(identity_id));
create policy mail_messages_all on public.mail_messages for all
	using (public.can_access_identity(identity_id)) with check (public.can_access_identity(identity_id));

-- Submissions and the outbox are a record of what happened: readable, and
-- an outbox row may be withdrawn (deleted), but they are written only by
-- mail_submit, so a client cannot mark its own held mail `queued`.
create policy mail_submissions_select on public.mail_submissions for select
	using (public.can_access_identity(identity_id));
create policy mail_outbox_select on public.mail_outbox for select
	using (public.can_access_identity(identity_id));
create policy mail_outbox_delete on public.mail_outbox for delete
	using (public.can_access_identity(identity_id));
create policy mail_changes_select on public.mail_changes for select
	using (public.can_access_identity(identity_id));

revoke all on public.mail_domains, public.mail_mailboxes, public.mail_threads, public.mail_blobs,
	public.mail_messages, public.mail_submissions, public.mail_outbox, public.mail_changes from anon;
grant select, insert, update, delete on public.mail_mailboxes, public.mail_threads, public.mail_blobs,
	public.mail_messages to authenticated;
grant select on public.mail_submissions, public.mail_changes to authenticated;
grant select, delete on public.mail_outbox to authenticated;
grant all on public.mail_domains, public.mail_mailboxes, public.mail_threads, public.mail_blobs,
	public.mail_messages, public.mail_submissions, public.mail_outbox, public.mail_changes to service_role;
grant usage on sequence public.mail_changes_seq_seq to authenticated, service_role;
