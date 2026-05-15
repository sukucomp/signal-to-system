-- =====================================================================
-- RDS SQL Server - Table Growth Tracker
-- Top N growing tables per database, over any time window (last XX hours)
--
-- Author: <your name>
-- License: MIT
-- Tested on: AWS RDS for SQL Server (Standard Edition)
-- Requires: SQL Server Agent (Standard or Enterprise edition)
--
-- Usage:
--   STEP 1 - Run ONCE to create the tracking database and table
--   STEP 2 - Schedule this hourly via SQL Server Agent
--   STEP 3 - Run anytime to see top N growing tables in the last XX hours
--   STEP 4-7 - Optional health-check queries for the monitoring itself
--   STEP 8 - Optional retention cleanup
-- =====================================================================


-- =====================================================================
-- STEP 1: ONE-TIME SETUP - Create tracking DB & table
-- Run this ONCE
-- =====================================================================

USE master;
GO

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'DBA_Monitoring')
    CREATE DATABASE DBA_Monitoring;
GO

USE DBA_Monitoring;
GO

IF OBJECT_ID('dbo.TableSizeSnapshot', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.TableSizeSnapshot (
        SnapshotID      BIGINT IDENTITY(1,1) PRIMARY KEY,
        SnapshotTime    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        DatabaseName    SYSNAME NOT NULL,
        SchemaName      SYSNAME NOT NULL,
        TableName       SYSNAME NOT NULL,
        TotalRows       BIGINT NULL,
        TotalSpaceMB    DECIMAL(18,2) NULL,
        UsedSpaceMB     DECIMAL(18,2) NULL,
        INDEX IX_Snapshot_Time_DB NONCLUSTERED (SnapshotTime, DatabaseName)
    );
END
GO


-- =====================================================================
-- STEP 2: TAKE SNAPSHOT
-- Schedule this hourly via SQL Server Agent for best results.
-- Loops through all user databases on the instance.
-- =====================================================================

USE DBA_Monitoring;
GO

DECLARE @SnapTime DATETIME2 = SYSUTCDATETIME();
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql = @sql + N'
USE ' + QUOTENAME(name) + N';
INSERT INTO DBA_Monitoring.dbo.TableSizeSnapshot 
    (SnapshotTime, DatabaseName, SchemaName, TableName, TotalRows, TotalSpaceMB, UsedSpaceMB)
SELECT 
    ''' + CAST(@SnapTime AS NVARCHAR(30)) + ''',
    ''' + name + ''',
    s.name,
    t.name,
    SUM(p.rows),
    CAST(SUM(a.total_pages) * 8.0 / 1024 AS DECIMAL(18,2)),
    CAST(SUM(a.used_pages)  * 8.0 / 1024 AS DECIMAL(18,2))
FROM sys.tables t
INNER JOIN sys.schemas s          ON t.schema_id = s.schema_id
INNER JOIN sys.indexes i          ON t.object_id = i.object_id
INNER JOIN sys.partitions p       ON i.object_id = p.object_id AND i.index_id = p.index_id
INNER JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE t.is_ms_shipped = 0 
  AND i.index_id IN (0,1)  -- heap or clustered only; avoids double-counting nonclustered indexes
GROUP BY s.name, t.name;
'
FROM sys.databases
WHERE database_id > 4                                  -- skip system DBs
  AND state_desc = 'ONLINE'
  AND name NOT IN ('rdsadmin','DBA_Monitoring');       -- skip RDS internal + this DB itself

EXEC sp_executesql @sql;

PRINT 'Snapshot taken at ' + CONVERT(VARCHAR, @SnapTime, 120);
GO


-- =====================================================================
-- STEP 3: REPORT - Top N growing tables per DB in the LAST XX hours
-- 
-- Change @HoursBack to any window: 1, 6, 24, 168 (week), 720 (month)...
-- Change @TopN to control how many tables per DB you want to see.
-- Change @TimezoneOffsetHours to convert UTC timestamps to your local time.
-- =====================================================================

USE DBA_Monitoring;
GO

DECLARE @HoursBack            INT = 24;   -- <<< CHANGE THIS
DECLARE @TopN                 INT = 5;
DECLARE @TimezoneOffsetHours  INT = 0;    -- e.g. 8 for UTC+8, -5 for UTC-5, 0 to keep UTC

;WITH LatestSnap AS (
    SELECT DatabaseName, SchemaName, TableName, TotalRows, TotalSpaceMB, SnapshotTime,
           ROW_NUMBER() OVER (PARTITION BY DatabaseName, SchemaName, TableName 
                              ORDER BY SnapshotTime DESC) AS rn
    FROM dbo.TableSizeSnapshot
),
BaselineSnap AS (
    -- Pick the snapshot CLOSEST to (now - @HoursBack), not the oldest ever.
    -- ABS(DATEDIFF()) finds the snapshot nearest to the target time.
    SELECT DatabaseName, SchemaName, TableName, TotalRows, TotalSpaceMB, SnapshotTime,
           ROW_NUMBER() OVER (
               PARTITION BY DatabaseName, SchemaName, TableName 
               ORDER BY ABS(DATEDIFF(MINUTE, SnapshotTime, 
                                      DATEADD(HOUR, -@HoursBack, SYSUTCDATETIME())))
           ) AS rn
    FROM dbo.TableSizeSnapshot
),
Growth AS (
    SELECT 
        l.DatabaseName,
        l.SchemaName,
        l.TableName,
        DATEADD(HOUR, @TimezoneOffsetHours, b.SnapshotTime)        AS BaselineTimeLocal,
        DATEADD(HOUR, @TimezoneOffsetHours, l.SnapshotTime)        AS LatestTimeLocal,
        CAST(DATEDIFF(MINUTE, b.SnapshotTime, l.SnapshotTime) / 60.0 AS DECIMAL(8,2)) AS HoursElapsed,
        b.TotalSpaceMB                                            AS OldSizeMB,
        l.TotalSpaceMB                                            AS NewSizeMB,
        (l.TotalSpaceMB - b.TotalSpaceMB)                         AS GrowthMB,
        b.TotalRows                                               AS OldRows,
        l.TotalRows                                               AS NewRows,
        (l.TotalRows - b.TotalRows)                               AS RowsAdded,
        CASE WHEN b.TotalSpaceMB > 0
             THEN CAST(((l.TotalSpaceMB - b.TotalSpaceMB) / b.TotalSpaceMB) * 100 AS DECIMAL(10,2))
             ELSE NULL END                                        AS GrowthPct,
        CAST((l.TotalSpaceMB - b.TotalSpaceMB) 
             / NULLIF(DATEDIFF(MINUTE, b.SnapshotTime, l.SnapshotTime) / 60.0, 0) 
             AS DECIMAL(10,2))                                    AS MBPerHour
    FROM LatestSnap l
    INNER JOIN BaselineSnap b
        ON  b.DatabaseName = l.DatabaseName
        AND b.SchemaName   = l.SchemaName
        AND b.TableName    = l.TableName
        AND b.rn = 1
    WHERE l.rn = 1
      AND l.SnapshotTime <> b.SnapshotTime                        -- can't compare a snap to itself
      AND l.TotalSpaceMB > b.TotalSpaceMB                         -- only growing tables
),
Ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY DatabaseName ORDER BY GrowthMB DESC) AS RankInDB
    FROM Growth
)
SELECT 
    DatabaseName,
    SchemaName,
    TableName,
    OldSizeMB,
    NewSizeMB,
    GrowthMB,
    GrowthPct,
    MBPerHour,
    CAST(MBPerHour * 24 AS DECIMAL(10,2))   AS ProjectedDailyMB,
    RowsAdded,
    HoursElapsed,
    BaselineTimeLocal,
    LatestTimeLocal
