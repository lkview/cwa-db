# CWA Ride Scheduler — Database & API Specification Repository

This repository tracks the evolution of the **CWA Ride Scheduler** database and API specification, its SQL implementations, and test results. The goal is to ensure clarity, reproducibility, and easy rollback at every stage of development.

---

## Repository Structure

```
cwa-ride-scheduler-db/
├─ spec/              # Markdown specs (v1.4, v1.5, …)
│   ├─ v1.4.md
│   ├─ v1.5.md
│   └─ ...
├─ sql/               # SQL scripts (drop + recreate everything)
│   ├─ v1.4.sql
│   ├─ v1.5.sql
│   └─ ...
├─ tests/             # SQL or JSON results from validation queries
│   ├─ v1.4-results.json
│   ├─ v1.5-results.json
│   └─ ...
└─ README.md          # This file
```

---

## Workflow

1. **Spec Iteration**  
   - Edit the Markdown spec (`spec/v1.X.md`).  
   - Commit with a clear message:  
     ```
     spec: add cancellation_reason requirement (v1.5)
     ```

2. **SQL Generation**  
   - In a new ChatGPT thread, paste the spec and request the full SQL (drop & recreate).  
   - Save as `sql/v1.X.sql`.  
   - Commit:  
     ```
     sql: regenerate schema for v1.5
     ```

3. **Testing**  
   - Run the SQL script fresh on Supabase/Postgres.  
   - Capture test results (JSON or SQL output). Save as `tests/v1.X-results.json`.  
   - Commit:  
     ```
     tests: add validation results for v1.5
     ```

4. **Tracking / Rollback**  
   - Each version produces a trio of files: spec, SQL, test results.  
   - If a change breaks things, you can roll back by re-running an earlier SQL script (e.g., `sql/v1.4.sql`).

---

## GitHub Desktop

This repo is designed for **GitHub Desktop**:  
- **Pull** latest changes.  
- Add/edit files under `spec/`, `sql/`, or `tests/`.  
- **Commit** with a descriptive message.  
- **Push** to GitHub.  

All versions will exist locally and in the cloud.

---

## Practical Tips

- **Naming convention:** Stick to `vX.Y` for both spec and SQL files.  
- **Branching (optional):** Use a `dev` branch for experiments; merge into `main` when validated.  
- **Automated tests:** Use SQL queries to check constraints, RLS, etc., so validation is reproducible.  
- **README.md:** Keep this file updated if the workflow changes.

---

## Next Steps

1. Use `spec/v1.4.md` as the baseline.  
2. Initialize a GitHub repo with this folder structure.  
3. Sync with GitHub Desktop.  
4. For v1.5 and onward, follow the workflow: update spec → regenerate SQL → run tests → commit all.
