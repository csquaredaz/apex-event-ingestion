/**
 * @description Processes one batch of due messages (ADR 0006): claims up to the batch size with a
 * row lock, dispatches them (ADR 0004) and records the results, all in one transaction. The lock
 * is the claim: no in-flight status is written, because it would always be rolled back or
 * overwritten. The attached `MessageProcessorFinalizer` decides the next run and recovers the
 * claimed messages if this transaction fails past the handlers' guard.
 *
 * Of the claimed messages it dispatches, in claim order, only those whose `Payload_Size__c` fits
 * `Dispatch_Payload_Budget__c` together, and always the first (ADR 0008). The rest keep their state,
 * with no attempt counted, and the Finalizer continues at once, as it does after a full batch.
 *
 * Limits (async): 1 SOQL to claim, 1 to load payloads, 1 to load claimed files when there are any,
 * the handlers' own budget, 1 DML statement for statuses. `execute` never enqueues a job, so a
 * handler can use the one Queueable slot, for example for a callout.
 * @group Processing
 */
public with sharing class MessageProcessorJob implements Queueable {
  /**
   * @description Claims, dispatches and records one batch. A claim that times out waiting for
   * another job's lock ends the run quietly: that job's Finalizer continues the drain.
   * @param context The Queueable context; unused.
   */
  public void execute(QueueableContext context) {
    // Attached first, so a failure even in reading the settings is reported.
    MessageProcessorFinalizer finalizer = new MessageProcessorFinalizer();
    System.attachFinalizer(finalizer);
    ILogger logger = (ILogger) Application.Service.newInstance(ILogger.class);

    IngestionSettings settings = IngestionSettings.current();
    Integer batchSize = settings.getBatchSize();
    List<Inbound_Message__c> claimed;
    try {
      claimed = ((IInboundMessagesSelector) Application.Selector.newInstance(Inbound_Message__c.SObjectType))
        .selectClaimable(Datetime.now(), batchSize);
    } catch (QueryException e) {
      // Usually "Record Currently Unavailable": another job held the rows for over 10 seconds.
      logger.warn('MessageProcessorJob claimed nothing: ' + e.getMessage());
      logger.flush();
      return;
    }
    if (claimed.isEmpty()) {
      logger.flush();
      return;
    }

    List<Inbound_Message__c> taken = withinBudget(claimed, settings.getDispatchPayloadBudget());
    Set<Id> messageIds = new Map<Id, Inbound_Message__c>(taken).keySet();
    // Messages left out by the budget are still due, so a trimmed claim counts as a full batch and
    // the Finalizer continues at once. They keep their state: no attempt is counted.
    finalizer.claimed(messageIds, taken.size() < claimed.size() ? taken.size() : batchSize);
    Map<Id, HandlerResult> results = ((IMessageDispatcher) Application.Service.newInstance(IMessageDispatcher.class))
      .dispatch(messageIds);
    finalizer.completed(
      ((IMessageLifecycle) Application.Service.newInstance(IMessageLifecycle.class)).recordResults(taken, results)
    );
    logger.info(
      'MessageProcessorJob processed ' +
        taken.size() +
        ' message(s)' +
        (taken.size() < claimed.size()
          ? '; ' + (claimed.size() - taken.size()) + ' left for the next job by the payload budget.'
          : '.')
    );
    logger.flush();
  }

  /**
   * The claimed messages, in claim order, whose payloads fit the budget together (ADR 0008). The
   * first is always taken, however large, so one big payload can't stall processing.
   */
  private static List<Inbound_Message__c> withinBudget(List<Inbound_Message__c> claimed, Integer budget) {
    List<Inbound_Message__c> taken = new List<Inbound_Message__c>();
    Long used = 0;
    for (Inbound_Message__c row : claimed) {
      Long size = row.Payload_Size__c == null ? 0 : row.Payload_Size__c.longValue();
      if (!taken.isEmpty() && used + size > budget) {
        break;
      }
      taken.add(row);
      used += size;
    }
    return taken;
  }
}
