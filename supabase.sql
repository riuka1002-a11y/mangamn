-- Run once in Supabase Dashboard -> SQL Editor
create extension if not exists pgcrypto;

create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Хэрэглэгч',
  role text not null default 'reader' check(role in('reader','translator','admin')),
  avatar_url text,
  created_at timestamptz not null default now()
);

-- Existing role constraint upgrade.
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check(role in('reader','translator','admin'));

create table if not exists public.translator_invites(
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  active boolean not null default true,
  max_uses integer not null default 1 check(max_uses>0),
  used_count integer not null default 0 check(used_count>=0),
  expires_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.mangas(
  id uuid primary key default gen_random_uuid(),
  translator_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check(char_length(title) between 1 and 120),
  slug text not null unique,
  description text not null default '',
  cover_url text,
  cover_path text,
  genres text[] not null default '{}',
  status text not null default 'draft' check(status in('draft','published')),
  series_status text not null default 'ongoing' check(series_status in('ongoing','completed','hiatus')),
  is_featured boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.chapters(
  id uuid primary key default gen_random_uuid(),
  manga_id uuid not null references public.mangas(id) on delete cascade,
  chapter_number numeric(8,2) not null check(chapter_number>=0),
  title text not null default '',
  published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(manga_id,chapter_number)
);
create table if not exists public.chapter_pages(
  id uuid primary key default gen_random_uuid(),
  chapter_id uuid not null references public.chapters(id) on delete cascade,
  image_url text not null,
  storage_path text not null,
  page_order integer not null check(page_order>0),
  created_at timestamptz not null default now(),
  unique(chapter_id,page_order)
);
create table if not exists public.favorites(
  user_id uuid not null references public.profiles(id) on delete cascade,
  manga_id uuid not null references public.mangas(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(user_id,manga_id)
);
create table if not exists public.reading_progress(
  user_id uuid not null references public.profiles(id) on delete cascade,
  chapter_id uuid not null references public.chapters(id) on delete cascade,
  page_index integer not null default 0 check(page_index>=0),
  updated_at timestamptz not null default now(),
  primary key(user_id,chapter_id)
);

-- Existing project upgrade: safe to run repeatedly.
alter table public.mangas
  add column if not exists series_status text not null default 'ongoing';

alter table public.mangas
  add column if not exists is_featured boolean not null default false;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='mangas_series_status_check'
      and conrelid='public.mangas'::regclass
  ) then
    alter table public.mangas
      add constraint mangas_series_status_check
      check(series_status in('ongoing','completed','hiatus'));
  end if;
end $$;

create table if not exists public.membership_plans(
  code text primary key,
  name text not null,
  duration_months integer not null check(duration_months>0),
  price_mnt integer not null check(price_mnt>0),
  description text not null default '',
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create table if not exists public.memberships(
  user_id uuid primary key references public.profiles(id) on delete cascade,
  plan_code text not null references public.membership_plans(code),
  starts_at timestamptz not null default now(),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.membership_requests(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  plan_code text not null references public.membership_plans(code),
  amount_mnt integer not null check(amount_mnt>0),
  sender_name text not null check(char_length(sender_name) between 2 and 120),
  transfer_reference text not null check(char_length(transfer_reference) between 2 and 180),
  transfer_date date not null,
  receipt_path text not null,
  status text not null default 'pending' check(status in('pending','approved','rejected')),
  admin_note text not null default '',
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists membership_requests_user_idx on public.membership_requests(user_id,created_at desc);
create index if not exists membership_requests_status_idx on public.membership_requests(status,created_at desc);

insert into public.membership_plans(code,name,duration_months,price_mnt,description,active,sort_order) values
('month1','1 сарын эрх',1,6900,'Бүх нийтлэгдсэн манга болон бүлгийг 1 сар унших эрх.',true,10),
('quarter','Улирлын эрх',3,26000,'Бүх нийтлэгдсэн манга болон бүлгийг 3 сар унших эрх.',true,20),
('halfyear','Хагас жилийн эрх',6,38000,'Бүх нийтлэгдсэн манга болон бүлгийг 6 сар унших эрх.',true,30),
('year','Жилийн эрх',12,81800,'Бүх нийтлэгдсэн манга болон бүлгийг 12 сар унших эрх.',true,40)
on conflict(code) do update set
 name=excluded.name,duration_months=excluded.duration_months,price_mnt=excluded.price_mnt,
 description=excluded.description,active=excluded.active,sort_order=excluded.sort_order;

create index if not exists mangas_status_created_idx on public.mangas(status,created_at desc);
create index if not exists mangas_status_updated_idx on public.mangas(status,updated_at desc);
create index if not exists mangas_series_status_idx on public.mangas(series_status);
create index if not exists mangas_translator_idx on public.mangas(translator_id);
create index if not exists chapters_manga_number_idx on public.chapters(manga_id,chapter_number);
create index if not exists pages_chapter_order_idx on public.chapter_pages(chapter_id,page_order);

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.profiles(id,display_name,role)
 values(new.id,coalesce(nullif(new.raw_user_meta_data->>'display_name',''),split_part(new.email,'@',1),'Хэрэглэгч'),'reader')
 on conflict(id) do nothing;
 return new;
end;$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.claim_translator_role(invite_code text) returns boolean language plpgsql security definer set search_path=public as $$
declare invite_row public.translator_invites%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if exists(select 1 from public.profiles where id=auth.uid() and role='translator') then return true; end if;
 select * into invite_row from public.translator_invites
 where code=trim(invite_code) and active=true and used_count<max_uses and(expires_at is null or expires_at>now()) for update;
 if not found then raise exception 'Invalid or expired translator invite'; end if;
 update public.translator_invites set used_count=used_count+1,active=case when used_count+1>=max_uses then false else active end where id=invite_row.id;
 update public.profiles set role='translator' where id=auth.uid();
 return true;
end;$$;
revoke all on function public.claim_translator_role(text) from public;
grant execute on function public.claim_translator_role(text) to authenticated;


create or replace function public.is_admin(check_user uuid default auth.uid())
returns boolean language sql security definer stable set search_path=public as $$
  select exists(select 1 from public.profiles where id=check_user and role='admin');
$$;

create or replace function public.has_active_membership(check_user uuid default auth.uid())
returns boolean language sql security definer stable set search_path=public as $$
  select exists(select 1 from public.memberships where user_id=check_user and expires_at>now());
$$;

revoke all on function public.is_admin(uuid) from public;
revoke all on function public.has_active_membership(uuid) from public;
grant execute on function public.is_admin(uuid) to authenticated;
grant execute on function public.has_active_membership(uuid) to authenticated;

create or replace function public.submit_membership_request(
  p_plan_code text,
  p_sender_name text,
  p_transfer_reference text,
  p_transfer_date date,
  p_receipt_path text
) returns uuid
language plpgsql security definer set search_path=public as $$
declare
  plan_row public.membership_plans%rowtype;
  new_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into plan_row from public.membership_plans where code=p_plan_code and active=true;
  if not found then raise exception 'Invalid membership plan'; end if;
  if split_part(p_receipt_path,'/',1)<>auth.uid()::text then raise exception 'Invalid receipt path'; end if;
  if exists(select 1 from public.membership_requests where user_id=auth.uid() and status='pending') then
    raise exception 'A pending request already exists';
  end if;
  insert into public.membership_requests(user_id,plan_code,amount_mnt,sender_name,transfer_reference,transfer_date,receipt_path)
  values(auth.uid(),plan_row.code,plan_row.price_mnt,trim(p_sender_name),trim(p_transfer_reference),p_transfer_date,p_receipt_path)
  returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.review_membership_request(
  p_request_id uuid,
  p_approve boolean,
  p_admin_note text default ''
) returns timestamptz
language plpgsql security definer set search_path=public as $$
declare
  req public.membership_requests%rowtype;
  duration integer;
  base_time timestamptz;
  new_expiry timestamptz;
begin
  if not public.is_admin(auth.uid()) then raise exception 'Admin access required'; end if;
  select * into req from public.membership_requests where id=p_request_id for update;
  if not found then raise exception 'Request not found'; end if;
  if req.status<>'pending' then raise exception 'Request already reviewed'; end if;
  if p_approve then
    select duration_months into duration from public.membership_plans where code=req.plan_code;
    select greatest(now(),coalesce(expires_at,now())) into base_time from public.memberships where user_id=req.user_id;
    if base_time is null then base_time:=now(); end if;
    new_expiry:=base_time+make_interval(months=>duration);
    insert into public.memberships(user_id,plan_code,starts_at,expires_at,updated_at)
    values(req.user_id,req.plan_code,now(),new_expiry,now())
    on conflict(user_id) do update set plan_code=excluded.plan_code,expires_at=new_expiry,updated_at=now();
    update public.membership_requests set status='approved',admin_note=coalesce(p_admin_note,''),reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=p_request_id;
    return new_expiry;
  end if;
  update public.membership_requests set status='rejected',admin_note=coalesce(p_admin_note,''),reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=p_request_id;
  return null;
end;
$$;

revoke all on function public.submit_membership_request(text,text,text,date,text) from public;
revoke all on function public.review_membership_request(uuid,boolean,text) from public;
grant execute on function public.submit_membership_request(text,text,text,date,text) to authenticated;
grant execute on function public.review_membership_request(uuid,boolean,text) to authenticated;

create or replace function public.touch_parent_manga()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare parent_id uuid;
begin
  parent_id := case when tg_op='DELETE' then old.manga_id else new.manga_id end;
  update public.mangas set updated_at=now() where id=parent_id;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists chapters_touch_parent_manga on public.chapters;
create trigger chapters_touch_parent_manga
after insert or update or delete on public.chapters
for each row execute procedure public.touch_parent_manga();

create or replace function public.get_home_sections()
returns jsonb
language sql
security definer
stable
set search_path=public
as $$
with base as (
  select
    m.id,
    m.title,
    m.slug,
    m.description,
    m.cover_url,
    m.genres,
    m.status,
    m.series_status,
    m.is_featured,
    m.created_at,
    m.updated_at,
    count(distinct f.user_id)::integer as favorite_count,
    count(distinct c.id) filter (where c.published=true)::integer as chapter_count,
    max(c.chapter_number) filter (where c.published=true) as latest_chapter
  from public.mangas m
  left join public.favorites f on f.manga_id=m.id
  left join public.chapters c on c.manga_id=m.id
  where m.status='published'
  group by m.id
),
latest_rows as (
  select * from base
  order by is_featured desc, updated_at desc, created_at desc
  limit 12
),
top_rows as (
  select * from base
  order by favorite_count desc, chapter_count desc, updated_at desc
  limit 10
),
completed_rows as (
  select * from base
  where series_status='completed'
  order by updated_at desc, created_at desc
  limit 12
)
select jsonb_build_object(
  'latest', coalesce((select jsonb_agg(to_jsonb(x) order by x.is_featured desc,x.updated_at desc) from latest_rows x),'[]'::jsonb),
  'top10', coalesce((select jsonb_agg(to_jsonb(x) order by x.favorite_count desc,x.chapter_count desc,x.updated_at desc) from top_rows x),'[]'::jsonb),
  'completed', coalesce((select jsonb_agg(to_jsonb(x) order by x.updated_at desc) from completed_rows x),'[]'::jsonb)
);
$$;

revoke all on function public.get_home_sections() from public;
grant execute on function public.get_home_sections() to authenticated;

alter table public.profiles enable row level security;
alter table public.translator_invites enable row level security;
alter table public.mangas enable row level security;
alter table public.chapters enable row level security;
alter table public.chapter_pages enable row level security;
alter table public.favorites enable row level security;
alter table public.reading_progress enable row level security;
alter table public.membership_plans enable row level security;
alter table public.memberships enable row level security;
alter table public.membership_requests enable row level security;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin(auth.uid()));
-- translator_invites intentionally has no direct client policies.

drop policy if exists mangas_select_visible on public.mangas;
create policy mangas_select_visible on public.mangas for select to authenticated using(status='published' or translator_id=auth.uid());
drop policy if exists mangas_insert_translator on public.mangas;
create policy mangas_insert_translator on public.mangas for insert to authenticated with check(translator_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='translator'));
drop policy if exists mangas_update_owner on public.mangas;
create policy mangas_update_owner on public.mangas for update to authenticated using(translator_id=auth.uid()) with check(translator_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='translator'));
drop policy if exists mangas_delete_owner on public.mangas;
create policy mangas_delete_owner on public.mangas for delete to authenticated using(translator_id=auth.uid());

drop policy if exists chapters_select_visible on public.chapters;
create policy chapters_select_visible on public.chapters for select to authenticated using(exists(select 1 from public.mangas m where m.id=chapters.manga_id and((m.status='published' and chapters.published=true) or m.translator_id=auth.uid())));
drop policy if exists chapters_insert_owner on public.chapters;
create policy chapters_insert_owner on public.chapters for insert to authenticated with check(exists(select 1 from public.mangas m join public.profiles p on p.id=auth.uid() where m.id=chapters.manga_id and m.translator_id=auth.uid() and p.role='translator'));
drop policy if exists chapters_update_owner on public.chapters;
create policy chapters_update_owner on public.chapters for update to authenticated using(exists(select 1 from public.mangas m where m.id=chapters.manga_id and m.translator_id=auth.uid())) with check(exists(select 1 from public.mangas m where m.id=chapters.manga_id and m.translator_id=auth.uid()));
drop policy if exists chapters_delete_owner on public.chapters;
create policy chapters_delete_owner on public.chapters for delete to authenticated using(exists(select 1 from public.mangas m where m.id=chapters.manga_id and m.translator_id=auth.uid()));

drop policy if exists pages_select_visible on public.chapter_pages;
create policy pages_select_visible on public.chapter_pages for select to authenticated using(exists(select 1 from public.chapters c join public.mangas m on m.id=c.manga_id where c.id=chapter_pages.chapter_id and((m.status='published' and c.published=true and(public.has_active_membership(auth.uid()) or exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in('translator','admin')))) or m.translator_id=auth.uid() or public.is_admin(auth.uid()))));
drop policy if exists pages_insert_owner on public.chapter_pages;
create policy pages_insert_owner on public.chapter_pages for insert to authenticated with check(exists(select 1 from public.chapters c join public.mangas m on m.id=c.manga_id where c.id=chapter_pages.chapter_id and m.translator_id=auth.uid()));
drop policy if exists pages_update_owner on public.chapter_pages;
create policy pages_update_owner on public.chapter_pages for update to authenticated using(exists(select 1 from public.chapters c join public.mangas m on m.id=c.manga_id where c.id=chapter_pages.chapter_id and m.translator_id=auth.uid())) with check(exists(select 1 from public.chapters c join public.mangas m on m.id=c.manga_id where c.id=chapter_pages.chapter_id and m.translator_id=auth.uid()));
drop policy if exists pages_delete_owner on public.chapter_pages;
create policy pages_delete_owner on public.chapter_pages for delete to authenticated using(exists(select 1 from public.chapters c join public.mangas m on m.id=c.manga_id where c.id=chapter_pages.chapter_id and m.translator_id=auth.uid()));

drop policy if exists favorites_own_all on public.favorites;
create policy favorites_own_all on public.favorites for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists progress_own_all on public.reading_progress;
create policy progress_own_all on public.reading_progress for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());


