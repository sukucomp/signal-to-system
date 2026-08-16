CREATE EVENT SESSION [tempdb_autogrowth_audit] ON SERVER
ADD EVENT sqlserver.database_file_size_change
(
    ACTION (
        sqlserver.session_id,
        sqlserver.client_hostname,
        sqlserver.client_app_name,
        sqlserver.server_principal_name,
        sqlserver.database_name,
        sqlserver.sql_text,
        sqlserver.query_hash,
        sqlserver.plan_handle
    )
    WHERE (
        [database_id] = 2          -- tempdb is always DB_ID 2
        AND [size_change_kb] > 0   -- growth only, excludes shrink
    )
)
ADD TARGET package0.event_file
(
    SET filename        = N'D:\rdsdbdata\log\tempdb_autogrowth_audit.xel',
        max_file_size   = 50,      -- MB per rollover file
        max_rollover_files = 10
)
WITH (
    MAX_MEMORY            = 4096 KB,
    EVENT_RETENTION_MODE  = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY  = 30 SECONDS,
    MEMORY_PARTITION_MODE = NONE,     -- required on RDS
    STARTUP_STATE         = ON        -- persists across restart
);
GO

ALTER EVENT SESSION [tempdb_autogrowth_audit] ON SERVER STATE = START;
