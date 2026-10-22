-- ميركادو: حسابات الزبائن (تسديدات وديون سابقة) (شغّله مرة وحدة فقط)
create table if not exists public.cust_ledger (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  phone text not null check (length(phone) between 5 and 30),
  name text check (length(name) <= 120),
  kind text not null check (kind in ('pay','debit')),
  day date not null default current_date,
  amount numeric not null check (amount >= 0),
  note text check (length(note) <= 500)
);

alter table public.cust_ledger enable row level security;
drop policy if exists "cust_ledger_owner_all" on public.cust_ledger;
create policy "cust_ledger_owner_all" on public.cust_ledger
  for all to authenticated using (public.is_owner()) with check (public.is_owner());
