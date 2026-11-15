/**
 * @description Selects `Inbound_Message__c` in user mode (apex-core-lib's `SObjectSelector`).
 * `inherited sharing`, because the store and later the processor job call it in their own
 * sharing context; the queries are user mode either way. The standard field list leaves out
 * `Payload__c`, which can be 131,072 characters: dispatch adds its own query for it.
 * @group Public API
 */
public inherited sharing class InboundMessagesSelector extends SObjectSelector implements IInboundMessagesSelector {
  /**
   * @description The type this selector queries.
   * @return `Inbound_Message__c.SObjectType`.
   */
  public override SObjectType getSObjectType() {
    return Inbound_Message__c.SObjectType;
  }

  /**
   * @description The identity and lifecycle fields.
   * @return The field list, without `Payload__c`.
   */
  public override List<SObjectField> getSObjectFieldList() {
    return new List<SObjectField>{
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
}
