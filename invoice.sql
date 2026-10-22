-- ميركادو: رقم فاتورة متسلسل (1001، 1002، 1003...) (شغّله مرة وحدة فقط)
create sequence if not exists public.invoice_seq start 1001;

create or replace function public.create_order(p_name text, p_phone text, p_address text, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_total numeric := 0;
  v_items jsonb := '[]'::jsonb;
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
  end loop;

  loop
    v_code := nextval('public.invoice_seq')::text;
    exit when not exists (select 1 from public.orders where code = v_code);
  end loop;

  insert into public.orders (code, name, phone, address, items, total)
  values (v_code, trim(p_name), trim(p_phone), trim(p_address), v_items, v_total)
  returning * into v_row;

  return jsonb_build_object('code', v_row.code, 'total', v_row.total, 'items', v_row.items,
                            'status', v_row.status, 'created_at', v_row.created_at);
end $$;

grant execute on function public.create_order(text, text, text, jsonb) to anon, authenticated;
