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
