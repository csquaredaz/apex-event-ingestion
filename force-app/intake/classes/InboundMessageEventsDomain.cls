/**
 * @description Stores `Inbound_Message_Event__e` events in the message store and starts processing
 * (Domain, ADR 0007). `InboundMessageEventTrigger` calls apex-core-lib's `TriggerDispatcher`, which
 * builds this domain through the `DI_Binding.Inbound_Message_Events_Domain` row, so a
 * `Trigger_Setting__mdt` row can switch intake off.
 *
 * Each trigger run:
 * 1. Takes events in order up to `IngestionSettings.getIntakeBatchSize()` events or
 *    `getIntakePayloadBudget()` payload characters, whichever comes first, and always at least one.
 *    A trigger can receive up to 2,000 events, and full payloads would not fit the async heap.
 * 2. Appends them through `IMessageStore` (one partial-success insert, ADR 0003) and, when at
 *    least one was new, calls `MessageProcessing.enqueue()`.
 * 3. Sets a resume checkpoint on the last event taken when it left some behind; the event bus
 *    redelivers the rest in a new trigger run (proven in a scratch org, 2026-11-16).
 *
 * A rejected message is final (ADR 0003): it is logged at WARN by key only, never retried. Any
 * exception while storing or enqueueing, including `MessageStoreException`, throws
 * `EventBus.RetryableException`, so the whole run is rolled back and redelivered. Unlike log
 * persistence in apex-platform-logging, intake never gives up, because giving up loses messages.
 * On the platform's last retry it raises one CRITICAL alert; if that retry fails too, the trigger
 * is suspended and keeps its events until it is resumed in Setup. An alert sink that writes
 * records would be rolled back with the run, so sinks should publish or call out.
 *
 * Runs as the Automated Process user, which a scratch-org probe showed has full access to
 * `Inbound_Message__c` without any permission set, including rows other users own, so the store's
 * user-mode insert and the processor job's user-mode updates work as-is.
 * @group Intake
 */
