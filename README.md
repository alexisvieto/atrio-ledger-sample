# Month-end ledger close in PostgreSQL

A sample from **Atrio**, a multi-tenant SaaS I built for managing residential buildings in Panama (accounting, payroll, resident portal). This is the piece that closes an accounting month.

When a building administrator closes a month, the entries in that month have to become official: numbered with a sequential folio, with no gaps and no duplicates, and frozen. Official accounting books are numbered sequentially, and an auditor will notice a missing number.

All of it runs inside the database, so no application bug, retry or second browser tab can break the rules.

## What it does

**Closing a month** (`close_accounting_period`)
- Only an owner or administrator of that building can close it.
- Months close in order. If an earlier month still has unnumbered entries, the close is refused.
- Each entry gets the next folio for the fiscal year, in date order. The counter row is locked with `SELECT ... FOR UPDATE`, so two closes running at the same time can't assign the same number or skip one.

**Reopening a month** (`reopen_accounting_period`)
- Only the latest closed month can be reopened. Its folios are cleared and the counter steps back, so numbering stays gap-free when it is closed again.
- Older months are corrected with a reversing entry in the current open month, never by rewriting closed books.

**Period lock** (`fn_period_guard`)
- A trigger rejects any insert, update or delete of a source document (payments here; charges, expenses, payroll and others in production) dated in a closed month.

Every query is filtered by `organization_id`. In production, Row Level Security keeps each building's data isolated as well.

## Run the tests

You need PostgreSQL 14+ and a throwaway database.

```bash
createdb ledger_test
DATABASE_URL=postgres:///ledger_test ./run_tests.sh
# NOTICE:  All ledger checks passed.
```

The test covers permissions, close order, gap-free numbering, tenant isolation, the period lock, and reopen then close again.

## Files

| File | Content |
|---|---|
| `sql/01_schema.sql` | Minimal tables, plus stand-ins for Supabase Auth (`auth.uid()`) and the roles check |
| `sql/02_close_and_reopen.sql` | Close and reopen functions |
| `sql/03_period_guard.sql` | Period lock trigger |
| `tests/test_ledger.sql` | Assertions for the rules above |

## Notes

- Production runs on Supabase (PostgreSQL). The close and reopen functions are the production code with messages translated to English. The schema and the guard are trimmed to what the sample needs.
- I build with Claude Code. The data model, the accounting rules and the locking strategy are my design, and every change is checked against a real database before it ships.

Alexis Vieto · [nexerai.io/v/alexis](https://www.nexerai.io/v/alexis)
