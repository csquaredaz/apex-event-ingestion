/**
 * @description The default `IMessageStore` (ADR 0002, 0003). Each message gets an idempotency key
 * and is inserted on its own with partial success, so the unique `Idempotency_Key__c` index, not
 * a query beforehand, decides what is new. That also holds when two transactions race.
 *
 * Writes go through `IPartialDml` rather than the Unit of Work. This is a documented exception to
 * the repository's Unit of Work rule: apex-core-lib's Unit of Work is all-or-none, and one bad or
 * repeated message must not fail the batch (ADR 0003). Repeats inside one batch are left to the
 * database too: the first copy wins and later copies get `DUPLICATE_VALUE`, which also handles a
 * first copy that is itself rejected.
 * @group Public API
 */
public with sharing class MessageStore implements IMessageStore {
  /**
   * The optional producer fields. Required fields are always createable, so they need no check.
   * Without edit access to these, user-mode DML would fail each row, and a rejection is final.
   */
  private static final List<SObjectField> OPTIONAL_PRODUCER_FIELDS = new List<SObjectField>{
    Inbound_Message__c.Payload__c,
    Inbound_Message__c.Correlation_Id__c,
    Inbound_Message__c.Occurred_At__c
  };

  /**
   * @description See `IMessageStore.append`. Limits: 1 DML via `IPartialDml`, plus 1 SOQL through
   * `IInboundMessagesSelector` when there are duplicates. Bulk-safe at 200.
   * @param messages Unsaved messages.
   * @return One result per message, in the same order.
   * @throws MessageStoreException If the running user can't create `Inbound_Message__c`.
   */
  public List<AppendResult> append(List<Inbound_Message__c> messages) {
    if (messages == null || messages.isEmpty()) {
      return new List<AppendResult>();
    }
    assertCanCreate();

    Batch batch = new Batch(messages);
    if (batch.hasRows()) {
      Set<String> duplicateKeys = batch.record(
        ((IPartialDml) Application.Service.newInstance(IPartialDml.class)).insertPartial(batch.rows)
      );
      if (!duplicateKeys.isEmpty()) {
        batch.resolveDuplicates(selector().selectByIdempotencyKeys(duplicateKeys));
      }
    }
    return batch.results;
  }

  /** A setup error must throw (so the delivery is retried), not reject every message (ADR 0003). */
  private static void assertCanCreate() {
    Boolean canCreate = Inbound_Message__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isCreateable();
    for (SObjectField field : OPTIONAL_PRODUCER_FIELDS) {
      canCreate = canCreate && field.getDescribe().isCreateable();
    }
    if (!canCreate) {
      throw new MessageStoreException(
        'The running user cannot create Inbound_Message__c with its producer fields. Assign the Event_Ingestion_Processor permission set.'
      );
    }
  }

  private static IInboundMessagesSelector selector() {
    return (IInboundMessagesSelector) Application.Selector.newInstance(Inbound_Message__c.SObjectType);
  }

  /**
   * One append call: the rows to insert, which input position each came from, and the result for
   * every input. A result stays null until its outcome is known.
   */
  private class Batch {
    final List<AppendResult> results = new List<AppendResult>();
    final List<Inbound_Message__c> rows = new List<Inbound_Message__c>();
    final List<Integer> positions = new List<Integer>();

    Batch(List<Inbound_Message__c> messages) {
      for (Integer i = 0; i < messages.size(); i++) {
        results.add(null);
        Inbound_Message__c message = messages[i];
        if (message == null) {
          results[i] = AppendResult.rejected(null, 'The message is null.');
          continue;
        }
        try {
          rows.add(newRow(message, IdempotencyKey.of(message.Source__c, message.External_Message_Id__c)));
          positions.add(i);
        } catch (IllegalArgumentException e) {
          results[i] = AppendResult.rejected(null, e.getMessage());
        }
      }
    }

    Boolean hasRows() {
      return !rows.isEmpty();
    }

    /** Records accepted and rejected rows; returns the keys that were already stored. */
    Set<String> record(List<Database.SaveResult> saves) {
      Set<String> duplicateKeys = new Set<String>();
      for (Integer j = 0; j < saves.size(); j++) {
        String key = rows[j].Idempotency_Key__c;
        Database.SaveResult save = saves[j];
        if (save.isSuccess()) {
          results[positions[j]] = AppendResult.accepted(key, save.getId());
        } else if (isDuplicate(save)) {
          duplicateKeys.add(key);
        } else {
          results[positions[j]] = AppendResult.rejected(key, describe(save.getErrors()));
        }
      }
      return duplicateKeys;
    }

    /** Points every duplicate at its stored row. Map<String, …> keys are case-sensitive, like the key. */
    void resolveDuplicates(List<Inbound_Message__c> stored) {
      Map<String, Id> storedIdByKey = new Map<String, Id>();
      for (Inbound_Message__c row : stored) {
        storedIdByKey.put(row.Idempotency_Key__c, row.Id);
      }
      for (Integer j = 0; j < rows.size(); j++) {
        if (results[positions[j]] == null) {
          String key = rows[j].Idempotency_Key__c;
          results[positions[j]] = AppendResult.duplicate(key, storedIdByKey.get(key));
        }
      }
    }
  }

  /** Copies only the producer's fields; lifecycle fields always start fresh. */
  private static Inbound_Message__c newRow(Inbound_Message__c message, String key) {
    return new Inbound_Message__c(
      Idempotency_Key__c = key,
      Source__c = message.Source__c,
      External_Message_Id__c = message.External_Message_Id__c,
      Message_Type__c = message.Message_Type__c,
      Payload__c = message.Payload__c,
      Correlation_Id__c = message.Correlation_Id__c,
      Occurred_At__c = message.Occurred_At__c,
      Status__c = MessageStatuses.RECEIVED,
      Attempts__c = 0
    );
  }

  /** The only unique field on the object is the idempotency key, so DUPLICATE_VALUE means "already stored". */
  private static Boolean isDuplicate(Database.SaveResult save) {
    for (Database.Error error : save.getErrors()) {
      if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
        return true;
      }
    }
    return false;
  }

  private static String describe(List<Database.Error> errors) {
    List<String> parts = new List<String>();
    for (Database.Error error : errors) {
      parts.add(error.getStatusCode() + ': ' + error.getMessage());
    }
    return String.join(parts, '; ');
  }
}
