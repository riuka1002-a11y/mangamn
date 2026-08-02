-- Run once in Supabase Dashboard -> SQL Editor
create extension if not exists pgcrypto;

create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Хэрэглэгч',
  role text not null default 'reader' check(role in('reader','translator')),
  avatar_url text,
  created_at timestamptz not null default now()
);
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
create index if not exists mangas_status_created_idx on public.mangas(status,created_at desc);
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

alter table public.profiles enable row level security;
alter table public.translator_invites enable row level security;
alter table public.mangas enable row level security;
alter table public.chapters enable row level security;
alter table public.chapter_pages enable row level security;
alter table public.favorites enable row level security;
alter table public.reading_progress enable row level security;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles for select to authenticated using(id=auth.uid());
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
create policy pages_select_visible on public.chapter_pages for select to authenticated using(exists(select 1 from public.chapters c join public.mangas m on m.id=c.manga_id where c.id=chapter_pages.chapter_id and((m.status='published' and c.published=true) or m.translator_id=auth.uid())));
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

insert into public.translator_invites(code,max_uses) values('CHANGE-ME-TRANSLATOR',5) on conflict(code) do nothing;
