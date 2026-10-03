-- Period lock. Any insert, update or delete that would touch a closed month
-- is rejected by the database itself, whatever the application does.
-- In production one trigger function covers every source document table
-- (charges, payments, expenses, payroll...); journal entries are generated
-- from those documents. Here it guards `payments` to keep the sample small.

create or replace function fn_period_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org  uuid;
  v_date date;
begin
  if tg_op in ('INSERT', 'UPDATE') then
    v_org  := (to_jsonb(new) ->> 'organization_id')::uuid;
    v_date := case tg_table_name
      when 'payments' then (to_jsonb(new) ->> 'paid_on')::date
    end;
    if is_period_closed(v_org, coalesce(v_date, current_date)) then
      raise exception 'The accounting period % is closed. Reopen it to make changes.',
        to_char(coalesce(v_date, current_date), 'MM/YYYY');
    end if;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    v_org  := (to_jsonb(old) ->> 'organization_id')::uuid;
    v_date := case tg_table_name
      when 'payments' then (to_jsonb(old) ->> 'paid_on')::date
    end;
    if is_period_closed(v_org, coalesce(v_date, current_date)) then
      raise exception 'The accounting period % is closed. Reopen it to make changes.',
        to_char(coalesce(v_date, current_date), 'MM/YYYY');
    end if;
  end if;

  if tg_op = 'DELETE' then return old; else return new; end if;
end
$$;

create trigger trg_period_guard_payments
  before insert or update or delete on payments
  for each row execute function fn_period_guard();
