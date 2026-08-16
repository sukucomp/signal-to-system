# RDS SQL Server - Backup & Restore Runbook with User & Role Preservation

A four-step T-SQL runbook for backing up and restoring an **Amazon RDS for SQL
Server** database via native `.bak` files in S3 — **without losing database
users, role memberships, or schema-level grants** across the restore.

This runbook captures those mappings *before* the restore, into a 
**durable store table**, and re-applies them *after*, in an orphan-safe way.

The steps are **run separately**, by design, so an engineer can confirm the
capture exists and looks correct **before** the database is touched.

## Where each step runs?

- **Step 1 (backup)** runs on the **source** instance — the DB you are copying *from*.
- **Steps 2–4 (capture / restore / replay)** run on the **target** instance — the
  DB you are copying *into*.

If a suitable scheduled/daily backup already exists in S3, you
can **skip Step 1**.

## Why it's split?

The capture is written to a real table (`<ops_db>.dbo.RdsRestoreReplay`), not a
session table variable. That means:

- The capture **survives connection drops** and can be reviewed by anyone.
- **Step 3 (restore) refuses to run** unless a capture for the database exists.
- **Step 4 (replay) is safely re-runnable** after any interruption.

## The steps

| # | Script | What it does | Run as |
|---|--------|--------------|--------|
| 1 | `01-backup-database.sql` | Native-backs up the source DB to S3 and polls the backup's own `task_id` to completion. Skip if a suitable backup already exists. | On the source, first (optional) |
| 2 | `02-capture-user-mappings.sql` | Reads live users, role memberships and schema grants on the target; builds idempotent, orphan-safe replay statements; stores them in `<ops_db>.dbo.RdsRestoreReplay`. Sections 0–4 perform the capture; **Section 5 is a separate, read-only block** for reviewing/retrieving a stored capture. Re-running Sections 0–4 replaces that DB's prior capture. | Before restore |
| 3 | `03-restore-database.sql` | **Guards** on capture presence, then renames the live DB to `<db>_Old`, restores from S3, polls the restore's own `task_id`, and drops `<db>_Old` (disabling CDC on `<db>_Old` first if the source had it, so the drop succeeds). Does **not** recreate users and does **not** re-enable CDC on the restored DB. | After Step 2 verified |
| 4 | `04-replay-user-mappings.sql` | Reads the stored statements and applies them to the restored DB, recording `applied_at` / `apply_result` per row, then prints a verification listing. Safe to re-run. | After Step 3 succeeds |

## Usage

Each script has a **Section 0** parameter block — edit only that.

**Step 1 — backup** (on the source; skip if a backup already exists)
```sql
DECLARE @database_name sysname       = N'<db_name>';
DECLARE @env           nvarchar(10)  = N'<env>';
DECLARE @s3_bucket     nvarchar(200) = @env + N'-yourorg-db-backups';
--      @s3_bucket     alt           = @env + N'-yourorg-db-backups-alt';
DECLARE @s3_prefix     nvarchar(200) = @database_name;
DECLARE @backup_file   nvarchar(200) = @database_name + N'.bak';     -- or _YYYYMMDD.bak
DECLARE @overwrite     bit           = 1;
```

**Step 2 — capture** (on the target)
```sql
DECLARE @database_name sysname = N'<db_name>';
DECLARE @ops_db        sysname = N'msdb';   -- durable store; a DB that is NOT restored
```
Run it, then **review the printed grid** (produced by Section 5). Confirm the
expected users/roles are present and the count is non-zero before continuing.

> **Retrieving an existing capture (read-only).** `Section 5` at the bottom of
> `02_capture` is a separate batch. To view a capture taken earlier — for any
> database, including one captured by another engineer — **without** re-capturing,
> highlight from the `SECTION 5` banner to the end of the file, set its own
> `@database_name` / `@ops_db`, and run just that selection. It only reads the
> store table; it never touches the live database or modifies the store. An
> optional (commented) query in that block lists every database currently held in
> the store, with statement counts and capture/apply timestamps.

