/**
 * @description Processes one batch of due messages (ADR 0006): claims up to the batch size with a
 * row lock, dispatches them (ADR 0004) and records the results, all in one transaction. The lock
 * is the claim: no in-flight status is written, because it would always be rolled back or
 * overwritten. The attached `MessageProcessorFinalizer` decides the next run and recovers the
 * claimed messages if this transaction fails past the handlers' guard.
 *
 * Limits (async): 1 SOQL to claim, 1 to load payloads, the handlers' own budget, 1 DML statement
 * for statuses. `execute` never enqueues a job, so a handler can use the one Queueable slot, for
 * example for a callout.
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

    Integer batchSize = IngestionSettings.current().getBatchSize();
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

    Set<Id> messageIds = new Map<Id, Inbound_Message__c>(claimed).keySet();
    finalizer.claimed(messageIds, batchSize);
    Map<Id, HandlerResult> results = ((IMessageDispatcher) Application.Service.newInstance(IMessageDispatcher.class))
      .dispatch(messageIds);
    finalizer.completed(
      ((IMessageLifecycle) Application.Service.newInstance(IMessageLifecycle.class)).recordResults(claimed, results)
    );
    logger.info('MessageProcessorJob processed ' + claimed.size() + ' message(s).');
    logger.flush();
  }
}
