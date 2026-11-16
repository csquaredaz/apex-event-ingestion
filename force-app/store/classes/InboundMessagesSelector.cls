/**
 * @description Selects `Inbound_Message__c` in user mode (apex-core-lib's `SObjectSelector`).
 * `inherited sharing`, because the store and later the processor job call it in their own
 * sharing context; the queries are user mode either way. The standard field list leaves out
 * `Payload__c`, which can be 131,072 characters; only `selectWithPayloadByIds`, used by dispatch,
 * adds it.
 * @group Public API
 */
public inherited sharing class InboundMessagesSelector extends SObjectSelector implements IInboundMessagesSelector {
  // The most messages one claim takes: a dispatch batch must stay bulk-safe at 200 (ADR 0004).
  private static final Integer MAX_CLAIM = 200;

  private static final String DUE_SOQL =
    'SELECT Id, Status__c, Next_Attempt_At__c, CreatedDate FROM Inbound_Message__c' +
    ' WHERE (Status__c = :received AND CreatedDate <= :dueBy)' +
    ' OR (Status__c = :failed AND Next_Attempt_At__c <= :dueBy)' +
    ' ORDER BY Id LIMIT :maxRows';

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
      Inbound_Message__c.Payload_Ref__c,
      Inbound_Message__c.Payload_Size__c,
      Inbound_Message__c.Status__c,
      Inbound_Message__c.Attempts__c,
      Inbound_Message__c.Next_Attempt_At__c,
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

  /**
   * @description See `IInboundMessagesSelector.selectClaimable`. Limits: 1 SOQL. The base class's
   * `query` always appends `ORDER BY`, which the platform rejects with `FOR UPDATE` ("Explicit
   * ORDER BY not allowed when locking rows"). This method builds the same statement, swaps the
   * ordering for a bound `LIMIT` and `FOR UPDATE`, and runs it in user mode with binds only.
   * @param now The time a `Failed` message must be due by.
   * @param maxRows The most rows to claim, from 1 to 200.
   * @return The claimed messages.
   * @throws IllegalArgumentException If `now` is null or `maxRows` is outside 1 to 200.
   */
  public List<Inbound_Message__c> selectClaimable(Datetime now, Integer maxRows) {
    if (now == null || maxRows == null || maxRows < 1 || maxRows > MAX_CLAIM) {
      throw new IllegalArgumentException('selectClaimable needs a time and 1 to ' + MAX_CLAIM + ' rows.');
    }
    return (List<Inbound_Message__c>) Database.queryWithBinds(
      buildClaimSoql(),
      new Map<String, Object>{
        'received' => MessageStatuses.RECEIVED,
        'failed' => MessageStatuses.FAILED,
        'now' => now,
        'maxRows' => maxRows
      },
      AccessLevel.USER_MODE
    );
  }

  /**
   * @description See `IInboundMessagesSelector.selectDue`. Limits: 1 SOQL, at most 200 rows. The
   * statement is written here rather than built from the standard field list, so the sweeper's
   * permission set needs read access to only the fields it filters on.
   * @param dueBy The latest time a message became due.
   * @param maxRows The most rows to return, from 1 to 200.
   * @return The due messages, with `Id`, `Status__c`, `Next_Attempt_At__c` and `CreatedDate`.
   * @throws IllegalArgumentException If `dueBy` is null or `maxRows` is outside 1 to 200.
   */
  public List<Inbound_Message__c> selectDue(Datetime dueBy, Integer maxRows) {
    if (dueBy == null || maxRows == null || maxRows < 1 || maxRows > MAX_CLAIM) {
      throw new IllegalArgumentException('selectDue needs a time and 1 to ' + MAX_CLAIM + ' rows.');
    }
    return (List<Inbound_Message__c>) Database.queryWithBinds(
      DUE_SOQL,
      new Map<String, Object>{
        'received' => MessageStatuses.RECEIVED,
        'failed' => MessageStatuses.FAILED,
        'dueBy' => dueBy,
        'maxRows' => maxRows
      },
      AccessLevel.USER_MODE
    );
  }

  /**
   * @description The claim statement, visible to tests so its shape can be asserted.
   * @return SOQL with the standard fields, the due filter, a bound limit and `FOR UPDATE`.
   */
  @TestVisible
  private String buildClaimSoql() {
    String soql = buildSoql('Status__c = :received OR (Status__c = :failed AND Next_Attempt_At__c <= :now)');
    return soql.substringBeforeLast(' ORDER BY ') + ' LIMIT :maxRows FOR UPDATE';
  }
}
