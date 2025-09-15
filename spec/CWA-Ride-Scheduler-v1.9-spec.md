# CWA Ride Scheduler — Functional & Data Spec (v1.9, updated)

> This version incorporates the practical additions requested: **people/role/status/availability RPCs**, **self-service views** for pilots and ECs, the **`app_user_people`** mapping, and expanded **tests** that cover those paths. It also includes a clear section on **why RLS is deferred now** (with mitigations and the upgrade path).

---

## 1) Scope & Objectives

**What this is:**  
A Postgres-backed scheduling system for community trishaw rides. It models people, roles (pilot, passenger), availability/unavailability, certifications, ride events, emergency contacts, and enforces business rules so **schedulers** and **admins** can operate safely.

**Who uses it:**  
- **Schedulers**: primary operators (write).  
- **Admins**: superusers (write).  
- **Authenticated viewers**: read only via masked views.  
- **Pilots / Emergency contacts**: self-service reads (and limited self-edits via dedicated RPCs if enabled).

**Non-goals in v1.9:**  
- Row Level Security (RLS) — deferred; see §11.  
- Notifications/messaging — deferred.  
- Full audit logs & idempotency — deferred.  
- UI/UX details — out of scope (this is a DB spec).

**Timezone:** All business rules operate in **America/Los_Angeles**.

---

## 2) Glossary

- **Ride**: Scheduled event with one pilot and up to two passengers.  
- **Person**: Anyone who can be pilot, passenger, or EC.  
- **Role**: Domain role (pilot, passenger).  
- **Status**: Standing of a person (pilot: `active`, `in_training`, `inactive`; passenger: `interested`, `not_interested`, `deceased`).  
- **Roster readiness**: Eligibility to appear in roster views.  
- **Operating hours**: Daily window rides must fit within.  
- **Unavailability**: Time ranges a person cannot be scheduled.  
- **Masking**: PII obscured for non-privileged readers.

---

## 3) Data Model (Conceptual)

### 3.1 Core Entities
- **people** — identity & contact (PII here), single `status_key`.  
- **roles** (catalog) — seeded: `pilot`, `passenger`.  
- **statuses** (catalog) — seeded values per role family (see above).  
- **role_allowed_statuses** (bridge) — which statuses are allowed for each role.  
  - v1.9 policy:  
    - `pilot`: `active`, `in_training` (assignable only if `active`; see §6.2)  
    - `passenger`: `interested`  
- **person_roles** — which roles a person holds.  
- **people_unavailability** — half-open `[start,end)` timestamptz ranges.  
- **ride_events** — start/end, status, cancel_reason, notes…  
- **ride_assignments** — persons assigned to a ride with a role.  
- **ride_passenger_contacts** — **per-passenger EC links** `(ride_id, passenger_id, contact_person_id)` (**Option B**).  
- **certifications / person_certifications** — pilot certs with expirations.  
- **app_user_people** — maps `auth_user_id` → `person_id` for self-service scoping.

### 3.2 Views (Read Models)
- **v_pilot_roster** — readiness flags, cert warnings; masked PII for non-admins.  
- **v_passenger_roster** — readiness flags; masked PII for non-admins.  
- **v_ride_list** — compact ride summaries.  
- **v_ride_detail** — ride + pilot + passengers + ECs.  
- **v_my_rides** — rides where the caller is the **pilot** (self-service).  
- **v_my_ec_rides** — rides where the caller is an **EC** (self-service).

> Masking rules apply to non-privileged readers (see §10). Self-service views scope by the caller via `app_user_people`.

---

## 4) Security & Access (Masking-Only in v1.9)

- **No RLS** yet (see §11).  
- **Write access** only via SECURITY DEFINER RPCs gated by `is_admin_or_scheduler()`.  
- **Read access** for general authenticated users is via **views** with **PII masking**.  
- **Base tables** should **not** be granted to general readers in production; use views only.

**PII Masking (minimum):**  
- Name: last name reduced (e.g., “Pat S…”).  
- Email: mask local part (e.g., `p•••@example.com`).  
- Phone: show last 2–4 digits.  
- Address (if present): city only or masked.  
- Admins/schedulers see unmasked via role check.

---

## 5) Public API (Stored Procedures / RPCs)

All RPCs return **`{ ok: boolean, data?: jsonb, err_code?: text, message?: text, warnings?: jsonb }`**.

### 5.1 People & Contact Info
- **`upsert_person(p_person jsonb) → jsonb`**  
  Create/edit people atomically. Normalize email/phone. Optionally dedupe. Returns canonical row.

