/**
 * @description Starts a processor job when `Processor_Wake_Event__e` arrives (Domain, ADR 0009).
 * `ProcessorWakeEventTrigger` calls apex-core-lib's `TriggerDispatcher`, which builds this domain
 * through `DI_Binding.Processor_Wake_Events_Domain`.
 *
 * Runs as the Automated Process user, so the job it enqueues does too, and can update every message
 * that user stored (ADR 0007). One enqueue per trigger run, however many events arrive; the duplicate
 * signature turns it into a no-op while a job is queued. A failure is logged and not retried: the
 * event carries no data, and the next sweep asks again.
 * @group Stall detection
 */
public with sharing class ProcessorWakeEventsDomain extends SObjectDomain {
  /**
   * @description Creates the domain over a trigger batch.
   * @param records The `Processor_Wake_Event__e` events.
   */
  public ProcessorWakeEventsDomain(List<SObject> records) {
    super(records);
  }

  /**
   * @description The type this domain owns.
   * @return `Processor_Wake_Event__e.SObjectType`.
   */
  public override SObjectType getSObjectType() {
    return Processor_Wake_Event__e.SObjectType;
  }

  /**
   * @description Enqueues one processor job. Limits: 1 Queueable, no SOQL or DML.
   */
  public override void onAfterInsert() {
    ILogger logger = (ILogger) Application.Service.newInstance(ILogger.class);
    try {
      Id jobId = MessageProcessing.enqueue();
      logger.info(
        'Processor wake (' +
          getRecords().size() +
          ' event(s)): ' +
          (jobId == null ? 'a processor job was already queued.' : 'enqueued ' + jobId + '.')
      );
    } catch (Exception failure) {
      logger.error('Processor wake could not enqueue a job; the next sweep asks again.', failure);
    }
    logger.flush();
  }

  /** @description Builds the domain for `DomainFactory` (bound by `DI_Binding.Processor_Wake_Events_Domain`). */
  public class Constructor implements IDomainConstructor {
    /**
     * @description Creates the domain.
     * @param records The events.
     * @return A `ProcessorWakeEventsDomain`.
     */
    public IDomain construct(List<SObject> records) {
      return new ProcessorWakeEventsDomain(records);
    }
  }
}
