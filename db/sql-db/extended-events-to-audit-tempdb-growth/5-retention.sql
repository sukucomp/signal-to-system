USE msdb;
GO
EXEC dbo.sp_add_job @job_name = N'DBA - Purge tempdb snapshots';
EXEC dbo.sp_add_jobstep
     @job_name = N'DBA - Purge tempdb snapshots',
     @step_name = N'Purge > 14 days',
     @subsystem = N'TSQL',
     @database_name = N'DBA_Utility',
     @command = N'
        DELETE FROM dbo.tempdb_session_snapshot WHERE snapshot_time_utc < DATEADD(DAY,-14,SYSUTCDATETIME());
        DELETE FROM dbo.tempdb_file_snapshot    WHERE snapshot_time_utc < DATEADD(DAY,-14,SYSUTCDATETIME());';
EXEC dbo.sp_add_schedule
     @schedule_name = N'Nightly 0200',
     @freq_type = 4, @freq_interval = 1,          -- daily
     @active_start_time = 020000;                 -- 02:00
EXEC dbo.sp_attach_schedule
     @job_name = N'DBA - Purge tempdb snapshots', @schedule_name = N'Nightly 0200';
EXEC dbo.sp_add_jobserver @job_name = N'DBA - Purge tempdb snapshots';
GO
