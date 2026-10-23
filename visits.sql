-- ميركادو: عداد الزوار (للمالك فقط) (شغّله مرة وحدة فقط)
-- يحسب كل دخول للموقع (مرة وحدة لكل جهاز كل 30 دقيقة) وعدد الزوار المختلفين

create table if not exists public.visits (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  vid text not null check (length(vid) between 8 and 64),
  ref text check (length(ref) <= 200)
);
create index if not exists visits_created_idx on public.visits (created_at);
create index if not exists visits_vid_idx on public.visits (vid, created_at desc);

-- بدون سياسات = ما أحد يكدر يقرأ أو يكتب بالجدول مباشرة
alter table public.visits enable row level security;

create or replace function public.track_visit(p_vid text, p_ref text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(coalesce(p_vid, '')) not between 8 and 64 then return; end if;
  if exists (select 1 from public.visits where vid = p_vid and created_at > now() - interval '30 minutes') then return; end if;
  if (select count(*) from public.visits where created_at > now() - interval '1 minute') >= 200 then return; end if;
  insert into public.visits (vid, ref) values (p_vid, left(p_ref, 200));
end $$;

grant execute on function public.track_visit(text, text) to anon, authenticated;

create or replace function public.visit_stats()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  tz constant text := 'Asia/Baghdad';
  d0 date := (now() at time zone tz)::date;
  res jsonb;
begin
  if not public.is_owner() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'today',  jsonb_build_object('v', count(*) filter (where (created_at at time zone tz)::date = d0),
                                 'u', count(distinct vid) filter (where (created_at at time zone tz)::date = d0)),
    'week',   jsonb_build_object('v', count(*) filter (where (created_at at time zone tz)::date >= d0 - 6),
                                 'u', count(distinct vid) filter (where (created_at at time zone tz)::date >= d0 - 6)),
    'month',  jsonb_build_object('v', count(*) filter (where (created_at at time zone tz)::date >= date_trunc('month', d0::timestamp)::date),
                                 'u', count(distinct vid) filter (where (created_at at time zone tz)::date >= date_trunc('month', d0::timestamp)::date)),
    'all',    jsonb_build_object('v', count(*), 'u', count(distinct vid))
  ) into res from public.visits;

  res := res || jsonb_build_object('days', (
    select coalesce(jsonb_agg(jsonb_build_object('d', g.d, 'v', coalesce(x.v, 0), 'u', coalesce(x.u, 0)) order by g.d), '[]'::jsonb)
    from generate_series(d0 - 13, d0, interval '1 day') as g(d)
    left join (
      select (created_at at time zone tz)::date as d, count(*) as v, count(distinct vid) as u
      from public.visits group by 1
    ) x on x.d = g.d::date
  ));
  return res;
end $$;

grant execute on function public.visit_stats() to authenticated;
