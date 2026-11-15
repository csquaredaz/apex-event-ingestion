/**
 * @description Selects `Inbound_Message__c` in user mode (apex-core-lib's `SObjectSelector`).
 * `inherited sharing`, because the store and later the processor job call it in their own
 * sharing context; the queries are user mode either way. The standard field list leaves out
 * `Payload__c`, which can be 131,072 characters; only `selectWithPayloadByIds`, used by dispatch,
 * adds it.
 * @group Public API
 */
public inherited sharing class InboundMessagesSelector extends SObjectSelector implements IInboundMessagesSelector {
  // True only for the duration of selectWithPayloadByIds, so the base class's query builder
  // includes the payload; every other query leaves it out.
  private Boolean includePayload = false;

  /**
   * @description The type this selector queries.
   * @return `Inbound_Message__c.SObjectType`.
   */
  public override SObjectType getSObjectType() {
    return Inbound_Message__c.SObjectType;
  }

  /**
   * @description The identity and lifecycle fields.
   * @return The field list; `Payload__c` only while `selectWithPayloadByIds` runs.
   */
  public override List<SObjectField> getSObjectFieldList() {
    List<SObjectField> fields = new List<SObjectField>{
      Inbound_Message__c.Name,
      Inbound_Message__c.Idempotency_Key__c,
      Inbound_Message__c.Source__c,
      Inbound_Message__c.External_Message_Id__c,
      Inbound_Message__c.Message_Type__c,
      Inbound_Message__c.Status__c,
      Inbound_Message__c.Attempts__c,
      Inbound_Message__c.Next_Attempt_At__c,
      Inbound_Message__c.Locked_Until__c,
      Inbound_Message__c.Correlation_Id__c,
      Inbound_Message__c.Occurred_At__c,
      Inbound_Message__c.Processed_At__c
    };
    if (includePayload) {
      fields.add(Inbound_Message__c.Payload__c);
    }
    return fields;
  }

  /**
   * @description See `IInboundMessagesSelector.selectByIdempotencyKeys`. Limits: 1 SOQL, none for
   * an empty set; the key is a unique external Id, so the filter is indexed.
   * @param keys Idempotency keys.
   * @return The exact matches.
   */
  public List<Inbound_Message__c> selectByIdempotencyKeys(Set<String> keys) {
    List<Inbound_Message__c> matches = new List<Inbound_Message__c>();
    if (keys == null || keys.isEmpty()) {
      return matches;
    }
    List<Inbound_Message__c> rows = (List<Inbound_Message__c>) query(
      'Idempotency_Key__c IN :keys',
      new Map<String, Object>{ 'keys' => keys }
    );
    // Set<String>.contains is case-sensitive, unlike the SOQL IN above.
    for (Inbound_Message__c row : rows) {
      if (keys.contains(row.Idempotency_Key__c)) {
        matches.add(row);
      }
    }
    return matches;
  }

  /**
   * @description See `IInboundMessagesSelector.selectWithPayloadByIds`. Limits: 1 SOQL, none for
   * an empty set.
   * @param ids Message Ids.
   * @return The messages with their payloads.
   */
  public List<Inbound_Message__c> selectWithPayloadByIds(Set<Id> ids) {
    if (ids == null || ids.isEmpty()) {
      return new List<Inbound_Message__c>();
    }
    includePayload = true;
    try {
      return (List<Inbound_Message__c>) query('Id IN :ids', new Map<String, Object>{ 'ids' => ids });
    } finally {
      includePayload = false;
    }
  }
}
