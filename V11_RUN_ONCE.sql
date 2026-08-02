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
