-- The password manager: end-to-end encrypted vaults, one keyset per identity,
-- items synced one record at a time. See cloud/docs/vault.md for the whole
-- design and apps/vault/SECURITY.md for the threat model.
--
-- The server stores ciphertext and the minimum it needs to route it. Every
-- column holding a person's secret -- item titles, usernames, passwords,
-- URLs, tags, notes, vault names -- is inside an AEAD blob the server cannot
-- open. What is visible, and why, is listed in vault.md ("What the server
-- sees"); the short version is: ids, which identity owns what, revision
-- counters, timestamps, padded sizes, and who shares with whom.
--
-- Access follows the contract (cloud/CONTRACT.md): every table has
-- identity_id and every policy goes through can_access_identity(). Sharing
-- between identities is an explicit row in vault_shares, created by the
-- source identity, carrying the key wrapped to the grantee's public key.
--
-- One rule is added on top of the contract, and only ever narrows it: a
-- session minted for an *assistant* (public.devices.kind = 'assistant') gets
-- nothing from any vault table or function. Not the ciphertext, not the
-- public keys, not the share graph. The ciphertext would be useless to it
-- without the keys, but "useless" is a property of the cryptography and
-- "absent" is a property you can test.

--------------------------------------------------------------------------------
-- Who may use the vault at all
--------------------------------------------------------------------------------

-- True for a signed-in session that is not an assistant's. A scoped *device*
-- session (a machine acting for one identity) passes; the identity check is
-- can_access_identity()'s, applied separately by each policy.
create function public.vault_session_ok() returns boolean
language sql stable security definer
set search_path = ''
as $$
	select auth.uid() is not null
	   and not exists (
		select 1 from public.devices d
		where d.session_id = nullif(auth.jwt() ->> 'session_id', '')::uuid
		  and d.kind = 'assistant')
$$;

-- The one access rule for the vault, written once: the contract's rule, for a
-- session that is not an assistant's.
create function public.vault_can_access(target uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
	select public.vault_session_ok() and public.can_access_identity(target)
$$;

-- Base64 of bounded length. The server never decodes these; the check is
-- there so a column cannot be used to smuggle anything but opaque bytes.
create function public.vault_b64(v text, max_len integer) returns boolean
language sql immutable
set search_path = ''
as $$
	select v ~ '^[A-Za-z0-9+/]*={0,2}$' and char_length(v) <= max_len
$$;

--------------------------------------------------------------------------------
-- Keysets: one per identity
--------------------------------------------------------------------------------

-- An identity's public keys (in the clear: other identities need them to
-- share with it) and its private keys (sealed under the account key, which is
-- sealed under the account unlock key -- master password and Secret Key).
--
-- The KDF salt and parameters are in the clear because a client must know
-- them before it can derive anything. They are the same on every identity of
-- one account; they are repeated per identity so that no account-level table
-- is needed and a device scoped to one identity has everything it needs.
create table public.vault_keysets (
	identity_id      uuid primary key references public.identities (id) on delete cascade,
	format           integer not null default 1 check (format = 1),
	-- X25519 (32 bytes), ML-KEM-768 encapsulation key (1184), Ed25519 (32).
	enc_pub          text not null check (public.vault_b64(enc_pub, 44)),
	kem_pub          text not null check (public.vault_b64(kem_pub, 1580)),
	sign_pub         text not null check (public.vault_b64(sign_pub, 44)),
	kdf_salt         text not null check (public.vault_b64(kdf_salt, 24)),
	kdf_m            integer not null check (kdf_m between 8192 and 4194304),
	kdf_t            integer not null check (kdf_t between 1 and 64),
	kdf_p            integer not null check (kdf_p between 1 and 64),
	-- The account key under the account unlock key, and this identity's
	-- private keys under the account key. Both XChaCha20-Poly1305.
	account_key_wrap text not null check (public.vault_b64(account_key_wrap, 400)),
	private_wrap     text not null check (public.vault_b64(private_wrap, 800)),
	-- Bumped when the master password changes, so a device holding an old
	-- wrap knows to re-derive.
	key_epoch        integer not null default 1,
	created_at       timestamptz not null default now(),
	updated_at       timestamptz not null default now()
);

--------------------------------------------------------------------------------
-- Vaults, items, shares
--------------------------------------------------------------------------------

create table public.vault_vaults (
	id           uuid primary key,
	identity_id  uuid not null references public.identities (id) on delete cascade,
	-- The vault key, sealed to the owning identity's public keys.
	key_wrap     text not null check (public.vault_b64(key_wrap, 2400)),
	key_version  integer not null default 1 check (key_version >= 1),
	-- Name, colour and icon, under the vault key.
	meta         text not null check (public.vault_b64(meta, 2800)),
	revision     bigint not null default 1,
	created_at   timestamptz not null default now(),
	updated_at   timestamptz not null default now(),
	deleted_at   timestamptz,
	unique (id, identity_id)
);

create index vault_vaults_identity on public.vault_vaults (identity_id);

-- One record per item. `blob` is the whole item under its own item key;
-- `key_wrap` is the item key under the vault key. A tombstone keeps its id
-- and revision and drops both, so a deletion syncs like any other change.
create table public.vault_items (
	id           uuid primary key,
	identity_id  uuid not null,
	vault_id     uuid not null,
	revision     bigint not null check (revision >= 1),
	key_version  integer not null default 1 check (key_version >= 1),
	key_wrap     text check (key_wrap is null or public.vault_b64(key_wrap, 200)),
	blob         text check (blob is null or public.vault_b64(blob, 2800000)),
	deleted      boolean not null default false,
	created_at   timestamptz not null default now(),
	updated_at   timestamptz not null default now(),
	foreign key (vault_id, identity_id) references public.vault_vaults (id, identity_id) on delete cascade,
	check (deleted or (key_wrap is not null and blob is not null)),
	unique (id, vault_id)
);

create index vault_items_vault on public.vault_items (vault_id);
create index vault_items_identity on public.vault_items (identity_id);

-- Identity to identity, whole vault or one item. Made by the source identity.
-- `wrapped_key` is the vault key (or the item key) sealed to the grantee's
-- public keys; `signature` is the source identity's Ed25519 signature over
-- the share's canonical transcript, so a server that substitutes a key of its
-- own choosing is caught by the grantee (vault.md, "Signed shares").
-- Revoking sets revoked_at: the grantee stops receiving the rows at once, and
-- the client rotates the key so nothing synced afterwards opens under the old
-- one. The row stays as the record that the share existed.
create table public.vault_shares (
	id               uuid primary key,
	identity_id      uuid not null references public.identities (id) on delete cascade,
	vault_id         uuid not null,
	item_id          uuid,
	grantee_identity uuid not null references public.identities (id) on delete cascade,
	role             text not null default 'read' check (role in ('read', 'write')),
	key_version      integer not null check (key_version >= 1),
	wrapped_key      text not null check (public.vault_b64(wrapped_key, 2400)),
	signature        text not null check (public.vault_b64(signature, 88)),
	created_at       timestamptz not null default now(),
	revoked_at       timestamptz,
	foreign key (vault_id, identity_id) references public.vault_vaults (id, identity_id) on delete cascade,
	foreign key (item_id, vault_id) references public.vault_items (id, vault_id) on delete cascade,
	check (grantee_identity <> identity_id),
	-- An item share is read-only. Writing to someone else's item without
	-- holding its vault key would mean re-wrapping an item key the grantee
	-- cannot wrap; a whole-vault share is how editing is granted.
	check (item_id is null or role = 'read')
);

create unique index vault_shares_live on public.vault_shares
	(vault_id, coalesce(item_id, '00000000-0000-0000-0000-000000000000'::uuid), grantee_identity)
	where revoked_at is null;
create index vault_shares_grantee on public.vault_shares (grantee_identity) where revoked_at is null;

-- The devices that hold this identity's vault. `pub` is an X25519 key the
-- device generated; an already-enrolled device approves a new one by sealing
-- the account's Secret Key to it (sealed_secret), after the person compares
-- the short code both screens show. Revoking a device stops its sync through
-- public.devices (the session) -- this row is what tells the other devices
-- to stop trusting it, and it cannot take back what the device already holds.
create table public.vault_devices (
	id            uuid primary key,
	identity_id   uuid not null references public.identities (id) on delete cascade,
	name          text not null check (char_length(btrim(name)) between 1 and 80),
	pub           text not null check (public.vault_b64(pub, 44)),
	sealed_secret text check (sealed_secret is null or public.vault_b64(sealed_secret, 2400)),
	created_at    timestamptz not null default now(),
	approved_at   timestamptz,
	last_sync_at  timestamptz,
	revoked_at    timestamptz
);

create index vault_devices_identity on public.vault_devices (identity_id);

--------------------------------------------------------------------------------
-- Integrity: what may change, and what may not
--------------------------------------------------------------------------------

create function public.vault_touch() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	new.updated_at := now();
	return new;
end
$$;

create trigger vault_keysets_touch before update on public.vault_keysets
	for each row execute function public.vault_touch();
create trigger vault_vaults_touch before update on public.vault_vaults
	for each row execute function public.vault_touch();

-- An item's identity and vault are permanent (moving between vaults is a
-- delete and an insert, re-encrypted under the other vault's key), and its
-- revision only ever goes up by exactly one per write. The revision is what a
-- client compares to detect a conflict, so the server must not let anyone --
-- including a grantee with write access -- rewind or skip it.
create function public.vault_items_before_update() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if new.id <> old.id or new.identity_id <> old.identity_id or new.vault_id <> old.vault_id
	   or new.created_at <> old.created_at then
		raise exception 'an item''s id, identity and vault are permanent' using errcode = '42501';
	end if;
	if new.revision <> old.revision + 1 then
		raise exception 'an item''s revision goes up by one per write (was %, got %)', old.revision, new.revision
			using errcode = '40001';
	end if;
	if new.deleted then
		new.key_wrap := null;
		new.blob := null;
	end if;
	new.updated_at := now();
	return new;
end
$$;

create trigger vault_items_before_update before update on public.vault_items
	for each row execute function public.vault_items_before_update();

create function public.vault_items_before_insert() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if new.revision <> 1 then
		raise exception 'a new item starts at revision 1' using errcode = '40001';
	end if;
	new.created_at := now();
	new.updated_at := now();
	return new;
end
$$;

create trigger vault_items_before_insert before insert on public.vault_items
	for each row execute function public.vault_items_before_insert();

-- A share is fixed once made, apart from being revoked; changing what it
-- grants means revoking it and making a new one (which needs a new
-- signature, which only the source identity's client can produce).
create function public.vault_shares_before_update() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if (new.id, new.identity_id, new.vault_id, new.item_id, new.grantee_identity, new.role,
	    new.key_version, new.wrapped_key, new.signature, new.created_at)
	   is distinct from
	   (old.id, old.identity_id, old.vault_id, old.item_id, old.grantee_identity, old.role,
	    old.key_version, old.wrapped_key, old.signature, old.created_at) then
		raise exception 'a share can only be revoked, not changed' using errcode = '42501';
	end if;
	if old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at then
		raise exception 'a revoked share stays revoked' using errcode = '42501';
	end if;
	return new;
end
$$;

create trigger vault_shares_before_update before update on public.vault_shares
	for each row execute function public.vault_shares_before_update();

-- A device's key is fixed: approving a device seals the secret to *that* key,
-- and letting the key change afterwards would let whoever changed it receive
-- the next approval.
create function public.vault_devices_before_update() returns trigger
language plpgsql
set search_path = ''
as $$
begin
	if new.id <> old.id or new.identity_id <> old.identity_id or new.pub <> old.pub
	   or new.created_at <> old.created_at then
		raise exception 'a device''s identity and key are permanent' using errcode = '42501';
	end if;
	if old.revoked_at is not null and new.sealed_secret is distinct from old.sealed_secret then
		raise exception 'a revoked device cannot be approved' using errcode = '42501';
	end if;
	return new;
end
$$;

create trigger vault_devices_before_update before update on public.vault_devices
	for each row execute function public.vault_devices_before_update();

--------------------------------------------------------------------------------
-- Access helpers
--------------------------------------------------------------------------------

-- The role the caller holds on a vault, or on one item of it, through a live
-- share to an identity the caller may act for. Null when nothing reaches it.
-- Owners are not "shared"; their access is vault_can_access(identity_id).
create function public.vault_shared_role(p_vault uuid, p_item uuid) returns text
language sql stable security definer
set search_path = ''
as $$
	select case when bool_or(s.role = 'write') then 'write'
	            when count(*) > 0 then 'read' end
	from public.vault_shares s
	where s.vault_id = p_vault
	  and (s.item_id is null or s.item_id = p_item)
	  and s.revoked_at is null
	  and public.vault_session_ok()
	  and public.can_access_identity(s.grantee_identity)
$$;

-- Whether the caller holds a live whole-vault share (which is what lets it see
-- the vault's encrypted name and add items to it).
create function public.vault_vault_role(p_vault uuid) returns text
language sql stable security definer
set search_path = ''
as $$
	select case when bool_or(s.role = 'write') then 'write'
	            when count(*) > 0 then 'read' end
	from public.vault_shares s
	where s.vault_id = p_vault
	  and s.item_id is null
	  and s.revoked_at is null
	  and public.vault_session_ok()
	  and public.can_access_identity(s.grantee_identity)
$$;

revoke execute on function public.vault_shared_role(uuid, uuid) from public, anon;
revoke execute on function public.vault_vault_role(uuid) from public, anon;
grant execute on function public.vault_shared_role(uuid, uuid) to authenticated;
grant execute on function public.vault_vault_role(uuid) to authenticated;

--------------------------------------------------------------------------------
-- Policies
--------------------------------------------------------------------------------

alter table public.vault_keysets enable row level security;
alter table public.vault_vaults enable row level security;
alter table public.vault_items enable row level security;
alter table public.vault_shares enable row level security;
alter table public.vault_devices enable row level security;

create policy vault_keysets_select on public.vault_keysets for select
	using (public.vault_can_access(identity_id));
create policy vault_keysets_insert on public.vault_keysets for insert
	with check (public.vault_can_access(identity_id));
create policy vault_keysets_update on public.vault_keysets for update
	using (public.vault_can_access(identity_id))
	with check (public.vault_can_access(identity_id));
-- No delete: a keyset goes with its identity.

create policy vault_vaults_select on public.vault_vaults for select
	using (public.vault_can_access(identity_id) or public.vault_vault_role(id) is not null);
create policy vault_vaults_insert on public.vault_vaults for insert
	with check (public.vault_can_access(identity_id));
create policy vault_vaults_update on public.vault_vaults for update
	using (public.vault_can_access(identity_id))
	with check (public.vault_can_access(identity_id));
create policy vault_vaults_delete on public.vault_vaults for delete
	using (public.vault_can_access(identity_id));

create policy vault_items_select on public.vault_items for select
	using (public.vault_can_access(identity_id) or public.vault_shared_role(vault_id, id) is not null);
create policy vault_items_insert on public.vault_items for insert
	with check (public.vault_can_access(identity_id) or public.vault_vault_role(vault_id) = 'write');
create policy vault_items_update on public.vault_items for update
	using (public.vault_can_access(identity_id) or public.vault_vault_role(vault_id) = 'write')
	with check (public.vault_can_access(identity_id) or public.vault_vault_role(vault_id) = 'write');
-- Items are tombstoned, never deleted, so the deletion reaches every device.
-- The owner may purge (a vault deletion cascades too).
create policy vault_items_delete on public.vault_items for delete
	using (public.vault_can_access(identity_id));

-- The source sees its shares; the grantee sees what was shared with it.
create policy vault_shares_select on public.vault_shares for select
	using (public.vault_can_access(identity_id) or public.vault_can_access(grantee_identity));
create policy vault_shares_insert on public.vault_shares for insert
	with check (public.vault_can_access(identity_id));
create policy vault_shares_update on public.vault_shares for update
	using (public.vault_can_access(identity_id))
	with check (public.vault_can_access(identity_id));

create policy vault_devices_select on public.vault_devices for select
	using (public.vault_can_access(identity_id));
create policy vault_devices_insert on public.vault_devices for insert
	with check (public.vault_can_access(identity_id));
create policy vault_devices_update on public.vault_devices for update
	using (public.vault_can_access(identity_id))
	with check (public.vault_can_access(identity_id));

grant select, insert, update on public.vault_keysets to authenticated;
grant select, insert, update, delete on public.vault_vaults, public.vault_items to authenticated;
grant select, insert, update on public.vault_shares, public.vault_devices to authenticated;

--------------------------------------------------------------------------------
-- Functions
--------------------------------------------------------------------------------

-- Write one item, compare-and-swap on its revision. `p_base` is the revision
-- the client last saw (0 for a new item). Returns the stored row; when
-- someone else wrote first, raises 40001 with the current revision in the
-- detail, and the client merges (vault.md, "Conflicts").
--
-- Security invoker: the policies above decide whether the caller may write.
create function public.vault_put_item(
	p_id uuid,
	p_identity uuid,
	p_vault uuid,
	p_base bigint,
	p_key_version integer,
	p_key_wrap text,
	p_blob text,
	p_deleted boolean default false
) returns public.vault_items
language plpgsql
volatile
set search_path = ''
as $$
declare
	cur public.vault_items;
	r   public.vault_items;
begin
	if not public.vault_session_ok() then
		raise exception 'the vault is not available to this session' using errcode = '42501';
	end if;
	select * into cur from public.vault_items where id = p_id;
	if not found then
		if p_base <> 0 then
			-- Either it never existed, or this session cannot see it.
			raise exception 'no such item' using errcode = 'PT404';
		end if;
		insert into public.vault_items (id, identity_id, vault_id, revision, key_version, key_wrap, blob, deleted)
		values (p_id, p_identity, p_vault, 1, p_key_version, p_key_wrap, p_blob, p_deleted)
		returning * into r;
		return r;
	end if;
	if cur.revision <> p_base then
		raise exception 'conflict: the item is at revision %', cur.revision
			using errcode = '40001', detail = cur.revision::text, hint = 'vault_conflict';
	end if;
	update public.vault_items
	set revision = cur.revision + 1, key_version = p_key_version, key_wrap = p_key_wrap,
	    blob = p_blob, deleted = p_deleted
	where id = p_id and revision = p_base
	returning * into r;
	if not found then
		raise exception 'the item cannot be written by this session' using errcode = '42501';
	end if;
	return r;
end
$$;

revoke all on function public.vault_put_item(uuid, uuid, uuid, bigint, integer, text, text, boolean) from public, anon;
grant execute on function public.vault_put_item(uuid, uuid, uuid, bigint, integer, text, text, boolean) to authenticated;

-- The public half of an identity's keyset, found by handle: what a client
-- needs to share something with an identity it does not own. Public keys are
-- public, but the lookup is still refused to assistants, so that the vault
-- surface is absent for them rather than partly present.
create function public.vault_public_keys(p_handle text)
returns table (identity_id uuid, handle text, display_name text, enc_pub text, kem_pub text, sign_pub text)
language sql
stable
security definer
set search_path = ''
as $$
	select i.id, i.handle, i.display_name, k.enc_pub, k.kem_pub, k.sign_pub
	from public.identities i
	join public.vault_keysets k on k.identity_id = i.id
	where i.handle = lower(btrim(p_handle))
	  and i.archived_at is null
	  and public.vault_session_ok()
$$;

revoke all on function public.vault_public_keys(text) from public, anon;
grant execute on function public.vault_public_keys(text) to authenticated;

-- The same by identity id, for verifying a share's signature when the share
-- arrives: the grantee looks up the source identity's signing key.
create function public.vault_public_keys_by_id(p_identity uuid)
returns table (identity_id uuid, handle text, display_name text, enc_pub text, kem_pub text, sign_pub text)
language sql
stable
security definer
set search_path = ''
as $$
	select i.id, i.handle, i.display_name, k.enc_pub, k.kem_pub, k.sign_pub
	from public.identities i
	join public.vault_keysets k on k.identity_id = i.id
	where i.id = p_identity
	  and public.vault_session_ok()
$$;

revoke all on function public.vault_public_keys_by_id(uuid) from public, anon;
grant execute on function public.vault_public_keys_by_id(uuid) to authenticated;
