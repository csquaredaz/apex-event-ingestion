/**
 * @description Queries over `Inbound_Message__c`. Bound to `InboundMessagesSelector` by the
 * `DI_Binding.Inbound_Messages_Selector` row, so tests can stand in a mock through
 * `Application.Selector`.
 * @group Public API
 */
public interface IInboundMessagesSelector extends ISelector {
  /**
   * @description Selects the messages whose idempotency key equals one of the keys exactly. SOQL
   * compares text case-insensitively, so the case-sensitive match is applied after the query.
   * @param keys Idempotency keys; null or empty returns an empty list without querying.
   * @return The matching messages the running user can see, in user mode.
   */
  List<Inbound_Message__c> selectByIdempotencyKeys(Set<String> keys);

  /**
   * @description Selects messages by Id with the standard fields plus `Payload__c`, for dispatch.
   * @param ids Message Ids; null or empty returns an empty list without querying.
   * @return The messages the running user can see, in user mode.
   * @throws QueryException If the running user can't read `Payload__c` (user mode).
   */
  List<Inbound_Message__c> selectWithPayloadByIds(Set<Id> ids);

  /**
   * @description Claims up to `maxRows` messages that are due for processing: `Received`, or
   * `Failed` with `Next_Attempt_At__c` at or before `now`. The rows are locked `FOR UPDATE` until
   * the transaction ends, so a concurrent claim waits and then skips them (ADR 0006). Rows come in
   * Id order, the only order the platform allows with a lock.
   * @param now The time a `Failed` message must be due by.
   * @param maxRows The most rows to claim, from 1 to 200.
   * @return The claimed messages the running user can see, in user mode, without the payload.
   * @throws QueryException If another transaction holds the lock for more than 10 seconds
   * ("Record Currently Unavailable"), or the running user can't read the fields (user mode).
   */
  List<Inbound_Message__c> selectClaimable(Datetime now, Integer maxRows);
}
