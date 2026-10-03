-- Minimal schema needed to run the ledger-close sample on plain PostgreSQL.
-- In production this runs on Supabase; auth.uid() and the membership table
-- below are small stand-ins for Supabase Auth and the real roles model.

create extension if not exists pgcrypto;

create schema if not exists auth;
create or replace function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

create type org_role as enum ('owner', 'administrador', 'asistente', 'guardia');

create table organizations (
  id   uuid primary key default gen_random_uuid(),
  name text not null
);

create table org_members (
  organization_id uuid not null references organizations(id),
  user_id         uuid not null,
  role            org_role not null,
  primary key (organization_id, user_id)
);

-- Does the current user hold one of these roles in this organization?
create or replace function has_org_role(p_org uuid, p_roles org_role[])
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from org_members
    where organization_id = p_org and user_id = auth.uid() and role = any(p_roles)
  )
$$;

-- Journal entries. `folio` stays NULL while the month is open and gets a
-- gap-free sequential number when the month is closed.
create table journal_entries (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  entry_date      date not null,
  description     text not null,
  folio           int,
  folio_year      int,
  unique (organization_id, folio_year, folio)
);

create table accounting_periods (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  period_start    date not null,
  status          text not null check (status in ('abierto', 'cerrado')),
  closed_at       timestamptz,
  closed_by       uuid,
  reopened_at     timestamptz,
  reopened_by     uuid,
  created_at      timestamptz not null default now(),
  unique (organization_id, period_start)
);

-- One counter per organization and fiscal year.
create table folio_sequences (
  organization_id uuid not null references organizations(id),
  fiscal_year     int  not null,
  last_folio      int  not null default 0,
  primary key (organization_id, fiscal_year)
);

-- Example source document guarded by the period lock.
create table payments (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  paid_on         date not null,
  amount          numeric(12,2) not null
);

create or replace function is_period_closed(p_org uuid, p_date date)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from accounting_periods
    where organization_id = p_org
      and period_start = date_trunc('month', p_date)::date
      and status = 'cerrado'
  )
$$;
