/**
 * @description Tests for `InboundMessage`, all in memory.
 *
 * Subject:  InboundMessage.fromRecord (inline and resolved payloads), getAttempt, isOlderThan
 * Mocks:    none
 * Bulk:     not applicable (a value object)
 * Negative: a null row; unknown times on either side of the stale guard
 */
@IsTest
private class InboundMessageTest {
  @IsTest
  static void fromRecord_row_copiesEveryProducerField() {
    Inbound_Message__c row = EventIngestionTestFactory.message('erp', 'ORD-1');
    row.Id = FakeId.generate(Inbound_Message__c.SObjectType);
    row.Idempotency_Key__c = 'erp:ORD-1';

    InboundMessage message = InboundMessage.fromRecord(row);

    Assert.areEqual(row.Id, message.getMessageId(), 'Id');
    Assert.areEqual('erp:ORD-1', message.getIdempotencyKey(), 'Key');
    Assert.areEqual('erp', message.getSource(), 'Source');
    Assert.areEqual('ORD-1', message.getExternalMessageId(), 'External Id');
    Assert.areEqual(EventIngestionTestFactory.MESSAGE_TYPE, message.getMessageType(), 'Type');
    Assert.areEqual(row.Payload__c, message.getPayload(), 'Payload');
    Assert.areEqual('corr-ORD-1', message.getCorrelationId(), 'Correlation Id');
    Assert.areEqual(row.Occurred_At__c, message.getOccurredAt(), 'Occurred at');
  }

  @IsTest
  static void fromRecord_laterChangeToTheRow_doesNotChangeTheMessage() {
    Inbound_Message__c row = EventIngestionTestFactory.message('erp', 'ORD-1');
    InboundMessage message = InboundMessage.fromRecord(row);

    row.Payload__c = 'changed';

    Assert.areNotEqual('changed', message.getPayload(), 'The message is a snapshot');
  }

  @IsTest
  static void getAttempt_storedAttempts_isTheNextAttemptNumber() {
    Inbound_Message__c fresh = EventIngestionTestFactory.message('erp', 'ORD-1');
    Inbound_Message__c retried = EventIngestionTestFactory.message('erp', 'ORD-2');
    retried.Attempts__c = 2;

    Assert.areEqual(1, InboundMessage.fromRecord(fresh).getAttempt(), 'No attempts stored: first attempt');
    Assert.areEqual(3, InboundMessage.fromRecord(retried).getAttempt(), 'Two failed attempts: third attempt');
  }

  @IsTest
  static void fromRecord_null_throwsIllegalArgument() {
    try {
      InboundMessage.fromRecord(null);
      Assert.fail('Expected IllegalArgumentException');
    } catch (IllegalArgumentException e) {
      Assert.isTrue(e.getMessage().contains('Inbound_Message__c'), e.getMessage());
    }
  }

  @IsTest
  static void isOlderThan_comparesOccurrenceTimes() {
    Inbound_Message__c row = EventIngestionTestFactory.message('erp', 'ORD-1');
    InboundMessage message = InboundMessage.fromRecord(row);
    Datetime occurred = row.Occurred_At__c;

    Assert.isTrue(message.isOlderThan(occurred.addSeconds(1)), 'A later change is already applied: stale');
    Assert.isFalse(message.isOlderThan(occurred), 'Equal times are not stale');
    Assert.isFalse(message.isOlderThan(occurred.addSeconds(-1)), 'An earlier change: apply this one');
    Assert.isFalse(message.isOlderThan(null), 'Nothing applied yet: not stale');
  }

  @IsTest
  static void isOlderThan_unknownOccurrence_isNeverStale() {
    Inbound_Message__c row = EventIngestionTestFactory.message('erp', 'ORD-1');
    row.Occurred_At__c = null;

    Assert.isFalse(InboundMessage.fromRecord(row).isOlderThan(Datetime.now()), 'Unknown time proves nothing');
  }

  @IsTest
  static void fromRecord_resolvedPayload_replacesTheInlineOneAndKeepsTheClaim() {
    Inbound_Message__c row = EventIngestionTestFactory.message('erp', 'ORD-1');
    row.Payload__c = null;
    row.Payload_Ref__c = FakeId.generate(ContentVersion.SObjectType);

    InboundMessage message = InboundMessage.fromRecord(row, '{"from":"file"}');

    Assert.areEqual('{"from":"file"}', message.getPayload(), 'The resolved text');
    Assert.areEqual(row.Payload_Ref__c, message.getPayloadRef(), 'The claim');
    Assert.isNull(
      InboundMessage.fromRecord(EventIngestionTestFactory.message('erp', 'ORD-2')).getPayloadRef(),
      'Inline: no claim'
    );
  }

  @IsTest
  static void fromRecord_nullRowWithPayload_throws() {
    try {
      InboundMessage.fromRecord(null, '{}');
      Assert.fail('Expected IllegalArgumentException');
    } catch (IllegalArgumentException e) {
      Assert.isTrue(e.getMessage().contains('Inbound_Message__c'), e.getMessage());
    }
  }
}