drop policy if exists membership_plans_read on public.membership_plans;
create policy membership_plans_read on public.membership_plans for select to authenticated using(active=true or public.is_admin(auth.uid()));

drop policy if exists memberships_read_own_or_admin on public.memberships;
create policy memberships_read_own_or_admin on public.memberships for select to authenticated using(user_id=auth.uid() or public.is_admin(auth.uid()));

drop policy if exists membership_requests_read_own_or_admin on public.membership_requests;
create policy membership_requests_read_own_or_admin on public.membership_requests for select to authenticated using(user_id=auth.uid() or public.is_admin(auth.uid()));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('manga-pages','manga-pages',true,12582912,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=excluded.public,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists manga_images_public_read on storage.objects;
create policy manga_images_public_read on storage.objects for select to public using(bucket_id='manga-pages');
drop policy if exists translator_upload_own_folder on storage.objects;
create policy translator_upload_own_folder on storage.objects for insert to authenticated with check(bucket_id='manga-pages' and(storage.foldername(name))[1]=auth.uid()::text and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='translator'));
drop policy if exists translator_update_own_folder on storage.objects;
create policy translator_update_own_folder on storage.objects for update to authenticated using(bucket_id='manga-pages' and(storage.foldername(name))[1]=auth.uid()::text) with check(bucket_id='manga-pages' and(storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists translator_delete_own_folder on storage.objects;
create policy translator_delete_own_folder on storage.objects for delete to authenticated using(bucket_id='manga-pages' and(storage.foldername(name))[1]=auth.uid()::text);



insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('membership-receipts','membership-receipts',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict(id) do update set public=excluded.public,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists membership_receipts_insert_own on storage.objects;
create policy membership_receipts_insert_own on storage.objects for insert to authenticated
with check(bucket_id='membership-receipts' and(storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists membership_receipts_read_own_or_admin on storage.objects;
create policy membership_receipts_read_own_or_admin on storage.objects for select to authenticated
using(bucket_id='membership-receipts' and((storage.foldername(name))[1]=auth.uid()::text or public.is_admin(auth.uid())));
drop policy if exists membership_receipts_delete_own_pending on storage.objects;
create policy membership_receipts_delete_own_pending on storage.objects for delete to authenticated
using(bucket_id='membership-receipts' and(storage.foldername(name))[1]=auth.uid()::text);

insert into public.translator_invites(code,max_uses) values('CHANGE-ME-TRANSLATOR',5) on conflict(code) do nothing;


-- IMPORTANT: After creating your own account, run this ONCE with your real login email.
-- update public.profiles
-- set role='admin'
-- where id=(select id from auth.users where email='YOUR-ADMIN-EMAIL@example.com');


-- ============================================================
-- V9 PATCH — membership plan repair + controlled team access
-- Run safely on existing projects. Re-runnable.
-- ============================================================
create extension if not exists pgcrypto;

-- Always repair/seed the four paid plans so the select is never empty.
insert into public.membership_plans(code,name,duration_months,price_mnt,description,active,sort_order) values
('month1','1 сарын эрх',1,6900,'Бүх нийтлэгдсэн манга болон бүлгийг 1 сар унших эрх.',true,10),
('quarter','Улирлын эрх',3,26000,'Бүх нийтлэгдсэн манга болон бүлгийг 3 сар унших эрх.',true,20),
('halfyear','Хагас жилийн эрх',6,38000,'Бүх нийтлэгдсэн манга болон бүлгийг 6 сар унших эрх.',true,30),
('year','Жилийн эрх',12,81800,'Бүх нийтлэгдсэн манга болон бүлгийг 12 сар унших эрх.',true,40)
on conflict(code) do update set
 name=excluded.name,duration_months=excluded.duration_months,price_mnt=excluded.price_mnt,
 description=excluded.description,active=true,sort_order=excluded.sort_order;

drop policy if exists membership_plans_read on public.membership_plans;
create policy membership_plans_read on public.membership_plans
for select to authenticated using(active=true or public.is_admin(auth.uid()));

create table if not exists public.translator_teams(
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  code_hash text not null,
  max_members integer not null default 20 check(max_members between 1 and 20),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.translator_team_members(
  team_id uuid not null references public.translator_teams(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key(team_id,user_id),
  unique(user_id)
);

alter table public.profiles add column if not exists translator_team_id uuid references public.translator_teams(id) on delete set null;
alter table public.mangas add column if not exists team_id uuid references public.translator_teams(id) on delete set null;
create index if not exists profiles_translator_team_idx on public.profiles(translator_team_id);
create index if not exists mangas_team_idx on public.mangas(team_id);
create index if not exists translator_team_members_team_idx on public.translator_team_members(team_id);

-- Create/update the main team. Code is stored as a bcrypt hash, not plain text.
insert into public.translator_teams(name,code_hash,max_members,active)
select 'OOOMAAGAAD баг',crypt('OOOMAAGAAD',gen_salt('bf')),20,true
where not exists(select 1 from public.translator_teams where name='OOOMAAGAAD баг');
update public.translator_teams
set code_hash=crypt('OOOMAAGAAD',gen_salt('bf')),max_members=20,active=true
where name='OOOMAAGAAD баг';

create or replace function public.join_translator_team(p_team_code text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  team_row public.translator_teams%rowtype;
  member_total integer;
begin
  if auth.uid() is null then raise exception 'Нэвтэрсэн хэрэглэгч шаардлагатай'; end if;

  select * into team_row
  from public.translator_teams
  where active=true
    and code_hash=crypt(upper(trim(p_team_code)),code_hash)
  for update;

  if not found then raise exception 'Багийн код буруу эсвэл идэвхгүй байна'; end if;

  if exists(select 1 from public.translator_team_members where user_id=auth.uid()) then
    select count(*) into member_total from public.translator_team_members where team_id=team_row.id;
    return jsonb_build_object('id',team_row.id,'name',team_row.name,'member_count',member_total,'max_members',team_row.max_members);
  end if;

  select count(*) into member_total from public.translator_team_members where team_id=team_row.id;
  if member_total >= team_row.max_members then raise exception 'Энэ багийн 20 гишүүний лимит дүүрсэн байна'; end if;

  insert into public.translator_team_members(team_id,user_id) values(team_row.id,auth.uid());
  update public.profiles set role='translator',translator_team_id=team_row.id where id=auth.uid();

  member_total := member_total + 1;
  return jsonb_build_object('id',team_row.id,'name',team_row.name,'member_count',member_total,'max_members',team_row.max_members);
end;
$$;

create or replace function public.get_my_translator_team()
returns jsonb
language sql
security definer
stable
set search_path=public
as $$
  select case when t.id is null then null else jsonb_build_object(
    'id',t.id,'name',t.name,'member_count',(select count(*) from public.translator_team_members tm where tm.team_id=t.id),'max_members',t.max_members
  ) end
  from public.profiles p
  left join public.translator_teams t on t.id=p.translator_team_id
  where p.id=auth.uid();
$$;

create or replace function public.same_translator_team(other_user uuid)
returns boolean
language sql
security definer
stable
set search_path=public
as $$
  select public.is_admin(auth.uid()) or exists(
    select 1 from public.profiles me join public.profiles other on other.id=other_user
    where me.id=auth.uid() and me.translator_team_id is not null and me.translator_team_id=other.translator_team_id
  );
$$;

create or replace function public.can_manage_manga(check_manga uuid)
returns boolean
language sql
security definer
stable
set search_path=public
as $$
  select public.is_admin(auth.uid()) or exists(
    select 1 from public.mangas m join public.profiles p on p.id=auth.uid()
    where m.id=check_manga and (m.translator_id=auth.uid() or (m.team_id is not null and p.translator_team_id=m.team_id and p.role='translator'))
  );
$$;

revoke all on function public.join_translator_team(text) from public;
revoke all on function public.get_my_translator_team() from public;
revoke all on function public.same_translator_team(uuid) from public;
revoke all on function public.can_manage_manga(uuid) from public;
grant execute on function public.join_translator_team(text) to authenticated;
grant execute on function public.get_my_translator_team() to authenticated;
grant execute on function public.same_translator_team(uuid) to authenticated;
grant execute on function public.can_manage_manga(uuid) to authenticated;

-- Disable the old self-selected translator invite path.
do $$ begin
  if to_regprocedure('public.claim_translator_role(text)') is not null then
    revoke execute on function public.claim_translator_role(text) from authenticated;
  end if;
end $$;

alter table public.translator_teams enable row level security;
alter table public.translator_team_members enable row level security;
-- Direct client reads are intentionally blocked; only the security-definer RPCs expose safe summaries.

-- Attach existing translator-owned manga to that translator's team when possible.
update public.mangas m set team_id=p.translator_team_id
from public.profiles p
where p.id=m.translator_id and m.team_id is null and p.translator_team_id is not null;

-- Team-aware manga policies.
drop policy if exists mangas_select_visible on public.mangas;
create policy mangas_select_visible on public.mangas for select to authenticated
using(status='published' or public.can_manage_manga(id));

drop policy if exists mangas_insert_translator on public.mangas;
create policy mangas_insert_translator on public.mangas for insert to authenticated
with check(
  translator_id=auth.uid()
  and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='translator' and p.translator_team_id=team_id)
);

drop policy if exists mangas_update_owner on public.mangas;
create policy mangas_update_owner on public.mangas for update to authenticated
using(public.can_manage_manga(id))
with check(public.can_manage_manga(id) and (public.is_admin(auth.uid()) or team_id=(select translator_team_id from public.profiles where id=auth.uid())));

drop policy if exists mangas_delete_owner on public.mangas;
create policy mangas_delete_owner on public.mangas for delete to authenticated
using(public.can_manage_manga(id));

-- Team-aware chapter policies.
drop policy if exists chapters_select_visible on public.chapters;
create policy chapters_select_visible on public.chapters for select to authenticated
using(exists(select 1 from public.mangas m where m.id=chapters.manga_id and ((m.status='published' and chapters.published=true) or public.can_manage_manga(m.id))));

drop policy if exists chapters_insert_owner on public.chapters;
create policy chapters_insert_owner on public.chapters for insert to authenticated
with check(public.can_manage_manga(manga_id));

drop policy if exists chapters_update_owner on public.chapters;
create policy chapters_update_owner on public.chapters for update to authenticated
using(public.can_manage_manga(manga_id)) with check(public.can_manage_manga(manga_id));

drop policy if exists chapters_delete_owner on public.chapters;
create policy chapters_delete_owner on public.chapters for delete to authenticated
using(public.can_manage_manga(manga_id));

-- Team-aware page policies while preserving paid-reader access.
drop policy if exists pages_select_visible on public.chapter_pages;
create policy pages_select_visible on public.chapter_pages for select to authenticated
using(exists(select 1 from public.chapters c join public.mangas m on m.id=c.manga_id
  where c.id=chapter_pages.chapter_id and (
    (m.status='published' and c.published=true and (public.has_active_membership(auth.uid()) or exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in('translator','admin'))))
    or public.can_manage_manga(m.id)
  )
));

drop policy if exists pages_insert_owner on public.chapter_pages;
create policy pages_insert_owner on public.chapter_pages for insert to authenticated
with check(exists(select 1 from public.chapters c where c.id=chapter_pages.chapter_id and public.can_manage_manga(c.manga_id)));

drop policy if exists pages_update_owner on public.chapter_pages;
create policy pages_update_owner on public.chapter_pages for update to authenticated
using(exists(select 1 from public.chapters c where c.id=chapter_pages.chapter_id and public.can_manage_manga(c.manga_id)))
with check(exists(select 1 from public.chapters c where c.id=chapter_pages.chapter_id and public.can_manage_manga(c.manga_id)));

drop policy if exists pages_delete_owner on public.chapter_pages;
create policy pages_delete_owner on public.chapter_pages for delete to authenticated
using(exists(select 1 from public.chapters c where c.id=chapter_pages.chapter_id and public.can_manage_manga(c.manga_id)));

-- Team members may update/delete files uploaded by another member of the same team.
drop policy if exists translator_update_own_folder on storage.objects;
create policy translator_update_own_folder on storage.objects for update to authenticated
using(bucket_id='manga-pages' and (
  (storage.foldername(name))[1]=auth.uid()::text or
  ((storage.foldername(name))[1] ~* '^[0-9a-f-]{36}$' and public.same_translator_team(((storage.foldername(name))[1])::uuid))
))
with check(bucket_id='manga-pages' and (
  (storage.foldername(name))[1]=auth.uid()::text or
  ((storage.foldername(name))[1] ~* '^[0-9a-f-]{36}$' and public.same_translator_team(((storage.foldername(name))[1])::uuid))
));

drop policy if exists translator_delete_own_folder on storage.objects;
create policy translator_delete_own_folder on storage.objects for delete to authenticated
using(bucket_id='manga-pages' and (
  (storage.foldername(name))[1]=auth.uid()::text or
  ((storage.foldername(name))[1] ~* '^[0-9a-f-]{36}$' and public.same_translator_team(((storage.foldername(name))[1])::uuid))
));


-- ============================================================
-- V10 PATCH — auth-safe features, chapter interactions, super likes
-- ============================================================

alter table public.translator_teams add column if not exists bank_name text not null default 'M банк';
alter table public.translator_teams add column if not exists bank_account text not null default '8010 28 4219';
alter table public.translator_teams add column if not exists bank_iban text not null default 'MN1000 3900 8010 28 4219';
alter table public.translator_teams add column if not exists bank_holder text not null default 'Ариун-Эрдэнэ';
update public.translator_teams set bank_name='M банк',bank_account='8010 28 4219',bank_iban='MN1000 3900 8010 28 4219',bank_holder='Ариун-Эрдэнэ' where name='OOOMAAGAAD баг';

create table if not exists public.chapter_comments(
  id uuid primary key default gen_random_uuid(),
  chapter_id uuid not null references public.chapters(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check(char_length(body) between 1 and 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists chapter_comments_chapter_idx on public.chapter_comments(chapter_id,created_at desc);
create index if not exists chapter_comments_user_idx on public.chapter_comments(user_id,created_at desc);

create table if not exists public.chapter_likes(
  chapter_id uuid not null references public.chapters(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(chapter_id,user_id)
);
create index if not exists chapter_likes_chapter_idx on public.chapter_likes(chapter_id);

create table if not exists public.super_like_requests(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  team_id uuid not null references public.translator_teams(id) on delete cascade,
  chapter_id uuid not null references public.chapters(id) on delete cascade,
  quantity integer not null check(quantity between 1 and 9999),
  unit_price_mnt integer not null default 1000 check(unit_price_mnt=1000),
  amount_mnt integer not null check(amount_mnt>0),
  sender_name text not null check(char_length(sender_name) between 2 and 120),
  transfer_reference text not null check(char_length(transfer_reference) between 2 and 180),
  transfer_date date not null,
  receipt_path text not null,
  status text not null default 'pending' check(status in('pending','approved','rejected')),
  admin_note text not null default '',
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(amount_mnt=quantity*unit_price_mnt)
);
create index if not exists super_like_requests_team_idx on public.super_like_requests(team_id,status,created_at desc);
create index if not exists super_like_requests_chapter_idx on public.super_like_requests(chapter_id,status);
create index if not exists super_like_requests_user_idx on public.super_like_requests(user_id,created_at desc);

create or replace function public.can_interact_with_chapter(p_chapter_id uuid)
returns boolean language sql security definer stable set search_path=public as $$
  select exists(
    select 1 from public.chapters c join public.mangas m on m.id=c.manga_id
    where c.id=p_chapter_id and (
      public.can_manage_manga(m.id)
      or (m.status='published' and c.published=true and (
        public.has_active_membership(auth.uid())
        or exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in('translator','admin'))
      ))
    )
  );
$$;

create or replace function public.get_chapter_social(p_chapter_id uuid)
returns jsonb language sql security definer stable set search_path=public as $$
  select case when not public.can_interact_with_chapter(p_chapter_id) then
    jsonb_build_object('comments','[]'::jsonb,'like_count',0,'comment_count',0,'super_like_count',0,'user_liked',false,'team',null)
  else jsonb_build_object(
    'like_count',(select count(*) from public.chapter_likes l where l.chapter_id=p_chapter_id),
    'comment_count',(select count(*) from public.chapter_comments c where c.chapter_id=p_chapter_id),
    'super_like_count',(select coalesce(sum(quantity),0) from public.super_like_requests s where s.chapter_id=p_chapter_id and s.status='approved'),
    'user_liked',exists(select 1 from public.chapter_likes l where l.chapter_id=p_chapter_id and l.user_id=auth.uid()),
    'comments',coalesce((select jsonb_agg(jsonb_build_object(
      'id',c.id,'body',c.body,'created_at',c.created_at,'display_name',p.display_name,
      'can_delete',(c.user_id=auth.uid() or public.is_admin(auth.uid()) or public.can_manage_manga(ch.manga_id))
    ) order by c.created_at desc)
      from public.chapter_comments c join public.profiles p on p.id=c.user_id join public.chapters ch on ch.id=c.chapter_id
      where c.chapter_id=p_chapter_id),'[]'::jsonb),
    'team',(select case when t.id is null then null else jsonb_build_object(
      'id',t.id,'name',t.name,'bank_name',t.bank_name,'bank_account',t.bank_account,'bank_iban',t.bank_iban,'bank_holder',t.bank_holder
    ) end from public.chapters c join public.mangas m on m.id=c.manga_id left join public.translator_teams t on t.id=m.team_id where c.id=p_chapter_id)
  ) end;
$$;

create or replace function public.toggle_chapter_like(p_chapter_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if not public.can_interact_with_chapter(p_chapter_id) then raise exception 'Энэ бүлэгт үйлдэл хийх эрхгүй'; end if;
  if exists(select 1 from public.chapter_likes where chapter_id=p_chapter_id and user_id=auth.uid()) then
    delete from public.chapter_likes where chapter_id=p_chapter_id and user_id=auth.uid();
    return false;
  end if;
  insert into public.chapter_likes(chapter_id,user_id) values(p_chapter_id,auth.uid());
  return true;
end;$$;

create or replace function public.add_chapter_comment(p_chapter_id uuid,p_body text)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
  if not public.can_interact_with_chapter(p_chapter_id) then raise exception 'Энэ бүлэгт сэтгэгдэл үлдээх эрхгүй'; end if;
  if char_length(trim(p_body))<1 or char_length(trim(p_body))>500 then raise exception 'Сэтгэгдэл 1-500 тэмдэгт байна'; end if;
  if exists(select 1 from public.chapter_comments where user_id=auth.uid() and created_at>now()-interval '10 seconds') then raise exception 'Дахин сэтгэгдэл бичихийн өмнө түр хүлээнэ үү'; end if;
  insert into public.chapter_comments(chapter_id,user_id,body) values(p_chapter_id,auth.uid(),trim(p_body)) returning id into new_id;
  return new_id;
end;$$;

create or replace function public.delete_chapter_comment(p_comment_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare row_data record;
begin
  select c.user_id,ch.manga_id into row_data from public.chapter_comments c join public.chapters ch on ch.id=c.chapter_id where c.id=p_comment_id;
  if not found then return false; end if;
  if row_data.user_id<>auth.uid() and not public.is_admin(auth.uid()) and not public.can_manage_manga(row_data.manga_id) then raise exception 'Устгах эрхгүй'; end if;
  delete from public.chapter_comments where id=p_comment_id;
  return true;
end;$$;

create or replace function public.submit_super_like_request(
  p_chapter_id uuid,p_quantity integer,p_sender_name text,p_transfer_reference text,p_transfer_date date,p_receipt_path text
) returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid; target_team uuid;
begin
  if auth.uid() is null then raise exception 'Нэвтрэх шаардлагатай'; end if;
  if p_quantity<1 or p_quantity>9999 then raise exception 'Super Like-ийн тоо буруу'; end if;
  if split_part(p_receipt_path,'/',1)<>auth.uid()::text then raise exception 'Баримтын зам буруу'; end if;
  select m.team_id into target_team from public.chapters c join public.mangas m on m.id=c.manga_id where c.id=p_chapter_id and m.status='published' and c.published=true;
  if target_team is null then raise exception 'Орчуулагч баг олдсонгүй'; end if;
  insert into public.super_like_requests(user_id,team_id,chapter_id,quantity,amount_mnt,sender_name,transfer_reference,transfer_date,receipt_path)
  values(auth.uid(),target_team,p_chapter_id,p_quantity,p_quantity*1000,trim(p_sender_name),trim(p_transfer_reference),p_transfer_date,p_receipt_path)
  returning id into new_id;
  return new_id;
end;$$;

create or replace function public.review_super_like_request(p_request_id uuid,p_approve boolean,p_admin_note text default '')
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin(auth.uid()) then raise exception 'Админ эрх шаардлагатай'; end if;
  update public.super_like_requests set status=case when p_approve then 'approved' else 'rejected' end,admin_note=coalesce(p_admin_note,''),reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now()
  where id=p_request_id and status='pending';
  if not found then raise exception 'Хүсэлт олдсонгүй эсвэл өмнө нь шийдэгдсэн'; end if;
  return true;
end;$$;

create or replace function public.get_admin_super_like_requests()
returns jsonb language sql security definer stable set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',s.id,'user_name',p.display_name,'team_name',t.name,'manga_title',m.title,'chapter_number',c.chapter_number,
    'quantity',s.quantity,'amount_mnt',s.amount_mnt,'sender_name',s.sender_name,'transfer_reference',s.transfer_reference,
    'transfer_date',s.transfer_date,'receipt_path',s.receipt_path,'status',s.status,'admin_note',s.admin_note,'created_at',s.created_at
  ) order by s.created_at desc),'[]'::jsonb)
  from public.super_like_requests s join public.profiles p on p.id=s.user_id join public.translator_teams t on t.id=s.team_id
  join public.chapters c on c.id=s.chapter_id join public.mangas m on m.id=c.manga_id
  where public.is_admin(auth.uid());
$$;

-- Replace team summary with Super Like totals and bank details.
create or replace function public.get_my_translator_team()
returns jsonb language sql security definer stable set search_path=public as $$
  select case when t.id is null then null else jsonb_build_object(
    'id',t.id,'name',t.name,
    'member_count',(select count(*) from public.translator_team_members tm where tm.team_id=t.id),
    'max_members',t.max_members,
    'super_like_count',(select coalesce(sum(quantity),0) from public.super_like_requests s where s.team_id=t.id and s.status='approved'),
    'super_like_value',(select coalesce(sum(amount_mnt),0) from public.super_like_requests s where s.team_id=t.id and s.status='approved'),
    'bank_name',t.bank_name,'bank_account',t.bank_account,'bank_iban',t.bank_iban,'bank_holder',t.bank_holder
  ) end
  from public.profiles p left join public.translator_teams t on t.id=p.translator_team_id where p.id=auth.uid();
$$;

revoke all on function public.can_interact_with_chapter(uuid) from public;
revoke all on function public.get_chapter_social(uuid) from public;
revoke all on function public.toggle_chapter_like(uuid) from public;
revoke all on function public.add_chapter_comment(uuid,text) from public;
revoke all on function public.delete_chapter_comment(uuid) from public;
revoke all on function public.submit_super_like_request(uuid,integer,text,text,date,text) from public;
revoke all on function public.review_super_like_request(uuid,boolean,text) from public;
revoke all on function public.get_admin_super_like_requests() from public;
grant execute on function public.can_interact_with_chapter(uuid) to authenticated;
grant execute on function public.get_chapter_social(uuid) to authenticated;
grant execute on function public.toggle_chapter_like(uuid) to authenticated;
grant execute on function public.add_chapter_comment(uuid,text) to authenticated;
grant execute on function public.delete_chapter_comment(uuid) to authenticated;
grant execute on function public.submit_super_like_request(uuid,integer,text,text,date,text) to authenticated;
grant execute on function public.review_super_like_request(uuid,boolean,text) to authenticated;
grant execute on function public.get_admin_super_like_requests() to authenticated;

alter table public.chapter_comments enable row level security;
alter table public.chapter_likes enable row level security;
alter table public.super_like_requests enable row level security;
-- Direct access is intentionally narrow; interactions use validated RPC functions.
drop policy if exists super_like_requests_read_own_or_admin on public.super_like_requests;
create policy super_like_requests_read_own_or_admin on public.super_like_requests for select to authenticated
using(user_id=auth.uid() or public.is_admin(auth.uid()) or team_id=(select translator_team_id from public.profiles where id=auth.uid()));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('super-like-receipts','super-like-receipts',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists super_like_receipts_insert_own on storage.objects;
create policy super_like_receipts_insert_own on storage.objects for insert to authenticated
with check(bucket_id='super-like-receipts' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists super_like_receipts_read_own_admin on storage.objects;
create policy super_like_receipts_read_own_admin on storage.objects for select to authenticated
using(bucket_id='super-like-receipts' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin(auth.uid())));

create or replace function public.admin_create_translator_team(
  p_name text,p_code text,p_max_members integer,p_bank_name text,p_bank_account text,p_bank_iban text,p_bank_holder text
) returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
  if not public.is_admin(auth.uid()) then raise exception 'Админ эрх шаардлагатай'; end if;
  if char_length(trim(p_name))<2 or char_length(trim(p_code))<4 then raise exception 'Багийн нэр эсвэл код хэт богино'; end if;
  if p_max_members<1 or p_max_members>20 then raise exception 'Гишүүний тоо 1-20 байна'; end if;
  insert into public.translator_teams(name,code_hash,max_members,active,bank_name,bank_account,bank_iban,bank_holder)
  values(trim(p_name),crypt(upper(trim(p_code)),gen_salt('bf')),p_max_members,true,trim(p_bank_name),trim(p_bank_account),trim(p_bank_iban),trim(p_bank_holder))
  returning id into new_id;
  return new_id;
end;$$;

create or replace function public.get_admin_translator_teams()
returns jsonb language sql security definer stable set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',t.id,'name',t.name,'max_members',t.max_members,'active',t.active,
    'member_count',(select count(*) from public.translator_team_members tm where tm.team_id=t.id),
    'manga_count',(select count(*) from public.mangas m where m.team_id=t.id),
    'super_like_count',(select coalesce(sum(quantity),0) from public.super_like_requests s where s.team_id=t.id and s.status='approved'),
    'super_like_value',(select coalesce(sum(amount_mnt),0) from public.super_like_requests s where s.team_id=t.id and s.status='approved'),
    'bank_name',t.bank_name,'bank_account',t.bank_account,'bank_iban',t.bank_iban,'bank_holder',t.bank_holder
  ) order by t.created_at desc),'[]'::jsonb)
  from public.translator_teams t where public.is_admin(auth.uid());
$$;
revoke all on function public.admin_create_translator_team(text,text,integer,text,text,text,text) from public;
revoke all on function public.get_admin_translator_teams() from public;
grant execute on function public.admin_create_translator_team(text,text,integer,text,text,text,text) to authenticated;
grant execute on function public.get_admin_translator_teams() to authenticated;


-- ============================================================
-- MangaMN v11 Stability & Security migration
-- Run once in Supabase SQL Editor after the v10 database repair.
-- Existing rows are preserved.
-- ============================================================

create extension if not exists pgcrypto;

-- Upload state prevents partially-uploaded chapters from being published.
alter table public.chapters
  add column if not exists upload_status text not null default 'ready';

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conname='chapters_upload_status_check'
      and conrelid='public.chapters'::regclass
  ) then
    alter table public.chapters
      add constraint chapters_upload_status_check
      check(upload_status in('uploading','ready','failed'));
  end if;
end $$;

-- Track which Storage bucket owns each page. Legacy pages stay in manga-pages;
-- all new v11 page uploads use the private chapter-pages bucket.
alter table public.chapter_pages
  add column if not exists storage_bucket text not null default 'manga-pages';

update public.chapter_pages
set storage_bucket='manga-pages'
where storage_bucket is null or storage_bucket='';

create index if not exists chapter_pages_storage_object_idx
  on public.chapter_pages(storage_bucket,storage_path);

-- Fix team manga creation without recursive RLS checks.
create or replace function public.can_create_manga_for_team(check_team uuid)
returns boolean
language sql
security definer
stable
set search_path=public
as $$
  select
    public.is_admin(auth.uid())
    or exists(
      select 1
      from public.profiles p
      join public.translator_team_members tm
        on tm.user_id=p.id
       and tm.team_id=p.translator_team_id
      where p.id=auth.uid()
        and p.role='translator'
        and p.translator_team_id=check_team
    );
$$;

revoke all on function public.can_create_manga_for_team(uuid) from public;
grant execute on function public.can_create_manga_for_team(uuid) to authenticated;

drop policy if exists mangas_insert_translator on public.mangas;
create policy mangas_insert_translator
on public.mangas for insert to authenticated
with check(
  translator_id=auth.uid()
  and public.can_create_manga_for_team(team_id)
);

-- Only fully uploaded chapters may be shown as public chapters.
drop policy if exists chapters_select_visible on public.chapters;
create policy chapters_select_visible
on public.chapters for select to authenticated
using(exists(
  select 1 from public.mangas m
  where m.id=chapters.manga_id
    and (
      (m.status='published' and chapters.published=true and chapters.upload_status='ready')
      or public.can_manage_manga(m.id)
    )
));

-- Helpers used by Storage RLS. Paths follow:
-- uploader_user_id / manga_id / chapter_id / file-name.webp
create or replace function public.can_upload_chapter_object(object_name text)
returns boolean
language plpgsql
security definer
stable
set search_path=public,storage
as $$
declare
  parts text[];
  path_user uuid;
  path_manga uuid;
begin
  if auth.uid() is null then return false; end if;
  parts:=storage.foldername(object_name);
  if coalesce(array_length(parts,1),0)<3 then return false; end if;
  begin
    path_user:=parts[1]::uuid;
    path_manga:=parts[2]::uuid;
  exception when others then
    return false;
  end;
  return path_user=auth.uid() and public.can_manage_manga(path_manga);
end;
$$;

create or replace function public.can_manage_chapter_object(object_name text)
returns boolean
language plpgsql
security definer
stable
set search_path=public,storage
as $$
declare
  parts text[];
  path_manga uuid;
begin
  if auth.uid() is null then return false; end if;
  parts:=storage.foldername(object_name);
  if coalesce(array_length(parts,1),0)<3 then return false; end if;
  begin path_manga:=parts[2]::uuid;
  exception when others then return false;
  end;
  return public.can_manage_manga(path_manga);
end;
$$;

create or replace function public.can_read_chapter_object(object_name text)
returns boolean
language sql
security definer
stable
set search_path=public
as $$
  select
    public.is_admin(auth.uid())
    or exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='translator')
    or exists(
      select 1
      from public.chapter_pages cp
      join public.chapters c on c.id=cp.chapter_id
      join public.mangas m on m.id=c.manga_id
      where cp.storage_bucket='chapter-pages'
        and cp.storage_path=object_name
        and c.upload_status='ready'
        and c.published=true
        and m.status='published'
        and public.has_active_membership(auth.uid())
    )
    or exists(
      select 1
      from public.chapter_pages cp
      join public.chapters c on c.id=cp.chapter_id
      where cp.storage_bucket='chapter-pages'
        and cp.storage_path=object_name
        and public.can_manage_manga(c.manga_id)
    );
$$;

revoke all on function public.can_upload_chapter_object(text) from public;
revoke all on function public.can_manage_chapter_object(text) from public;
revoke all on function public.can_read_chapter_object(text) from public;
grant execute on function public.can_upload_chapter_object(text) to authenticated;
grant execute on function public.can_manage_chapter_object(text) to authenticated;
grant execute on function public.can_read_chapter_object(text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('chapter-pages','chapter-pages',false,12582912,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

-- SELECT is also necessary for Storage upload responses and signed URLs.
drop policy if exists chapter_private_select on storage.objects;
create policy chapter_private_select
on storage.objects for select to authenticated
using(
  bucket_id='chapter-pages'
  and (
    owner_id=auth.uid()::text
    or public.can_read_chapter_object(name)
  )
);

drop policy if exists chapter_private_insert on storage.objects;
create policy chapter_private_insert
on storage.objects for insert to authenticated
with check(
  bucket_id='chapter-pages'
  and public.can_upload_chapter_object(name)
);

drop policy if exists chapter_private_update on storage.objects;
create policy chapter_private_update
on storage.objects for update to authenticated
using(bucket_id='chapter-pages' and public.can_manage_chapter_object(name))
with check(bucket_id='chapter-pages' and public.can_manage_chapter_object(name));

drop policy if exists chapter_private_delete on storage.objects;
create policy chapter_private_delete
on storage.objects for delete to authenticated
using(bucket_id='chapter-pages' and public.can_manage_chapter_object(name));

-- Database page rows remain protected by membership/team RLS.
drop policy if exists pages_select_visible on public.chapter_pages;
create policy pages_select_visible
on public.chapter_pages for select to authenticated
using(exists(
  select 1
  from public.chapters c
  join public.mangas m on m.id=c.manga_id
  where c.id=chapter_pages.chapter_id
    and (
      (m.status='published' and c.published=true and c.upload_status='ready'
        and (public.has_active_membership(auth.uid())
          or exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in('translator','admin'))))
      or public.can_manage_manga(m.id)
    )
));

-- Verification output.
select
  to_regclass('public.chapter_pages') as chapter_pages,
  (select public from storage.buckets where id='chapter-pages') as private_bucket_public_flag,
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='chapter_private_select') as select_policy,
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='chapter_private_insert') as insert_policy;


-- ============================================================
-- MangaMN v12 — Single Admin Dashboard & Analytics
-- Run once in Supabase SQL Editor after v11.
-- Main administrator: riuka1002@gmail.com
-- ============================================================

-- 1. User account state.
alter table public.profiles
  add column if not exists account_status text not null default 'active';

do $$
begin
  if not exists(
    select 1 from pg_constraint
    where conname='profiles_account_status_check'
      and conrelid='public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_account_status_check
      check(account_status in('active','suspended'));
  end if;
end $$;

create index if not exists profiles_account_status_idx
on public.profiles(account_status);

-- 2. Keep exactly one administrator.
do $$
declare
  v_admin_id uuid;
begin
  select id into v_admin_id
  from auth.users
  where lower(email)=lower('riuka1002@gmail.com')
  limit 1;

  if v_admin_id is null then
    raise exception 'riuka1002@gmail.com хэрэглэгч олдсонгүй. Эхлээд сайтад энэ имэйлээр бүртгүүлнэ үү.';
  end if;

  update public.profiles
  set role='reader'
  where role='admin' and id<>v_admin_id;

  update public.profiles
  set role='admin', account_status='active'
  where id=v_admin_id;
end $$;

drop index if exists public.profiles_single_admin_idx;
create unique index profiles_single_admin_idx
on public.profiles(role)
where role='admin';

-- 3. Active-account-aware security helpers.
create or replace function public.is_admin(check_user uuid default auth.uid())
returns boolean
language sql
security definer
stable
set search_path=public
as $$
  select exists(
    select 1 from public.profiles
    where id=check_user
      and role='admin'
      and account_status='active'
  );
$$;

create or replace function public.has_active_membership(check_user uuid default auth.uid())
returns boolean
language sql
security definer
stable
set search_path=public
as $$
  select exists(
    select 1
    from public.memberships m
    join public.profiles p on p.id=m.user_id
    where m.user_id=check_user
      and m.expires_at>now()
      and p.account_status='active'
  );
$$;

create or replace function public.same_translator_team(other_user uuid)
returns boolean
language sql
security definer
stable
set search_path=public
as $$
  select public.is_admin(auth.uid()) or exists(
    select 1
    from public.profiles me
    join public.profiles other on other.id=other_user
    where me.id=auth.uid()
      and me.account_status='active'
      and other.account_status='active'
      and me.role='translator'
      and me.translator_team_id is not null
      and me.translator_team_id=other.translator_team_id
  );
$$;

create or replace function public.can_manage_manga(check_manga uuid)
returns boolean
language sql
security definer
stable
set search_path=public
as $$
  select public.is_admin(auth.uid()) or exists(
    select 1
    from public.mangas m
    join public.profiles p on p.id=auth.uid()
    where m.id=check_manga
      and p.account_status='active'
      and p.role='translator'
      and (
        m.translator_id=auth.uid()
        or (
          m.team_id is not null
          and p.translator_team_id=m.team_id
        )
      )
  );
$$;

-- 4. Admin dashboard data.
create or replace function public.get_admin_dashboard()
returns jsonb
language plpgsql
security definer
stable
set search_path=public
as $$
declare
  result jsonb;
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'Админ эрх шаардлагатай';
  end if;

  select jsonb_build_object(
    'summary', jsonb_build_object(
      'total_users', (select count(*) from public.profiles),
      'active_users', (select count(*) from public.profiles where account_status='active'),
      'suspended_users', (select count(*) from public.profiles where account_status='suspended'),
      'new_users_30d', (select count(*) from auth.users where created_at>=now()-interval '30 days'),
      'reader_users', (select count(*) from public.profiles where role='reader'),
      'translator_users', (select count(*) from public.profiles where role='translator'),
      'active_members', (select count(*) from public.memberships where expires_at>now()),
      'expiring_7d', (select count(*) from public.memberships where expires_at>now() and expires_at<=now()+interval '7 days'),
      'pending_membership_requests', (select count(*) from public.membership_requests where status='pending'),
      'pending_super_like_requests', (select count(*) from public.super_like_requests where status='pending'),
      'membership_revenue', (select coalesce(sum(amount_mnt),0) from public.membership_requests where status='approved'),
      'membership_revenue_30d', (select coalesce(sum(amount_mnt),0) from public.membership_requests where status='approved' and reviewed_at>=now()-interval '30 days'),
      'super_like_revenue', (select coalesce(sum(amount_mnt),0) from public.super_like_requests where status='approved'),
      'total_revenue',
        (select coalesce(sum(amount_mnt),0) from public.membership_requests where status='approved')
        +
        (select coalesce(sum(amount_mnt),0) from public.super_like_requests where status='approved'),
      'published_manga', (select count(*) from public.mangas where status='published'),
      'published_chapters', (select count(*) from public.chapters where published=true and upload_status='ready'),
      'translator_teams', (select count(*) from public.translator_teams where active=true),
      'comments', (select count(*) from public.chapter_comments)
    ),
    'users', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',u.id,
          'email',u.email,
          'display_name',p.display_name,
          'role',p.role,
          'account_status',p.account_status,
          'created_at',u.created_at,
          'last_sign_in_at',u.last_sign_in_at,
          'team_name',t.name,
          'membership_plan_code',ms.plan_code,
          'membership_plan_name',mp.name,
          'membership_expires_at',ms.expires_at,
          'membership_active',coalesce(ms.expires_at>now(),false),
          'days_remaining',case
            when ms.expires_at>now()
            then greatest(0,ceil(extract(epoch from(ms.expires_at-now()))/86400.0)::integer)
            else 0
          end
        )
        order by u.created_at desc
      )
      from auth.users u
      join public.profiles p on p.id=u.id
      left join public.translator_teams t on t.id=p.translator_team_id
      left join public.memberships ms on ms.user_id=u.id
      left join public.membership_plans mp on mp.code=ms.plan_code
    ),'[]'::jsonb)
  ) into result;

  return result;
