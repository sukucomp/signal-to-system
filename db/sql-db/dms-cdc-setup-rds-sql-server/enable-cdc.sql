/* =============================================================================
   DMS + CDC Setup Script  (RDS SQL Server source for AWS DMS)

   Configuration:
     - Login name and target databases are defined once in the CONFIG section.
     - Tables to track are defined per-database in the @TableMap variable.
     - To skip a database, comment out its row in @TableMap and in @DBList.

   Environment login names:
     - Development : dev_dms
     - Staging     : stg_dms
     - Production  : prod_dms
     Set @LoginName in the CONFIG section to match the target environment.

   Prerequisites:
     - Server-level login already exists for the target environment.
       If not, create it with (substitute the correct login name and password):
         EXEC msdb.dbo.rds_sqlserver_create_login
              @login_name       = 'dev_dms',      -- or 'stg_dms' / 'prod_dms'
              @password         = '<strong-password>',
              @check_expiration = 0,
              @check_policy     = 1;

   Idempotency:
     - All CREATE USER, ALTER ROLE, GRANT, and CDC enable steps are guarded.
     - Safe to re-run; already-applied steps are skipped.
     - Also safe to re-run after an RDS restore (CDC state is not preserved
       across restores; permissions typically are).
   ============================================================================= */

SET NOCOUNT ON;

/* ============================================================================
   CONFIG -- edit here
   ============================================================================ */

-- Uncomment ONE line matching the target environment:
DECLARE @LoginName SYSNAME = N'dev_dms';   -- Development
-- DECLARE @LoginName SYSNAME = N'stg_dms'; -- Staging
-- DECLARE @LoginName SYSNAME = N'dms';     -- Production

-- Databases to configure. Comment out a row to skip that database.
DECLARE @DBList TABLE (db_name SYSNAME PRIMARY KEY);
INSERT INTO @DBList (db_name) VALUES
    (N'AppDB_Sales'),
    (N'AppDB_Customers'),
    (N'AppDB_Inventory'),
    (N'AppDB_Billing'),
    (N'AppDB_Support');

-- Tables to enable CDC on, per database. Comment out rows to skip.
DECLARE @TableMap TABLE (db_name SYSNAME, table_name SYSNAME);
INSERT INTO @TableMap (db_name, table_name) VALUES
    (N'AppDB_Customers',     N'Customer'),
    (N'AppDB_Customers',     N'CustomerName'),
    (N'AppDB_Customers',     N'CustomerIdentity'),
    (N'AppDB_Customers',     N'CustomerAddress'),
    (N'AppDB_Customers',     N'CustomerRelationship'),

    (N'AppDB_Sales',         N'Customer'),
    (N'AppDB_Sales',         N'CustomerIdentity'),
    (N'AppDB_Sales',         N'CustomerName'),
    (N'AppDB_Sales',         N'CustomerRegion'),
    (N'AppDB_Sales',         N'CustomerRelationship'),

    (N'AppDB_Inventory',     N'Customer'),
    (N'AppDB_Inventory',     N'CustomerIdentity'),
    (N'AppDB_Inventory',     N'CustomerName'),
    (N'AppDB_Inventory',     N'CustomerRegion'),
    (N'AppDB_Inventory',     N'CustomerRelationship'),

    (N'AppDB_Billing',       N'Customer'),
    (N'AppDB_Billing',       N'CustomerIdentity'),
    (N'AppDB_Billing',       N'CustomerName'),
    (N'AppDB_Billing',       N'CustomerRegion'),
    (N'AppDB_Billing',       N'CustomerRelationship'),

    (N'AppDB_Support',       N'Customer'),
    (N'AppDB_Support',       N'CustomerChangeTracking'),
    (N'AppDB_Support',       N'RelationshipChangeTracking');


/* ============================================================================
   STEP 1 -- Server-level permissions
   ============================================================================ */

DECLARE @sql NVARCHAR(MAX);

SET @sql = N'USE master; GRANT VIEW SERVER STATE TO ' + QUOTENAME(@LoginName) + N';';
EXEC sp_executesql @sql;
PRINT '[OK] GRANT VIEW SERVER STATE on master';


/* ============================================================================
   STEP 2 -- msdb user + backup history access
   On RDS, prefer role membership over direct grants on system tables.
   ============================================================================ */

