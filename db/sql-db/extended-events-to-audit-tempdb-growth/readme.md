# tempdb Autogrowth Audit — RDS SQL Server

**Which query? Run by whom? Made tempdb grow?** — recurring offenders can be found and restructured before they force another grow.

It runs entirely inside the SQL Server instance. Target instance is single-AZ RDS SQL Server (Standard/Enterprise, so SQL Agent is available).

---

## How to investigate?

> Open **`6-investigation.sql`**. Run **Section 1**, then **Section 2**, in the **same query window**.
> **Section 2** is a ranked table of the queries that caused the most tempdb growth.

Everything below is either one-time setup or optional depth.

---

## Files

**Setup — run ONCE, in order, in SSMS as the RDS master user:**

| # | File | What it creates |
|---|------|-----------------|
| 1 | `1-xe-session.sql` | Extended Events session that records every tempdb autogrowth — the *trigger* side (who/what fired the grow). |
| 2 | `2-utility-db-tables.sql` | `DBA_Utility` database + two snapshot tables — the *holder* side. |
| 3 | `3-capture-proc.sql` | Proc that snapshots tempdb holders. |
| 4 | `4-scheduling.sql` | SQL Agent job that runs the proc every minute. |
| 5 | `5-retention.sql` | Nightly Agent job that keeps 14 days of snapshots. |

**Investigation — run any time tempdb has grown (read-only, safe on prod):**

| File | What it does |
|------|--------------|
| `6-investigation.sql` | Section 2 = the answer. Sections 1+3 = optional depth. Section 4 = dev-only test. |

---

## One-time setup

Run files 1 → 5 once, in order, each top-to-bottom, as the master user.

**Do not re-run files 4 and 5** — they create named Agent jobs and will error on a duplicate name. If you need to change a job, alter it, don't re-add it.

Verify it took:

```sql
-- XE session running?  (create_time non-NULL = running)
SELECT s.name, s.startup_state, r.create_time
FROM sys.server_event_sessions s
LEFT JOIN sys.dm_xe_sessions r ON r.name = s.name
WHERE s.name = 'tempdb_autogrowth_audit';

-- Snapshots landing?  (wait ~2 min after setup, then this count should climb)
SELECT COUNT(*) AS rows_total, MAX(snapshot_time_utc) AS latest_utc
FROM DBA_Utility.dbo.tempdb_file_snapshot;
```

---

## Everyday use — Section 2

Run Section 1 then Section 2 of `6-investigation.sql`. Section 2 returns one row per query shape, ranked by how much tempdb it forced. Read it like this:

| Column | Meaning |
|--------|---------|
| `total_mb_grown` | Total tempdb this pattern forced. **This is the ranking measure.** |
| `grow_events` | How many separate autogrows it triggered (high = recurring, not a one-off). |
| `query_hash` | Identifies the query *shape*; every parameterised run shares it. Also the key to look the plan up in Query Store. |
| `login_name` | Connecting login — a *person* only if they logged in individually (see caveats). |
| `host_name` / `app_name` | Together, these separate application traffic from a human running ad-hoc SQL. |
| `sample_sql` | A representative full statement for that shape. |

---

## Going deeper (optional)

**Who was holding tempdb (Section 3).** When the triggering query looks innocent but tempdb still blew up, the real cause is often cumulative — version store, a long-open transaction, or someone else's spill. Section 3 joins each grow to the tempdb holders at that minute: `internal_object_mb` = spills, `version_store_mb` = row-versioning, plus the top holding sessions.

**Get the execution plan.** `sample_sql` tells you *what* ran; the plan tells you whether it's *structured properly*. Take the `query_hash` from Section 2 and look it up in Query Store **on the database in `database_name`** (Query Store is per-database):

```sql
DECLARE @qh BINARY(8) = CONVERT(BINARY(8), CONVERT(BIGINT, <query_hash>));
SELECT q.query_id, qt.query_sql_text, p.plan_id,
       rs.count_executions, rs.avg_tempdb_space_used, rs.max_tempdb_space_used,
       CAST(p.query_plan AS XML) AS query_plan
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt ON qt.query_text_id = q.query_text_id
JOIN sys.query_store_plan p        ON p.query_id = q.query_id
LEFT JOIN sys.query_store_runtime_stats rs ON rs.plan_id = p.plan_id
WHERE q.query_hash = @qh
ORDER BY rs.count_executions DESC;
```

In the plan, the tempdb offenders to look for: sort/hash **spill** warnings, a memory grant far larger than used, scans where a seek was possible, `CONVERT_IMPLICIT` forcing a scan, and large row-count misestimates.

---

## Caveats — state these when presenting findings

- **`login_name` is a person only for individual logins.** Application traffic (an internal app server, a legacy ETL job, an ORM) will show a shared service account + an app-server host + an app name like `.Net SqlClient` or `EntityFramework`. That maps to a **codebase/team**, not a person — trace it via `query_hash` → the repo. Use `host_name`/`app_name` to tell app traffic from human ad-hoc (a laptop host + `Microsoft SQL Server Management Studio`).
- **`login_name` can be NULL** for some statement types — fall back to `sql_text` + `host_name` + `app_name`.
- **Timestamps are UTC by design** (both the XE `@timestamp` and the snapshot tables). Do not convert the stored values to local time, or the Section 3 join silently misses.
- **Section 3 NULL holders** = the capture job wasn't running before that grow. Expected for historical grows; only grows *after* setup correlate.
- **A spill inside the 60-second gap** may show at category level (`internal_object_mb` rising) without a named holder session. The category still proves it was spills.
- **Query Store is per-database and capture-mode dependent.** If a hash returns nothing, confirm Query Store is `READ_WRITE` on that DB and, for ad-hoc coverage, capture mode is `ALL` not `AUTO`. Plan cache is transient — recurring prod queries stay cached; one-off queries may not.