FROM Ranked
WHERE RankInDB <= @TopN
ORDER BY DatabaseName, GrowthMB DESC;
GO


-- =====================================================================
-- STEP 4 (OPTIONAL): Storage used by the monitoring DB itself
-- Use this to verify the tracking overhead stays small.
-- =====================================================================

USE DBA_Monitoring;
GO

-- Size of the snapshot table specifically
SELECT 
    t.name                                                          AS TableName,
    p.rows                                                          AS [RowCount],
    CAST(SUM(a.total_pages) * 8.0 / 1024 AS DECIMAL(10,2))          AS TotalSpaceMB,
    CAST(SUM(a.used_pages)  * 8.0 / 1024 AS DECIMAL(10,2))          AS UsedSpaceMB,
    CAST(SUM(a.total_pages) * 8.0 / 1024 / 1024 AS DECIMAL(10,2))   AS TotalSpaceGB
FROM sys.tables t
INNER JOIN sys.indexes i      ON t.object_id = i.object_id
INNER JOIN sys.partitions p   ON i.object_id = p.object_id AND i.index_id = p.index_id
INNER JOIN sys.allocation_units a ON p.partition_id = a.container_id
WHERE t.name = 'TableSizeSnapshot'
GROUP BY t.name, p.rows;

-- Size of the entire DBA_Monitoring DB (data + log files)
SELECT 
    name                                                            AS LogicalName,
    type_desc                                                       AS FileType,
    CAST(size * 8.0 / 1024 AS DECIMAL(10,2))                        AS AllocatedMB,
    CAST(FILEPROPERTY(name,'SpaceUsed') * 8.0 / 1024 AS DECIMAL(10,2)) AS UsedMB
