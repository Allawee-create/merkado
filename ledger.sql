-- ميركادو: نظام حسابات المشتريات لكل براند (شغّله مرة وحدة فقط)
create table if not exists public.ledger (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  brand int not null check (brand >= 0),
  kind text not null check (kind in ('buy','pay','credit')),
  day date not null default current_date,
  item text check (length(item) <= 200),
  qty numeric,
  amount numeric not null check (amount >= 0),
  note text check (length(note) <= 500)
);

alter table public.ledger enable row level security;
drop policy if exists "ledger_owner_all" on public.ledger;
create policy "ledger_owner_all" on public.ledger
  for all to authenticated using (public.is_owner()) with check (public.is_owner());