end;
$$;

-- 5. Admin user state management.
create or replace function public.admin_set_user_status(
  p_user_id uuid,
  p_status text
) returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  target_role text;
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'Админ эрх шаардлагатай';
  end if;
  if p_status not in('active','suspended') then
    raise exception 'Төлөв буруу';
  end if;

  select role into target_role
  from public.profiles
  where id=p_user_id
  for update;

  if not found then raise exception 'Хэрэглэгч олдсонгүй'; end if;
  if target_role='admin' then
    raise exception 'Үндсэн админы төлөвийг эндээс өөрчлөх боломжгүй';
  end if;

  update public.profiles
  set account_status=p_status
  where id=p_user_id;

  return true;
end;
$$;

-- 6. Manual membership adjustment.
create or replace function public.admin_adjust_membership(
  p_user_id uuid,
  p_action text,
  p_days integer default 0
) returns timestamptz
language plpgsql
security definer
set search_path=public
as $$
declare
  target_role text;
  base_time timestamptz;
  new_expiry timestamptz;
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'Админ эрх шаардлагатай';
  end if;

  select role into target_role
  from public.profiles
  where id=p_user_id;

  if not found then raise exception 'Хэрэглэгч олдсонгүй'; end if;
  if target_role='admin' then
    raise exception 'Үндсэн админы эрхийг өөрчлөх боломжгүй';
  end if;

  if p_action='revoke' then
    update public.memberships
    set expires_at=now(),updated_at=now()
    where user_id=p_user_id;
    return now();
  end if;

  if p_action<>'add_days' then
    raise exception 'Үйлдэл буруу';
  end if;
  if p_days<1 or p_days>3650 then
    raise exception 'Хоногийн тоо 1-3650 байна';
  end if;

  select greatest(now(),coalesce(expires_at,now()))
  into base_time
  from public.memberships
  where user_id=p_user_id;

  if base_time is null then base_time:=now(); end if;
  new_expiry:=base_time+make_interval(days=>p_days);

  insert into public.memberships(user_id,plan_code,starts_at,expires_at,updated_at)
  values(p_user_id,'month1',now(),new_expiry,now())
  on conflict(user_id) do update
  set expires_at=new_expiry,
      updated_at=now();

  return new_expiry;
