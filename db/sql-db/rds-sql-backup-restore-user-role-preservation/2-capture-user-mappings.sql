/*==============================================================================
  02-capture-user-mappings.sql   (STEP 2 of 4)
  ------------------------------------------------------------------------------
  Capture the current database users, role memberships and schema-level grants
  for a database that is about to be restored on Amazon RDS for SQL Server,
  and persist them to a DURABLE store table in a database that is NOT being
  restored (default: msdb).

  Because the capture is written to a real table -- not a session table variable
  -- it survives connection drops and can be inspected by any engineer before
  the restore proceeds. STEP 3 (restore) refuses to run unless this capture
  exists.

  Re-running this script for the same @database_name replaces its prior capture.

  Change ONLY the parameters in SECTION 0. If your instance has its own set of
  service/admin accounts that should never be recreated by this script, add
  them to the exclusion list in SECTION 2.

  NOTE: SECTION 5 at the bottom is a SEPARATE, READ-ONLY batch. Highlight and run
  it on its own to VIEW a previously-stored capture (for any database, including
  one captured by another engineer) WITHOUT re-capturing. Running the full file
  top-to-bottom performs the capture (Sections 0-4) and then displays it
  (Section 5).
==============================================================================*/
SET NOCOUNT ON;
USE master;
 
/*==============================================================================
  SECTION 0 - PARAMETERS
==============================================================================*/
DECLARE @database_name sysname = N'<db_name>';            -- DB to be restored
DECLARE @ops_db        sysname = N'msdb';                 -- durable store location
                                                          -- (a DB that is NOT restored)
 
