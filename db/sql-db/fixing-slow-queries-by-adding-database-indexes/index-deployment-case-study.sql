/*==============================================================================
  index-deployment-case-study.sql

  WHAT THIS IS
  ------------
  The exact SQL that was run to add two indexes to a production database
  (AWS RDS SQL Server) to fix repeated query slowdowns / CPU spikes.

  This file is a RECORD of a real change, with the database, table, and
  index names replaced by generic placeholders for public sharing. If you
  need to do something similar on a DIFFERENT database, read the README
  first, then copy this file and change the names by hand.

  HOW TO READ IT
  --------------
  The steps are numbered 1-6 and match the README.

  THE ONE RULE
  ------------
  Steps 1, 2, 4, 5 are SAFE to run anytime - they only READ information.
  Step 3 CHANGES the database and briefly blocks the tables - only run it in
  an approved time window. Step 6 removes the change (rollback).
==============================================================================*/


/*==============================================================================
  STEP 1 - How big are the tables? (safe - read only)
  ------------------------------------------------------------------------------
  This tells us roughly how long the change in Step 3 will take.
  It reads a summary counter, so it is instant and touches nothing.
==============================================================================*/
USE CoreDB;

SELECT
    OBJECT_NAME(p.object_id) AS table_name,
    SUM(p.rows)              AS row_count
FROM sys.partitions p
WHERE p.object_id IN (OBJECT_ID('dbo.Entity'), OBJECT_ID('dbo.EntityStatusHistory'))
  AND p.index_id IN (0, 1)
GROUP BY p.object_id;
-- Result when we ran it: Entity ~10M rows, EntityStatusHistory ~10M rows.
-- Both are small by SQL Server standards, so the change is quick (a few minutes).



/*==============================================================================
  STEP 2 - Do these indexes already exist? (safe - read only)
  ------------------------------------------------------------------------------
  Before adding anything, check the names are not already taken.
  IMPORTANT: the "current_db" column must say CoreDB. If it says something
  else, you are connected to the wrong database and the result is meaningless.
==============================================================================*/
USE CoreDB;

SELECT
    DB_NAME()                AS current_db,   -- must read: CoreDB
    OBJECT_NAME(object_id)   AS table_name,
    name                     AS index_name,
    type_desc,
    is_disabled
FROM sys.indexes
WHERE name IN ('ix_entity_type_secondary_id_type', 'ix_IsLatestStatus_SourceStatus');
-- Before the change: this returned NO rows (names were free). Good to proceed.
-- If it returns rows, STOP - the indexes already exist. Do not run Step 3.



/*==============================================================================
  STEP 3 - Add the two indexes  ***THIS CHANGES PRODUCTION***
  ------------------------------------------------------------------------------
  ONLY run this inside an approved time window.
  While each line runs, that table is briefly BLOCKED - no one else can read
  or write to it until it finishes (a few minutes at this table size).
  Run the two statements one after another, not at the same time.
==============================================================================*/
USE CoreDB;

CREATE INDEX ix_entity_type_secondary_id_type
ON Entity (entity_type, secondary_id_type);

CREATE INDEX ix_IsLatestStatus_SourceStatus
ON EntityStatusHistory (source_status)
INCLUDE (entity_guid)
WHERE is_latest_status = 1;



/*==============================================================================
  STEP 4 - Did it work? (safe - read only)
  ------------------------------------------------------------------------------
  Confirms both indexes now exist, are switched on (is_disabled = 0), and are
  built the way we intended (right columns and filter).
==============================================================================*/
USE CoreDB;

-- 4a. They exist and are on
SELECT
    DB_NAME()               AS current_db,
    OBJECT_NAME(object_id)  AS table_name,
    name                    AS index_name,
    type_desc,
    is_disabled              -- 0 means enabled / healthy
FROM sys.indexes
WHERE name IN ('ix_entity_type_secondary_id_type', 'ix_IsLatestStatus_SourceStatus');

-- 4b. They are built correctly (columns + filter match what we asked for)
SELECT
    OBJECT_NAME(i.object_id)                    AS table_name,
    i.name                                      AS index_name,
    i.type_desc,
    i.filter_definition,
    STRING_AGG(CASE WHEN ic.is_included_column = 0 THEN c.name END, ', ')
        WITHIN GROUP (ORDER BY ic.key_ordinal)  AS key_columns,
    STRING_AGG(CASE WHEN ic.is_included_column = 1 THEN c.name END, ', ')
        AS included_columns
FROM sys.indexes i
JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
JOIN sys.columns c        ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE i.name IN ('ix_entity_type_secondary_id_type', 'ix_IsLatestStatus_SourceStatus')
GROUP BY i.object_id, i.name, i.type_desc, i.filter_definition;
-- Expected:
--   ix_entity_type_secondary_id_type -> keys: entity_type, secondary_id_type | no filter | no include
--   ix_IsLatestStatus_SourceStatus   -> key: source_status | include: entity_guid | filter: is_latest_status = 1



/*==============================================================================
  STEP 5 - Is the database actually using the new indexes? (safe - read only)
  ------------------------------------------------------------------------------
  Run this a day or two later, after normal traffic. If the "seeks"/"scans"
  numbers are going up, the indexes are being used and doing their job.
  If they stay at 0, the indexes aren't helping.
==============================================================================*/
USE CoreDB;

SELECT
    OBJECT_NAME(s.object_id) AS table_name,
    i.name                   AS index_name,
    s.user_seeks,            -- going up = being used
    s.user_scans,
    s.user_lookups,
    s.last_user_seek,
    s.last_user_scan
FROM sys.dm_db_index_usage_stats s
JOIN sys.indexes i ON s.object_id = i.object_id AND s.index_id = i.index_id
WHERE i.name IN ('ix_entity_type_secondary_id_type', 'ix_IsLatestStatus_SourceStatus')
  AND s.database_id = DB_ID();



/*==============================================================================
  STEP 6 - Undo the change (rollback)  ***only if you need to back out***
  ------------------------------------------------------------------------------
  Removing an index is quick and safe - it deletes no data, it only removes
  the lookup shortcut. The lines are commented out so they don't run by
  accident. Remove the "--" to use them.
==============================================================================*/
USE CoreDB;
-- DROP INDEX ix_entity_type_secondary_id_type ON Entity;
-- DROP INDEX ix_IsLatestStatus_SourceStatus ON EntityStatusHistory;
