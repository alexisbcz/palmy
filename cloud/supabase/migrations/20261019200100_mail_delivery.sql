-- Mail: addressing, delivery and submission.
--
-- Delivery is the one place mail crosses from one identity to another, and it
-- crosses in exactly one direction: a definer function inserts a message into
-- the recipient's inbox. The sender never gains read access to anything of the
-- recipient's, and the function returns only per-recipient outcomes. That is
-- what mail is — anyone may put a letter in your box — and it is the reason
-- delivery is a function and not a policy.
--
-- Two entry points:
--
--   mail_deliver   service_role only. The SMTP receiver calls it for mail that
--                  arrived from outside a session (the MX role). Local
--                  recipients only; anything else is refused per recipient.
--   mail_submit    authenticated. A person (or a session scoped to one
--                  identity) sends as an identity they can access. Local
--                  recipients are delivered now; every other recipient is
--                  held in mail_outbox with status `held`, because there is
--                  no outbound delivery to the internet.
--
-- `p_meta` is the header summary the server parsed out of the raw message:
--
--   {"subject": "...", "messageId": "...", "inReplyTo": [...],
--    "references": [...], "from": [{"name","email"}], "sender": [...],
--    "replyTo": [...], "to": [...], "cc": [...], "bcc": [...],
--    "sentAt": "2026-10-19T10:00:00Z", "preview": "...",
--    "hasAttachment": false}
--
-- Postgres does not parse MIME; the server does, and these functions trust
-- its summary only for display fields. Addressing decisions use the envelope.

-- The address of an identity: <handle>@<default local domain>.
create function public.mail_default_domain() returns text
language sql stable security definer
set search_path = ''
as $$
	select domain from public.mail_domains where is_default
	union all
	select domain from public.mail_domains
	limit 1
$$;

create function public.mail_address_of(p_identity uuid) returns text
language sql stable security definer
set search_path = ''
as $$
	-- Only for an identity the caller can reach: an id is not a way to look
	-- up somebody else's handle. Definer callers (mail_submit) pass the same
	-- check before they get here.
	select i.handle || '@' || public.mail_default_domain()
	from public.identities i where i.id = p_identity and public.can_access_identity(i.id)
$$;

-- Split and normalise an address. Only the domain is case-folded by the RFC;
-- handles are lowercase by the identities check, so the local part is folded
-- too, which is what every real mail system does in practice.
create function public.mail_normalise(p_addr text) returns text
language sql immutable
as $$
	select lower(trim(both ' <>' from p_addr))
$$;

-- Is this address on a domain this server is the destination for?
create function public.mail_is_local(p_addr text) returns boolean
language sql stable security definer
set search_path = ''
as $$
	select exists (
		select 1 from public.mail_domains d
		where d.domain = split_part(public.mail_normalise(p_addr), '@', 2)
	)
$$;

-- The identity a local address belongs to, or null. Archived identities do
-- not receive mail.
create function public.mail_resolve(p_addr text) returns uuid
language sql stable security definer
set search_path = ''
as $$
	select i.id from public.identities i
	where public.mail_is_local(p_addr)
	  and i.handle = split_part(public.mail_normalise(p_addr), '@', 1)
	  and i.archived_at is null
$$;

-- The standard mailbox set, created on first need.
create function public.mail_ensure_mailboxes_internal(p_identity uuid) returns void
language plpgsql security definer
set search_path = ''
as $$
begin
	insert into public.mail_mailboxes (identity_id, name, role, sort_order)
	select p_identity, x.name, x.role, x.ord
	from (values ('Inbox', 'inbox', 0), ('Drafts', 'drafts', 1), ('Outbox', 'outbox', 2),
	             ('Sent', 'sent', 3), ('Archive', 'archive', 4), ('Junk', 'junk', 5),
	             ('Trash', 'trash', 6)) as x (name, role, ord)
	where not exists (select 1 from public.mail_mailboxes m
	                  where m.identity_id = p_identity and m.role = x.role)
	on conflict do nothing;