- **`set_person_status(p_person_id uuid, p_status text) → jsonb`**  
  Validates status exists and is compatible with any roles via `role_allowed_statuses`. May reject with `ERR_STATUS`.

- **`add_person_role(p_person_id uuid, p_role text) → jsonb`**  
  Adds a role; ensures catalogs exist; may warn if incompatible with current status.

- **`remove_person_role(p_person_id uuid, p_role text) → jsonb`**  
  Removes a role; may block if existing future assignments depend on it.

- **`upsert_contact_methods(p_person_id uuid, p_contact jsonb) → jsonb`**  
  Update email/phone with normalization; recompute `has_contact_method` view flag.

- **(Optional)** **`find_or_create_person_by_contact(p_name text, p_email text, p_phone text) → jsonb`**  
  Heuristic match on normalized email/phone; if high confidence, returns existing person; else creates.

### 5.2 Availability
- **`add_unavailability(p_person_id uuid, p_start timestamptz, p_end timestamptz) → jsonb`**  
  Validates `start<end`; records `[start,end)`. May block if overlapping an **existing ride assignment** unless admin override.

- **`remove_unavailability(p_unavailability_id uuid) → jsonb`**  
  Deletes one block.

- **`bulk_set_unavailability(p_person_id uuid, p_ranges jsonb) → jsonb`**  
  Replace the person’s set of blocks atomically.

### 5.3 Rides & Assignments
- **`save_ride(p_ride jsonb) → jsonb`**  
  Creates/updates a ride; enforces **operating hours**, **state transitions**, **cancel reason**; respects **immutability** rules.

- **`assign_person(p_ride_id uuid, p_person_id uuid, p_role text) → jsonb`**  
  Requires person has role; checks **role_allowed_statuses**; enforces **composition** (1 pilot, ≤2 pax), **double-booking**, **unavailability**; returns **cert warnings** (warn-only).

- **`unassign_person(p_ride_id uuid, p_person_id uuid, p_role text) → jsonb`**

- **`link_emergency_contact(p_ride_id uuid, p_passenger_id uuid, p_contact_person_id uuid) → jsonb`**  
  **Option B** per-passenger EC; passenger must already be assigned; EC status/availability validated.

- **`unlink_emergency_contact(p_ride_id uuid, p_passenger_id uuid, p_contact_person_id uuid) → jsonb`**

### 5.4 Certifications
- **`upsert_person_cert(p_person_id uuid, p_cert_key text, p_expires_on date) → jsonb`**  
  Maintains pilot certs; `assign_person` surfaces warnings only.

### 5.5 Self-Service (Scoped to Caller; Optional in v1.9)
- **`self_set_unavailability(p_ranges jsonb) → jsonb`**  
  SECURITY DEFINER; looks up caller via `app_user_people`; edits only their rows.

- **`self_update_contact(p_contact jsonb) → jsonb`**  
  Same scoping; update own contact info.

> All write RPCs check `is_admin_or_scheduler()` except self-service ones, which **must** verify “caller owns this row.”

---

## 6) Error Model

Canonical `err_code`s:  
`ERR_PRIVS`, `ERR_INPUT`, `ERR_STATE`, `ERR_CANCEL_REASON`,  
`ERR_HOURS`, `ERR_ROLE`, `ERR_STATUS`, `ERR_UNAVAILABLE`,  
`ERR_OVERLAP`, `ERR_COMPOSITION`, `ERR_EC_LINK`, `ERR_IMMUTABLE`.

---

## 7) Business Rules

### 7.1 Ride State Transitions
Enum: `tentative`, `scheduled`, `completed`, `cancelled`.

**Allowed:**  
- `tentative → scheduled | cancelled`  
- `scheduled → completed | cancelled`

**Forbidden (examples):**  
- `completed → *`, `cancelled → *`, `scheduled → tentative`.

On `cancelled`, **`cancel_reason` required** (non-empty).

### 7.2 Role & Status Gating
- Person must **hold** the role (`person_roles`).  
- Person’s `status_key` must be **allowed** for that role (`role_allowed_statuses`).  
- **Assignment strictness (v1.9):**  
  - **Pilot**: must be `active` to be **assignable**; `in_training` appears in rosters with `assignable=false`.  
  - **Passenger**: must be `interested` to be assignable.

### 7.3 Composition & Overlaps
- **Exactly 1 pilot**, **0–2 passengers** per ride.  
- No person may be assigned to **overlapping** rides.  
- Enforced by **deferrable, initially deferred** constraint triggers; violations surface at **commit**.

