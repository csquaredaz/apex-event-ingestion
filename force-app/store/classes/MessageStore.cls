/**
 * @description The default `IMessageStore` (ADR 0002, 0003, 0008). Each message gets an idempotency
 * key and is inserted on its own with partial success, so the unique `Idempotency_Key__c` index, not
 * a query beforehand, decides what is new. That also holds when two transactions race.
 *
 * Writes go through `IPartialDml` rather than the Unit of Work. This is a documented exception to
 * the repository's Unit of Work rule: apex-core-lib's Unit of Work is all-or-none, and one bad or
 * repeated message must not fail the batch (ADR 0003). Repeats inside one batch are left to the
 * database too: the first copy wins and later copies get `DUPLICATE_VALUE`, which also handles a
 * first copy that is itself rejected.
 *
 * A message carries its payload inline (`Payload__c`) or as a claim check (`Payload_Ref__c`), never
 * both. `MessageClaims` inspects every claim through `IPayloadResolver` before the insert and must name a version
 * the producer uploaded, within `Claim_Max_Bytes__c`; anything else is rejected (ADR 0008). The store
 * records `Payload_Size__c` so the processor job can keep one job's payloads within the heap.
 * @group Public API
 */
public with sharing class MessageStore implements IMessageStore {
  /**
   * The optional fields the store writes. Required fields are always createable, so they need no
   * check. Without edit access to these, user-mode DML would fail each row, and a rejection is final.
   */
  private static final List<SObjectField> OPTIONAL_FIELDS = new List<SObjectField>{
    Inbound_Message__c.Payload__c,
    Inbound_Message__c.Payload_Ref__c,
    Inbound_Message__c.Payload_Size__c,
    Inbound_Message__c.Correlation_Id__c,
    Inbound_Message__c.Occurred_At__c
  };

  private static final String TWO_PAYLOADS = 'A message carries its payload in Payload__c or Payload_Ref__c, not both (ADR 0008).';

  /**
   * @description See `IMessageStore.append`. The running user is the producer of every message.
   * @param messages Unsaved messages.
   * @return One result per message, in the same order.
   * @throws MessageStoreException If the running user can't create `Inbound_Message__c`.
   */
  public List<AppendResult> append(List<Inbound_Message__c> messages) {
    return append(messages, null);
  }

  /**
   * @description See `IMessageStore.append(List<Inbound_Message__c>, List<Id>)`. Limits: 1 DML via
   * `IPartialDml`, plus 1 SOQL through `IPayloadResolver` when there are claims and 1 through
   * `IInboundMessagesSelector` when there are duplicates. Bulk-safe at 200.
   * @param messages Unsaved messages.
   * @param producerIds The producer of each message, in the same order; null means the running user.
   * @return One result per message, in the same order.
   * @throws IllegalArgumentException If `producerIds` isn't null and its size differs from `messages`.
   * @throws MessageStoreException If the running user can't create `Inbound_Message__c`.
   */
  public List<AppendResult> append(List<Inbound_Message__c> messages, List<Id> producerIds) {
    if (messages == null || messages.isEmpty()) {
      return new List<AppendResult>();
    }
    if (producerIds != null && producerIds.size() != messages.size()) {
      throw new IllegalArgumentException('append needs one producer Id per message, or none.');
    }
    assertCanCreate();

    Batch batch = new Batch(messages);
    batch.reject(MessageClaims.check(batch.rows, batch.producersOf(producerIds)));
    if (batch.hasRows()) {
      batch.resolveDuplicates(
        batch.record(((IPartialDml) Application.Service.newInstance(IPartialDml.class)).insertPartial(batch.rows))
      );
    }
    return batch.results;
  }

  /** A setup error must throw (so the delivery is retried), not reject every message (ADR 0003). */
  private static void assertCanCreate() {
    Boolean canCreate = Inbound_Message__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isCreateable();
    for (SObjectField field : OPTIONAL_FIELDS) {
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
        AppendResult refusal = refusalOf(messages[i]);
        results.add(refusal);
        if (refusal == null) {
          rows.add(newRow(messages[i]));
          positions.add(i);
        }
      }
    }

    Boolean hasRows() {
      return !rows.isEmpty();
    }

    /** The producer of each row: the given one at its input position, else the running user. */
    List<Id> producersOf(List<Id> producerIds) {
      List<Id> producers = new List<Id>();
      for (Integer position : positions) {
        producers.add(producerIds?.get(position) ?? UserInfo.getUserId());
      }
      return producers;
    }

    /** Rejects the rows with a problem, keyed by row index, and drops them from the insert. */
    void reject(Map<Integer, String> problemsByRow) {
      List<Inbound_Message__c> kept = new List<Inbound_Message__c>();
      List<Integer> keptPositions = new List<Integer>();
      for (Integer j = 0; j < rows.size(); j++) {
        if (problemsByRow.containsKey(j)) {
          results[positions[j]] = AppendResult.rejected(rows[j].Idempotency_Key__c, problemsByRow.get(j));
        } else {
          kept.add(rows[j]);
          keptPositions.add(positions[j]);
        }
      }
      rows.clear();
      rows.addAll(kept);
      positions.clear();
      positions.addAll(keptPositions);
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

    /**
     * Points every duplicate at its stored row, with one query and none when there are no
     * duplicates. Map<String, …> keys are case-sensitive, like the key.
     */
    void resolveDuplicates(Set<String> duplicateKeys) {
      if (duplicateKeys.isEmpty()) {
        return;
      }
      Map<String, Id> storedIdByKey = new Map<String, Id>();
      for (Inbound_Message__c row : selector().selectByIdempotencyKeys(duplicateKeys)) {
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

  /**
   * Why a message is refused before the insert, or null: it is null, it has no valid key, or it
   * carries an inline payload and a claim together. The inline limit is the field's 131,072
   * characters; anything larger must be claimed (ADR 0008).
   */
  private static AppendResult refusalOf(Inbound_Message__c message) {
    if (message == null) {
      return AppendResult.rejected(null, 'The message is null.');
    }
    String key;
    try {
      key = IdempotencyKey.of(message.Source__c, message.External_Message_Id__c);
    } catch (IllegalArgumentException e) {
      return AppendResult.rejected(null, e.getMessage());
    }
    if (String.isNotBlank(message.Payload__c) && String.isNotBlank(message.Payload_Ref__c)) {
      return AppendResult.rejected(key, TWO_PAYLOADS);
    }
    return null;
  }

  /** Copies only the producer's fields; lifecycle fields always start fresh. */
  private static Inbound_Message__c newRow(Inbound_Message__c message) {
    return new Inbound_Message__c(
      Idempotency_Key__c = IdempotencyKey.of(message.Source__c, message.External_Message_Id__c),
      Source__c = message.Source__c,
      External_Message_Id__c = message.External_Message_Id__c,
      Message_Type__c = message.Message_Type__c,
      Payload__c = message.Payload__c,
      Payload_Ref__c = message.Payload_Ref__c,
      Payload_Size__c = message.Payload__c == null ? 0 : message.Payload__c.length(),
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
