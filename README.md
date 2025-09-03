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
