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
}
