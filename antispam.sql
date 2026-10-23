-- ميركادو: حماية من الطلبات والاستشارات الوهمية (شغّله مرة وحدة، بعد profit.sql و consult.sql)
-- الطلبات: حد أقصى 5 طلبات لنفس الرقم كل 10 دقايق، و60 طلب للموقع كله كل 10 دقايق
-- الاستشارات: حد أقصى 3 لنفس الرقم كل ساعة، و40 للموقع كله كل ساعة

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

  if (select count(*) from public.orders where phone = trim(p_phone) and created_at > now() - interval '10 minutes') >= 5 then
    raise exception 'rate_limited';
  end if;
  if (select count(*) from public.orders where created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'rate_limited';
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

create or replace function public.create_consult(
  p_name text, p_phone text, p_project text, p_address text, p_service text, p_notes text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(trim(coalesce(p_name, ''))) not between 1 and 120 then raise exception 'invalid name'; end if;
  if length(trim(coalesce(p_phone, ''))) not between 5 and 30 then raise exception 'invalid phone'; end if;
  if length(trim(coalesce(p_project, ''))) not between 1 and 160 then raise exception 'invalid project'; end if;
  if length(trim(coalesce(p_address, ''))) not between 1 and 250 then raise exception 'invalid address'; end if;
  if length(trim(coalesce(p_service, ''))) not between 1 and 80 then raise exception 'invalid service'; end if;
  if length(coalesce(p_notes, '')) > 1000 then raise exception 'invalid notes'; end if;

  if (select count(*) from public.consultations where phone = trim(p_phone) and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'rate_limited';
  end if;
  if (select count(*) from public.consultations where created_at > now() - interval '1 hour') >= 40 then
    raise exception 'rate_limited';
  end if;

  insert into public.consultations (name, phone, project, address, service, notes)
  values (trim(p_name), trim(p_phone), trim(p_project), trim(p_address), trim(p_service), nullif(trim(coalesce(p_notes, '')), ''));
end $$;

grant execute on function public.create_consult(text, text, text, text, text, text) to anon, authenticated;

-- نمنع الإدخال المباشر بالجدول، فالاستشارات تمر فقط من الدالة اللي فيها الحماية
drop policy if exists "consult_insert" on public.consultations;
