# DMS + CDC Setup on RDS SQL Server

Setting up AWS Database Migration Service (DMS) against Amazon RDS SQL Server sources using Change Data Capture (CDC).

---

## Table of contents

- [What is CDC and why enable it?](#what-is-cdc-and-why-enable-it)
- [CDC is not persistent across RDS restores](#cdc-is-not-persistent-across-rds-restores)
- [Environment conventions](#environment-conventions)
- [Key concepts](#key-concepts)
- [Outstanding items](#outstanding-items)

---

## What is CDC and why enable it?

**Change Data Capture (CDC)** is a SQL Server feature that records every `INSERT`, `UPDATE`, and `DELETE` against tracked tables into a set of side tables (`cdc.<schema>_<table>_CT`), along with the log sequence number (LSN) and operation type for each row change. The capture happens asynchronously by reading the transaction log. The source tables and applications are not affected.

### Why enable it?

Software or data engineering teams typically request CDC for one of the following reasons:

- **Real-time or near-real-time replication.** They want row-level changes streamed out of the production database to another system — a data warehouse, a search index, a downstream microservice, another database — without heavy polling queries that would put load on the source.
- **Analytics and reporting pipelines.** ELT tools (DMS, Debezium, Fivetran, Airbyte, etc.) use CDC as the "ongoing changes" feed after an initial full-table load, so the downstream copy stays in sync.
- **Event-driven architectures.** Downstream consumers (Kafka topics, event buses) react to database changes as events — CDC provides an authoritative source for those events.
- **Audit and history.** Even without a downstream consumer, the CDC change tables themselves are a queryable history of changes for a configurable retention window (default 3 days).

### What privileges needed to enable CDC?

Enabling CDC requires elevated privileges (`db_owner` on each database), changes SQL Agent job configuration, and — for RDS — needs the RDS-specific wrapper procedures.

### What CDC costs?

- **Transaction log volume.** CDC is a "log reader" feature — it holds the transaction log until the capture job has processed it. Log backups still truncate normally, but if the capture job falls behind, the log grows.
- **Storage.** Change tables consume space proportional to change volume × retention window.
- **A small write amplification.** Each tracked change is also written to a change table by the capture job (background), and CDC adds columns and metadata behind the scenes.

For most OLTP workloads these costs are modest, but they're worth mentioning when the request comes in — especially the log growth implication if the capture job stops running.

---

## CDC is not persistent across RDS restores

**RDS automatically disables CDC when a database is restored from a backup** — including cross-account and cross-environment restores (e.g. restoring a prod backup into staging, or bringing a snapshot into another AWS account). This happens because RDS cannot preserve the LSN marker that CDC had reached in the source instance; without that marker, a new capture job on the restored database would either replay old changes or miss recent ones. RDS's safe default is to reset the state.

**Practical consequence:** every cross-account or cross-environment restore is followed by a CDC re-enablement. Both layers need to be re-applied from scratch:

- The database-level flag (`is_cdc_enabled` will show `0` after the restore).
- All table-level tracking (the `cdc` schema and change tables are gone).

The consolidated setup script (`enable-cdc.sql`) in this repo is designed exactly for this — re-running it after a restore is safe (idempotent) and re-establishes the full CDC state.

---

## Environment conventions

Login names differ per environment. Everywhere in this document, substitute the correct login name for your target environment:

| Environment | Login name |
|---|---|
| Development | `dev_dms` |
| Staging | `stg_dms` |
| Production | `prod_dms` |

The consolidated script has a single `@LoginName` variable in its CONFIG section — set it once per environment.

**Source databases in scope** (all environments): the `@DBList` / `@TableMap` variables at the top of the script — edit these to match your own database and table names. The sample values in the script are placeholders (`AppDB_Sales`, `AppDB_Customers`, etc.) meant to illustrate the shape of the config, not a real environment.

---

## Key concepts

### CDC layers

- **`is_cdc_enabled`** on `sys.databases` is the database-level flag (set by `rds_cdc_enable_db`).
- **`is_tracked_by_cdc`** on `sys.tables` is the table-level flag (set by `sp_cdc_enable_table`).

Both must be `1` for DMS to see changes from a table. **After an RDS restore, both will be `0`**.

---

## Outstanding items

**A DDL trigger can silently block database-level CDC enablement.** In one environment, `rds_cdc_enable_db` failed because a DDL trigger on security/identity events (firing on `CREATE_SCHEMA` and `CREATE_USER`, both of which `rds_cdc_enable_db` triggers internally) had a broken dependency on another database and rolled back the whole operation. The error surfaced as a generic failure from the RDS procedure, which is misleading — the actual cause was the trigger, not CDC itself.

**Mitigation:** identify any DDL triggers scoped to `CREATE_SCHEMA` / `CREATE_USER` (or broader security-event scopes) on the target database, briefly disable the trigger, enable CDC, then re-enable the trigger before re-running the rest of the setup script.

**Broader takeaway:** if your database has audit or compliance triggers on schema/security DDL events, check them *before* attempting `rds_cdc_enable_db` rather than after a failure — and treat the fix as something that needs to be reliable and repeatable, since any database that gets restored across environments will hit the same problem again.
