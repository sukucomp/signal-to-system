/**********************************************************************************************
  6-investigation.sql   (tempdb autogrowth attribution)
  ------------------------------------------------------------------------------------------
  WHEN TO USE : tempdb has grown and you want to know which query / who caused it.

  >>> IF YOU JUST WANT THE ANSWER: run SECTION 1, then SECTION 2, in the SAME query window.
  >>> SECTION 2 is a ranked table you can paste straight into an update to your lead.

  SECTION 3 is optional depth (what was HOLDING tempdb at the moment it grew).
  SECTION 4 is a DEV-ONLY test harness. NEVER run it on production.

  RUN AS  : RDS master user.  Sections 1-3 are READ-ONLY and safe on prod.
  RDS NOTE: .xel files live in D:\rdsdbdata\log — the only writable XE path on RDS. Keep it.
  See README.md for how to read the output and the attribution caveats.
**********************************************************************************************/


/*==========================================================================================
  SECTION 1 - Shred the XE file into #grows  (run this first; READ-ONLY)
  One row per autogrowth event, with the statement + identity captured at that moment.
==========================================================================================*/
IF OBJECT_ID('tempdb..#grows') IS NOT NULL DROP TABLE #grows;

WITH raw AS (
    SELECT CAST(event_data AS XML) AS event_data
    FROM sys.fn_xe_file_target_read_file(
             'd:\rdsdbdata\log\tempdb_autogrowth_audit*.xel', NULL, NULL, NULL)
)
SELECT
    ev.value('(@timestamp)[1]','datetime2')                                       AS grow_time_utc,   -- UTC
    ev.value('(data[@name="size_change_kb"]/value)[1]','bigint')/1024.0           AS grow_mb,         -- MB this file grew
    ev.value('(action[@name="server_principal_name"]/value)[1]','nvarchar(256)')  AS login_name,      -- person OR service account
    ev.value('(action[@name="client_hostname"]/value)[1]','nvarchar(256)')        AS host_name,       -- origin machine
    ev.value('(action[@name="client_app_name"]/value)[1]','nvarchar(256)')        AS app_name,        -- SSMS / EF Core / .Net SqlClient
    ev.value('(action[@name="database_name"]/value)[1]','sysname')                AS database_name,   -- DB the query ran in (which Query Store to check)
    ev.value('(action[@name="session_id"]/value)[1]','int')                       AS session_id,
    ev.value('(action[@name="query_hash"]/value)[1]','nvarchar(64)')              AS query_hash,      -- groups identical query SHAPES
    ev.value('(action[@name="sql_text"]/value)[1]','nvarchar(max)')               AS trigger_sql      -- statement that tripped the grow
INTO #grows
FROM raw
CROSS APPLY raw.event_data.nodes('/event') AS x(ev);

-- sanity: how many events, over what window
SELECT COUNT(*) AS grow_events_loaded, MIN(grow_time_utc) AS earliest_utc, MAX(grow_time_utc) AS latest_utc
FROM #grows;


/*==========================================================================================
  SECTION 2 - OFFENDER RANKING   *** THIS IS THE ANSWER ***   (READ-ONLY)
  Same rows collapsed by identity + query_hash, ranked by total MB grown.
  Top rows = the query shapes that caused the most tempdb growth = fix these first.
==========================================================================================*/
SELECT
    login_name,
    host_name,
    app_name,
    query_hash,
    COUNT(*)           AS grow_events,      -- how many autogrows this pattern triggered
    SUM(grow_mb)       AS total_mb_grown,   -- total tempdb it forced (RANK ON THIS)
    MIN(grow_time_utc) AS first_seen_utc,
    MAX(grow_time_utc) AS last_seen_utc,
    MAX(trigger_sql)   AS sample_sql        -- representative statement for this hash
FROM #grows
GROUP BY login_name, host_name, app_name, query_hash
ORDER BY total_mb_grown DESC, grow_events DESC;


/*==========================================================================================
  SECTION 3 (OPTIONAL DEPTH) - What was HOLDING tempdb when it grew.
  Joins each grow to the nearest snapshot at/before it (version store vs. user obj vs. spills)
  and names the top sessions holding >=10 MB. NULL holder columns just mean the capture job
  wasn't running before that grow yet - expected, not a fault.  READ-ONLY.
==========================================================================================*/
SELECT
    g.grow_time_utc, g.grow_mb, g.login_name, g.host_name, g.app_name, g.database_name, g.query_hash,
    fs.version_store_mb, fs.user_object_mb, fs.internal_object_mb,   -- spills land in internal_object_mb
    holder.session_id  AS holder_session,
    holder.login_name  AS holder_login,
    holder.total_mb    AS holder_tempdb_mb,
    holder.sql_text    AS holder_sql
FROM #grows g
OUTER APPLY (
    SELECT TOP (1) *
    FROM DBA_Utility.dbo.tempdb_file_snapshot f
    WHERE f.snapshot_time_utc <= g.grow_time_utc
    ORDER BY f.snapshot_time_utc DESC
) fs
OUTER APPLY (
    SELECT TOP (3) s.*
    FROM DBA_Utility.dbo.tempdb_session_snapshot s
    WHERE s.snapshot_time_utc = fs.snapshot_time_utc
    ORDER BY s.total_mb DESC
) holder
ORDER BY g.grow_time_utc DESC, holder.total_mb DESC;


/*==========================================================================================
  SECTION 4 - DEV-ONLY test harness.  *** DO NOT RUN ON PRODUCTION ***
  Forces a tempdb autogrowth to validate the pipeline end to end. Shrinks a tempdb file to
  remove free headroom first (else a small spill won't trigger a grow), then spills.
==========================================================================================*/
/*
USE tempdb;
DBCC SHRINKFILE (tempdev, 20);

SELECT TOP (5000000) a.number, b.number AS b_number, NEWID() AS filler, REPLICATE('x', 200) AS pad
INTO #spill
FROM master.dbo.spt_values a CROSS JOIN master.dbo.spt_values b
ORDER BY NEWID();
DROP TABLE #spill;

ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev, SIZE = 200MB);   -- reset (restart also resets)
*/
