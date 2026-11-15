/**
 * @description A bulk Command that handles every message of one type (ADR 0004). Name the class
 * in a `Message_Route__mdt` row; it must be `public`, have a public no-argument constructor and
 * hold no state between calls.
 *
 * The contract:
 * - **Idempotent.** A message can reach a handler more than once: after a retry, after another
 *   handler on the same route failed, or after the job died. Applying it twice must be harmless.
 * - **Order-free.** Messages arrive in no particular order (ADR 0005). Guard updates with
 *   `InboundMessage.isOlderThan` against what the record already reflects.
 * - **No synchronous callouts.** The dispatcher holds a savepoint around the call, and the job has
 *   already written to the database, so the platform refuses callouts. Enqueue a Queueable for them.
 * - **Report, don't throw.** Return `fatal` for a message that will never succeed and `retryable`
 *   for one that might later. A thrown exception rolls back this handler's DML and retries
 *   every message in the call. A rollback can't recall a Publish Immediately event or a job the
 *   handler already enqueued, so start those last.
 * @group Public API
 */
public interface IMessageHandler {
  /**
   * @description Handles a batch of messages of one type. Limits: the handler's own; it shares
   * the job's transaction with the other handlers dispatched in it.
   * @param messages The messages, never null or empty.
   * @return One result per message, matched by message Id. A message with no result is retried.
   */
  List<HandlerResult> handle(List<InboundMessage> messages);
}
