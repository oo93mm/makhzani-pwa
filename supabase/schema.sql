-- Makhzani shared inventory schema.
-- Run once in Supabase Dashboard > SQL Editor as the project owner.

create extension if not exists pgcrypto;
create schema if not exists private;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null default '',
  display_name text not null default '',
  role text not null default 'employee' check (role in ('manager','employee')),
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists email text not null default '';

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  name text not null check (length(trim(name)) between 1 and 80),
  code text not null default '',
  note text not null default '',
  buy bigint not null default 0 check (buy >= 0),
  sell bigint not null default 0 check (sell >= 0),
  qty integer not null default 0 check (qty >= 0),
  min_qty integer not null default 2 check (min_qty >= 0),
  photo text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.inventory_events (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  kind text not null check (kind in ('sale','purchase','adjustment','audit')),
  product_id uuid references public.products(id) on delete set null,
  name text not null default '',
  qty integer not null default 0,
  delta integer not null default 0,
  unit_price bigint not null default 0,
  total bigint not null default 0,
  details text not null default '',
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.legacy_imports (
  fingerprint text primary key,
  imported_by uuid not null references auth.users(id),
  imported_at timestamptz not null default now(),
  product_count integer not null default 0,
  event_count integer not null default 0
);

create index if not exists inventory_events_created_at_idx on public.inventory_events(created_at desc);
create index if not exists inventory_events_product_id_idx on public.inventory_events(product_id);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id, email, display_name, role)
  values(new.id, coalesce(new.email,''), coalesce(new.raw_user_meta_data->>'display_name',''), 'employee')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_makhzani on auth.users;
create trigger on_auth_user_created_makhzani
  after insert on auth.users for each row execute function public.handle_new_user();

create or replace function private.is_manager()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.profiles where id = (select auth.uid()) and role = 'manager');
$$;

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.inventory_events enable row level security;
alter table public.legacy_imports enable row level security;

drop policy if exists "profile owner or manager can read profiles" on public.profiles;
create policy "profile owner or manager can read profiles" on public.profiles
  for select to authenticated using (id = (select auth.uid()) or (select private.is_manager()));
drop policy if exists "manager updates profiles" on public.profiles;
create policy "manager updates profiles" on public.profiles
  for update to authenticated using ((select private.is_manager())) with check ((select private.is_manager()));

drop policy if exists "authenticated users read products" on public.products;
create policy "authenticated users read products" on public.products
  for select to authenticated using (true);
drop policy if exists "authenticated users read inventory history" on public.inventory_events;
create policy "authenticated users read inventory history" on public.inventory_events
  for select to authenticated using ((select private.is_manager()) or created_by = (select auth.uid()));

revoke all on public.profiles from anon, authenticated;
revoke all on public.products from anon, authenticated;
revoke all on public.inventory_events from anon, authenticated;
revoke all on public.legacy_imports from anon, authenticated;
grant select on public.profiles, public.inventory_events to authenticated;
grant update(role, display_name) on public.profiles to authenticated;
grant usage on schema private to authenticated;
grant execute on function private.is_manager() to authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;

create or replace function public.list_products()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare result jsonb;
begin
  if (select auth.uid()) is null then raise exception 'login_required'; end if;
  if private.is_manager() then
    select coalesce(jsonb_agg(to_jsonb(p) - 'legacy_id' order by p.name), '[]'::jsonb) into result from public.products p;
  else
    select coalesce(jsonb_agg((to_jsonb(p) - 'legacy_id') || jsonb_build_object('buy', null) order by p.name), '[]'::jsonb) into result from public.products p;
  end if;
  return result;
end;
$$;

create or replace function public.create_product(
  p_name text,p_code text,p_note text,p_buy bigint,p_sell bigint,p_qty integer,p_min_qty integer,p_photo text
) returns public.products language plpgsql security definer set search_path = '' as $$
declare v public.products;
begin
  if not private.is_manager() then raise exception 'manager_required'; end if;
  if p_qty < 0 or p_buy < 0 or p_sell < 0 then raise exception 'invalid_product_values'; end if;
  insert into public.products(name,code,note,buy,sell,qty,min_qty,photo)
  values(trim(p_name),coalesce(p_code,''),coalesce(p_note,''),p_buy,p_sell,p_qty,greatest(coalesce(p_min_qty,2),0),coalesce(p_photo,'')) returning * into v;
  insert into public.inventory_events(kind,product_id,name,qty,delta,unit_price,total,details,created_by)
  values('adjustment',v.id,v.name,v.qty,v.qty,v.buy,v.buy*v.qty,'إضافة المنتج والمخزون الأولي',(select auth.uid()));
  return v;