SET @sql = N'
USE msdb;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ' + QUOTENAME(@LoginName, '''') + N')
    CREATE USER ' + QUOTENAME(@LoginName) + N' FOR LOGIN ' + QUOTENAME(@LoginName) + N';

IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ''rds_backup_operator'' AND type = ''R'')
    AND NOT EXISTS (
        SELECT 1
        FROM sys.database_role_members rm
        JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
        JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
        WHERE r.name = ''rds_backup_operator'' AND m.name = ' + QUOTENAME(@LoginName, '''') + N')
    ALTER ROLE rds_backup_operator ADD MEMBER ' + QUOTENAME(@LoginName) + N';

-- Fallback if rds_backup_operator is not present (non-RDS instances):
-- GRANT SELECT ON dbo.backupset         TO ' + QUOTENAME(@LoginName) + N';
-- GRANT SELECT ON dbo.backupmediafamily TO ' + QUOTENAME(@LoginName) + N';
-- GRANT SELECT ON dbo.backupfile        TO ' + QUOTENAME(@LoginName) + N';

GRANT EXEC ON dbo.rds_dms_tlog_download         TO ' + QUOTENAME(@LoginName) + N';
GRANT EXEC ON dbo.rds_dms_tlog_read             TO ' + QUOTENAME(@LoginName) + N';
GRANT EXEC ON dbo.rds_dms_tlog_list_current_lsn TO ' + QUOTENAME(@LoginName) + N';
GRANT EXEC ON dbo.rds_task_status               TO ' + QUOTENAME(@LoginName) + N';
';
EXEC sp_executesql @sql;
PRINT '[OK] msdb user, role, and EXEC grants';


/* ============================================================================
   STEP 3 -- Per-database user, db_owner membership, VIEW DEFINITION
   ============================================================================ */

DECLARE @DBName SYSNAME;
DECLARE db_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT db_name FROM @DBList;

OPEN db_cur;
FETCH NEXT FROM db_cur INTO @DBName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
USE ' + QUOTENAME(@DBName) + N';

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ' + QUOTENAME(@LoginName, '''') + N')
    CREATE USER ' + QUOTENAME(@LoginName) + N' FOR LOGIN ' + QUOTENAME(@LoginName) + N';

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members rm
    JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
    JOIN sys.database_principals m ON rm.member_principal_id = m.principal_id
    WHERE r.name = ''db_owner'' AND m.name = ' + QUOTENAME(@LoginName, '''') + N')
    ALTER ROLE [db_owner] ADD MEMBER ' + QUOTENAME(@LoginName) + N';

GRANT VIEW DEFINITION TO ' + QUOTENAME(@LoginName) + N';
';
        EXEC sp_executesql @sql;
        PRINT '[OK] DB user setup: ' + @DBName;
    END TRY
    BEGIN CATCH
        PRINT '[ERR] DB user setup failed for ' + @DBName + ': ' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM db_cur INTO @DBName;
END;

CLOSE db_cur;
DEALLOCATE db_cur;


/* ============================================================================
   STEP 4 -- Enable CDC at the database level
   ============================================================================ */

DECLARE db_cur2 CURSOR LOCAL FAST_FORWARD FOR
    SELECT l.db_name
    FROM @DBList l
    JOIN sys.databases d ON d.name = l.db_name
    WHERE d.is_cdc_enabled = 0
      AND d.state_desc = 'ONLINE';

OPEN db_cur2;
FETCH NEXT FROM db_cur2 INTO @DBName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC msdb.dbo.rds_cdc_enable_db @DBName;
        PRINT '[OK] CDC enabled on database: ' + @DBName;
    END TRY
    BEGIN CATCH
        PRINT '[ERR] rds_cdc_enable_db failed for ' + @DBName + ': ' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM db_cur2 INTO @DBName;
END;

CLOSE db_cur2;
DEALLOCATE db_cur2;


/* ============================================================================
   STEP 5 -- Enable CDC on tables (idempotent: skips already-enabled tables)
   ============================================================================ */

DECLARE @TblName SYSNAME;
DECLARE tbl_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT m.db_name, m.table_name
    FROM @TableMap m
    JOIN @DBList   l ON l.db_name = m.db_name
    JOIN sys.databases d ON d.name = m.db_name
    WHERE d.is_cdc_enabled = 1
      AND d.state_desc = 'ONLINE'
    ORDER BY m.db_name, m.table_name;

OPEN tbl_cur;
FETCH NEXT FROM tbl_cur INTO @DBName, @TblName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
USE ' + QUOTENAME(@DBName) + N';

