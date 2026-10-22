-- ميركادو: تفعيل صور المنتجات (شغّله مرة وحدة فقط)
alter table public.products add column if not exists image text;

insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

drop policy if exists "pimg_read" on storage.objects;
drop policy if exists "pimg_owner_write" on storage.objects;
drop policy if exists "pimg_owner_update" on storage.objects;
drop policy if exists "pimg_owner_delete" on storage.objects;

create policy "pimg_read" on storage.objects
  for select to anon, authenticated using (bucket_id = 'product-images');
create policy "pimg_owner_write" on storage.objects
  for insert to authenticated with check (bucket_id = 'product-images' and public.is_owner());
create policy "pimg_owner_update" on storage.objects
  for update to authenticated using (bucket_id = 'product-images' and public.is_owner());
create policy "pimg_owner_delete" on storage.objects
  for delete to authenticated using (bucket_id = 'product-images' and public.is_owner());