end
$$;

-- Callable by a person: ensures the mailboxes of every identity they can
-- reach in this session, and nothing else.
create function public.mail_bootstrap() returns void
language plpgsql security definer
set search_path = ''
as $$
declare
	r record;
begin
	for r in select i.id from public.identities i where public.can_access_identity(i.id) loop
		perform public.mail_ensure_mailboxes_internal(r.id);
	end loop;
end
$$;

-- The identities this session can use for mail, with their addresses.
-- Security invoker: it reads identities through that table's own policy.
create function public.mail_identities()
returns table (id uuid, handle text, display_name text, kind text, color text, address text)
language sql stable security invoker
set search_path = ''
as $$
	select i.id, i.handle, i.display_name, i.kind, i.color, public.mail_address_of(i.id)
	from public.identities i
	where public.can_access_identity(i.id)
	order by i.created_at, i.handle
$$;

-- Per-mailbox counts, through RLS (security invoker).
create function public.mail_mailbox_counts(p_identity uuid)
returns table (mailbox_id uuid, total_emails bigint, unread_emails bigint,
               total_threads bigint, unread_threads bigint)
language sql stable security invoker
set search_path = ''
as $$
	select b.id,
	       count(m.id),
	       count(m.id) filter (where not ('$seen' = any (m.keywords))),
	       count(distinct m.thread_id),
	       count(distinct m.thread_id) filter (where not ('$seen' = any (m.keywords)))
	from public.mail_mailboxes b
	left join public.mail_messages m on m.identity_id = b.identity_id and b.id = any (m.mailbox_ids)
	where b.identity_id = p_identity
	group by b.id
$$;

create function public.mail_addr_list(p jsonb) returns jsonb
language sql immutable
as $$
	select case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end
$$;

create function public.mail_text_list(p jsonb) returns text[]
language sql immutable
as $$
	select coalesce(array(select jsonb_array_elements_text(
		case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end)), '{}')
$$;

-- Store one copy of a message into one identity. Not granted to anyone: the
-- two entry points below decide who may cause it.
create function public.mail_store(
	p_identity uuid, p_raw bytea, p_meta jsonb, p_roles text[], p_keywords text[]
) returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
	v_sha    text := encode(sha256(p_raw), 'hex');
	v_blob   uuid;
	v_thread uuid;
	v_boxes  uuid[];
	v_id     uuid;
	v_refs   text[] := public.mail_text_list(p_meta -> 'inReplyTo') || public.mail_text_list(p_meta -> 'references');
	v_sent   timestamptz;
