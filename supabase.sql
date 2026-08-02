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
