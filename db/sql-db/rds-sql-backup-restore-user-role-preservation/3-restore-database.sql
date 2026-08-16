/*==============================================================================
  03-restore-database.sql   (STEP 3 of 4)
  ------------------------------------------------------------------------------
  Native S3 restore of a single database on Amazon RDS for SQL Server.

  SAFETY GUARD: this script ABORTS unless STEP 2 has stored a capture for
  @database_name in <ops_db>.dbo.RdsRestoreReplay. This guarantees the user /
  role mappings exist and are recoverable before the database is replaced.

  This script does NOT recreate users -- run STEP 4 (replay) after it succeeds.
  CDC: this script does NOT re-enable CDC on the restored DB (a separate script
  owns that). It DOES disable CDC on <db>_Old when the source had CDC enabled,
  because rds_drop_database fails otherwise.

  Change ONLY the parameters in SECTION 0.
==============================================================================*/
SET NOCOUNT ON;
USE master;
 
/*==============================================================================
  SECTION 0 - PARAMETERS
==============================================================================*/
DECLARE @database_name sysname       = N'<db_name>';            -- DB to restore
DECLARE @ops_db        sysname       = N'msdb';                 -- where STEP 2 stored the capture
DECLARE @env           nvarchar(10)  = N'<ev>';                 -- dev | stg | prod
 
-- Pick the bucket that holds this DB's .bak. Replace with your own naming
-- convention; the two examples below show how you might split by workload:
DECLARE @s3_bucket     nvarchar(200) = @env + N'-yourorg-db-backups';
-- DECLARE @s3_bucket  nvarchar(200) = @env + N'-yourorg-db-backups-alt';   -- alt
 
DECLARE @s3_prefix     nvarchar(200) = @database_name;                     -- folder in bucket
DECLARE @backup_file   nvarchar(200) = @database_name + N'.bak';           -- override for dated .bak
 
/*------------------------------------------------------------------------------
  Derived
------------------------------------------------------------------------------*/
DECLARE @old_name sysname        = @database_name + N'_Old';
DECLARE @s3_arn   nvarchar(1000) =
        N'arn:aws:s3:::' + @s3_bucket + N'/' + @s3_prefix + N'/' + @backup_file;
 
/*==============================================================================
  SECTION 1 - GUARD: refuse to restore without a stored capture
==============================================================================*/
IF OBJECT_ID(QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay') IS NULL
BEGIN
    RAISERROR('ABORT: store table %s.dbo.RdsRestoreReplay does not exist. Run STEP 1 (01_capture) first.',
              16, 1, @ops_db);
    RETURN;
END
 
DECLARE @cnt int;
DECLARE @gsql nvarchar(max) =
    N'SELECT @c = COUNT(*) FROM ' + QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay WHERE database_name = @dbn;';
EXEC sp_executesql @gsql, N'@dbn sysname, @c int OUTPUT', @dbn = @database_name, @c = @cnt OUTPUT;
 
IF @cnt = 0
BEGIN
    RAISERROR('ABORT: no capture found for [%s] in %s.dbo.RdsRestoreReplay. Run STEP 1 (01_capture) first.',
              16, 1, @database_name, @ops_db);
    RETURN;
END
PRINT '== Guard OK: ' + CAST(@cnt AS varchar) + ' captured statement(s) found for [' + @database_name + '].';
PRINT '== Restore target : ' + @database_name;
PRINT '== S3 source      : ' + @s3_arn;
 
/*==============================================================================
  SECTION 2 - RESTORE
==============================================================================*/
-- Detect CDC on the source DB so we can disable it on <db>_Old before the drop
-- (rds_drop_database fails if CDC is still enabled). This script does NOT
-- re-enable CDC on the restored DB -- that is handled by a separate script.
DECLARE @cdc_enabled bit = (SELECT is_cdc_enabled FROM sys.databases WHERE name = @database_name);
PRINT '== CDC enabled on source DB: ' + CASE WHEN @cdc_enabled = 1 THEN 'YES' ELSE 'NO' END;
 
-- Rename current DB out of the way
EXEC (N'ALTER DATABASE ' + QUOTENAME(@database_name) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;');
EXEC rdsadmin.dbo.rds_modify_db_name @database_name, @old_name;
 
-- Start the native restore
EXEC msdb.dbo.rds_restore_database
        @restore_db_name        = @database_name,
        @s3_arn_to_restore_from = @s3_arn;
 
-- Poll THIS restore's own task_id
DECLARE @taskid int = (
    SELECT TOP 1 task_id
    FROM   msdb.dbo.rds_fn_task_status(NULL, 0)
    WHERE  database_name = @database_name
      AND  task_type     = 'RESTORE_DB'
    ORDER BY task_id DESC);
 
DECLARE @state nvarchar(50), @waited int = 0;
WHILE (1 = 1)
BEGIN
    SET @state = (SELECT lifecycle FROM msdb.dbo.rds_fn_task_status(NULL, 0) WHERE task_id = @taskid);
    IF @state = 'SUCCESS' BREAK;
    IF @state = 'ERROR'
    BEGIN
        PRINT '!! Restore task reported ERROR.';
        BREAK;
    END
    WAITFOR DELAY '00:00:10';
    SET @waited += 10;
END
PRINT '== Restore task ' + CAST(@taskid AS varchar) + ' final state: ' + ISNULL(@state, 'UNKNOWN')
      + ' after ~' + CAST(@waited AS varchar) + 's';
 
/*==============================================================================
  SECTION 3 - Post-restore: disable CDC on old DB (if any), then drop it
  ------------------------------------------------------------------------------
  NOTE: CDC ENABLEMENT on the restored DB is out of scope -- handled by a
  separate script. This section only disables CDC on <db>_Old when the source
  had it enabled, because rds_drop_database fails if CDC is still on.
==============================================================================*/
IF @state = 'SUCCESS' AND DB_ID(@database_name) IS NOT NULL
BEGIN
    IF @cdc_enabled = 1
    BEGIN
        EXEC msdb.dbo.rds_cdc_disable_db @old_name;
        PRINT '== CDC disabled on ' + @old_name + ' (required before drop).';
    END
 
    EXEC msdb.dbo.rds_drop_database @old_name;
    PRINT '== Dropped ' + @old_name;
 
    PRINT '';
    PRINT '== RESTORE COMPLETE. Now run STEP 3 (03_replay_user_mappings.sql) to recreate users.';
    IF @cdc_enabled = 1
        PRINT '== Reminder: CDC was enabled on the source. Re-enable it via your CDC script.';
END
ELSE
BEGIN
    PRINT '!! Restore did not succeed. Rolling back rename ' + @old_name + ' -> ' + @database_name;
    IF DB_ID(@old_name) IS NOT NULL
    BEGIN
        EXEC (N'ALTER DATABASE ' + QUOTENAME(@old_name) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;');
        EXEC rdsadmin.dbo.rds_modify_db_name @old_name, @database_name;
        EXEC (N'ALTER DATABASE ' + QUOTENAME(@database_name) + N' SET MULTI_USER;');
        PRINT '== Original database restored to service. Capture in ' + @ops_db + ' is untouched.';
    END
    ELSE
        PRINT '!! ' + @old_name + ' not found - manual investigation required.';
END
GO
