-- ميركادو: إشعار على التلفون لكل طلب جديد (مجاني عبر ntfy.sh)
-- غيّر اسم القناة mirkado-021abe991594 إذا تريد، بس لازم يطابق اللي تشترك بيه بتطبيق ntfy
create extension if not exists pg_net with schema extensions;

create or replace function public.notify_new_order()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform net.http_post(
    url := 'https://ntfy.sh/',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object(
      'topic', 'mirkado-021abe991594',
      'title', 'طلب جديد #' || new.code,
      'message', new.name || ' - ' || new.phone || E'\n' || 'الإجمالي: ' || new.total || ' د.ع',
      'priority', 4,
      'tags', jsonb_build_array('shopping_cart')
    )
  );
  return new;
exception when others then
  return new; -- لا تخلي فشل الإشعار يمنع الطلب
end;
$$;

drop trigger if exists trg_notify_new_order on public.orders;
create trigger trg_notify_new_order
after insert on public.orders
for each row execute function public.notify_new_order();
