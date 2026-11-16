/**
 * @description Starts message processing (ADR 0006). Intake calls `enqueue()` after storing
 * messages. At most one processor job waits in the queue at a time, so calling this for every
 * intake batch is cheap: a call while a job is already queued returns null, and that job claims
 * whatever is due when it runs.
 *
 * `enqueue()` runs the job as the calling user, who must be able to update every message it claims.
 * `requestRun()` is for callers that can't, such as the stall sweeper (ADR 0009): the job then runs as
 * the Automated Process user, which stores and processes every event-borne message (ADR 0007).
 * @group Public API
 */
public with sharing class MessageProcessing {
  /**
   * @description Enqueues a processor job to run as soon as possible, through the bound
   * `IProcessorQueue`.
   * @return The job Id, or null if a processor job is already queued.
   */
  public static Id enqueue() {
    return ((IProcessorQueue) Application.Service.newInstance(IProcessorQueue.class)).enqueue(0);
  }

  /**
   * @description Asks for a processor job that runs as the Automated Process user, by publishing
   * `Processor_Wake_Event__e` (Publish Immediately). Its trigger calls `enqueue()`, so the duplicate
   * signature still keeps one job queued. The caller needs Create on the event
   * (`Event_Ingestion_Sweeper`). Limits: 1 event publish, no SOQL or DML.
   * @throws AsyncException If the event bus refuses the event, for example without Create on it.
   */
  public static void requestRun() {
    Database.SaveResult result = EventBus.publish(new Processor_Wake_Event__e());
    if (!result.isSuccess()) {
      List<String> errors = new List<String>();
      for (Database.Error error : result.getErrors()) {
        errors.add(error.getStatusCode() + ': ' + error.getMessage());
      }
      throw new AsyncException('Processor_Wake_Event__e was not published: ' + String.join(errors, '; '));
    }
  }
}