/*==============================================================================
  SECTION 1 - Ensure the durable store table exists
==============================================================================*/
DECLARE @ddl nvarchar(max) = N'
IF OBJECT_ID(''' + QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay'') IS NULL
CREATE TABLE ' + QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay (
    id            int IDENTITY(1,1) PRIMARY KEY,
    database_name sysname       NOT NULL,
    seq           int           NOT NULL,   -- 1=user  2=role member  3=schema grant
    stmt          nvarchar(max) NOT NULL,
    captured_at   datetime2(0)  NOT NULL CONSTRAINT DF_RdsRestoreReplay_cap DEFAULT SYSUTCDATETIME(),
    applied_at    datetime2(0)  NULL,
    apply_result  nvarchar(400) NULL
);';
EXEC (@ddl);
 
/*==============================================================================
  SECTION 2 - Read live principals (against the DB being restored)
==============================================================================*/
CREATE TABLE #users (usr sysname, lgn sysname, schm sysname);
CREATE TABLE #roles (rolename sysname, membername sysname);
CREATE TABLE #perms (perm sysname, schm sysname, grantee sysname);
CREATE TABLE #replay (seq int, stmt nvarchar(max));
 
INSERT INTO #users (usr, lgn, schm)
EXEC (N'USE ' + QUOTENAME(@database_name) + N';
SELECT dp.name, sp.name, dp.default_schema_name
FROM   sys.database_principals dp
JOIN   sys.server_principals   sp ON dp.sid = sp.sid
WHERE  dp.type IN (''S'',''G'',''U'')
  AND  dp.name NOT LIKE ''##%##''
  AND  dp.name NOT LIKE ''NT AUTHORITY%''
  AND  dp.name NOT LIKE ''NT SERVICE%''
  AND  dp.name NOT IN (''sa'',''your_replication_admin'',''your_stg_admin'',''your_dev_admin'')  -- adjust to your own excluded accounts
  AND  dp.default_schema_name IS NOT NULL
  AND  dp.principal_id > 4;');
 
INSERT INTO #roles (rolename, membername)
EXEC (N'USE ' + QUOTENAME(@database_name) + N';
SELECT r.name, u.name
FROM   sys.database_role_members l
JOIN   sys.database_principals   r  ON r.principal_id = l.role_principal_id
JOIN   sys.database_principals   u  ON u.principal_id = l.member_principal_id
JOIN   sys.server_principals     sp ON u.sid = sp.sid
WHERE  u.principal_id > 4;');
 
INSERT INTO #perms (perm, schm, grantee)
EXEC (N'USE ' + QUOTENAME(@database_name) + N';
SELECT dp.permission_name, s.name, gr.name
FROM   sys.database_permissions dp
JOIN   sys.database_principals  dpin ON dp.grantee_principal_id = dpin.principal_id
JOIN   sys.server_principals    gr   ON dpin.sid = gr.sid
JOIN   sys.schemas              s    ON dp.major_id = s.schema_id
WHERE  dp.class = 3;');
 
/*==============================================================================
  SECTION 3 - Build idempotent, orphan-safe replay statements
==============================================================================*/
-- seq 1: users - remap orphan if present, else create; skip if login missing
INSERT INTO #replay (seq, stmt)
SELECT 1,
  N'USE ' + QUOTENAME(@database_name) + N'; '
+ N'IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = ' + QUOTENAME(lgn, '''') + N') '
+ N'BEGIN '
+   N'IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ' + QUOTENAME(usr, '''') + N') '
+     N'ALTER USER ' + QUOTENAME(usr) + N' WITH LOGIN = ' + QUOTENAME(lgn)
        + N', DEFAULT_SCHEMA = ' + QUOTENAME(schm) + N'; '
+   N'ELSE '
+     N'CREATE USER ' + QUOTENAME(usr) + N' FOR LOGIN ' + QUOTENAME(lgn)
        + N' WITH DEFAULT_SCHEMA = ' + QUOTENAME(schm) + N'; '
+ N'END '
+ N'ELSE PRINT ' + QUOTENAME(N'SKIP user (server login missing): ' + lgn, '''') + N';'
FROM #users;
 
-- seq 2: role memberships - add only if role + user exist and not already a member
INSERT INTO #replay (seq, stmt)
SELECT 2,
  N'USE ' + QUOTENAME(@database_name) + N'; '
+ N'IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ' + QUOTENAME(rolename, '''') + N' AND type = ''R'') '
+ N'AND EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ' + QUOTENAME(membername, '''') + N') '
+ N'AND IS_ROLEMEMBER(' + QUOTENAME(rolename, '''') + N', ' + QUOTENAME(membername, '''') + N') = 0 '
+ N'ALTER ROLE ' + QUOTENAME(rolename) + N' ADD MEMBER ' + QUOTENAME(membername) + N';'
FROM #roles;
 
-- seq 3: schema-level grants - re-grant only if grantee exists
INSERT INTO #replay (seq, stmt)
SELECT 3,
  N'USE ' + QUOTENAME(@database_name) + N'; '
+ N'IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ' + QUOTENAME(grantee, '''') + N') '
+ N'GRANT ' + perm + N' ON SCHEMA::' + QUOTENAME(schm) + N' TO ' + QUOTENAME(grantee) + N';'
FROM #perms;
 
/*==============================================================================
  SECTION 4 - Persist to the durable store (replaces any prior capture)
==============================================================================*/
DECLARE @persist nvarchar(max) = N'
DELETE FROM ' + QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay WHERE database_name = @dbn;
INSERT INTO ' + QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay (database_name, seq, stmt)
SELECT @dbn, seq, stmt FROM #replay;';
EXEC sp_executesql @persist, N'@dbn sysname', @dbn = @database_name;
 
DROP TABLE #users, #roles, #perms, #replay;
 
PRINT '== Capture persisted for [' + @database_name + '] into '
      + @ops_db + '.dbo.RdsRestoreReplay.';
PRINT '== Run SECTION 5 below to review it before STEP 2 (restore).';
GO
 
/*==============================================================================
  SECTION 5 - RETRIEVE / VERIFY a stored capture      *** READ-ONLY ***
  ------------------------------------------------------------------------------
  SAFE TO RUN ON ITS OWN. This is a separate batch: highlight from this banner
  down to the end of the file and execute it to VIEW a previously-stored capture
  WITHOUT re-capturing anything. It only READS the store table -- it never
  touches the live database and never modifies the store.
 
  Use this to inspect a capture taken earlier (e.g. by another engineer): set
  @database_name to that DB and @ops_db to the store location.
==============================================================================*/
DECLARE @database_name sysname = N'<db_name>';            -- DB whose capture to view
DECLARE @ops_db        sysname = N'msdb';                 -- store location
 
IF OBJECT_ID(QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay') IS NULL
BEGIN
    PRINT '!! Store table ' + @ops_db + '.dbo.RdsRestoreReplay does not exist in this @ops_db.';
    RETURN;
END
 
DECLARE @cnt int;
DECLARE @vsql nvarchar(max) =
    N'SELECT @c = COUNT(*) FROM ' + QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay WHERE database_name = @dbn;';
EXEC sp_executesql @vsql, N'@dbn sysname, @c int OUTPUT', @dbn = @database_name, @c = @cnt OUTPUT;
 
PRINT '== [' + @database_name + '] has ' + CAST(@cnt AS varchar)
      + ' stored statement(s) in ' + @ops_db + '.dbo.RdsRestoreReplay.';
IF @cnt = 0
    PRINT '!! No capture found for this database name in this store. Check spelling/case and @ops_db.';
 
-- Stored capture for the chosen database (includes replay status columns)
EXEC (N'SELECT seq, stmt, captured_at, applied_at, apply_result
        FROM ' + QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay
        WHERE database_name = ' + QUOTENAME(@database_name, '''') + N'
        ORDER BY seq, id;');
 
-- Optional: uncomment to list every database currently held in the store
-- EXEC (N'SELECT database_name, COUNT(*) AS stmts, MIN(captured_at) AS captured_at,
--                MAX(applied_at) AS last_applied
--         FROM ' + QUOTENAME(@ops_db) + N'.dbo.RdsRestoreReplay
--         GROUP BY database_name ORDER BY database_name;');
GO
