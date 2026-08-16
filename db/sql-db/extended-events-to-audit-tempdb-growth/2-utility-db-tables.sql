IF DB_ID('DBA_Utility') IS NULL
    CREATE DATABASE DBA_Utility;
GO
USE DBA_Utility;
GO

CREATE TABLE dbo.tempdb_session_snapshot
(
    snapshot_id       BIGINT IDENTITY(1,1) PRIMARY KEY,
    snapshot_time_utc DATETIME2(3)  NOT NULL,
    session_id        INT           NOT NULL,
    login_name        SYSNAME       NULL,
    host_name         NVARCHAR(128) NULL,
    program_name      NVARCHAR(256) NULL,
    request_id        INT           NULL,
    user_obj_mb       DECIMAL(18,2) NOT NULL,
    internal_obj_mb   DECIMAL(18,2) NOT NULL,
    total_mb          AS (user_obj_mb + internal_obj_mb) PERSISTED,
    command           NVARCHAR(64)  NULL,
    sql_text          NVARCHAR(MAX) NULL,
    INDEX ix_time (snapshot_time_utc)
);

CREATE TABLE dbo.tempdb_file_snapshot
(
    snapshot_time_utc  DATETIME2(3) PRIMARY KEY,
    free_mb            DECIMAL(18,2) NOT NULL,
    version_store_mb   DECIMAL(18,2) NOT NULL,
    user_object_mb     DECIMAL(18,2) NOT NULL,
    internal_object_mb DECIMAL(18,2) NOT NULL,
    mixed_extent_mb    DECIMAL(18,2) NOT NULL
);
GO
