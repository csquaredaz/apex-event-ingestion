/**
 * @description Starts message processing (ADR 0006). Intake calls `enqueue()` after storing
 * messages. At most one processor job waits in the queue at a time, so calling this for every
 * intake batch is cheap: a call while a job is already queued returns null, and that job claims
 * whatever is due when it runs.
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
}
