/**
 * @description The default `IStallDetector` (ADR 0009), a stateless service.
 *
 * A message is **due** when it is `Received`, or `Failed` with `Next_Attempt_At__c` passed. The
 * Finalizer leaves a retry more than 10 minutes away to the sweeper (ADR 0006), so finding due
 * messages is normal, and the sweep only requests a run. A message is **stalled** when it has been
 * due for longer than `Stall_After_Minutes__c` (default 30, two sweeps): a run should have taken it by
 * then. That covers an intake whose enqueue was lost, a job that keeps dying before recovery (ADR
 * 0006's known limit) and a backlog that isn't draining.
 *
 * The sweep runs as whoever scheduled it, who can't update messages the Automated Process user owns,
 * so it never updates or enqueues: it reads in user mode and calls `MessageProcessing.requestRun()`,
 * whose job runs as the Automated Process user. Alerts name counts and Ids only.
 *
 * Limits: 1 SOQL when anything is stalled, else 2 (at most 201 rows); 1 event publish; no DML.
 * @group Stall detection
 */
public with sharing class StallDetector implements IStallDetector {
  private static final Integer ALERT_SAMPLE = 10;

  /**
   * @description See `IStallDetector.sweep`.
   * @param now The time of the sweep.
   * @return What the sweep found.
   * @throws QueryException If the running user can't read messages (assign `Event_Ingestion_Sweeper`).
   * @throws AsyncException If the wake event can't be published.
   * @throws IllegalArgumentException If `now` is null.
   */
  public StallReport sweep(Datetime now) {
    if (now == null) {
      throw new IllegalArgumentException('sweep needs the time of the sweep.');
    }
    IInboundMessagesSelector selector = (IInboundMessagesSelector) Application.Selector.newInstance(
      Inbound_Message__c.SObjectType
    );
    Datetime stalledBefore = now.addMinutes(-IngestionSettings.current().getStallAfterMinutes());
    List<Id> stalledIds = idsOf(selector.selectDue(stalledBefore, StallReport.MAX_STALLED));
    // Anything stalled is also due, so the second query is needed only when nothing is stalled.
    List<Id> dueIds = stalledIds.isEmpty() ? idsOf(selector.selectDue(now, 1)) : new List<Id>();
    StallReport report = new StallReport(stalledBefore, stalledIds, dueIds);

    if (report.hasDueMessages()) {
      MessageProcessing.requestRun();
    }
    if (!stalledIds.isEmpty()) {
      alert(report);
    }
    ILogger logger = (ILogger) Application.Service.newInstance(ILogger.class);
    logger.info(
      'StallDetector: ' +
        (report.hasDueMessages() ? 'processing requested' : 'nothing due') +
        '; ' +
        stalledIds.size() +
        (report.isCapped() ? ' or more' : '') +
        ' stalled.'
    );
    logger.flush();
    return report;
  }

  /** In query order (Id order), so the alert names the oldest first. */
  private static List<Id> idsOf(List<Inbound_Message__c> rows) {
    List<Id> ids = new List<Id>();
    for (Inbound_Message__c row : rows) {
      ids.add(row.Id);
    }
    return ids;
  }

  /** One alert per sweep while the stall lasts: stateless, at most four an hour. */
  private static void alert(StallReport report) {
    List<Id> stalledIds = report.getStalledIds();
    List<Id> sample = new List<Id>();
    for (Integer i = 0; i < Math.min(stalledIds.size(), ALERT_SAMPLE); i++) {
      sample.add(stalledIds[i]);
    }
    ((IAlertSink) Application.Service.newInstance(IAlertSink.class))
      .send(
        new List<Alert>{
          new Alert(
            Alert.Severity.WARNING,
            stalledIds.size() + (report.isCapped() ? ' or more' : '') + ' inbound message(s) stalled',
            'Due since ' +
              report.getStalledBefore().formatGmt('yyyy-MM-dd HH:mm') +
              ' UTC or earlier and not yet processed; a processor run was requested. Inbound_Message__c Ids (first ' +
              ALERT_SAMPLE +
              '): ' +
              String.join(sample, ', '),
            StallDetector.class.getName()
          )
        }
      );
  }
}
