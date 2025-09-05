# CWA Ride Scheduler (v1.4)

> **Note:** v1.4 includes **Step 4 (DB Hardening)**: DB CHECK on `rides` for `cancellation_reason` when `status='cancelled'`, a constraint trigger capping passengers to ≤2, and the `app_settings` table powering `is_within_operating_hours()`.


This repository defines the Supabase/Postgres schema, views, RPCs, and tests for the CWA Ride Scheduler.

## Quick Start (Dev/Disposable DB only)

1. Open the Supabase SQL Editor.
2. Run the installer:
   ```sql
   \i sql/v1.4-run-all-fixed.sql
   ```
   ⚠️ This script **drops and recreates** the `public` schema. Do not run on production.
3. Run the tests:
   ```sql
   \i tests/tests/v1.4-tests.sql
   ```
   All rows should have `pass = true`.

## Role Bootstrapping

To see unmasked data in views, insert your Supabase `auth.users.id` into `app_user_roles`:

```sql
insert into app_user_roles (user_id, role_key)
values ('<your-auth-user-id>', 'admin');
```

## File Layout

- `spec/v1.4.md` – Canonical spec (rules, process, runbook, next steps)
- `sql/v1.4-run-all-fixed.sql` – One-pass installer (schema → views → seed → RPCs)
- `tests/tests/v1.4-tests.sql` – Self-contained PASS/FAIL test suite

Supporting files (for traceability):
- `sql/v1.4.sql` – Base schema only
- `sql/v1.4-step2-views-rls.sql` – Views + RLS
- `sql/v1.4-step2.1-seed.sql` – Seed data
- `sql/v1.4-step3-rpcs-validations.sql` – RPCs & validations
- `tests/v1.4-step3-tests-v2.sql` – Raw test results

## Known Limitations

- Some business rules are enforced in RPCs, not yet at DB-level.
- Operating window hardcoded (07:00–20:00 PT).
- Run-all works but CI automation not yet set up.
- Placeholder `app_user_roles` need to be replaced with real `auth.users.id`.

## Next Steps (Step 4 Plan)

- Add DB-level `CHECK` for `cancellation_reason` when cancelled.
- Add constraint trigger for ≤ 2 passengers (optional).
- Create `app_settings` table for configurable hours & timezone.
- Refactor `is_within_operating_hours()` to read from `app_settings`.
- Add CI workflow (GitHub Action) to run run-all + tests automatically.

---

## Tests (single-file suite)

Use the consolidated test runner for v1.4 (Step 3 + Step 4 hardening).

```bash
# Install schema + seeds
psql "$DATABASE_URL" -f sql/v1.4-run-all-fixed.sql

# Run all tests (one result set)
psql "$DATABASE_URL" -f tests/v1.4-tests.sql
```

