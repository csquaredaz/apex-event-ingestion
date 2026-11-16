/**
 * @description The default `IProcessorQueue` (ADR 0006). Every processor job carries one
 * duplicate signature, so at most one waits in the queue at a time: the platform rejects a second
 * while the first is still queued, and accepts a new one once it starts running.
 * @group Processing
 */
public with sharing class ProcessorQueue implements IProcessorQueue {
  /** @description The duplicate signature every processor job carries; the platform caps it at 32 bytes. */
  public static final String JOB_SIGNATURE = 'aei.MessageProcessorJob';
  /** @description The longest delay the platform allows for a Queueable, in minutes. */
  public static final Integer MAX_DELAY_MINUTES = 10;

  /**
   * @description See `IProcessorQueue.enqueue`. Limits: 1 Queueable.
   * @param delayMinutes Minutes to wait, clamped to 0 to 10.
   * @return The job Id, or null if a processor job is already queued.
   */
  public Id enqueue(Integer delayMinutes) {
    AsyncOptions options = new AsyncOptions();
    options.DuplicateSignature = QueueableDuplicateSignature.Builder().addString(JOB_SIGNATURE).build();
    options.MinimumQueueableDelayInMinutes = delayMinutes == null
      ? 0
      : Math.max(0, Math.min(delayMinutes, MAX_DELAY_MINUTES));
    try {
      return System.enqueueJob(new MessageProcessorJob(), options);
    } catch (DuplicateMessageException alreadyQueued) {
      // Expected under load: the queued job claims whatever is due when it runs.
      return null;
    }
  }
}