FROM sys.database_files;
GO


-- =====================================================================
-- STEP 5 (OPTIONAL): SQL Agent job execution history & duration
-- Replace job name to match your scheduled job.
-- =====================================================================

USE msdb;
GO

SELECT TOP 30
    j.name                                          AS JobName,
    h.run_date,
    h.run_time,
    -- Convert run_duration (HHMMSS as int) to readable seconds
    (h.run_duration / 10000) * 3600 
        + ((h.run_duration / 100) % 100) * 60 
        + (h.run_duration % 100)                    AS DurationSeconds,
    CASE h.run_status 
        WHEN 0 THEN 'Failed' 
        WHEN 1 THEN 'Succeeded' 
        WHEN 3 THEN 'Canceled' 
    END                                             AS Status
FROM msdb.dbo.sysjobs j
INNER JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id
WHERE j.name = 'DBA_TableSizeSnapshot'              -- <<< match your job name
  AND h.step_id = 0                                 -- 0 = overall job summary
ORDER BY h.run_date DESC, h.run_time DESC;
GO


-- =====================================================================
-- STEP 6 (OPTIONAL): Actual CPU / I/O used by the snapshot query
-- Survives until plan cache eviction; useful for catching regression.
-- =====================================================================

SELECT TOP 5
    qs.execution_count,
    qs.total_worker_time / 1000                      AS TotalCPUms,
    qs.total_worker_time / qs.execution_count / 1000 AS AvgCPUms,
    qs.total_elapsed_time / qs.execution_count / 1000 AS AvgElapsedMs,
    qs.total_logical_reads / qs.execution_count      AS AvgLogicalReads,
    SUBSTRING(st.text, qs.statement_start_offset/2 + 1,
        (CASE WHEN qs.statement_end_offset = -1 
              THEN LEN(CONVERT(NVARCHAR(MAX), st.text)) * 2
              ELSE qs.statement_end_offset
         END - qs.statement_start_offset) / 2)       AS QueryText
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
WHERE st.text LIKE '%TableSizeSnapshot%'
  AND st.text LIKE '%INSERT%'
ORDER BY qs.total_worker_time DESC;
GO


-- =====================================================================
-- STEP 7 (OPTIONAL): Total instance I/O per database since startup
-- Use to put DBA_Monitoring overhead in proportion to real workload.
-- =====================================================================

SELECT 
    DB_NAME(database_id)                            AS DatabaseName,
    SUM(num_of_reads)                               AS TotalReads,
    SUM(num_of_writes)                              AS TotalWrites,
    CAST(SUM(num_of_bytes_written) / 1024.0 / 1024 / 1024 AS DECIMAL(10,2)) AS TotalWrittenGB
FROM sys.dm_io_virtual_file_stats(NULL, NULL)
GROUP BY DB_NAME(database_id)
ORDER BY TotalWrittenGB DESC;
GO


-- =====================================================================
-- STEP 8 (OPTIONAL): Retention cleanup - keeps last 30 days
-- Run this manually, or schedule it as a weekly SQL Agent job.
-- =====================================================================

DELETE FROM DBA_Monitoring.dbo.TableSizeSnapshot
WHERE SnapshotTime < DATEADD(DAY, -30, SYSUTCDATETIME());
GO
