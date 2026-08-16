USE DBA_Utility;
GO
/*  Snapshots tempdb HOLDERS once per run (driven every minute by the Agent job).
    IMPORTANT: sys.dm_db_file_space_usage and sys.dm_db_session_space_usage are
    DATABASE-SCOPED. They must be read with the three-part name tempdb.sys.* so they
    report tempdb regardless of the proc's own (DBA_Utility) context. Do NOT change
    these back to sys.dm_db_*_space_usage WHERE database_id = 2 — that returns no rows
    from inside DBA_Utility and the insert fails with a NULL error. The ISNULL guards
    are a second line of defence against the same failure.  */
CREATE OR ALTER PROCEDURE dbo.usp_capture_tempdb_snapshot
    @min_session_mb DECIMAL(18,2) = 10   -- ignore trivial sessions to keep the table small
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME();

    -- Category breakdown across all tempdb files (the "what")
    INSERT INTO dbo.tempdb_file_snapshot
        (snapshot_time_utc, free_mb, version_store_mb, user_object_mb, internal_object_mb, mixed_extent_mb)
    SELECT
        @now,
        ISNULL(SUM(unallocated_extent_page_count),      0) * 8 / 1024.0,
        ISNULL(SUM(version_store_reserved_page_count),  0) * 8 / 1024.0,
        ISNULL(SUM(user_object_reserved_page_count),    0) * 8 / 1024.0,
        ISNULL(SUM(internal_object_reserved_page_count),0) * 8 / 1024.0,
        ISNULL(SUM(mixed_extent_page_count),            0) * 8 / 1024.0
    FROM tempdb.sys.dm_db_file_space_usage;          -- three-part name pins tempdb

    -- Per-session tempdb holders (the "who")
    INSERT INTO dbo.tempdb_session_snapshot
        (snapshot_time_utc, session_id, login_name, host_name, program_name,
         request_id, user_obj_mb, internal_obj_mb, command, sql_text)
    SELECT
        @now,
        ssu.session_id,
        es.login_name,
        es.host_name,
        es.program_name,
        er.request_id,
        (ssu.user_objects_alloc_page_count     - ssu.user_objects_dealloc_page_count)     * 8 / 1024.0,
        (ssu.internal_objects_alloc_page_count - ssu.internal_objects_dealloc_page_count) * 8 / 1024.0,
        er.command,
        st.text
    FROM tempdb.sys.dm_db_session_space_usage ssu    -- three-part name pins tempdb
    JOIN sys.dm_exec_sessions  es ON es.session_id = ssu.session_id
    LEFT JOIN sys.dm_exec_requests er ON er.session_id = ssu.session_id
    OUTER APPLY sys.dm_exec_sql_text(er.sql_handle) st
    WHERE ((ssu.user_objects_alloc_page_count     - ssu.user_objects_dealloc_page_count)
         + (ssu.internal_objects_alloc_page_count - ssu.internal_objects_dealloc_page_count))
          * 8 / 1024.0 >= @min_session_mb;
END;
GO
