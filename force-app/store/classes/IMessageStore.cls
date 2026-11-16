/**
 * @description The message store port (ADR 0002): appends producer messages to
 * `Inbound_Message__c`, at most once per idempotency key (ADR 0003). Resolve it with
 * `(IMessageStore) Application.Service.newInstance(IMessageStore.class)`; the
 * `DI_Binding.Message_Store` row binds `MessageStore`.
 * @group Public API
 */
public interface IMessageStore {
  /**
   * @description Stores each message once; the running user is the producer. Only the producer
   * fields are copied onto the new row (`Source__c`, `External_Message_Id__c`, `Message_Type__c`,
   * `Payload__c`, `Payload_Ref__c`, `Correlation_Id__c`, `Occurred_At__c`); the lifecycle fields
   * always start at `Received` with 0 attempts. One bad message never fails the others. Claims
   * follow the rules of `append(messages, producerIds)`.
   * Limits: 1 DML statement (partial success, user mode), plus 1 SOQL when there are claims and 1
   * when there are duplicates. Bulk-safe at 200.
   * @param messages Unsaved messages. Null or empty returns an empty list.
   * @return One result per message, in the same order.
   * @throws MessageStoreException If the running user can't create `Inbound_Message__c`, so that
   * the caller retries later instead of losing good messages.
   */
  List<AppendResult> append(List<Inbound_Message__c> messages);

  /**
   * @description Stores each message once, as `append(messages)` does, for producers other than the
   * running user. Intake uses it: the Automated Process user stores what each publisher sent.
   * A message carries its payload inline in `Payload__c` (up to 131,072 characters) or as a claim
   * check in `Payload_Ref__c`, the Id of a `ContentVersion`, never both (ADR 0008). A claim is
   * accepted only when that message's producer uploaded the version and it fits
   * `Claim_Max_Bytes__c`; otherwise the message is rejected. The store records `Payload_Size__c`.
   * Limits: 1 DML statement (partial success, user mode), plus 1 SOQL when there are claims and 1
   * when there are duplicates. Bulk-safe at 200.
   * @param messages Unsaved messages. Null or empty returns an empty list.
   * @param producerIds The user who produced each message, in the same order. A null list, or a
   * null entry, means the running user.
   * @return One result per message, in the same order.
   * @throws IllegalArgumentException If `producerIds` isn't null and its size differs from `messages`.
   * @throws MessageStoreException If the running user can't create `Inbound_Message__c`.
   */
  List<AppendResult> append(List<Inbound_Message__c> messages, List<Id> producerIds);
}