**Step 3 — restore** (on the target)
```sql
DECLARE @database_name sysname       = N'<db_name>';
DECLARE @ops_db        sysname       = N'msdb';
DECLARE @env           nvarchar(10)  = N'<env>';                       -- dev | stg | prod
DECLARE @s3_bucket     nvarchar(200) = @env + N'-yourorg-db-backups';
--      @s3_bucket     alt           = @env + N'-yourorg-db-backups-alt';
DECLARE @s3_prefix     nvarchar(200) = @database_name;
DECLARE @backup_file   nvarchar(200) = @database_name + N'.bak';     -- or _YYYYMMDD.bak
```
ARN assembled as `arn:aws:s3:::{@s3_bucket}/{@s3_prefix}/{@backup_file}`.
If no capture exists for the database, the script **aborts** before making any
change. On restore failure it rolls the rename back automatically.

**Step 4 — replay** (on the target)
```sql
DECLARE @database_name sysname = N'<db_name>';
DECLARE @ops_db        sysname = N'msdb';
```
Run after Step 3 prints `RESTORE COMPLETE`. Review the verification grid.

## The three variables you normally change

For a typical restore you only touch three things at the top of the scripts:

1. **`@database_name`** — the DB name.
2. **`@env`** — `dev` / `stg` / `prod`.
3. **`@s3_bucket`** — pick the backup source bucket for your naming convention
   (the scripts show two examples to illustrate splitting by workload/product line —
   replace both with your own bucket names).

`@ops_db` defaults to `msdb` and usually needs no change.

## Requirements

- RDS SQL Server with the **native backup/restore option group** and S3
  integration enabled.
- Connected as the **RDS master user**, with rights to the `rdsadmin` / `msdb`
  backup/restore procedures, to create the store table in `@ops_db`, and to alter
  database principals.
- **Server logins must already exist** on the target instance. This runbook
  recreates *database users* and their mappings, not server logins. A user whose
  login is missing is skipped and logged as
  `SKIP user (server login missing): <login>`.

## The store table

`02_capture` creates it if absent:

```
<ops_db>.dbo.RdsRestoreReplay
  ( id, database_name, seq, stmt, captured_at, applied_at, apply_result )
```

It is a **shared, persistent table**, keyed by `database_name` — captures for
different databases coexist, and Section 5 / Step 3 / Step 4 all filter by the
database name you set. Rows carry no per-engineer tag; re-capturing a database
replaces that database's rows (the Section 4 `DELETE ... WHERE database_name = @dbn`),
so "the capture for a DB" is always the most recent one anyone stored. Check
`captured_at` for freshness.

`@ops_db` defaults to `msdb` for zero setup. If your standards discourage user
objects in `msdb`, point `@ops_db` at a small dedicated ops/admin database — it
just must **not** be the database being restored. All target-side steps must use
the **same** `@ops_db`.

## CDC

**CDC enablement is out of scope in this runbook** — enabling CDC on the restored
database is managed by a separate script (see the DMS + CDC setup project, if
you're pairing this runbook with a CDC-based replication pipeline). Step 3 does
**not** re-enable CDC.

Step 3 **does** handle one CDC concern automatically: if the source database had
CDC enabled, it disables CDC on `<db>_Old` before dropping it, because on RDS
`rds_drop_database` fails while CDC is still enabled. It then prints a reminder
that CDC needs to be re-enabled on the restored DB via your CDC script. For
databases without CDC, none of this applies.

## Important notes

- **Orphan-safe replay.** Each user statement remaps an existing (orphaned) user
  with `ALTER USER ... WITH LOGIN`, or creates it with `CREATE USER ... FOR LOGIN`
  if absent. Role adds use `ALTER ROLE ... ADD MEMBER` and only fire when the
  role and member exist and the membership isn't already present.
- **Task-scoped polling.** The backup and restore wait loops each target their
  own `task_id`, so a concurrent scheduled task won't fool them. Running away from
  backup windows is still good hygiene.
- **Permission scope.** Capture covers user→login mappings, default schemas, role
  memberships, and **schema-level (`class = 3`)** grants. It does **not** capture
  object-level (`class = 1`) or database-level (`class = 0`) permissions,
  contained users, or certificate/key users. Extend Sections 2–3 of `02_capture`
  if your database depends on those.
- **Excluded accounts.** System, service, `sa`, and known managed/admin accounts
  are excluded from recreation by design (see the placeholder names in
  `02_capture` Section 2 — `your_replication_admin`, `your_stg_admin`, etc. —
  and the `NT AUTHORITY` / `NT SERVICE` / `##…##` patterns). Adjust the exclusion
  list to match your own environment's service and admin accounts.

## A note on this repo

The scripts contain no credentials and no hard-coded principal names — user and
role names are read from the live instance at runtime. Bucket patterns and
environment identifiers are examples only.
