# RDS SQL Server – Table Growth Tracker

A lightweight, self-contained T-SQL toolkit that snapshots table sizes across every user database on an AWS RDS for SQL Server instance, then reports the top N fastest-growing tables over any time window you choose (last hour, last 24h, last week, etc.).

## How it works

1. An hourly SQL Agent job takes a **snapshot**: row counts and space usage (MB) for every user table in every online, non-system database, written into a central `DBA_Monitoring` database.
2. A **report query** compares the latest snapshot against a baseline snapshot from `N` hours ago, and ranks tables by growth (MB) per database.
3. Optional health-check queries let you keep an eye on the monitoring overhead itself (storage, job duration, query cost).
4. An optional cleanup step purges old snapshots so the tracking table doesn't grow forever.

## Requirements

- AWS RDS for SQL Server (Standard or Enterprise edition)
- SQL Server Agent enabled (Standard/Enterprise — not available on Express)
- A login/role with permission to create the `DBA_Monitoring` database and to read `sys.tables` / `sys.dm_db_partition_stats` in every database you want tracked
- rds_sysadmin (or equivalent) is generally sufficient on RDS

## Setup

Run the steps in `table-growth-tracker.sql` in order, the first time only where noted.

### Step 1 — One-time setup
Creates the `DBA_Monitoring` database and the `dbo.TableSizeSnapshot` table that stores every snapshot. Safe to re-run (idempotent — checks `IF NOT EXISTS` / `OBJECT_ID`).

### Step 2 — Take a snapshot
Loops through every online user database (`database_id > 4`, excluding `rdsadmin` and `DBA_Monitoring` itself) and inserts one row per table with:
- `TotalRows`
- `TotalSpaceMB`
- `UsedSpaceMB`

**Schedule this hourly** as a SQL Server Agent job for the best (and most consistent) reporting granularity. You can run it more or less often — the report query always finds the snapshot *closest* to your requested time window, so it tolerates gaps or irregular scheduling.

### Step 3 — Report: Top N growing tables
Set these three variables at the top of the query:

| Variable | Purpose | Example |
|---|---|---|
| `@HoursBack` | How far back to compare against | `24` = last day, `168` = last week, `720` = last month |
| `@TopN` | How many tables to show per database | `5` |
| `@TimezoneOffsetHours` | Shifts displayed timestamps from UTC to your local time | `8` for UTC+8, `-5` for UTC-5, `0` to leave as UTC |

Output columns:
- `OldSizeMB` / `NewSizeMB` / `GrowthMB` / `GrowthPct`
- `MBPerHour` and `ProjectedDailyMB` (linear extrapolation — useful for early warning on runaway growth)
- `RowsAdded`
- `HoursElapsed`, `BaselineTimeLocal`, `LatestTimeLocal`

Only tables that actually grew (`NewSizeMB > OldSizeMB`) are included, ranked per-database by `GrowthMB` descending.

### Steps 4–7 (optional) — Health checks
- **Step 4**: Size of the `TableSizeSnapshot` table and the `DBA_Monitoring` database itself, so you can confirm the monitoring overhead stays small.
- **Step 5**: SQL Agent job history for the snapshot job — update the job name (`'DBA_TableSizeSnapshot'`) to match whatever you name it when scheduling.
- **Step 6**: Plan-cache stats (CPU/IO/duration) for the snapshot INSERT, to catch performance regressions as databases grow.
- **Step 7**: Instance-wide I/O per database, for context on how much of total workload the monitoring adds.

### Step 8 (optional) — Retention cleanup
Deletes snapshots older than 30 days. Run manually or schedule as a weekly SQL Agent job. Adjust the `DATEADD(DAY, -30, ...)` interval to change retention.

## Scheduling via SQL Server Agent

1. Create a new Job (e.g. `DBA_TableSizeSnapshot`).
2. Add a step running **Step 2** (the snapshot INSERT block) against `DBA_Monitoring`.
3. Schedule: hourly, on a recurring basis.
4. (Optional) Add a second weekly job/step running **Step 8** for cleanup.

## Notes & caveats

- Sizes come from `sys.allocation_units` / `sys.partitions`, counting only heap or clustered index storage (`i.index_id IN (0,1)`) to avoid double-counting nonclustered indexes.
- The report compares the **latest** snapshot to the snapshot **nearest** to `now − @HoursBack` — not strictly the oldest — so results stay meaningful even with irregular snapshot intervals.
- `MBPerHour` / `ProjectedDailyMB` are simple linear projections between two points, not a trend fit — treat them as a rough early-warning signal, not a forecast guarantee.
- All timestamps are stored in UTC (`SYSUTCDATETIME()`); use `@TimezoneOffsetHours` in Step 3 to view them in local time without changing what's stored.
- The dynamic SQL in Step 2 loops over databases by name; if a database name requires unusual quoting beyond `QUOTENAME`, review the generated `@sql` before relying on it in production.

## License

MIT
