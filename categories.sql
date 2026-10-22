-- ميركادو: أقسام مخصصة لكل براند (شغّله مرة وحدة فقط)
create table if not exists public.categories (
  id bigint generated always as identity primary key,
  brand int not null check (brand >= 0),
  name text not null check (length(name) between 1 and 60),
  sort int not null default 0,
  created_at timestamptz not null default now()
);

alter table public.categories enable row level security;
drop policy if exists "cats_read" on public.categories;
drop policy if exists "cats_owner_write" on public.categories;
create policy "cats_read" on public.categories
  for select to anon, authenticated using (true);
create policy "cats_owner_write" on public.categories
  for all to authenticated using (public.is_owner()) with check (public.is_owner());

-- أقسام البداية لكل براند + ربط المنتجات الحالية بأقسامها الجديدة
do $$
begin
  if not exists (select 1 from public.categories) then
    insert into public.categories (brand, name, sort)
    select b, t.n, t.i::int
    from generate_series(0, 5) as b,
         unnest(array['مواد عزل','لواصق','بيتومين','إيبوكسيات','مواد زرع شيش']) with ordinality as t(n, i);

    alter table public.products add column if not exists cat_new bigint;
    update public.products p set cat_new = c.id
      from public.categories c
      where c.brand = p.brand and c.sort = p.cat + 1;
    update public.products set cat = cat_new where cat_new is not null;
    alter table public.products drop column cat_new;
  end if;
end $$;

alter publication supabase_realtime add table public.categories;