public with sharing class InboundMessageEventsDomain extends SObjectDomain {
  /** @description The platform's last retry of a trigger run; the alert is raised on it. */
  public static final Integer FINAL_RETRY = 9;

  /** Test seam: the retry count, because `EventBus.TriggerContext` exists only in a real delivery. */
  @TestVisible
  private static Integer retriesOverride;

  /** Test seam: when set, checkpoints are recorded here instead of set on the event bus. */
  @TestVisible
  private static List<String> recordedCheckpoints;

  /**
   * @description Creates the domain over a trigger batch.
   * @param records The `Inbound_Message_Event__e` events.
   */
  public InboundMessageEventsDomain(List<SObject> records) {
    super(records);
  }

  /**
   * @description The type this domain owns.
   * @return `Inbound_Message_Event__e.SObjectType`.
   */
  public override SObjectType getSObjectType() {
    return Inbound_Message_Event__e.SObjectType;
  }

  /**
   * @description Stores the events this run can take, starts processing and checkpoints the rest.
   * Limits: 1 DML statement and at most 1 SOQL (the store), 1 Queueable; bulk-safe at 2,000.
   * @throws EventBus.RetryableException If storing or enqueueing fails, so the run is redelivered.
   */
  public override void onAfterInsert() {
    List<Inbound_Message_Event__e> events = (List<Inbound_Message_Event__e>) getRecords();
    List<Inbound_Message_Event__e> taken = take(events, IngestionSettings.current());
    ILogger logger = (ILogger) Application.Service.newInstance(ILogger.class);
    try {
      List<AppendResult> results = ((IMessageStore) Application.Service.newInstance(IMessageStore.class))
        .append(toMessages(taken));
      if (logRejections(taken, results, logger)) {
        MessageProcessing.enqueue();
      }
    } catch (Exception failure) {
      throw retry(failure, taken.size(), logger);
    }
    if (taken.size() < events.size()) {
      checkpoint(taken[taken.size() - 1].ReplayId);
    }
    logger.flush();
  }

  /** The first events, in order, within the count and payload limits; never none. */
  private static List<Inbound_Message_Event__e> take(
    List<Inbound_Message_Event__e> events,
    IngestionSettings settings
  ) {
    List<Inbound_Message_Event__e> taken = new List<Inbound_Message_Event__e>();
    Integer budget = settings.getIntakePayloadBudget();
    Integer used = 0;
    for (Inbound_Message_Event__e event : events) {
      Integer size = event.Payload__c == null ? 0 : event.Payload__c.length();
      if (taken.size() == settings.getIntakeBatchSize() || (!taken.isEmpty() && used + size > budget)) {
        break;
      }
      taken.add(event);
      used += size;
    }
    return taken;
  }

  /** Producer fields only; the store sets the key and the lifecycle fields. */
  private static List<Inbound_Message__c> toMessages(List<Inbound_Message_Event__e> events) {
    List<Inbound_Message__c> messages = new List<Inbound_Message__c>();
    for (Inbound_Message_Event__e event : events) {
      messages.add(
        new Inbound_Message__c(
          Source__c = event.Source__c,
          External_Message_Id__c = event.External_Message_Id__c,
          Message_Type__c = event.Message_Type__c,
          Payload__c = event.Payload__c,
          Correlation_Id__c = event.Correlation_Id__c,
          Occurred_At__c = event.Occurred_At__c
        )
      );
    }
    return messages;
  }

  /**
   * Logs each rejection by key (or the event's UUID when it has no key), never the payload or the
   * error text, which can quote it. Returns whether any message was new.
   */
  private static Boolean logRejections(
    List<Inbound_Message_Event__e> events,
    List<AppendResult> results,
    ILogger logger
  ) {
    Boolean anyAccepted = false;
    for (Integer i = 0; i < results.size(); i++) {
      AppendResult result = results[i];
      anyAccepted = anyAccepted || result.isAccepted();
      if (result.isRejected()) {
        String key = result.getIdempotencyKey() == null
          ? 'EventUuid ' + events[i].EventUuid
          : result.getIdempotencyKey();
        logger.warn('Inbound_Message_Event__e rejected and not retried: ' + key + '.');
      }
    }
    return anyAccepted;
  }

  /** Logs the failure, alerts on the last retry, and returns the exception that asks for redelivery. */
  private static EventBus.RetryableException retry(Exception failure, Integer eventCount, ILogger logger) {
    Integer retries = retries();
    logger.error(
      'Intake failed on attempt ' + (retries + 1) + ' of ' + (FINAL_RETRY + 1) + '; the run will be redelivered.',
      failure
    );
    if (retries >= FINAL_RETRY) {
      ((IAlertSink) Application.Service.newInstance(IAlertSink.class))
        .send(
          new List<Alert>{
            new Alert(
              Alert.Severity.CRITICAL,
              'Intake failed on its last retry; ' + eventCount + ' event(s) wait in a suspended trigger',
              'Resume InboundMessageEventTrigger in Setup → Platform Events once the cause is fixed. The error is in the log.',
              InboundMessageEventsDomain.class.getName()
            )
          }
        );
    }
    logger.flush();
    return new EventBus.RetryableException(
      'Intake failed on attempt ' + (retries + 1) + ': ' + failure.getTypeName() + ': ' + failure.getMessage()
    );
  }

  private static Integer retries() {
    if (retriesOverride != null) {
      return retriesOverride;
    }
    return EventBus.TriggerContext.currentContext().retries;
  }

  private static void checkpoint(String replayId) {
    if (recordedCheckpoints != null) {
      recordedCheckpoints.add(replayId);
      return;
    }
    EventBus.TriggerContext.currentContext().setResumeCheckpoint(replayId);
  }

  /** @description Builds the domain for `DomainFactory` (bound by `DI_Binding.Inbound_Message_Events_Domain`). */
  public class Constructor implements IDomainConstructor {
    /**
     * @description Creates the domain.
     * @param records The events.
     * @return An `InboundMessageEventsDomain`.
     */
    public IDomain construct(List<SObject> records) {
      return new InboundMessageEventsDomain(records);
    }
  }
}
