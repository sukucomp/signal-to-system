/*==============================================================================
  04-replay-user-mappings.sql   (STEP 4 of 4)
  ------------------------------------------------------------------------------
  Recreate database users, role memberships and schema-level grants on the
  freshly restored database, reading from the durable store table populated by
  STEP 2.

  Each captured statement is idempotent and orphan-safe, so this script is
  SAFE TO RE-RUN (e.g. after a connection drop): it remaps users that already
  exist and creates those that do not, and never hard-fails on a missing
  login/role/schema.

  Change ONLY the parameters in SECTION 0.
==============================================================================*/
SET NOCOUNT ON;
USE master;

/*==============================================================================
  SECTION 0 - PARAMETERS
==============================================================================*/
DECLARE @database_name sysname = N'<db_name>';   -- the restored DB
DECLARE @ops_db        sysname = N'msdb';        -- where STEP 2 stored the capture

/*==============================================================================
  SECTION 1 - GUARDS: restored DB present, capture present
==============================================================================*/
IF DB_ID(@database_name) IS NULL
BEGIN
    RAISERROR('ABORT: database [%s] does not exist. Restore it (STEP 2) before replay.', 16, 1, @database_name);
    RETURN;
END
IF OBJECT_ID(QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay') IS NULL
BEGIN
    RAISERROR('ABORT: store table %s.dbo.RdsRestoreReplay does not exist. Run STEP 1 (01_capture) first.', 16, 1, @ops_db);
    RETURN;
END

DECLARE @cnt int;
DECLARE @gsql nvarchar(max) =
    N'SELECT @c = COUNT(*) FROM ' + QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay WHERE database_name = @dbn;';
EXEC sp_executesql @gsql, N'@dbn sysname, @c int OUTPUT', @dbn = @database_name, @c = @cnt OUTPUT;
IF @cnt = 0
BEGIN
    RAISERROR('ABORT: no capture found for [%s] in %s.dbo.RdsRestoreReplay.', 16, 1, @database_name, @ops_db);
    RETURN;
END
PRINT '== Replaying ' + CAST(@cnt AS varchar) + ' captured statement(s) for [' + @database_name + ']...';

/*==============================================================================
  SECTION 2 - Pull captured statements and apply
==============================================================================*/
CREATE TABLE #apply (id int, stmt nvarchar(max));
DECLARE @pull nvarchar(max) =
    N'INSERT INTO #apply (id, stmt)
      SELECT id, stmt FROM ' + QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay
      WHERE database_name = @dbn ORDER BY seq, id;';
EXEC sp_executesql @pull, N'@dbn sysname', @dbn = @database_name;

DECLARE @id int, @stmt nvarchar(max), @res nvarchar(400);
DECLARE @upd nvarchar(max) =
    N'UPDATE ' + QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay
      SET applied_at = SYSUTCDATETIME(), apply_result = @r WHERE id = @i;';

DECLARE apply_cur CURSOR LOCAL FAST_FORWARD FOR SELECT id, stmt FROM #apply ORDER BY id;
OPEN apply_cur;
FETCH NEXT FROM apply_cur INTO @id, @stmt;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        PRINT @stmt;
        EXEC (@stmt);
        SET @res = N'OK';
    END TRY
    BEGIN CATCH
        SET @res = LEFT(ERROR_MESSAGE(), 400);
        PRINT '   !! ' + @res;
    END CATCH
    EXEC sp_executesql @upd, N'@r nvarchar(400), @i int', @r = @res, @i = @id;
    FETCH NEXT FROM apply_cur INTO @id, @stmt;
END
CLOSE apply_cur;
DEALLOCATE apply_cur;
DROP TABLE #apply;

PRINT '== Replay complete.';

/*==============================================================================
  SECTION 3 - Verify: users, resolved logins, default schema, roles
==============================================================================*/
EXEC (N'USE ' + QUOTENAME(@database_name) + N';
SELECT dp.name AS db_user,
       sp.name AS server_login,
       dp.default_schema_name AS default_schema,
       STUFF((SELECT '', '' + r.name
              FROM sys.database_role_members l
              JOIN sys.database_principals r ON r.principal_id = l.role_principal_id
              WHERE l.member_principal_id = dp.principal_id
              FOR XML PATH('''')), 1, 2, '''') AS roles
FROM   sys.database_principals dp
LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE  dp.principal_id > 4
  AND  dp.type IN (''S'',''G'',''U'')
ORDER BY dp.name;');
GO
