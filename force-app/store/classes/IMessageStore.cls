/**
 * @description The message store port (ADR 0002): appends producer messages to
 * `Inbound_Message__c`, at most once per idempotency key (ADR 0003). Resolve it with
 * `(IMessageStore) Application.Service.newInstance(IMessageStore.class)`; the
 * `DI_Binding.Message_Store` row binds `MessageStore`.
 * @group Public API
 */
public interface IMessageStore {
  /**
   * @description Stores each message once. Only the producer fields are copied onto the new row
   * (`Source__c`, `External_Message_Id__c`, `Message_Type__c`, `Payload__c`, `Correlation_Id__c`,
   * `Occurred_At__c`); the lifecycle fields always start at `Received` with 0 attempts. One bad
   * message never fails the others.
   * Limits: 1 DML statement (partial success, user mode), plus 1 SOQL only when there are
   * duplicates. Bulk-safe at 200.
   * @param messages Unsaved messages. Null or empty returns an empty list.
   * @return One result per message, in the same order.
   * @throws MessageStoreException If the running user can't create `Inbound_Message__c`, so that
   * the caller retries later instead of losing good messages.
   */
  List<AppendResult> append(List<Inbound_Message__c> messages);
}
