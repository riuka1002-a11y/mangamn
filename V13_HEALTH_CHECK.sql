-- MangaVerse v13 health check
select
  to_regclass('public.user_xp_events') as user_xp_events,
  to_regprocedure('public.award_gamification(text,uuid)') as award_rpc,
  to_regprocedure('public.get_my_gamification()') as gamification_rpc,
  to_regprocedure('public.get_my_team_stats()') as team_stats_rpc;

select event_type,count(*) event_count,sum(xp) xp
from public.user_xp_events
group by event_type
order by event_type;