end;
$$;

revoke all on function public.get_admin_dashboard() from public;
revoke all on function public.admin_set_user_status(uuid,text) from public;
revoke all on function public.admin_adjust_membership(uuid,text,integer) from public;

grant execute on function public.get_admin_dashboard() to authenticated;
grant execute on function public.admin_set_user_status(uuid,text) to authenticated;
grant execute on function public.admin_adjust_membership(uuid,text,integer) to authenticated;

-- Verification.
select
  u.email,
  p.role,
  p.account_status
from auth.users u
join public.profiles p on p.id=u.id
where p.role='admin';

select public.get_admin_dashboard()->'summary' as admin_summary;


-- ================= V13 =================
-- MangaVerse v13: gamification + translator statistics
-- Run once after v12.

create table if not exists public.user_xp_events(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  event_type text not null check(event_type in('daily_login','read_chapter','favorite_manga','comment')),
  entity_id uuid not null,
  event_day date not null default current_date,
  xp integer not null check(xp>0),
  created_at timestamptz not null default now(),
  unique(user_id,event_type,entity_id,event_day)
);
create index if not exists user_xp_events_user_created_idx on public.user_xp_events(user_id,created_at desc);
alter table public.user_xp_events enable row level security;
drop policy if exists user_xp_events_read_own on public.user_xp_events;
create policy user_xp_events_read_own on public.user_xp_events for select to authenticated using(user_id=auth.uid() or public.is_admin(auth.uid()));

