-- ميركادو: تفعيل الخصم على الطلبات (شغّله مرة وحدة فقط)
alter table public.orders add column if not exists discount numeric not null default 0 check (discount >= 0);

create or replace function public.track_order(p_code text, p_phone text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('code', code, 'status', status, 'items', items, 'total', total, 'discount', discount, 'created_at', created_at)
  from public.orders
  where code = p_code
    and regexp_replace(phone, '[^0-9]', '', 'g') = regexp_replace(p_phone, '[^0-9]', '', 'g')
    and length(regexp_replace(p_phone, '[^0-9]', '', 'g')) >= 5
  limit 1
$$;
