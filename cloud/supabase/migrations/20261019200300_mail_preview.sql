-- Mail: the preview rule, and a flag for messages whose parts disagree.
--
-- A message with both a text/plain and a text/html part carries the same
-- message twice, and nothing makes a sender keep the two alike. The stored
-- preview (and the `search` column built from it) came from the first
-- text/plain part, while a reader that renders HTML shows the HTML part: a
-- sender could put words in the list, in search and in front of the
-- assistant that the message itself never showed. palm-maild now cuts the
-- preview from what a reader shows, the HTML part's visible text when there
-- is one (cloud/mail/readable), and says in `p_meta.partsDiffer` when the two
-- parts differ significantly. That flag is stored here, so every reader can
-- tell the person the other part says something else.
--
-- Like the other display fields it is the summarising server's word, not
-- Postgres's: Postgres does not parse MIME.

alter table public.mail_messages
	add column parts_differ boolean not null default false;

comment on column public.mail_messages.parts_differ is
	'text/plain and text/html parts differ significantly (cloud/mail/readable); set at delivery from p_meta.partsDiffer';

create or replace function public.mail_store(
	p_identity uuid, p_raw bytea, p_meta jsonb, p_roles text[], p_keywords text[],
	p_boxes uuid[] default null
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

	if p_boxes is not null then
		v_boxes := p_boxes;
	else
		select array_agg(b.id order by b.sort_order) into v_boxes
		from public.mail_mailboxes b
		where b.identity_id = p_identity and b.role = any (p_roles);
	end if;

	begin
		v_sent := (p_meta ->> 'sentAt')::timestamptz;
	exception when others then
		v_sent := null;
	end;

	insert into public.mail_messages (
		identity_id, thread_id, blob_id, mailbox_ids, keywords, size, sent_at,
		message_id, in_reply_to, "references", subject, "from", sender, reply_to,
		"to", cc, bcc, preview, has_attachment, parts_differ)
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
		coalesce((p_meta ->> 'hasAttachment')::boolean, false),
		coalesce((p_meta ->> 'partsDiffer')::boolean, false))
	returning id into v_id;
	return v_id;
end
$$;

revoke execute on function public.mail_store(uuid, bytea, jsonb, text[], text[], uuid[]) from public, anon, authenticated;
