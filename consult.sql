-- ميركادو: حجز استشارات (شغّله مرة وحدة فقط)
create table if not exists public.consultations (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  name text not null check (length(name) between 1 and 120),
  phone text not null check (length(phone) between 5 and 30),
  project text not null check (length(project) between 1 and 160),
  address text not null check (length(address) between 1 and 250),
  service text not null check (length(service) between 1 and 80),
  notes text check (length(notes) <= 1000),
  status text not null default 'new' check (status in ('new','done'))
);

alter table public.consultations enable row level security;
drop policy if exists "consult_insert" on public.consultations;
drop policy if exists "consult_owner_all" on public.consultations;
create policy "consult_insert" on public.consultations
  for insert to anon, authenticated with check (status = 'new');
create policy "consult_owner_all" on public.consultations
  for all to authenticated using (public.is_owner()) with check (public.is_owner());

do $$
begin
  alter publication supabase_realtime add table public.consultations;
exception when others then null;
end $$;
