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
