-- ميركادو: الموظفين (محاسب + مندوب مبيعات) وسجل النشاط (شغّله مرة وحدة فقط)

create table if not exists public.staff (
  email text primary key check (email = lower(email) and length(email) <= 200),
  role text not null check (role in ('accountant','sales')),
  name text check (length(name) <= 100),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.staff enable row level security;
drop policy if exists "staff_owner_all" on public.staff;
create policy "staff_owner_all" on public.staff
  for all to authenticated using (public.is_owner()) with check (public.is_owner());

-- دور المستخدم الحالي: owner / accountant / sales / null
create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select case when public.is_owner() then 'owner'
    else (select s.role from public.staff s
          where s.email = lower(coalesce(auth.jwt() ->> 'email','')) and s.active limit 1) end;
$$;
revoke all on function public.my_role() from public, anon;
grant execute on function public.my_role() to authenticated;

create or replace function public.has_role(r text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.my_role() = r;
$$;
revoke all on function public.has_role(text) from public, anon;
grant execute on function public.has_role(text) to authenticated;

-- سجل النشاط (المالك فقط يقرأه)
create table if not exists public.activity_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor text,
  role text,
  action text not null,
  detail text
);
alter table public.activity_log enable row level security;
drop policy if exists "activity_owner_read" on public.activity_log;
create policy "activity_owner_read" on public.activity_log
  for select to authenticated using (public.is_owner());
drop policy if exists "activity_owner_del" on public.activity_log;
create policy "activity_owner_del" on public.activity_log
  for delete to authenticated using (public.is_owner());

create or replace function public.log_act(p_action text, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
declare v_mail text := lower(coalesce(auth.jwt() ->> 'email',''));
begin
  if v_mail = '' then return; end if;
  insert into public.activity_log (actor, role, action, detail)
  values (v_mail, public.my_role(), p_action, left(p_detail, 400));
end $$;
revoke all on function public.log_act(text,text) from public, anon, authenticated;

-- المحاسب: قراءة الحسابات والأرباح + تسجيل تسديد (إضافة فقط، بدون تعديل أو حذف)
drop policy if exists "ledger_acc_read" on public.ledger;
create policy "ledger_acc_read" on public.ledger for select to authenticated using (public.has_role('accountant'));
drop policy if exists "ledger_acc_ins" on public.ledger;
create policy "ledger_acc_ins" on public.ledger for insert to authenticated with check (public.has_role('accountant'));
drop policy if exists "cust_acc_read" on public.cust_ledger;
create policy "cust_acc_read" on public.cust_ledger for select to authenticated using (public.has_role('accountant'));
drop policy if exists "cust_acc_ins" on public.cust_ledger;
create policy "cust_acc_ins" on public.cust_ledger for insert to authenticated with check (public.has_role('accountant'));
drop policy if exists "costs_acc_read" on public.product_costs;
create policy "costs_acc_read" on public.product_costs for select to authenticated using (public.has_role('accountant'));

-- قراءة الطلبات للموظفين (المندوب ما يشوف سعر الشراء ولا الأرباح)
create or replace function public.staff_orders()
returns setof public.orders language plpgsql stable security definer set search_path = public as $$
declare v_role text := public.my_role(); r public.orders;
begin
  if v_role is null then raise exception 'forbidden'; end if;
  for r in select * from public.orders order by created_at desc limit 3000 loop
    if v_role = 'sales' then r.cost_total := null; r.costs := null; end if;
    return next r;
  end loop;
end $$;
revoke all on function public.staff_orders() from public, anon;
grant execute on function public.staff_orders() to authenticated;

-- المندوب: تغيير حالة الطلب فقط
create or replace function public.staff_set_status(p_id text, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() not in ('owner','sales') then raise exception 'forbidden'; end if;
  if p_status not in ('new','confirmed','delivered','cancelled') then raise exception 'bad status'; end if;
  update public.orders set status = p_status where id::text = p_id;
end $$;
revoke all on function public.staff_set_status(text,text) from public, anon;
grant execute on function public.staff_set_status(text,text) to authenticated;

-- تسجيل النشاط تلقائياً
create or replace function public.trg_log_order()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status then
    perform public.log_act('order_status', 'طلب #' || new.code || ' (' || new.name || '): ' || old.status || ' → ' || new.status);
  end if;
  return new;
end $$;
drop trigger if exists order_log on public.orders;
create trigger order_log after update of status on public.orders
  for each row execute function public.trg_log_order();

create or replace function public.trg_log_cust()
returns trigger language plpgsql security definer set search_path = public as $$
declare r public.cust_ledger;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  perform public.log_act('cust_' || lower(tg_op),
    (case when r.kind = 'pay' then 'تسديد' else 'دين سابق' end) || ' — ' || coalesce(r.name, r.phone) || ' (' || r.phone || ') — ' || r.amount
    || case when tg_op = 'INSERT' then '' when tg_op = 'UPDATE' then ' [تعديل]' else ' [حذف]' end
    || coalesce(' — ' || nullif(r.note,''), ''));
  return r;
end $$;
drop trigger if exists cust_log on public.cust_ledger;
create trigger cust_log after insert or update or delete on public.cust_ledger
  for each row execute function public.trg_log_cust();

create or replace function public.trg_log_ledger()
returns trigger language plpgsql security definer set search_path = public as $$
declare r public.ledger;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  if coalesce(r.auto,false) then return r; end if;
  perform public.log_act('ledger_' || lower(tg_op),
    'براند #' || r.brand || ' — ' || (case r.kind when 'buy' then 'شراء' when 'pay' then 'تسديد للبراند' else 'مطالبة' end) || ' — ' || r.amount
    || case when tg_op = 'INSERT' then '' when tg_op = 'UPDATE' then ' [تعديل]' else ' [حذف]' end
    || coalesce(' — ' || nullif(r.item,''), ''));
  return r;
end $$;
drop trigger if exists ledger_log on public.ledger;
create trigger ledger_log after insert or update or delete on public.ledger
  for each row execute function public.trg_log_ledger();
