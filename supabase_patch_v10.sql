

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