create or replace function public.award_gamification(p_event_type text,p_entity_id uuid)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_xp integer;
  v_total integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_entity_id is null then raise exception 'Entity required'; end if;
  v_xp:=case p_event_type
    when 'daily_login' then 5
    when 'read_chapter' then 10
    when 'favorite_manga' then 3
    when 'comment' then 5
    else 0 end;
  if v_xp=0 then raise exception 'Unsupported event'; end if;
  insert into public.user_xp_events(user_id,event_type,entity_id,event_day,xp)
  values(auth.uid(),p_event_type,p_entity_id,current_date,v_xp)
  on conflict(user_id,event_type,entity_id,event_day) do nothing;
  select coalesce(sum(xp),0)::integer into v_total from public.user_xp_events where user_id=auth.uid();
  return v_total;
end;$$;
revoke all on function public.award_gamification(text,uuid) from public;
grant execute on function public.award_gamification(text,uuid) to authenticated;

create or replace function public.get_my_gamification()
returns jsonb
language sql
security definer
stable
set search_path=public
as $$
with totals as(
  select coalesce(sum(xp),0)::integer total_xp from public.user_xp_events where user_id=auth.uid()
),today as(
  select
    count(*) filter(where event_type='read_chapter')::integer reads,
    count(*) filter(where event_type='comment')::integer comments,
    count(*) filter(where event_type='favorite_manga')::integer favorites
  from public.user_xp_events where user_id=auth.uid() and event_day=current_date
)
select jsonb_build_object(
  'total_xp',t.total_xp,
  'rank',case when t.total_xp>=2000 then 'Манга Мастер' when t.total_xp>=800 then 'Отаку' when t.total_xp>=300 then 'Судлаач' when t.total_xp>=100 then 'Уншигч' else 'Шинэков' end,
  'rank_base_xp',case when t.total_xp>=2000 then 2000 when t.total_xp>=800 then 800 when t.total_xp>=300 then 300 when t.total_xp>=100 then 100 else 0 end,
  'next_rank_xp',case when t.total_xp>=2000 then 2000 when t.total_xp>=800 then 2000 when t.total_xp>=300 then 800 when t.total_xp>=100 then 300 else 100 end,
  'quests',jsonb_build_object('reads',d.reads,'comments',d.comments,'favorites',d.favorites)
) from totals t cross join today d;
$$;
revoke all on function public.get_my_gamification() from public;
grant execute on function public.get_my_gamification() to authenticated;

