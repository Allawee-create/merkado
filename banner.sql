-- ميركادو: مساحة الإعلانات المتحركة بالواجهة (شغّله مرة وحدة فقط) — يحتاج roles.sql قبله
create table if not exists public.site_settings (
  key text primary key check (length(key) <= 40),
  value text check (length(value) <= 600),
  updated_at timestamptz not null default now()
);
alter table public.site_settings enable row level security;
drop policy if exists "settings_read" on public.site_settings;
create policy "settings_read" on public.site_settings for select to anon, authenticated using (true);
drop policy if exists "settings_owner_w" on public.site_settings;
create policy "settings_owner_w" on public.site_settings
  for all to authenticated using (public.is_owner()) with check (public.is_owner());

-- الأكثر مبيعاً: أسماء فقط (بدون كميات) من الطلبات المؤكدة والمسلّمة آخر 120 يوم
create or replace function public.top_sellers()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('n', n, 'b', b) order by q desc), '[]'::jsonb)
  from (
    select i ->> 'n' as n, (i ->> 'b')::int as b, sum((i ->> 'q')::numeric) as q
    from public.orders o, jsonb_array_elements(o.items) i
    where o.status in ('confirmed','delivered') and o.created_at > now() - interval '120 days'
    group by 1, 2 order by q desc limit 5
  ) t;
$$;
grant execute on function public.top_sellers() to anon, authenticated;