end;
$$;

create or replace function public.update_product(
  p_id uuid,p_name text,p_code text,p_note text,p_buy bigint,p_sell bigint,p_qty integer,p_min_qty integer,p_photo text
) returns public.products language plpgsql security definer set search_path = '' as $$
declare v public.products; old_qty integer; old_name text;
begin
  if not private.is_manager() then raise exception 'manager_required'; end if;
  if p_qty < 0 or p_buy < 0 or p_sell < 0 then raise exception 'invalid_product_values'; end if;
  select qty,name into old_qty,old_name from public.products where id=p_id for update;
  if not found then raise exception 'product_not_found'; end if;
  update public.products set name=trim(p_name),code=coalesce(p_code,''),note=coalesce(p_note,''),buy=p_buy,sell=p_sell,qty=p_qty,
    min_qty=greatest(coalesce(p_min_qty,2),0),photo=coalesce(p_photo,''),updated_at=now() where id=p_id returning * into v;
  if p_qty<>old_qty then
    insert into public.inventory_events(kind,product_id,name,qty,delta,unit_price,total,details,created_by)
    values('adjustment',v.id,v.name,abs(p_qty-old_qty),p_qty-old_qty,v.buy,abs(p_qty-old_qty)*v.buy,'تعديل كمية المنتج',(select auth.uid()));
  end if;
  insert into public.inventory_events(kind,product_id,name,details,created_by)
  values('audit',v.id,v.name,'تعديل بيانات المنتج «'||old_name||'»',(select auth.uid()));
  return v;
end;
$$;