IF EXISTS (
    SELECT 1
    FROM sys.tables t
    WHERE t.name = ' + QUOTENAME(@TblName, '''') + N'
      AND SCHEMA_NAME(t.schema_id) = ''dbo''
      AND OBJECTPROPERTY(t.object_id, ''TableHasPrimaryKey'') = 1
      AND NOT EXISTS (
          SELECT 1 FROM cdc.change_tables c WHERE c.source_object_id = t.object_id
      )
)
BEGIN
    EXEC sys.sp_cdc_enable_table
         @source_schema       = N''dbo'',
         @source_name         = ' + QUOTENAME(@TblName, '''') + N',
         @role_name           = NULL,
         @supports_net_changes = 1;
END
';
        EXEC sp_executesql @sql;
        PRINT '[OK] CDC table check: ' + @DBName + '.dbo.' + @TblName;
    END TRY
    BEGIN CATCH
        PRINT '[ERR] CDC enable failed for ' + @DBName + '.dbo.' + @TblName + ': ' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM tbl_cur INTO @DBName, @TblName;
END;

CLOSE tbl_cur;
DEALLOCATE tbl_cur;


/* ============================================================================
   STEP 6 -- Tune the CDC capture job for each CDC-enabled database
   ============================================================================ */

DECLARE db_cur3 CURSOR LOCAL FAST_FORWARD FOR
    SELECT l.db_name
    FROM @DBList l
    JOIN sys.databases d ON d.name = l.db_name
    WHERE d.is_cdc_enabled = 1
      AND d.state_desc = 'ONLINE';

OPEN db_cur3;
FETCH NEXT FROM db_cur3 INTO @DBName;

WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @sql = N'
USE ' + QUOTENAME(@DBName) + N';

EXEC sys.sp_cdc_stop_job  @job_type = N''capture'';

EXEC sys.sp_cdc_change_job
     @job_type        = N''capture'',
     @pollinginterval = 5,
     @maxtrans        = 500000,
     @maxscans        = 20;

EXEC sys.sp_cdc_start_job @job_type = N''capture'';
';
        EXEC sp_executesql @sql;
        PRINT '[OK] capture job tuned for ' + @DBName;
    END TRY
    BEGIN CATCH
        PRINT '[ERR] capture job tuning failed for ' + @DBName + ': ' + ERROR_MESSAGE();
    END CATCH;

    FETCH NEXT FROM db_cur3 INTO @DBName;
END;

CLOSE db_cur3;
DEALLOCATE db_cur3;

/* ============================================================================
   STEP 7 -- Verification (database-level + table-level in one result set)
   ============================================================================ */

PRINT '--- Database-level CDC status ---';
SELECT d.name AS database_name, d.is_cdc_enabled, d.state_desc
FROM sys.databases d
JOIN @DBList l ON l.db_name = d.name
ORDER BY d.name;

PRINT '--- Table-level CDC status (dynamic across enabled databases) ---';

DECLARE @verifySql NVARCHAR(MAX) = N'';

SELECT @verifySql = @verifySql +
    CASE WHEN @verifySql = N'' THEN N'' ELSE N'
UNION ALL
' END +
    N'SELECT ' + QUOTENAME(d.name, '''') + N' AS database_name,
       ' + CAST(d.is_cdc_enabled AS NVARCHAR(1)) + N' AS is_cdc_enabled,
       s.name AS schema_name, t.name AS table_name,
       t.is_tracked_by_cdc, c.capture_instance,
       c.supports_net_changes, c.index_name, c.create_date
FROM '   + QUOTENAME(d.name) + N'.sys.tables t
JOIN '   + QUOTENAME(d.name) + N'.sys.schemas s        ON t.schema_id = s.schema_id
JOIN '   + QUOTENAME(d.name) + N'.cdc.change_tables c  ON t.object_id = c.source_object_id'
FROM sys.databases d
JOIN @DBList l ON l.db_name = d.name
WHERE d.is_cdc_enabled = 1
  AND d.state_desc = 'ONLINE';

IF @verifySql = N''
    PRINT '(no databases in @DBList currently have CDC enabled)';
ELSE
BEGIN
    SET @verifySql = @verifySql + N'
ORDER BY database_name, schema_name, table_name;';
    EXEC sp_executesql @verifySql;
END;

PRINT '=== Done ===';