### 7.4 Operating Hours
- A ride must both start and end within the configured local window (e.g., 09:00–18:00 **America/Los_Angeles**), same-day only.  
- Local clock-time comparison; DST behaves as resolved by the timezone.

### 7.5 Emergency Contacts — **Option B (Per-Passenger)**
- `ride_passenger_contacts(ride_id, passenger_id, contact_person_id)`.  
- Rules:  
  1) `passenger_id` must already be assigned to the ride as passenger.  
  2) EC must be a valid person in allowed status.  
  3) EC must be **available** for the ride window.  
  4) 0..N ECs per passenger (recommend ≤2).

### 7.6 Certifications (Warn-Only)
- Missing/expired certs **do not** block assignment; surfaced in `warnings`.

### 7.7 History Immutability
- If `end_at < now()`: historical.  
- Block edits to `start_at`, `end_at`, and assignments.  
- Allow: `scheduled → completed` within 24h after end; `cancel_reason`; non-critical notes.

---

## 8) Data Quality & Indexes

- **Contact requirement:** roster-ready requires ≥1 contact method (email or phone).  
- **Half-open ranges:** all time windows are `[start,end)`.  
- **Indexes:**  
  - FKs on all FK columns.  
  - `ride_events(start_at)`, `ride_events(end_at)`  
  - `ride_assignments(ride_id)`, `ride_assignments(person_id)`  
  - `people_unavailability(person_id, start_at, end_at)`  
  - Consider GiST if moving to exclusion constraints later.

---

## 9) Seeds & Bootstrap

1) Seed catalogs: `roles`, `statuses`, `role_allowed_statuses`, `cert_types` (if used).  
2) Add at least one **admin** and **scheduler** to `app_user_roles` (or equivalent).  
3) Map real users for self-service: insert into `app_user_people(auth_user_id, person_id)`.  
4) Configure operating hours (settings table or function constants).  
5) Seed representative people (various statuses) for test coverage.

---

## 10) Read Models by Persona

- **Schedulers/Admins:** `v_pilot_roster`, `v_passenger_roster`, `v_ride_list`, `v_ride_detail`.  
- **Pilots:** `v_my_rides` — scoped by `app_user_people` to caller’s `person_id`.  
- **Emergency Contacts:** `v_my_ec_rides` — scoped similarly.

Self-service views are SECURITY DEFINER (or stable functions) that internally map the caller’s `auth_user_id` to their `person_id` and filter accordingly. PII masking still applies for non-privileged fields.

---

## 11) Why RLS Is Deferred (and Why It’s an Upgrade)

**What RLS is:** Row-Level Security enforces per-row access with SQL policies injected into every query.

**Why defer now:**  
- **Complexity**: many tables × roles × cases; policies are easy to get wrong while the model is still moving.  
- **Debuggability**: invisible filters complicate early dev/testing.  
- **RPC interplay**: RLS applies **inside** functions; crafting policies that also permit SECURITY DEFINER RPCs adds friction.  
- **Evolving model**: roles, statuses, EC linkage, and transitions are still being tuned.

**Mitigations in v1.9:**  
- **No base-table grants** to general users; reads go through **masked views**; writes go through **gated RPCs**.  
- **PII masking** in views for non-privileged readers.  
- **Constraints + triggers** enforce integrity regardless of the client.  
- **Self-service scope**: “My Rides”/“My EC Rides” views/functions scoped by `app_user_people`, preparing the UX for RLS.

**Upgrade path:**  
- Enable RLS on base tables once the model stabilizes.  
- Add policies for admins/schedulers (full), pilots (own rides), ECs (their rides), general viewers (none/limited).  
- Extend tests with RLS assertions (admin sees; non-admin doesn’t; pilot sees only theirs).  
- Keep **RPC signatures and views unchanged** so the UI doesn’t need to change.

---

## 12) Test Plan (Authoritative)

### 12.1 Harness Requirements
- For **deferred** constraints, each test either:
  - issues `SET CONSTRAINTS ALL IMMEDIATE` before the statement, **or**  
  - runs in its **own transaction** and `COMMIT`s to surface violations.

All tests return JSON with `ok`, `err_code`, optional `warnings`.

### 12.2 Catalog (what each test proves)

