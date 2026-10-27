-- Montra sync. Run this once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Tables are locked; the app can only use the functions below.
-- Data is encrypted on the device before upload, so this database only ever holds unreadable blobs.

create table if not exists montra_vaults(
  id text primary key check (id ~ '^[0-9a-f]{32}$'),
  token_hash bytea not null,
  data text,
  version bigint not null default 0,
  updated_at timestamptz not null default now()
);
create table if not exists montra_pairs(
  code text primary key,
  vault_id text not null references montra_vaults(id) on delete cascade,
  payload text not null,
  expires_at timestamptz not null
);
create table if not exists montra_hits(ip text not null, kind text not null, at timestamptz not null default now());
create index if not exists montra_hits_idx on montra_hits(ip, kind, at);

alter table montra_vaults enable row level security;
alter table montra_pairs enable row level security;
alter table montra_hits enable row level security;
revoke all on montra_vaults, montra_pairs, montra_hits from public, anon, authenticated;

-- caller's IP as passed by the Supabase API gateway
create or replace function montra_ip() returns text language sql stable set search_path = public as $$
  select coalesce(
    nullif(current_setting('request.headers', true), '')::json->>'cf-connecting-ip',
    split_part(nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for', ',', 1),
    'unknown')
$$;

-- raise if this IP already did `kind` `lim` times within `win`
create or replace function montra_limit(kind text, lim int, win interval) returns void language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from montra_hits h where h.ip = montra_ip() and h.kind = montra_limit.kind and h.at > now() - win) >= lim then
    raise exception 'rate_limited';
  end if;
end $$;

create or replace function montra_auth(p_vault text, p_token text) returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from montra_vaults where id = p_vault and token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8')))
$$;

create or replace function montra_vault_create(p_vault text, p_token text) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if length(p_token) < 64 then raise exception 'bad_token'; end if;
  perform montra_limit('create', 10, interval '1 hour');
  insert into montra_hits(ip, kind) values (montra_ip(), 'create');
  insert into montra_vaults(id, token_hash) values (p_vault, sha256(convert_to(p_token, 'UTF8'))) on conflict do nothing;
  return found;
end $$;

-- returns {version, data}; data is null when the caller already has this version
create or replace function montra_pull(p_vault text, p_token text, p_have bigint) returns json language plpgsql security definer set search_path = public as $$
declare v montra_vaults;
begin
  if not montra_auth(p_vault, p_token) then raise exception 'not_found'; end if;
  select * into v from montra_vaults where id = p_vault;
  return json_build_object('version', v.version, 'data', case when v.version = p_have then null else v.data end);
end $$;

-- saves only if nobody else saved since `p_base`; otherwise returns ok=false so the app merges and retries
create or replace function montra_push(p_vault text, p_token text, p_data text, p_base bigint) returns json language plpgsql security definer set search_path = public as $$
declare nv bigint;
begin
  if not montra_auth(p_vault, p_token) then raise exception 'not_found'; end if;
  if length(p_data) > 15000000 then raise exception 'too_big'; end if;
  update montra_vaults set data = p_data, version = version + 1, updated_at = now()
    where id = p_vault and version = p_base returning version into nv;
  if nv is null then
    return json_build_object('ok', false, 'version', (select version from montra_vaults where id = p_vault));
  end if;
  return json_build_object('ok', true, 'version', nv);
end $$;

-- one active 6-digit code per vault, valid for 10 minutes
create or replace function montra_pair_create(p_vault text, p_token text, p_code text, p_payload text) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not montra_auth(p_vault, p_token) then raise exception 'not_found'; end if;
  if p_code !~ '^\d{6}$' or length(p_payload) > 4000 then raise exception 'bad_request'; end if;
  delete from montra_pairs where expires_at < now() or vault_id = p_vault;
  insert into montra_pairs(code, vault_id, payload, expires_at) values (p_code, p_vault, p_payload, now() + interval '10 minutes') on conflict do nothing;
  return found;
end $$;

create or replace function montra_pair_cancel(p_vault text, p_token text) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not montra_auth(p_vault, p_token) then raise exception 'not_found'; end if;
  delete from montra_pairs where vault_id = p_vault;
  return true;
end $$;

create or replace function montra_pair_status(p_vault text, p_token text) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not montra_auth(p_vault, p_token) then raise exception 'not_found'; end if;
  return exists(select 1 from montra_pairs where vault_id = p_vault and expires_at > now());
end $$;

-- a code works once; 10 wrong codes from one IP block it for 15 minutes
create or replace function montra_pair_claim(p_code text) returns text language plpgsql security definer set search_path = public as $$
declare v text;
begin
  perform montra_limit('claim_fail', 10, interval '15 minutes');
  delete from montra_hits where at < now() - interval '1 day';
  delete from montra_pairs where code = p_code and expires_at > now() returning payload into v;
  if v is null then
    insert into montra_hits(ip, kind) values (montra_ip(), 'claim_fail');
  end if;
  return v;
end $$;

create or replace function montra_vault_delete(p_vault text, p_token text) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not montra_auth(p_vault, p_token) then raise exception 'not_found'; end if;
  delete from montra_vaults where id = p_vault;
  return true;
end $$;

revoke execute on function montra_ip(), montra_limit(text, int, interval), montra_auth(text, text) from public, anon, authenticated;
revoke execute on function montra_vault_create(text, text), montra_pull(text, text, bigint), montra_push(text, text, text, bigint),
  montra_pair_create(text, text, text, text), montra_pair_status(text, text), montra_pair_cancel(text, text), montra_pair_claim(text), montra_vault_delete(text, text) from public;
grant execute on function montra_vault_create(text, text), montra_pull(text, text, bigint), montra_push(text, text, text, bigint),
  montra_pair_create(text, text, text, text), montra_pair_status(text, text), montra_pair_cancel(text, text), montra_pair_claim(text), montra_vault_delete(text, text) to anon, authenticated;
