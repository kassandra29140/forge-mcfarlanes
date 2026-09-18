-- ============================================================
-- FORGE DE McFARLANE'S — BASE COMPLÈTE AVEC CLÔTURE HEBDOMADAIRE
-- Semaine comptable : vendredi -> jeudi
-- À exécuter dans Supabase > SQL Editor
-- ============================================================

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  role text not null default 'employee' check (role in ('admin','employee','viewer')),
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  insert into public.profiles(id,email,display_name,role)
  values(new.id,new.email,coalesce(new.raw_user_meta_data->>'display_name',split_part(new.email,'@',1)),'employee')
  on conflict(id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

create table if not exists public.forge_settings (
  id int primary key check (id=1),
  tax_rate numeric(6,2) not null default 10,
  boss_rate numeric(6,2) not null default 20,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
insert into public.forge_settings(id,tax_rate,boss_rate) values(1,10,20)
on conflict(id) do nothing;

create table if not exists public.accounting_periods (
  id uuid primary key default gen_random_uuid(),
  period_start date not null,
  period_end date not null,
  status text not null default 'open' check(status in ('open','closed')),
  closed_at timestamptz,
  closed_by uuid references public.profiles(id),
  tax_rate numeric(6,2),
  boss_rate numeric(6,2),
  snapshot_orders numeric(12,2),
  snapshot_shop numeric(12,2),
  snapshot_expenses numeric(12,2),
  snapshot_before_charges numeric(12,2),
  snapshot_before_tax numeric(12,2),
  snapshot_tax numeric(12,2),
  snapshot_net numeric(12,2),
  snapshot_boss numeric(12,2),
  created_at timestamptz not null default now(),
  unique(period_start,period_end)
);

create unique index if not exists accounting_periods_one_open
on public.accounting_periods ((1)) where status='open';

-- Période actuelle vendredi -> jeudi
do $$
declare s date;
begin
  if not exists(select 1 from public.accounting_periods where status='open') then
    s := current_date - ((extract(dow from current_date)::int - 5 + 7) % 7);
    insert into public.accounting_periods(period_start,period_end,status)
    values(s,s+6,'open');
  end if;
end $$;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.accounting_periods(id),
  date date not null,
  client text,
  detail text,
  amount numeric(12,2) not null check(amount>=0),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.shop_sales (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.accounting_periods(id),
  date date not null,
  detail text,
  amount numeric(12,2) not null check(amount>=0),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  period_id uuid not null references public.accounting_periods(id),
  date date not null,
  detail text,
  amount numeric(12,2) not null check(amount>=0),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create or replace function public.current_role()
returns text language sql stable security definer set search_path=public
as $$ select role from public.profiles where id=auth.uid() $$;

create or replace function public.period_is_open(p_period uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.accounting_periods where id=p_period and status='open') $$;

-- Transaction atomique de clôture
create or replace function public.close_current_period(p_closed_by uuid default null)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  p public.accounting_periods%rowtype;
  st public.forge_settings%rowtype;
  o numeric(12,2); s numeric(12,2); e numeric(12,2);
  before_charges numeric(12,2); before_tax numeric(12,2);
  taxv numeric(12,2); netv numeric(12,2); bossv numeric(12,2);
begin
  select * into p from public.accounting_periods where status='open' for update;
  if not found then raise exception 'Aucune période ouverte'; end if;

  select * into st from public.forge_settings where id=1;

  select coalesce(sum(amount),0) into o from public.orders where period_id=p.id;
  select coalesce(sum(amount),0) into s from public.shop_sales where period_id=p.id;
  select coalesce(sum(amount),0) into e from public.expenses where period_id=p.id;

  before_charges := o+s;
  before_tax := before_charges-e;
  taxv := greatest(0, round(before_tax*(st.tax_rate/100),2));
  netv := before_tax-taxv;
  bossv := greatest(0, round(netv*(st.boss_rate/100),2));

  update public.accounting_periods set
    status='closed',
    closed_at=now(),
    closed_by=p_closed_by,
    tax_rate=st.tax_rate,
    boss_rate=st.boss_rate,
    snapshot_orders=o,
    snapshot_shop=s,
    snapshot_expenses=e,
    snapshot_before_charges=before_charges,
    snapshot_before_tax=before_tax,
    snapshot_tax=taxv,
    snapshot_net=netv,
    snapshot_boss=bossv
  where id=p.id;

  insert into public.accounting_periods(period_start,period_end,status)
  values(p.period_end+1,p.period_end+7,'open')
  on conflict(period_start,period_end) do nothing;

  return p.id;
end $$;

revoke all on function public.close_current_period(uuid) from public,anon,authenticated;
grant execute on function public.close_current_period(uuid) to service_role;

-- RLS
alter table public.profiles enable row level security;
alter table public.forge_settings enable row level security;
alter table public.accounting_periods enable row level security;
alter table public.orders enable row level security;
alter table public.shop_sales enable row level security;
alter table public.expenses enable row level security;

drop policy if exists profiles_read on public.profiles;
drop policy if exists profiles_admin_update on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using(auth.uid() is not null);
create policy profiles_admin_update on public.profiles for update to authenticated using(public.current_role()='admin') with check(public.current_role()='admin');

drop policy if exists settings_read on public.forge_settings;
drop policy if exists settings_admin_update on public.forge_settings;
create policy settings_read on public.forge_settings for select to authenticated using(auth.uid() is not null);
create policy settings_admin_update on public.forge_settings for update to authenticated using(public.current_role()='admin') with check(public.current_role()='admin');

drop policy if exists periods_read on public.accounting_periods;
create policy periods_read on public.accounting_periods for select to authenticated using(auth.uid() is not null);

-- Commandes
drop policy if exists orders_read on public.orders;
drop policy if exists orders_insert on public.orders;
drop policy if exists orders_update on public.orders;
drop policy if exists orders_delete on public.orders;
create policy orders_read on public.orders for select to authenticated using(auth.uid() is not null);
create policy orders_insert on public.orders for insert to authenticated with check(
  public.current_role() in('admin','employee') and created_by=auth.uid() and public.period_is_open(period_id)
);
create policy orders_update on public.orders for update to authenticated using(
  public.period_is_open(period_id) and (public.current_role()='admin' or (public.current_role()='employee' and created_by=auth.uid()))
) with check(
  public.period_is_open(period_id) and (public.current_role()='admin' or (public.current_role()='employee' and created_by=auth.uid()))
);
create policy orders_delete on public.orders for delete to authenticated using(
  public.period_is_open(period_id) and (public.current_role()='admin' or (public.current_role()='employee' and created_by=auth.uid()))
);

-- Échoppe
drop policy if exists shop_read on public.shop_sales;
drop policy if exists shop_insert on public.shop_sales;
drop policy if exists shop_update on public.shop_sales;
drop policy if exists shop_delete on public.shop_sales;
create policy shop_read on public.shop_sales for select to authenticated using(auth.uid() is not null);
create policy shop_insert on public.shop_sales for insert to authenticated with check(
  public.current_role() in('admin','employee') and created_by=auth.uid() and public.period_is_open(period_id)
);
create policy shop_update on public.shop_sales for update to authenticated using(
  public.period_is_open(period_id) and (public.current_role()='admin' or (public.current_role()='employee' and created_by=auth.uid()))
) with check(
  public.period_is_open(period_id) and (public.current_role()='admin' or (public.current_role()='employee' and created_by=auth.uid()))
);
create policy shop_delete on public.shop_sales for delete to authenticated using(
  public.period_is_open(period_id) and (public.current_role()='admin' or (public.current_role()='employee' and created_by=auth.uid()))
);

-- Charges
drop policy if exists expenses_read on public.expenses;
drop policy if exists expenses_insert on public.expenses;
drop policy if exists expenses_update on public.expenses;
drop policy if exists expenses_delete on public.expenses;
create policy expenses_read on public.expenses for select to authenticated using(auth.uid() is not null);
create policy expenses_insert on public.expenses for insert to authenticated with check(
  public.current_role() in('admin','employee') and created_by=auth.uid() and public.period_is_open(period_id)
);
create policy expenses_update on public.expenses for update to authenticated using(
  public.period_is_open(period_id) and (public.current_role()='admin' or (public.current_role()='employee' and created_by=auth.uid()))
) with check(
  public.period_is_open(period_id) and (public.current_role()='admin' or (public.current_role()='employee' and created_by=auth.uid()))
);
create policy expenses_delete on public.expenses for delete to authenticated using(
  public.period_is_open(period_id) and (public.current_role()='admin' or (public.current_role()='employee' and created_by=auth.uid()))
);

revoke all on table public.profiles from anon;
revoke all on table public.forge_settings from anon;
revoke all on table public.accounting_periods from anon;
revoke all on table public.orders from anon;
revoke all on table public.shop_sales from anon;
revoke all on table public.expenses from anon;

grant select,update on public.profiles to authenticated;
grant select,update on public.forge_settings to authenticated;
grant select on public.accounting_periods to authenticated;
grant select,insert,update,delete on public.orders to authenticated;
grant select,insert,update,delete on public.shop_sales to authenticated;
grant select,insert,update,delete on public.expenses to authenticated;

-- Premier patron :
-- 1. crée l'utilisateur dans Authentication > Users
-- 2. exécute :
-- update public.profiles set role='admin',display_name='Nom du patron'
-- where email='TON-EMAIL@EXEMPLE.COM';
