# Handoff from Tim — CWA Ride Scheduler v1.9

Hi—Tim here. I’m handing you the **authoritative v1.9 spec** for the CWA Ride Scheduler database:

**Spec:** `CWA-Ride-Scheduler-v1.9-spec.md` (attached previously)

Your job is to produce the **SQL** and the **test SQL** to fully implement this spec. Please read this entire handoff before you begin.

---

## What I want you to deliver

### 1) Phase-based SQL deliverables (don’t do it all in one go)

I want a **cautious, phased build**. Each phase must come with:
- a single **run script** that **clears and recreates** the working schema and then builds everything for that phase, and
- a matching **test script** that proves the phase is correct.

**Naming:**
- `v1.9-phase1-run.sql` + `v1.9-phase1-tests.sql`
- `v1.9-phase2-run.sql` + `v1.9-phase2-tests.sql`
- …and so on.

**Important — clean rebuild every time:**  
Each `*-run.sql` must **clear out the database for its scope** and then recreate. Use a dedicated app schema (e.g., `cwa` or `dev`) so you can do:

```sql
DROP SCHEMA IF EXISTS cwa CASCADE;
CREATE SCHEMA cwa;
SET search_path = cwa, public;
```

Then create all objects under that schema.  
**Do not** rely on `SET ROLE postgres;` (this is Supabase).  
If you choose to use `public`, then implement a reliable “drop-and-recreate all objects” section at the top (tables, views, functions, triggers, types) so the script is idempotent and **leaves no leftovers**.

---

## Project phases & acceptance criteria

### **Phase 1 — Catalogs, Core Tables, Views (masked), Seeds**
**Build:**
- Catalogs: `roles`, `statuses`, `role_allowed_statuses`, optional `cert_types`.
- Core tables: `people`, `person_roles`, `people_unavailability`, `ride_events`, `ride_assignments`, `ride_passenger_contacts` (Option B), `person_certifications`, `app_user_people`.
- Helper functions: masking helpers (for name/email/phone), `is_within_operating_hours` (skeleton), any small utilities needed by views.
- Views (read-only): `v_pilot_roster`, `v_passenger_roster`, `v_ride_list`, `v_ride_detail` with **PII masking** for non-admins; **no writes yet**.
- Seeds: initial rows for catalogs; a few sample people in diverse statuses; **one admin** and **one scheduler** (however you model auth roles) and a sample `app_user_people` mapping.

**Tests (Phase 1):**
- Views exist and project fields as described.  
- Masking works for a “non-admin” role; “admin/scheduler” sees unmasked.  
- Roster readiness flags (`has_contact_method`, etc.) behave as specified.  
- Time ranges are half-open `[start,end)` in expressed views.

---

### **Phase 2 — Core Scheduling Rules & RPCs**
**Build:**
- RPCs: `save_ride`, `assign_person`, `unassign_person`, `link_emergency_contact`, `unlink_emergency_contact`.
- Business logic:  
  - **State transitions** (`tentative`, `scheduled`, `completed`, `cancelled`) with `cancel_reason` rule.  
  - **Operating hours** check (same-day; local window; DST by local clock).  
  - **Role & status gating** via `role_allowed_statuses` (pilot must be `active` to assign; passenger must be `interested`).  
  - **Composition** (exactly 1 pilot, ≤2 passengers).  
  - **No double-booking** (overlaps) using **deferrable, initially deferred** constraint triggers.  
  - EC linkage **Option B** (per-passenger EC; passenger must already be assigned; EC availability check).  
  - **Certs warn-only** (warnings array from `assign_person`).  
  - **History immutability** rules as spec’d.
- Permission helper: `is_admin_or_scheduler()` and use it inside write RPCs.
- Grants: do **not** grant base tables to general readers; views are for reads.

**Tests (Phase 2):**
- Happy path: create a valid ride (`ride_ok_create`).  
- Hours gate (`ride_bad_hours` → `ERR_HOURS`).  
- Cancel without reason (`ERR_CANCEL_REASON`).  
- Forbidden transitions (`ERR_STATE`).  
- Role missing / status not allowed (`ERR_ROLE` / `ERR_STATUS`).  
- Unavailability blocks assignment (`ERR_UNAVAILABLE`).  
- **Deferred** rules: second pilot, third passenger, and overlap must error deterministically (use `SET CONSTRAINTS ALL IMMEDIATE` or per-test `COMMIT`).  
- EC Option B: EC before passenger (`ERR_EC_LINK`), bad status/role, unavailable, and happy path.  
- Cert warn-only returns `warnings`.

---

### **Phase 3 — People & Availability RPCs**
**Build:**
- RPCs: `upsert_person`, `set_person_status`, `add_person_role`, `remove_person_role`, `upsert_contact_methods`.  
- Availability RPCs: `add_unavailability`, `remove_unavailability`, `bulk_set_unavailability`.  
- Optional quick-add: `find_or_create_person_by_contact`.

