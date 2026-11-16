/**
 * @description Runs the stall sweep (ADR 0009). The platform's finest schedule is hourly, so four
 * jobs at :00, :15, :30 and :45 give a 15-minute sweep. An unlocked package can't run a post-install
 * script, so scheduling is a setup step: `scripts/schedule-stall-sweeper.apex`, or Setup → Apex
 * Classes → Schedule Apex.
 *
 * Each job runs as the user who scheduled it. That user needs `Event_Ingestion_Sweeper`, plus
 * whatever the bound `IAlertSink` needs (apex-platform-logging's Slack sink needs principal access
 * on its External Credential). Limit context: synchronous scheduled Apex; the sweep's cost is in
 * `StallDetector`. Idempotent: a second sweep finds the same messages and requests a run the
 * duplicate signature absorbs. No retry: the next sweep is 15 minutes later.
 * @group Stall detection
 */
public with sharing class StallSweeperSchedulable implements Schedulable {
  /** @description The name every sweeper job's name starts with. */
  public static final String JOB_NAME_PREFIX = 'aei stall sweeper :';
  /** @description The minutes past the hour the four jobs run at. */
  public static final List<Integer> MINUTES = new List<Integer>{ 0, 15, 30, 45 };

  /**
   * @description Sweeps once through the bound `IStallDetector`.
   * @param context The schedule context; unused.
   */
  public void execute(SchedulableContext context) {
    ((IStallDetector) Application.Service.newInstance(IStallDetector.class)).sweep(Datetime.now());
  }

  /**
   * @description Schedules the four sweeper jobs as the running user. Limits: 4 scheduled jobs
   * (an org allows 100).
   * @return The `CronTrigger` Ids, in the order of `MINUTES`.
   * @throws AsyncException If a job with one of the names is already scheduled. The transaction
   * rolls back, so either all four are scheduled or none is.
   */
  public static List<Id> scheduleEveryQuarterHour() {
    return new List<Id>{
      scheduleAt(MINUTES[0]),
      scheduleAt(MINUTES[1]),
      scheduleAt(MINUTES[2]),
      scheduleAt(MINUTES[3])
    };
  }

  /**
   * @description The cron expression for one job.
   * @param minute Minutes past the hour.
   * @return Seconds 0, that minute, every hour, every day.
   */
  public static String cronAt(Integer minute) {
    return '0 ' + minute + ' * * * ?';
  }

  private static Id scheduleAt(Integer minute) {
    return System.schedule(
      JOB_NAME_PREFIX + String.valueOf(minute).leftPad(2, '0'),
      cronAt(minute),
      new StallSweeperSchedulable()
    );
  }
}
