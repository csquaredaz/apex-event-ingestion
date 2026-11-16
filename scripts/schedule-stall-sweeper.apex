// Schedules the stall sweeper (ADR 0009) as the user running this script, at :00, :15, :30 and :45.
// An unlocked package has no post-install script, so this is a setup step.
// Usage: npm run org:schedule-sweeper [-- --target-org <alias>]
// The running user needs Event_Ingestion_Sweeper and whatever the bound IAlertSink needs.
// Running it twice fails with "already scheduled" and changes nothing.
// To stop sweeping: Setup > Scheduled Jobs, delete the four "aei stall sweeper" jobs.
List<Id> jobIds = StallSweeperSchedulable.scheduleEveryQuarterHour();
System.debug(LoggingLevel.INFO, 'Scheduled ' + jobIds.size() + ' stall sweeper jobs: ' + jobIds);