begin
	perform public.mail_ensure_mailboxes_internal(p_identity);

	insert into public.mail_blobs (identity_id, sha256, size, raw)
	values (p_identity, v_sha, octet_length(p_raw), p_raw)
	on conflict (identity_id, sha256) do update set sha256 = excluded.sha256
	returning id into v_blob;

	-- Threading: a reply joins the thread of any message it names in
	-- In-Reply-To or References, within the same identity. Nothing else
	-- (no subject matching): two unrelated "Hello" mails are not a thread.
	select m.thread_id into v_thread
	from public.mail_messages m
	where m.identity_id = p_identity and cardinality(v_refs) > 0 and m.message_id = any (v_refs)
	order by m.received_at
	limit 1;
	-- The reverse case: this message is the parent of one already stored.
	if v_thread is null and coalesce(p_meta ->> 'messageId', '') <> '' then
		select m.thread_id into v_thread
		from public.mail_messages m
		where m.identity_id = p_identity
		  and ((p_meta ->> 'messageId') = any (m.in_reply_to) or (p_meta ->> 'messageId') = any (m."references"))
		limit 1;
	end if;
	if v_thread is null then
		insert into public.mail_threads (identity_id) values (p_identity) returning id into v_thread;
	end if;

	select array_agg(b.id order by b.sort_order) into v_boxes
	from public.mail_mailboxes b
	where b.identity_id = p_identity and b.role = any (p_roles);

	begin
		v_sent := (p_meta ->> 'sentAt')::timestamptz;
	exception when others then
		v_sent := null;
	end;

	insert into public.mail_messages (
		identity_id, thread_id, blob_id, mailbox_ids, keywords, size, sent_at,
		message_id, in_reply_to, "references", subject, "from", sender, reply_to,
		"to", cc, bcc, preview, has_attachment)
	values (
		p_identity, v_thread, v_blob, v_boxes, p_keywords, octet_length(p_raw), v_sent,
		nullif(p_meta ->> 'messageId', ''),
		public.mail_text_list(p_meta -> 'inReplyTo'),
		public.mail_text_list(p_meta -> 'references'),
		left(coalesce(p_meta ->> 'subject', ''), 998),
		public.mail_addr_list(p_meta -> 'from'),
		public.mail_addr_list(p_meta -> 'sender'),
		public.mail_addr_list(p_meta -> 'replyTo'),
		public.mail_addr_list(p_meta -> 'to'),
		public.mail_addr_list(p_meta -> 'cc'),
		public.mail_addr_list(p_meta -> 'bcc'),
		left(coalesce(p_meta ->> 'preview', ''), 256),
		coalesce((p_meta ->> 'hasAttachment')::boolean, false))
	returning id into v_id;
	return v_id;
end
$$;

-- The MX path: mail arriving at this server from a peer. Each recipient is
-- answered on its own, so the SMTP receiver can accept some and refuse
-- others, which is what RCPT TO semantics require.
create function public.mail_deliver(p_raw bytea, p_meta jsonb, p_rcpts text[])
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
	v_out  jsonb := '[]';
	v_rcpt text;
	v_id   uuid;
	v_msg  uuid;
	v_done uuid[] := '{}';
begin
	foreach v_rcpt in array p_rcpts loop
		if not public.mail_is_local(v_rcpt) then
			v_out := v_out || jsonb_build_object('rcpt', v_rcpt, 'status', 'refused',
				'reason', 'relaying denied: not a local domain');
			continue;
		end if;
		v_id := public.mail_resolve(v_rcpt);
		if v_id is null then
			v_out := v_out || jsonb_build_object('rcpt', v_rcpt, 'status', 'unknown',
				'reason', 'no such mailbox');
			continue;
		end if;
		if v_id = any (v_done) then
			-- Two envelope recipients that are the same identity get one copy.
			v_out := v_out || jsonb_build_object('rcpt', v_rcpt, 'status', 'delivered', 'duplicate', true);
			continue;
		end if;
		v_msg := public.mail_store(v_id, p_raw, p_meta, array['inbox'], '{}');
		v_done := v_done || v_id;
		v_out := v_out || jsonb_build_object('rcpt', v_rcpt, 'status', 'delivered');
	end loop;
	return v_out;
end
$$;

-- Submissions per identity per hour. The abuse limit for local delivery
-- today; the outbound plan in cloud/docs/mail.md tightens it per domain.
create function public.mail_submit_limit() returns integer
language sql immutable
as $$ select 200 $$;

-- The submission path: send as an identity this session can access.
create function public.mail_submit(p_identity uuid, p_raw bytea, p_meta jsonb, p_rcpts text[])
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
	v_addr   text;
	v_from   text;
	v_sent   uuid;
	v_sub    uuid;
	v_rcpt   text;
	v_id     uuid;
	v_out    jsonb := '[]';
	v_local  integer := 0;
	v_held   integer := 0;
	v_held_rcpts text[] := '{}';
	v_done   uuid[] := '{}';