create or replace function public.get_my_team_stats()
returns jsonb
language plpgsql
security definer
stable
set search_path=public
as $$
declare
  v_team uuid;
  result jsonb;
begin
  select translator_team_id into v_team from public.profiles where id=auth.uid() and role in('translator','admin');
  if v_team is null then return jsonb_build_object('mangas',0,'chapters',0,'reads',0,'favorites',0,'comments',0,'super_likes',0); end if;
  select jsonb_build_object(
    'mangas',(select count(*) from public.mangas m where m.team_id=v_team),
    'chapters',(select count(*) from public.chapters c join public.mangas m on m.id=c.manga_id where m.team_id=v_team),
    'reads',(select count(*) from public.reading_progress rp join public.chapters c on c.id=rp.chapter_id join public.mangas m on m.id=c.manga_id where m.team_id=v_team),
    'favorites',(select count(*) from public.favorites f join public.mangas m on m.id=f.manga_id where m.team_id=v_team),
    'comments',(select count(*) from public.chapter_comments cc join public.chapters c on c.id=cc.chapter_id join public.mangas m on m.id=c.manga_id where m.team_id=v_team),
    'super_likes',(select coalesce(sum(quantity),0) from public.super_like_requests where team_id=v_team and status='approved')
  ) into result;
  return result;
end;$$;
revoke all on function public.get_my_team_stats() from public;
grant execute on function public.get_my_team_stats() to authenticated;

select to_regclass('public.user_xp_events') as user_xp_events,
       to_regprocedure('public.award_gamification(text,uuid)') as award_rpc,
       to_regprocedure('public.get_my_gamification()') as gamification_rpc,
       to_regprocedure('public.get_my_team_stats()') as team_stats_rpc;