**Tests (Phase 3):**
- Person create/edit with normalized contact; dedupe behavior if you implement it.  
- Add/remove roles (block removal if future ride depends on it).  
- Status set OK vs. incompatible with role (→ `ERR_STATUS`).  
- Availability CRUD; boundary test for `[end=start)`; optional “can’t add unavailability over an existing future assignment”.

---

### **Phase 4 — Self-Service Views & RPCs (Scoped to Caller)**
**Build:**
- Views/Functions: `v_my_rides` (caller is the **pilot**), `v_my_ec_rides` (caller is **EC**), each using `app_user_people(auth_user_id → person_id)` internally.  
- Optional self-service RPCs: `self_set_unavailability`, `self_update_contact` (SECURITY DEFINER; “caller owns this row” checks).

**Tests (Phase 4):**
- As a pilot user, see **only my rides** (and not others’).  
- As an EC, see **only rides where I am EC**.  
- Self-service RPCs can update **only my rows**.

---

### **Phase 5 — Hardening & Docs**
**Build/Do:**
- Finalize indexes and check performance for roster views.  
- Verify masking completeness (no PII leaks).  
- Review grants: views for reads; RPCs for writes; nothing else.  
- Document any remaining gaps and a short RLS upgrade plan.

**Tests (Phase 5):**
- Full suite runs green end-to-end on a clean rebuild.  
- Add any edge-case tests discovered during review (DST boundary, day-end boundary, etc.).

---

## Technical expectations

- **Postgres / Supabase** target.  
- **Idempotent build**: Each `*-run.sql` can be executed repeatedly; it **drops the schema and recreates** all objects for that phase.  
- **No `SET ROLE postgres`** anywhere.  
- **Consistency**: All error responses from RPCs use the JSON shape defined in the spec (`ok, err_code, message, warnings?`).  
- **Triggers**: Overlap & composition rules should be **deferrable, initially deferred** so we catch issues at commit (and make tests force evaluation).  
- **Comments**: Add brief comments on non-obvious parts so the next person can maintain it.

---

## Tests — harness requirements (apply in every phase)

- The test script should be self-contained: it should **assume a clean schema** built by that phase’s run script.  
- For rules enforced by **deferred** triggers, ensure each test either:
  - runs `SET CONSTRAINTS ALL IMMEDIATE` before executing, **or**
  - runs in its own transaction and `COMMIT`s, so violations surface.  
- Each test should return structured JSON rows the way the spec describes (makes it easy to compare expected vs actual).

---

## Do you need my older v1.8 SQL?

**No for primary development**—please follow the v1.9 spec exactly. The 1.8 SQL had model mismatches (e.g., security model, EC linkage, role/status alignment). Reusing it risks carrying forward the wrong assumptions.

**If you want context**, I can provide the 1.8 files in a separate “archive” for background only. Do **not** copy patterns from it without reconciling with the v1.9 spec.

---

## Environment notes & assumptions

- Timezone: **America/Los_Angeles**.  
- Security (v1.9): **masking-only**, not RLS.  
- Writes: only via **SECURITY DEFINER RPCs** gated by `is_admin_or_scheduler()`.  
- Reads: via **views** (masked for non-privileged).  
- Mapping: `app_user_people` connects Supabase `auth.user_id` → `person_id` for self-service scoping.  
- In production, do **not** grant base tables to general users.

---

## Final deliverables checklist (per phase)

- `v1.9-phaseX-run.sql` — **drops and recreates** schema; builds DDL, views, RPCs, triggers, grants, seeds for that phase.  
- `v1.9-phaseX-tests.sql` — runs the phase’s tests and prints structured results.  
- A short README note inside a SQL comment at the top describing what the phase contains and how to run tests.

Thanks!

—Tim


## Phase 1 Status

Phase 1 has been completed successfully. The schema builds cleanly in Supabase, and all Phase 1 tests pass (masking, roster flags, view projections, contact method correctness).

Artifacts:
- `v1.9-phase1-run.sql` — schema and seeds.
- `v1.9-phase1-tests.sql` — unified test runner, all checks returned ok:true.

## Phase 2 Handoff

The next phase is to implement RPCs and enforcement logic.

Deliverables:
1. **Run script** (`v1.9-phase2-run.sql`) that adds stored procedures and deferrable constraints/triggers to the Phase 1 schema.
2. **Test script** (`v1.9-phase2-tests.sql`) that exercises each RPC, validates business rules, and confirms expected error codes.
3. Update to the spec (v1.9) if any clarifications are needed during implementation.

Scope of Phase 2:
- RPCs for people, roles, unavailability, rides, assignments, emergency contacts, certifications.
- Deferrable composition checks: exactly one pilot, max two passengers.
- Overlap prevention: a pilot cannot be assigned to overlapping rides.
- Passenger EC Option B enforcement.
- Certification presence/expiry warnings (non-blocking).

Each test should return JSON rows (or columnized equivalents) with fields `test | ok | data | err_code`, consistent with Phase 1.