create or replace function public.delete_product(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v public.products;
begin
  if not private.is_manager() then raise exception 'manager_required'; end if;
  select * into v from public.products where id=p_id for update;
  if not found then raise exception 'product_not_found'; end if;
  insert into public.inventory_events(kind,product_id,name,qty,delta,details,created_by)
  values('audit',null,v.name,v.qty,-v.qty,'حذف المنتج وإزالة الكمية المتبقية من المخزون',(select auth.uid()));
  delete from public.products where id=p_id;
end;
$$;

create or replace function public.record_sale(p_product_id uuid,p_qty integer)
returns public.inventory_events language plpgsql security definer set search_path = '' as $$
declare p public.products; e public.inventory_events;
begin
  if (select auth.uid()) is null then raise exception 'login_required'; end if;
  if p_qty<1 then raise exception 'invalid_quantity'; end if;
  select * into p from public.products where id=p_product_id for update;
  if not found then raise exception 'product_not_found'; end if;
  if p.qty<p_qty then raise exception 'insufficient_stock'; end if;
  update public.products set qty=qty-p_qty,updated_at=now() where id=p.id;
  insert into public.inventory_events(kind,product_id,name,qty,delta,unit_price,total,created_by)
  values('sale',p.id,p.name,p_qty,-p_qty,p.sell,p_qty*p.sell,(select auth.uid())) returning * into e;
  return e;
end;
$$;

create or replace function public.record_purchase(p_product_id uuid,p_qty integer,p_unit_price bigint)
returns public.inventory_events language plpgsql security definer set search_path = '' as $$
declare p public.products; e public.inventory_events;
begin
  if not private.is_manager() then raise exception 'manager_required'; end if;
  if p_qty<1 or p_unit_price<0 then raise exception 'invalid_purchase_values'; end if;
  select * into p from public.products where id=p_product_id for update;
  if not found then raise exception 'product_not_found'; end if;
  update public.products set qty=qty+p_qty,buy=p_unit_price,updated_at=now() where id=p.id;
  insert into public.inventory_events(kind,product_id,name,qty,delta,unit_price,total,created_by)
  values('purchase',p.id,p.name,p_qty,p_qty,p_unit_price,p_qty*p_unit_price,(select auth.uid())) returning * into e;
  return e;
end;
$$;

create or replace function public.edit_inventory_event(p_event_id uuid,p_qty integer,p_unit_price bigint)
returns public.inventory_events language plpgsql security definer set search_path = '' as $$
declare e public.inventory_events; p public.products; next_qty integer; old_event_qty integer;
begin
  if not private.is_manager() then raise exception 'manager_required'; end if;
  if p_qty<1 or p_unit_price<0 then raise exception 'invalid_values'; end if;
  select * into e from public.inventory_events where id=p_event_id and active and kind in ('sale','purchase') for update;
  if not found then raise exception 'event_not_found'; end if;
  select * into p from public.products where id=e.product_id for update;
  if not found then raise exception 'product_not_found'; end if;
  old_event_qty=e.qty;
  next_qty=p.qty-e.delta+(case when e.kind='sale' then -p_qty else p_qty end);
  if next_qty<0 then raise exception 'insufficient_stock_for_edit'; end if;
  update public.products set qty=next_qty,updated_at=now() where id=p.id;
  update public.inventory_events set qty=p_qty,delta=(case when kind='sale' then -p_qty else p_qty end),unit_price=p_unit_price,total=p_qty*p_unit_price where id=e.id returning * into e;
  insert into public.inventory_events(kind,product_id,name,details,created_by)
  values('audit',p.id,p.name,'تعديل حركة '||e.kind||' من '||old_event_qty||' إلى '||p_qty||' قطعة',(select auth.uid()));
  return e;
end;
$$;

create or replace function public.delete_inventory_event(p_event_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.inventory_events; p public.products; next_qty integer;
begin
  if not private.is_manager() then raise exception 'manager_required'; end if;
  select * into e from public.inventory_events where id=p_event_id and active and kind in ('sale','purchase') for update;
  if not found then raise exception 'event_not_found'; end if;
  select * into p from public.products where id=e.product_id for update;
  if not found then raise exception 'product_not_found'; end if;
  next_qty=p.qty-e.delta;
  if next_qty<0 then raise exception 'insufficient_stock_for_delete'; end if;
  update public.products set qty=next_qty,updated_at=now() where id=p.id;
  update public.inventory_events set active=false where id=e.id;
  insert into public.inventory_events(kind,product_id,name,details,created_by)
  values('audit',p.id,p.name,'حذف حركة '||e.kind||' ('||e.qty||' قطعة)',(select auth.uid()));
end;
$$;

-- Permanently remove only manager-selected history rows. Product stock and prices are untouched.
create or replace function public.clear_selected_history(p_event_ids uuid[])
returns integer language plpgsql security definer set search_path = '' as $$
declare removed integer;
begin
  if not private.is_manager() then raise exception 'manager_required'; end if;
  if coalesce(array_length(p_event_ids,1),0)<1 or array_length(p_event_ids,1)>1000 then
    raise exception 'invalid_event_selection';
  end if;
  delete from public.inventory_events where id = any(p_event_ids);
  get diagnostics removed = row_count;
  return removed;
end;
$$;

create or replace function public.import_legacy_data(p_fingerprint text,p_products jsonb,p_events jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p jsonb; e jsonb; v_product_id uuid; v_old_id text; v_kind text; v_qty integer; v_delta integer; v_total bigint; v_price bigint; v_time timestamptz; n bigint; imported_products integer:=0; imported_events integer:=0; batch_rows integer;
begin
  if not private.is_manager() then raise exception 'manager_required'; end if;
  if length(coalesce(p_fingerprint,''))<20 then raise exception 'invalid_import_fingerprint'; end if;
  insert into public.legacy_imports(fingerprint,imported_by) values(p_fingerprint,(select auth.uid())) on conflict do nothing;
  get diagnostics batch_rows = row_count;
  if batch_rows=0 then raise exception 'legacy_batch_already_imported'; end if;

  for p,n in select value,ordinality from jsonb_array_elements(coalesce(p_products,'[]'::jsonb)) with ordinality loop
    v_old_id:=coalesce(nullif(p->>'id',''),p_fingerprint||':product:'||n::text);
    insert into public.products(legacy_id,name,code,note,buy,sell,qty,min_qty,photo)
    values(v_old_id,trim(coalesce(p->>'name','منتج')),coalesce(p->>'code',''),coalesce(p->>'note',''),greatest(coalesce(nullif(p->>'buy','')::bigint,0),0),greatest(coalesce(nullif(p->>'sell','')::bigint,0),0),greatest(coalesce(nullif(p->>'qty','')::integer,0),0),greatest(coalesce(nullif(p->>'minQty','')::integer,2),0),coalesce(p->>'photo',''))
    on conflict (legacy_id) do nothing returning id into v_product_id;
    get diagnostics batch_rows = row_count;
    if batch_rows>0 then imported_products:=imported_products+1; end if;
  end loop;

  for e,n in select value,ordinality from jsonb_array_elements(coalesce(p_events,'[]'::jsonb)) with ordinality loop
    v_qty:=greatest(coalesce(nullif(e->>'qty','')::integer,0),0);
    v_total:=greatest(coalesce(nullif(e->>'total','')::bigint,0),0);
    v_kind:=case when coalesce(e->>'kind','')='sale' or coalesce(e->>'type','')='بيع' then 'sale'
      when coalesce(e->>'kind','')='purchase' or coalesce(e->>'type','')='شراء' then 'purchase'
      when coalesce(e->>'type','') in ('إضافة مخزون','تعديل مخزون') or coalesce(e->>'kind','')='adjustment' then 'adjustment'
      else 'audit' end;
    v_delta:=coalesce(nullif(e->>'delta','')::integer,case when v_kind='sale' then -v_qty when v_kind='purchase' or coalesce(e->>'type','')='إضافة مخزون' then v_qty else 0 end);
    v_price:=greatest(coalesce(nullif(e->>'unitPrice','')::bigint,nullif(e->>'unit_price','')::bigint,case when v_qty>0 then v_total/v_qty else 0 end),0);
    v_time:=coalesce(nullif(e->>'time','')::timestamptz,now());
    v_product_id:=null;
    if coalesce(e->>'productId','')<>'' then select id into v_product_id from public.products where legacy_id=e->>'productId' limit 1; end if;
    if v_product_id is null then
      select product.id into v_product_id from public.products product
      where product.name=coalesce(e->>'name','') and product.legacy_id in (
        select coalesce(nullif(item->>'id',''),p_fingerprint||':product:'||ord::text)
        from jsonb_array_elements(coalesce(p_products,'[]'::jsonb)) with ordinality as source(item,ord)
      ) order by product.created_at limit 1;
    end if;
    insert into public.inventory_events(legacy_id,kind,product_id,name,qty,delta,unit_price,total,details,active,created_by,created_at)
    values(p_fingerprint||':event:'||n::text,v_kind,v_product_id,coalesce(e->>'name',''),v_qty,v_delta,v_price,v_total,coalesce(e->>'description',''),coalesce((e->>'active')::boolean,true),(select auth.uid()),v_time)
    on conflict (legacy_id) do nothing;
    get diagnostics batch_rows = row_count;
    if batch_rows>0 then imported_events:=imported_events+1; end if;
  end loop;

  update public.legacy_imports set product_count=imported_products,event_count=imported_events where fingerprint=p_fingerprint;
  insert into public.inventory_events(kind,name,details,created_by)
  values('audit','استيراد بيانات','تم استيراد بيانات محلية: '||imported_products||' منتج و'||imported_events||' حركة',(select auth.uid()));
  return jsonb_build_object('products',imported_products,'events',imported_events);
end;
$$;

revoke all on function public.import_legacy_data(text,jsonb,jsonb) from public, anon;
revoke all on function public.create_product(text,text,text,bigint,bigint,integer,integer,text) from public, anon;
revoke all on function public.list_products() from public, anon;
revoke all on function public.update_product(uuid,text,text,text,bigint,bigint,integer,integer,text) from public, anon;
revoke all on function public.delete_product(uuid) from public, anon;
revoke all on function public.record_sale(uuid,integer) from public, anon;
revoke all on function public.record_purchase(uuid,integer,bigint) from public, anon;
revoke all on function public.edit_inventory_event(uuid,integer,bigint) from public, anon;
revoke all on function public.delete_inventory_event(uuid) from public, anon;
revoke all on function public.clear_selected_history(uuid[]) from public, anon;
grant execute on function public.create_product(text,text,text,bigint,bigint,integer,integer,text) to authenticated;
grant execute on function public.list_products() to authenticated;
grant execute on function public.import_legacy_data(text,jsonb,jsonb) to authenticated;
grant execute on function public.update_product(uuid,text,text,text,bigint,bigint,integer,integer,text) to authenticated;
grant execute on function public.delete_product(uuid) to authenticated;
grant execute on function public.record_sale(uuid,integer) to authenticated;
grant execute on function public.record_purchase(uuid,integer,bigint) to authenticated;
grant execute on function public.edit_inventory_event(uuid,integer,bigint) to authenticated;
grant execute on function public.delete_inventory_event(uuid) to authenticated;
grant execute on function public.clear_selected_history(uuid[]) to authenticated;
