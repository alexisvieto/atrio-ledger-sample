-- Month-end close for a double-entry ledger (multi-tenant).
--
-- Closing a month:
--   1. Only an owner or administrator of that organization can do it.
--   2. Months must be closed in order: it refuses if earlier entries are
--      still unnumbered.
--   3. Every entry in the month gets the next sequential folio for the fiscal
--      year, in date order. The counter row is locked with FOR UPDATE, so two
--      concurrent closes can't hand out the same number or leave a gap.
--
-- Reopening a month:
--   Only the most recent closed month can be reopened. Its folios are removed
--   and the counter steps back, so numbering stays gap-free. Older months are
--   corrected with a reversing entry instead of being reopened.

create or replace function close_accounting_period(p_org uuid, p_month date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end   date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_year  int  := extract(year from v_start)::int;
  v_last  int;
  r       record;
begin
  if not has_org_role(p_org, array['owner', 'administrador']::org_role[]) then
    raise exception 'Not authorized';
  end if;

  -- Earlier months must be closed first.
  if exists (
    select 1 from journal_entries
    where organization_id = p_org and entry_date < v_start and folio is null
  ) then
    raise exception 'Close earlier months first: there are unnumbered entries before %.',
      to_char(v_start, 'MM/YYYY');
  end if;

  insert into accounting_periods (organization_id, period_start, status, closed_at, closed_by)
  values (p_org, v_start, 'cerrado', now(), auth.uid())
  on conflict (organization_id, period_start)
  do update set status = 'cerrado', closed_at = now(), closed_by = auth.uid(),
                reopened_at = null, reopened_by = null;

  -- Lock this organization's counter for the year before numbering.
  insert into folio_sequences (organization_id, fiscal_year, last_folio)
  values (p_org, v_year, 0)
  on conflict (organization_id, fiscal_year) do nothing;

  select last_folio into v_last
  from folio_sequences
  where organization_id = p_org and fiscal_year = v_year
  for update;

  for r in
    select id from journal_entries
    where organization_id = p_org
      and entry_date between v_start and v_end
      and folio is null
    order by entry_date, id
  loop
    v_last := v_last + 1;
    update journal_entries set folio = v_last, folio_year = v_year where id = r.id;
  end loop;

  update folio_sequences set last_folio = v_last
  where organization_id = p_org and fiscal_year = v_year;
end
$$;

create or replace function reopen_accounting_period(p_org uuid, p_month date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_year  int  := extract(year from v_start)::int;
  v_count int;
begin
  if not has_org_role(p_org, array['owner', 'administrador']::org_role[]) then
    raise exception 'Not authorized';
  end if;

  if exists (
    select 1 from accounting_periods
    where organization_id = p_org and status = 'cerrado' and period_start > v_start
  ) then
    raise exception 'Only the latest closed month can be reopened. Correct older months with a reversing entry.';
  end if;

  perform 1 from folio_sequences
  where organization_id = p_org and fiscal_year = v_year
  for update;

  select count(*) into v_count from journal_entries
  where organization_id = p_org and folio is not null
    and date_trunc('month', entry_date)::date = v_start;

  update journal_entries set folio = null, folio_year = null
  where organization_id = p_org and folio is not null
    and date_trunc('month', entry_date)::date = v_start;

  update folio_sequences set last_folio = greatest(0, last_folio - coalesce(v_count, 0))
  where organization_id = p_org and fiscal_year = v_year;

  update accounting_periods
  set status = 'abierto', reopened_at = now(), reopened_by = auth.uid()
  where organization_id = p_org and period_start = v_start;
end
$$;

-- Callers go through the functions; clients get no direct execute on internals.
revoke all on function close_accounting_period(uuid, date) from public;
revoke all on function reopen_accounting_period(uuid, date) from public;
