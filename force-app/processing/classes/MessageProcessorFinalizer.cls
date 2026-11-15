/**
 * @description Runs after every `MessageProcessorJob`, in its own transaction (ADR 0006).
 *
 * - **Recovery.** If the job failed past the handlers' guard (a `LimitException`, a failed status
 *   commit), the job's work has rolled back, but this instance still holds the claimed Ids. It
 *   counts a retryable attempt for each through `IMessageLifecycle.recordJobFailure` and raises a
 *   CRITICAL alert.
 * - **Continuation.** It enqueues the next job: at once when the batch was full, delayed to the
 *   earliest retry when one is due within 10 minutes, otherwise not at all (later retries wait for
 *   the next intake or the stall sweeper, ADR 0009). A job enqueued from a Finalizer starts a new
 *   chain, so the drain never reaches the Developer Edition stack depth of 5.
 *
 * Limits: 1 SOQL and 1 DML statement for recovery, 1 enqueue. A Finalizer may enqueue one job; a
 * second throws an uncatchable `LimitException`. Known limit: if recovery itself fails, the
 * messages keep their state without an attempt counted, so a message that always breaks the job
 * never reaches `Dead`; the stall sweeper (ADR 0009) alerts on it.
 * @group Processing
 */
public with sharing class MessageProcessorFinalizer implements Finalizer {
  private final Set<Id> claimedIds = new Set<Id>();
  private Boolean batchFull = false;
  private Datetime nextRetryAt;

  /**
   * @description Called by the job once it holds the rows, before dispatch.
   * @param messageIds The claimed messages.
   * @param batchSize The most the claim could take; a full claim means more work is probably waiting.
   */
  public void claimed(Set<Id> messageIds, Integer batchSize) {
    claimedIds.addAll(messageIds);
    batchFull = batchSize != null && claimedIds.size() >= batchSize;
  }

  /**
   * @description Called by the job after its statuses are registered.
   * @param earliestRetryAt The earliest retry the job scheduled, or null.
   */
  public void completed(Datetime earliestRetryAt) {
    nextRetryAt = earliestRetryAt;
  }

  /**
   * @description Recovers a failed job's messages, then enqueues the next job if one is needed.
   * @param context The parent job's result and exception.
   */
  public void execute(FinalizerContext context) {
    ILogger logger = (ILogger) Application.Service.newInstance(ILogger.class);
    Datetime retryAt = nextRetryAt;
    if (context.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
      Exception cause = context.getException();
      String error = 'The processor job failed: ' + (cause == null ? 'unknown error' : cause.getMessage());
      logger.error(error, cause);
      try {
        retryAt = ((IMessageLifecycle) Application.Service.newInstance(IMessageLifecycle.class))
          .recordJobFailure(claimedIds, error);
      } catch (Exception recoveryFailure) {
        // Logged and alerted, not rethrown: a rethrow would only replace this log with the platform's.
        logger.error('MessageProcessorFinalizer could not record the failure.', recoveryFailure);
        alert('Processor recovery failed; ' + claimedIds.size() + ' message(s) kept their state', context);
        logger.flush();
        return;
      }
      alert('Processor job failed; ' + claimedIds.size() + ' message(s) scheduled for retry or Dead', context);
    }
    Integer delay = continuationDelay(batchFull, retryAt, Datetime.now());
    if (delay != null) {
      ((IProcessorQueue) Application.Service.newInstance(IProcessorQueue.class)).enqueue(delay);
    }
    logger.flush();
  }

  /**
   * @description When to run the next job.
   * @param batchWasFull True if the last claim filled the batch.
   * @param retryAt The earliest retry scheduled, or null.
   * @param now The current time.
   * @return 0 to run at once, 1 to 10 to wait that many minutes, or null for no next job.
   */
  @TestVisible
  private static Integer continuationDelay(Boolean batchWasFull, Datetime retryAt, Datetime now) {
    if (batchWasFull == true) {
      return 0;
    }
    if (retryAt == null) {
      return null;
    }
    Long millis = retryAt.getTime() - now.getTime();
    Integer minutes = millis <= 0 ? 0 : (Integer) Math.ceil(millis / 60000.0);
    return minutes <= ProcessorQueue.MAX_DELAY_MINUTES ? minutes : null;
  }

  /** Ids and counts only: an exception message can quote payload data. */
  private static void alert(String title, FinalizerContext context) {
    ((IAlertSink) Application.Service.newInstance(IAlertSink.class))
      .send(
        new List<Alert>{
          new Alert(
            Alert.Severity.CRITICAL,
            title,
            'AsyncApexJob ' + context.getAsyncApexJobId() + '. The error is in Last_Error__c and the log.',
            MessageProcessorFinalizer.class.getName()
          )
        }
      );
  }
}
