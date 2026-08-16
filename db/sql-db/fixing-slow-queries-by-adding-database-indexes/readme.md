# Fixing Slow Queries by Adding Database Indexes

**What you'll get from this:**

A. a record of a real fix applied to a production database,

B. a plain guide to doing the same kind of fix safely, and

C. follow-up check some weeks later showing **only half of this fix is actually working**, with the other half waiting on an application-side change. Read section D.

---

## Introduction

Sometimes a database gets slow because it has no fast way to find the rows a query needs — like a book with no index, where you have to read every page to find one topic. The fix is often to **add an index**: a lookup shortcut that points straight to the right rows.

Adding an index is a low-risk change (it adds a shortcut, it doesn't touch your actual data). But two things matter and are easy to miss:
1. While the index is being built, that table is **briefly locked** — nothing else can read or write to it for those few minutes. Plan around this.
2. Adding an index **does not guarantee the database will use it.** An index can sit there, cost effort to maintain, and never get used — which is exactly what happened to one of the two indexes here (see section C/D).

---

## Jargon

- **Index** — a lookup shortcut that makes finding rows fast. What we add.
- **Table** — where the data lives (e.g. `Entity`).
- **Query** — a request for data. A slow query is what we're trying to fix.
- **Locked / blocking** — while an index builds, the table is frozen to everyone else for those few minutes.
- **Query plan** — the database's chosen strategy for running a query. The same query can get a fast plan or a slow plan.
- **Parameter sniffing** — the database picks a plan based on the first set of values it sees, then reuses it even when it's wrong for later values.

---

# Part A - What we changed on a production database?

### The problem
A data-matching pipeline suddenly slowed roughly 10× overnight and stayed slow for hours. The slowness came from a specific search query that had started choosing a bad, expensive plan.

### The fix we deployed
We added **two indexes** to give the affected queries a faster path:

| Index | Table | Intended to speed up |
|---|---|---|
| `ix_entity_type_secondary_id_type` | `Entity` | The main search filter (entity type) |
| `ix_IsLatestStatus_SourceStatus` | `EntityStatusHistory` | The "latest status" check inside the same query |

Both tables were ~10 million rows — small enough that each index built in a few minutes. We ran the change during an approved deployment window, added the indexes one at a time, and verified them. The exact SQL is in **`index-deployment-case-study.sql`**.

---

# Part B - Why this happened? And is it fixed?

**The indexes are not the whole fix.** They treat a symptom.

### What actually caused the slowdown
The real trigger was a **code deployment** that added a new filter column to the search query. That changed the query enough that the database recompiled it and it landed on a **bad plan through parameter sniffing** (it guessed a strategy based on unrepresentative sample values and then reused it). The slow plans ran roughly 8–13x slower than the normal case.

It recovered on its own some hours later when the database happened to recompile the query again and, that time, landed on a good plan.

### So the index alone doesn't remove the risk
Because the root cause is **parameter sniffing**, the same query could pick a bad plan again after any future recompile. An index gives the database a *better option*, but it doesn't stop it from occasionally *choosing badly*. Removing that risk needs a **plan-stability step** — pinning a known-good plan or forcing a recompile via Query Store hints.

---

# Part C - How to do this again on another database?

Use this if a database gets slow and someone has identified an index as the fix. Follow the steps in order.

> ### ⚠️ Before you start — is this really your job to do?
> Adding an index to production is a real change to a live system. Only proceed yourself if **all** of these are true:
> - Someone who knows the database (a DBA, or clear documentation) has said *which* index to add and *why*. **Deciding which index is needed — and whether an index is even the right fix — is a separate judgment call from running the script.**
> - You have an approved change ticket and are deploying during an approved window.
> - You can connect to the database in SSMS.

### The steps

1. **Check how big the table is.** This tells you roughly how long the build and the lock will last. Small tables build in minutes; very large tables take longer, meaning a longer lock.

2. **Check the index doesn't already exist.** Confirm you're connected to the *right* database.

3. **Add the index during an approved window.** This is the one step that changes production and briefly locks the table. If adding more than one, do them one at a time.

4. **Check it worked.** Confirm the index now exists, is switched on, and was built with the columns you intended.

5. **A day or two later, check it's actually being used.** This is the step that mattered most here. See section D for how to read the result. If the usage numbers stay at zero, the index isn't helping.

6. **Know how to undo it.** Removing an index is quick and safe (deletes no data). The rollback line is in the SQL file.

### Using the SQL file for a different database
`index-deployment-case-study.sql` is hardcoded to a sample database and table names (`CoreDB`, `Entity`, `EntityStatusHistory`). To reuse it elsewhere: **copy the file**, then replace the database name, table names, index names, and column names with your own. The *structure* of each step stays the same.

---

# Part D - The outcome

We ran the "is it being used?" check (Step 5) some weeks after deployment. The result was **split** — one index working, one not:

| Index | Seeks | Scans | Last used | Reading |
|---|---|---|---|---|
| `ix_IsLatestStatus_SourceStatus` | climbing | climbing | same day | **Working** — actively picked up by the optimizer |
| `ix_entity_type_secondary_id_type` | 0 | 0 | never (NULL) | **Not working** — never chosen by the optimizer |

### How to read this
- **`ix_IsLatestStatus_SourceStatus` — working.** Its read counters (seeks + scans) are climbing and it was used the same day it was checked. Doing its job.
- **`ix_entity_type_secondary_id_type` — not working.** All read counters are `0` and it has **never** been used (last-used is NULL). The only non-zero number was `user_updates`, in the low hundred-thousands — the cost of keeping the index up to date every time the table changes, with no offsetting read benefit.
