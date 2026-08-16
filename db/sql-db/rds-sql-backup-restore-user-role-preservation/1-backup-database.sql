/*==============================================================================
  01-backup-database.sql   (STEP 1 of 4)
  ------------------------------------------------------------------------------
  Native backup of a single database to S3 on Amazon RDS for SQL Server.

  Run this on the SOURCE instance to produce the .bak that STEP 3 restores from.
  If a suitable scheduled/daily backup already exists in S3, you can SKIP this
  step and restore from that existing file instead.

  Note on where each step runs:
    - STEP 1 (this script)  -> SOURCE instance (the DB you are copying FROM)
    - STEPS 2-4 (capture / restore / replay) -> TARGET instance (the DB you are
      copying INTO).

  Change ONLY the parameters in SECTION 0.
==============================================================================*/
SET NOCOUNT ON;
USE master;

/*==============================================================================
  SECTION 0 - PARAMETERS
==============================================================================*/
DECLARE @database_name sysname       = N'<db_name>';   -- DB to back up
DECLARE @env           nvarchar(10)  = N'<env>';       -- dev | stg | prod

-- Bucket that will hold the .bak. Replace with your own naming convention;
-- the two examples below show how you might split by workload/product line.
DECLARE @s3_bucket     nvarchar(200) = @env + N'-yourorg-db-backups';
-- DECLARE @s3_bucket  nvarchar(200) = @env + N'-yourorg-db-backups-alt';   -- alt

DECLARE @s3_prefix     nvarchar(200) = @database_name;                     -- folder in bucket
DECLARE @backup_file   nvarchar(200) = @database_name + N'.bak';           -- or _YYYYMMDD.bak
DECLARE @overwrite     bit           = 1;                                  -- overwrite if the S3 file exists

/*------------------------------------------------------------------------------
  Derived
------------------------------------------------------------------------------*/
DECLARE @s3_arn nvarchar(1000) =
        N'arn:aws:s3:::' + @s3_bucket + N'/' + @s3_prefix + N'/' + @backup_file;
PRINT '== Backup source : ' + @database_name;
PRINT '== S3 target     : ' + @s3_arn;

/*==============================================================================
  SECTION 1 - Start the native backup
==============================================================================*/
EXEC msdb.dbo.rds_backup_database
        @source_db_name           = @database_name,
        @s3_arn_to_backup_to      = @s3_arn,
        @overwrite_s3_backup_file = @overwrite;

/*==============================================================================
  SECTION 2 - Poll THIS backup's own task_id until it finishes
==============================================================================*/
DECLARE @taskid int = (
    SELECT TOP 1 task_id
    FROM   msdb.dbo.rds_fn_task_status(NULL, 0)
    WHERE  database_name = @database_name
      AND  task_type     = 'BACKUP_DB'
    ORDER BY task_id DESC);

DECLARE @state nvarchar(50), @waited int = 0;
WHILE (1 = 1)
BEGIN
    SET @state = (SELECT lifecycle FROM msdb.dbo.rds_fn_task_status(NULL, 0) WHERE task_id = @taskid);
    IF @state = 'SUCCESS' BREAK;
    IF @state = 'ERROR'
    BEGIN
        PRINT '!! Backup task reported ERROR - check msdb.dbo.rds_task_status.';
        BREAK;
    END
    WAITFOR DELAY '00:00:10';
    SET @waited += 10;
END

PRINT '== Backup task ' + CAST(@taskid AS varchar) + ' final state: ' + ISNULL(@state, 'UNKNOWN')
      + ' after ~' + CAST(@waited AS varchar) + 's';
IF @state = 'SUCCESS'
BEGIN
    PRINT '== BACKUP COMPLETE: ' + @s3_arn;
    PRINT '== Next: on the TARGET instance run STEP 2 (02_capture_user_mappings.sql), then STEP 3 (restore).';
END
GO
