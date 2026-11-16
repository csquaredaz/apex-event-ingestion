/**
 * @description The read-only view of a stored message that a handler receives (ADR 0004).
 * Handlers never see the `Inbound_Message__c` row, so they can't change its lifecycle fields,
 * and the store can change shape without breaking them. Immutable.
 * @group Public API
 */
public with sharing class InboundMessage {
  private final Id messageId;
  private final String idempotencyKey;
  private final String source;
  private final String externalMessageId;
  private final String messageType;
  private final String payload;
  private final String payloadRef;
  private final String correlationId;
  private final Datetime occurredAt;
  private final Integer attempt;

  private InboundMessage(Inbound_Message__c row, String payload) {
    messageId = row.Id;
    idempotencyKey = row.Idempotency_Key__c;
    source = row.Source__c;
    externalMessageId = row.External_Message_Id__c;
    messageType = row.Message_Type__c;
    this.payload = payload;
    payloadRef = row.Payload_Ref__c;
    correlationId = row.Correlation_Id__c;
    occurredAt = row.Occurred_At__c;
    attempt = (row.Attempts__c == null ? 0 : row.Attempts__c.intValue()) + 1;
  }

  /**
   * @description Builds the view of a stored row. Handler tests can pass an unsaved row with a
   * `FakeId`.
   * @param row The row, queried with its payload.
   * @return The message.
   * @throws IllegalArgumentException If the row is null.
   */
  public static InboundMessage fromRecord(Inbound_Message__c row) {
    return fromRecord(row, row?.Payload__c);
  }

  /**
   * @description Builds the view of a stored row with a payload loaded from elsewhere: dispatch
   * passes a claimed payload's text here (ADR 0008).
   * @param row The row.
   * @param resolvedPayload The payload text the handler sees, in place of `Payload__c`.
   * @return The message.
   * @throws IllegalArgumentException If the row is null.
   */
  public static InboundMessage fromRecord(Inbound_Message__c row, String resolvedPayload) {
    if (row == null) {
      throw new IllegalArgumentException('An InboundMessage needs an Inbound_Message__c row.');
    }
    return new InboundMessage(row, resolvedPayload);
  }

  /** @description @return The stored row's Id; every result for this message carries it. */
  public Id getMessageId() {
    return messageId;
  }

  /** @description @return The producer's key, `Source:ExternalId` (ADR 0003). */
  public String getIdempotencyKey() {
    return idempotencyKey;
  }

  /** @description @return The producing system. */
  public String getSource() {
    return source;
  }

  /** @description @return The producer's message Id. */
  public String getExternalMessageId() {
    return externalMessageId;
  }

  /** @description @return The type the message was routed by. */
  public String getMessageType() {
    return messageType;
  }

  /**
   * @description The payload as the producer sent it, usually JSON: inline, or the claimed file's
   * text, which dispatch loads before the handler runs (ADR 0008).
   * @return The payload; may be null.
   */
  public String getPayload() {
    return payload;
  }

  /** @description @return The claimed `ContentVersion` Id when the payload came by claim check, else null. */
  public String getPayloadRef() {
    return payloadRef;
  }

  /** @description @return The producer's correlation Id, for logs; may be null. */
  public String getCorrelationId() {
    return correlationId;
  }

  /** @description @return When the producer says the event happened; may be null. */
  public Datetime getOccurredAt() {
    return occurredAt;
  }

  /** @description @return Which attempt this is: 1 the first time, 2 on the first retry. */
  public Integer getAttempt() {
    return attempt;
  }

  /**
   * @description The stale-update guard (ADR 0005). Messages arrive in no order, so before
   * applying one, compare it with the time the target record was last changed by a message.
   * Equal times are not stale. When either time is unknown nothing can be proven, so it isn't.
   * @param lastApplied When the change already on the target happened.
   * @return True if this message happened strictly before `lastApplied` and should be skipped.
   */
  public Boolean isOlderThan(Datetime lastApplied) {
    return occurredAt != null && lastApplied != null && occurredAt < lastApplied;
  }
}
