-- ميركادو: سعر الشراء والأرباح (شغّله مرة وحدة فقط، بعد invoice.sql)
-- سعر الشراء بجدول منفصل للمالك فقط حتى ما يشوفه أحد من الزبائن
create table if not exists public.product_costs (
  product_id uuid primary key references public.products(id) on delete cascade,
  cost numeric not null check (cost >= 0),
  updated_at timestamptz not null default now()
);
alter table public.product_costs enable row level security;
drop policy if exists "costs_owner_all" on public.product_costs;
create policy "costs_owner_all" on public.product_costs
  for all to authenticated using (public.is_owner()) with check (public.is_owner());

-- تكلفة كل طلب وقت الطلب (للمالك فقط، ما ترجع للزبون)
alter table public.orders add column if not exists cost_total numeric;
alter table public.orders add column if not exists costs jsonb;

create or replace function public.create_order(p_name text, p_phone text, p_address text, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_total numeric := 0;
  v_items jsonb := '[]'::jsonb;
  v_costs jsonb := '{}'::jsonb;
  v_cost_total numeric := 0;
  v_miss boolean := false;
  v_cost numeric;
  it jsonb;
  pr public.products;
  q int;
  v_row public.orders;
begin
  if length(trim(coalesce(p_name, ''))) not between 1 and 80 then raise exception 'invalid name'; end if;
  if length(trim(coalesce(p_phone, ''))) not between 5 and 20 then raise exception 'invalid phone'; end if;
  if length(trim(coalesce(p_address, ''))) not between 1 and 300 then raise exception 'invalid address'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 50 then
    raise exception 'invalid items';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    q := (it ->> 'q')::int;
    if q is null or q < 1 or q > 1000 then raise exception 'invalid qty'; end if;
    select * into pr from public.products where id = (it ->> 'id')::uuid;
    if not found then raise exception 'product not found'; end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object('n', pr.name, 'b', pr.brand, 'u', pr.unit, 'p', pr.price, 'q', q));
    v_total := v_total + pr.price * q;

    select cost into v_cost from public.product_costs where product_id = pr.id;
    if v_cost is null then v_miss := true; else v_cost_total := v_cost_total + v_cost * q; end if;
    v_costs := v_costs || jsonb_build_object(
      pr.brand::text,
      coalesce((v_costs ->> pr.brand::text)::numeric, 0) + coalesce(v_cost, pr.price) * q
    );
  end loop;

  loop
    v_code := nextval('public.invoice_seq')::text;
    exit when not exists (select 1 from public.orders where code = v_code);
  end loop;

  insert into public.orders (code, name, phone, address, items, total, cost_total, costs)
  values (v_code, trim(p_name), trim(p_phone), trim(p_address), v_items, v_total,
          case when v_miss then null else v_cost_total end, v_costs)
  returning * into v_row;

  return jsonb_build_object('code', v_row.code, 'total', v_row.total, 'items', v_row.items,
                            'status', v_row.status, 'created_at', v_row.created_at);
end $$;

grant execute on function public.create_order(text, text, text, jsonb) to anon, authenticated;

-- القيد التلقائي بحسابات البراند يصير بسعر الشراء إذا معروف
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
               sum(t.q),
               coalesce((new.costs ->> t.brand::text)::numeric, sum(t.p * t.q)),
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
