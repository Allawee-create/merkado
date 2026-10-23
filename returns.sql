-- ميركادو: مردود البيع (شغّله مرة وحدة فقط) — يحتاج roles.sql مشغّل قبله
create table if not exists public.order_returns (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  order_id text not null,
  code text not null,
  name text,
  phone text,
  items jsonb not null,
  total numeric not null,   -- قيمة المردود بسعر البيع
  value numeric not null,   -- القيمة بعد حصة الخصم (تنزل من حساب الزبون)
  cost numeric not null default 0, -- القيمة بسعر الشراء (ترجع للبراند)
  note text check (length(note) <= 300),
  created_by text default (auth.jwt() ->> 'email')
);
alter table public.order_returns enable row level security;
drop policy if exists "ret_owner_all" on public.order_returns;
create policy "ret_owner_all" on public.order_returns
  for all to authenticated using (public.is_owner()) with check (public.is_owner());
drop policy if exists "ret_acc_read" on public.order_returns;
create policy "ret_acc_read" on public.order_returns
  for select to authenticated using (public.has_role('accountant'));

-- تسجيل مردود: p_items = [{"i":0,"q":2}] (i رقم المادة بالفاتورة من 0)
create or replace function public.create_return(p_order text, p_items jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o public.orders; it jsonb; el jsonb; idx int; q numeric; sold numeric; done numeric;
  v_items jsonb := '[]'::jsonb; v_total numeric := 0; v_ratio numeric; v_value numeric;
  v_bsale jsonb := '{}'::jsonb; v_bret jsonb := '{}'::jsonb; v_cost numeric := 0;
  v_b text; v_c numeric; v_id bigint; r record;
begin
  if not public.is_owner() then raise exception 'forbidden'; end if;
  select * into o from public.orders where id::text = p_order;
  if not found then raise exception 'order not found'; end if;
  if o.status not in ('confirmed','delivered') then raise exception 'order not confirmed'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'no items'; end if;

  -- مجموع مبيعات كل براند بالفاتورة (لتوزيع سعر الشراء)
  for el in select * from jsonb_array_elements(o.items) loop
    v_bsale := v_bsale || jsonb_build_object(el ->> 'b',
      coalesce((v_bsale ->> (el ->> 'b'))::numeric, 0) + (el ->> 'p')::numeric * (el ->> 'q')::numeric);
  end loop;

  for it in select * from jsonb_array_elements(p_items) loop
    idx := (it ->> 'i')::int; q := (it ->> 'q')::numeric;
    if q is null or q <= 0 then continue; end if;
    el := o.items -> idx;
    if el is null then raise exception 'bad item'; end if;
    sold := (el ->> 'q')::numeric;
    select coalesce(sum((x ->> 'q')::numeric), 0) into done
      from public.order_returns rr, jsonb_array_elements(rr.items) x
      where rr.order_id = o.id::text and (x ->> 'i')::int = idx;
    if q + done > sold then raise exception 'qty exceeds sold'; end if;
    v_items := v_items || jsonb_build_array(jsonb_build_object('i', idx, 'n', el ->> 'n', 'b', (el ->> 'b')::int,
                'u', el ->> 'u', 'p', (el ->> 'p')::numeric, 'q', q));
    v_total := v_total + (el ->> 'p')::numeric * q;
    v_bret := v_bret || jsonb_build_object(el ->> 'b',
      coalesce((v_bret ->> (el ->> 'b'))::numeric, 0) + (el ->> 'p')::numeric * q);
  end loop;
  if v_total <= 0 then raise exception 'no items'; end if;

  v_ratio := case when o.total > 0 then greatest(0, o.total - coalesce(o.discount,0)) / o.total else 1 end;
  v_value := round(v_total * v_ratio);

  insert into public.order_returns (order_id, code, name, phone, items, total, value, cost, note)
  values (o.id::text, o.code, o.name, o.phone, v_items, v_total, v_value, 0, left(p_note, 300))
  returning id into v_id;

  -- يرجع للبراند: بسعر الشراء (إذا معروف) أو بسعر البيع
  for r in select key as b, value::numeric as ret from jsonb_each_text(v_bret) loop
    v_c := case when o.costs ? r.b and (v_bsale ->> r.b)::numeric > 0
                then round((o.costs ->> r.b)::numeric * r.ret / (v_bsale ->> r.b)::numeric)
                else r.ret end;
    v_cost := v_cost + v_c;
    insert into public.ledger (brand, kind, day, item, qty, amount, note, order_id, auto)
    values (r.b::int, 'credit', current_date, 'مردود بيع — فاتورة #' || o.code, null, v_c,
            'تلقائي: مردود #' || v_id, 'ret' || v_id, true);
  end loop;
  update public.order_returns set cost = v_cost where id = v_id;

  perform public.log_act('return', 'مردود بيع #' || v_id || ' من فاتورة #' || o.code || ' (' || o.name || ') — ' || v_value);
  return jsonb_build_object('id', v_id, 'value', v_value, 'total', v_total, 'cost', v_cost);
end $$;
revoke all on function public.create_return(text, jsonb, text) from public, anon;
grant execute on function public.create_return(text, jsonb, text) to authenticated;

-- إلغاء مردود (يرجّع حساب الزبون والبراند مثل قبل)
create or replace function public.delete_return(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare rr public.order_returns;
begin
  if not public.is_owner() then raise exception 'forbidden'; end if;
  select * into rr from public.order_returns where id = p_id;
  if not found then return; end if;
  delete from public.ledger where order_id = 'ret' || p_id and auto;
  delete from public.order_returns where id = p_id;
  perform public.log_act('return_del', 'إلغاء مردود #' || p_id || ' من فاتورة #' || rr.code);
end $$;
revoke all on function public.delete_return(bigint) from public, anon;
grant execute on function public.delete_return(bigint) to authenticated;
