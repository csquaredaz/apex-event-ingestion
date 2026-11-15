/**
 * @description Tests for `InboundMessagesSelector`: the binding, the query shape, and the
 * case-sensitive key match, as a Minimum Access user with the Processor permission set (admins get
 * no field permissions on this package's fields).
 *
 * Subject:  InboundMessagesSelector.selectByIdempotencyKeys
 * Mocks:    none (real rows)
 * Bulk:     covered by MessageStoreIntegrationTest
 * Negative: null and empty keys, keys that differ only in case, a key that isn't stored
 */
@IsTest
private class InboundMessagesSelectorTest {
  private static Inbound_Message__c row(String externalMessageId) {
    Inbound_Message__c message = EventIngestionTestFactory.message('erp', externalMessageId);
    message.Idempotency_Key__c = IdempotencyKey.of('erp', externalMessageId);
    return message;
  }

  @IsTest
  static void binding_forInboundMessage_resolvesTheSelector() {
    Assert.isInstanceOfType(
      Application.Selector.newInstance(Inbound_Message__c.SObjectType),
      InboundMessagesSelector.class,
      'DI_Binding.Inbound_Messages_Selector'
    );
  }

  @IsTest
  static void buildSoql_keys_selectsIdentityAndLifecycleFieldsWithoutPayload() {
    String soql = new InboundMessagesSelector().buildSoql('Idempotency_Key__c IN :keys');

    Assert.isTrue(soql.startsWith('SELECT Id, Name, Idempotency_Key__c, Source__c,'), soql);
    Assert.isTrue(soql.endsWith('FROM Inbound_Message__c WHERE Idempotency_Key__c IN :keys ORDER BY Id'), soql);
    Assert.isFalse(soql.contains('Payload__c'), 'The large payload is not in the standard list');
  }

  @IsTest
  static void selectByIdempotencyKeys_keysDifferingInCase_returnsOnlyTheExactMatch() {
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    System.runAs(processor) {
      insert as user new List<Inbound_Message__c>{ row('ORD-1'), row('ord-1'), row('ORD-2') };

      Test.startTest();
      List<Inbound_Message__c> found = new InboundMessagesSelector()
        .selectByIdempotencyKeys(new Set<String>{ 'erp:ORD-1', 'erp:ORD-9' });
      Test.stopTest();

      Assert.areEqual(1, found.size(), 'SOQL matches both cases; the selector keeps the exact one');
      Assert.areEqual('erp:ORD-1', found[0].Idempotency_Key__c, 'Exact-case key');
      Assert.areEqual(MessageStatuses.RECEIVED, found[0].Status__c, 'Lifecycle fields are selected');
    }
  }

  @IsTest
  static void selectByIdempotencyKeys_nullOrEmpty_returnsNothingWithoutQuerying() {
    InboundMessagesSelector selector = new InboundMessagesSelector();

    Assert.areEqual(0, selector.selectByIdempotencyKeys(null).size(), 'Null keys');
    Assert.areEqual(0, selector.selectByIdempotencyKeys(new Set<String>()).size(), 'Empty keys');
    Assert.areEqual(0, Limits.getQueries(), 'No SOQL spent');
  }
}
