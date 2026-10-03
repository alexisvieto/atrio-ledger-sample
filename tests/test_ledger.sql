-- Run after the files in sql/. Each check raises an exception on failure,
-- so the script stops at the first broken expectation.
\set ON_ERROR_STOP on

do $$
declare
  v_org   uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_admin uuid := gen_random_uuid();
  v_guard uuid := gen_random_uuid();
  v_folios int[];
  v_ok boolean;
begin
  insert into organizations (id, name) values (v_org, 'Building A'), (v_other, 'Building B');
  insert into org_members values (v_org, v_admin, 'administrador'), (v_org, v_guard, 'guardia');

  insert into journal_entries (organization_id, entry_date, description) values
    (v_org, '2026-01-20', 'Jan maintenance fee'),
    (v_org, '2026-01-05', 'Jan electricity'),
    (v_org, '2026-02-03', 'Feb maintenance fee'),
    (v_other, '2026-01-10', 'Other building, Jan');

  -- 1. A guard (non-admin role) cannot close a month.
  perform set_config('request.jwt.claim.sub', v_guard::text, false);
  begin
    perform close_accounting_period(v_org, '2026-01-01');
    raise exception 'FAIL: guard was allowed to close';
  exception when others then
    if sqlerrm not like 'Not authorized%' then raise; end if;
  end;

  -- 2. February cannot be closed while January is still open.
  perform set_config('request.jwt.claim.sub', v_admin::text, false);
  begin
    perform close_accounting_period(v_org, '2026-02-01');
    raise exception 'FAIL: closed February before January';
  exception when others then
    if sqlerrm not like 'Close earlier months first%' then raise; end if;
  end;

  -- 3. Closing January numbers its entries 1..n in date order.
  perform close_accounting_period(v_org, '2026-01-01');
  select array_agg(folio order by entry_date) into v_folios
  from journal_entries where organization_id = v_org and entry_date < '2026-02-01';
  if v_folios <> array[1, 2] then raise exception 'FAIL: January folios %', v_folios; end if;

  -- 4. Other tenants are untouched.
  if exists (select 1 from journal_entries where organization_id = v_other and folio is not null) then
    raise exception 'FAIL: closing one building numbered another building''s entries';
  end if;

  -- 5. Closing February continues the sequence with no gap.
  perform close_accounting_period(v_org, '2026-02-01');
  if (select folio from journal_entries where description = 'Feb maintenance fee') <> 3 then
    raise exception 'FAIL: February did not continue at 3';
  end if;

  -- 6. A payment dated in a closed month is rejected by the database.
  begin
    insert into payments (organization_id, paid_on, amount) values (v_org, '2026-01-15', 100);
    raise exception 'FAIL: payment accepted in a closed month';
  exception when others then
    if sqlerrm not like 'The accounting period%closed%' then raise; end if;
  end;

  -- 7. January cannot be reopened while February is closed.
  begin
    perform reopen_accounting_period(v_org, '2026-01-01');
    raise exception 'FAIL: reopened a month that is not the latest closed';
  exception when others then
    if sqlerrm not like 'Only the latest closed month%' then raise; end if;
  end;

  -- 8. Reopening February removes its folio and steps the counter back,
  --    so closing it again hands out the same number.
  perform reopen_accounting_period(v_org, '2026-02-01');
  if (select last_folio from folio_sequences where organization_id = v_org and fiscal_year = 2026) <> 2 then
    raise exception 'FAIL: counter not stepped back';
  end if;
  insert into journal_entries (organization_id, entry_date, description)
  values (v_org, '2026-02-01', 'Feb late correction');
  perform close_accounting_period(v_org, '2026-02-01');
  select array_agg(folio order by entry_date, id) into v_folios
  from journal_entries where organization_id = v_org and entry_date >= '2026-02-01';
  if v_folios <> array[3, 4] then raise exception 'FAIL: February folios after reopen %', v_folios; end if;

  raise notice 'All ledger checks passed.';
end
$$;
