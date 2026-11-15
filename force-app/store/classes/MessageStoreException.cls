/**
 * @description Thrown by `IMessageStore` when it can't write at all, for example because the
 * running user lacks the `Event_Ingestion_Processor` permission set. It means a setup error, not a
 * bad message, so callers should let it propagate and retry the delivery later.
 * @group Public API
 */
public with sharing class MessageStoreException extends Exception {
}