**Ride lifecycle**
- `ride_ok_create` — Valid ride within hours (happy path).  
- `ride_bad_hours` — Outside window → `ERR_HOURS`.  
- `cancel_without_reason` — `status=cancelled` without reason → `ERR_CANCEL_REASON`.  
- `state_transition_illegal` — Forbidden transitions (e.g., `scheduled→tentative`, `completed→scheduled`) → `ERR_STATE`.

**People / roles / status**
- `person_upsert_ok` — Create/edit person with normalized contact.  
- `add_role_ok` / `remove_role_ok` — Role management; prevents removal if future assignments depend on it.  
- `set_status_ok` — Valid status; incompatible status vs role → `ERR_STATUS`.  
- `assign_in_training_pilot_blocked` — Pilot `in_training` cannot be **assigned** (but appears in roster).  
- `assign_inactive_pilot_blocked` — Pilot `inactive` → `ERR_STATUS`.  
- `assign_interested_passenger_ok` — Happy path.  
- `assign_not_interested_passenger_blocked` / `assign_deceased_passenger_blocked` — → `ERR_STATUS`.

**Availability**
- `add_unavailability_ok` / `remove_unavailability_ok` — CRUD.  
- `unavailability_overlap_with_assignment_blocked` — Adding a block over an existing assignment → `ERR_UNAVAILABLE` (if enforced).  
- `unavailability_boundary_ok` — Touching boundary `[end=start)` is not overlap.

**Assignments — composition & overlaps (deferred)**
- `second_pilot_db_error` — Exactly one pilot.  
- `third_passenger_db_error` — ≤2 passengers.  
- `overlap_db_error` — No double-booking.

**Emergency contacts — Option B**
- `ec_before_passenger_blocked` — EC link before passenger assignment → `ERR_EC_LINK`.  
- `ec_wrong_status_or_role_blocked` — EC invalid → `ERR_STATUS`/`ERR_ROLE`.  
- `ec_unavailable_blocked` — EC unavailable → `ERR_UNAVAILABLE`.  
- `ec_link_ok` — Happy path.

**Certifications (warn-only)**
- `pilot_cert_warning_info` — Missing/expired cert surfaces in `warnings`, not an error.

**History immutability**
- `immutable_block_time_change` — Edits on historical ride → `ERR_IMMUTABLE`.  
- `immutable_allow_finalize` — `scheduled→completed` within 24h after end: allowed.

**Views & masking**
- `roster_masking_non_admin` — Non-admin sees masked PII; only roster-ready rows.  
- `roster_unmasked_admin` — Admin sees unmasked.  
- `v_my_rides_scope_ok` — Pilot sees only their own rides.  
- `v_my_ec_rides_scope_ok` — EC sees only rides where they’re linked.

**Assignments — composition & overlaps (deferred)**
- `second_pilot_db_error` — Exactly one pilot; early `ERR_COMPOSITION` **or** commit-time constraint is acceptable.  
- `third_passenger_db_error` — ≤2 passengers.  
- `overlap_db_error` — No double-booking.

**Emergency contacts — Option B**
- `ec_before_passenger_blocked` — EC link before passenger assignment → `ERR_EC_LINK`.  
- `ec_wrong_status_or_role_blocked` — EC invalid → `ERR_STATUS`/`ERR_ROLE`.  
- `ec_unavailable_blocked` — EC unavailable → `ERR_UNAVAILABLE`.  
- `ec_link_ok` — Happy path.

**Self-service & Views (Phase 3)**
- `self_set_unavailability_ok` — Caller can set their own unavailability via SECURITY DEFINER RPC (scoped by `app_user_people`).  
- `v_my_rides_scope_ok` — With caller’s JWT, returns rides where caller is **pilot** only.  
- `v_my_ec_rides_scope_ok` — With caller’s JWT, returns rides where caller is linked as **EC** only.


---

## 13) Implementation Notes

- Use **timestamptz** for all timestamps; convert to local TZ when comparing operating hours.  
- Keep business rules centralized:  
  - **RPCs** handle inputs, status/role gates, hours, immutability, EC linkage.  
  - **Deferrable triggers** handle composition/overlap at commit.  
- Small, reusable helpers: masking, normalization, readiness flags.

---

## 14) Change Log (since earlier v1.9 draft)

- Added **people/roles/status/availability RPCs** (§5.1–5.2).  
- Added **self-service RPCs** and **views** + `app_user_people` mapping (§5.5, §3.1, §10).  
- Expanded **Test Plan** with people/availability/self-service & masking tests (§12).  
- Clarified **masking-only** security model and production grants (§4).  
- Added **RLS deferral rationale**, mitigations, and upgrade path (§11).
