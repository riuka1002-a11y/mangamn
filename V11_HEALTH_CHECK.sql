-- MangaMN v11 health check (read-only)
select
  to_regclass('public.profiles') profiles,
  to_regclass('public.mangas') mangas,
  to_regclass('public.chapters') chapters,
  to_regclass('public.chapter_pages') chapter_pages,
  to_regclass('public.membership_plans') membership_plans,
  to_regclass('public.translator_teams') translator_teams;

select id,name,public,file_size_limit,allowed_mime_types
from storage.buckets
where id in('manga-pages','chapter-pages','membership-receipts','super-like-receipts')
order by id;

select upload_status,count(*)
from public.chapters
group by upload_status
order by upload_status;

select storage_bucket,count(*)
from public.chapter_pages
group by storage_bucket
order by storage_bucket;

select p.id,p.display_name,p.role,p.translator_team_id,
       exists(select 1 from public.translator_team_members tm where tm.user_id=p.id and tm.team_id=p.translator_team_id) team_membership_ok
from public.profiles p
where p.role='translator';
