/**
 * @description Turns processing outcomes into status changes on `Inbound_Message__c` (ADR 0006).
 * Every outcome counts an attempt. `SUCCESS` → `Processed`; `RETRYABLE` → `Failed` with
 * exponential backoff, or `Dead` once attempts run out; `FATAL` → `Dead`. Resolve it with
 * `(IMessageLifecycle) Application.Service.newInstance(IMessageLifecycle.class)`; the
 * `DI_Binding.Message_Lifecycle` row binds `MessageLifecycle`.
 * @group Processing
 */
public interface IMessageLifecycle {
  /**
   * @description Records the dispatch results for a claimed batch, in one user-mode Unit of Work.
   * A claimed message with no result is treated as `RETRYABLE`.
   * @param claimed The claimed rows, as `IInboundMessagesSelector.selectClaimable` returned them.
   * @param results The dispatcher's results, keyed by message Id.
   * @return The earliest `Next_Attempt_At__c` this call scheduled, or null if it scheduled none.
   */
  Datetime recordResults(List<Inbound_Message__c> claimed, Map<Id, HandlerResult> results);

  /**
   * @description Records a processor job that failed past the handlers' guard, for example with a
   * `LimitException`: every claimed message that isn't already `Processed` or `Dead` counts a
   * `RETRYABLE` attempt with `error`. Called by the Finalizer after the job's work rolled back.
   * @param messageIds The messages the failed job had claimed.
   * @param error Why the job failed.
   * @return The earliest `Next_Attempt_At__c` this call scheduled, or null if it scheduled none.
   */
  Datetime recordJobFailure(Set<Id> messageIds, String error);
}
