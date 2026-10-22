-- ميركادو: كل طلب مؤكَّد يتسجل تلقائياً كشراء من البراند (يزيد "يطلبني")
-- شغّله بعد ledger.sql. مرة وحدة فقط.
alter table public.ledger add column if not exists order_id text;
alter table public.ledger add column if not exists auto boolean not null default false;

create or replace function public.sync_order_ledger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from old.status then
    if new.status in ('confirmed','delivered') then
      if not exists (select 1 from public.ledger where order_id = new.id::text) then
        insert into public.ledger (brand, kind, day, item, qty, amount, note, order_id, auto)
        select t.brand, 'buy', current_date,
               left(string_agg(t.n || ' × ' || t.q, ' ، '), 200),
               sum(t.q), sum(t.p * t.q),
               'تلقائي من الطلب #' || new.code, new.id::text, true
        from (
          select (i->>'b')::int as brand, i->>'n' as n,
                 (i->>'q')::numeric as q, (i->>'p')::numeric as p
          from jsonb_array_elements(new.items) i
        ) t
        group by t.brand;
      end if;
    else
      delete from public.ledger where order_id = new.id::text and auto;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_order_ledger on public.orders;
create trigger trg_sync_order_ledger
after update of status on public.orders
for each row execute function public.sync_order_ledger();
