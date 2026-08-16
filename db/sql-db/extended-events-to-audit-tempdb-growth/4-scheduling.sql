USE msdb;
GO
EXEC dbo.sp_add_job @job_name = N'DBA - Capture tempdb snapshot';
EXEC dbo.sp_add_jobstep
     @job_name = N'DBA - Capture tempdb snapshot',
     @step_name = N'Capture',
     @subsystem = N'TSQL',
     @database_name = N'DBA_Utility',
     @command = N'EXEC dbo.usp_capture_tempdb_snapshot;';
EXEC dbo.sp_add_schedule
     @schedule_name = N'Every minute',
     @freq_type = 4, @freq_interval = 1,
     @freq_subday_type = 4, @freq_subday_interval = 1;   -- every 1 minute
EXEC dbo.sp_attach_schedule
     @job_name = N'DBA - Capture tempdb snapshot',
     @schedule_name = N'Every minute';
EXEC dbo.sp_add_jobserver @job_name = N'DBA - Capture tempdb snapshot';
GO