begin
	if not public.can_access_identity(p_identity) then
		raise exception 'this session cannot send as that identity' using errcode = '42501';
	end if;
	if cardinality(p_rcpts) is null or cardinality(p_rcpts) = 0 then
		raise exception 'no recipients' using errcode = '22023';
	end if;
	if cardinality(p_rcpts) > 100 then
		raise exception 'too many recipients' using errcode = '22023';
	end if;
	v_addr := public.mail_address_of(p_identity);
	v_from := public.mail_normalise(coalesce(p_meta -> 'from' -> 0 ->> 'email', ''));
	if v_addr is null or v_from <> v_addr then
		raise exception 'From must be %, the identity''s own address', v_addr using errcode = '42501';
	end if;
	if (select count(*) from public.mail_submissions s
	    where s.identity_id = p_identity and s.created_at > now() - interval '1 hour')
	   >= public.mail_submit_limit() then
		raise exception 'submission limit reached for this hour' using errcode = '54000';
	end if;

	-- Sort recipients first, so the sender's copy lands in the right boxes.
	foreach v_rcpt in array p_rcpts loop
		if public.mail_is_local(v_rcpt) then
			v_local := v_local + 1;
		else
			v_held := v_held + 1;
			v_held_rcpts := v_held_rcpts || public.mail_normalise(v_rcpt);
		end if;
	end loop;

	v_sent := public.mail_store(
		p_identity, p_raw, p_meta,
		case when v_held > 0 then array['sent', 'outbox'] else array['sent'] end,
		array['$seen']);

	insert into public.mail_submissions (identity_id, email_id, mail_from, rcpt_to, held)
	values (p_identity, v_sent, v_addr, p_rcpts, v_held)
	returning id into v_sub;

	v_local := 0;
	foreach v_rcpt in array p_rcpts loop
		if not public.mail_is_local(v_rcpt) then
			insert into public.mail_outbox (identity_id, submission_id, email_id, rcpt)
			values (p_identity, v_sub, v_sent, public.mail_normalise(v_rcpt));
			v_out := v_out || jsonb_build_object('rcpt', v_rcpt, 'status', 'held',
				'reason', 'outbound delivery is not enabled');
			continue;
		end if;
		v_id := public.mail_resolve(v_rcpt);
		if v_id is null then
			v_out := v_out || jsonb_build_object('rcpt', v_rcpt, 'status', 'unknown',
				'reason', 'no such mailbox');
			continue;
		end if;
		if not (v_id = any (v_done)) then
			perform public.mail_store(v_id, p_raw, p_meta, array['inbox'], '{}');
			v_done := v_done || v_id;
		end if;
		v_local := v_local + 1;
		v_out := v_out || jsonb_build_object('rcpt', v_rcpt, 'status', 'delivered');
	end loop;

	update public.mail_submissions set delivered = v_local where id = v_sub;
	return jsonb_build_object('submissionId', v_sub, 'emailId', v_sent, 'recipients', v_out);
end
$$;

-- Execution rights. Postgres grants EXECUTE to PUBLIC by default; take it
-- back everywhere and give it out deliberately.
revoke execute on function
	public.mail_default_domain(), public.mail_address_of(uuid), public.mail_is_local(text),
	public.mail_resolve(text), public.mail_ensure_mailboxes_internal(uuid), public.mail_bootstrap(),
	public.mail_identities(), public.mail_mailbox_counts(uuid),
	public.mail_store(uuid, bytea, jsonb, text[], text[]),
	public.mail_deliver(bytea, jsonb, text[]), public.mail_submit(uuid, bytea, jsonb, text[]),
	public.mail_check_mailboxes(), public.mail_gc_blob(), public.mail_log_change()
from public, anon, authenticated;

grant execute on function public.mail_bootstrap(), public.mail_identities(),
	public.mail_mailbox_counts(uuid), public.mail_submit(uuid, bytea, jsonb, text[]),
	public.mail_address_of(uuid), public.mail_default_domain(), public.mail_is_local(text)
to authenticated, service_role;

grant execute on function public.mail_deliver(bytea, jsonb, text[]), public.mail_resolve(text)
to service_role;
