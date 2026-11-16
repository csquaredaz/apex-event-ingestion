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

  @IsTest
  static void selectWithPayloadByIds_storedRows_includesThePayloadForThatQueryOnly() {
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    System.runAs(processor) {
      List<Inbound_Message__c> rows = new List<Inbound_Message__c>{ row('ORD-1'), row('ORD-2') };
      insert as user rows;
      InboundMessagesSelector selector = new InboundMessagesSelector();

      Test.startTest();
      List<Inbound_Message__c> found = selector.selectWithPayloadByIds(new Set<Id>{ rows[0].Id });
      Test.stopTest();

      Assert.areEqual(1, found.size(), 'Only the requested Id');
      Assert.areEqual(rows[0].Payload__c, found[0].Payload__c, 'The payload is selected');
      Assert.areEqual(MessageStatuses.RECEIVED, found[0].Status__c, 'Standard fields too');
      Assert.isFalse(selector.buildSoql('Id IN :ids').contains('Payload__c'), 'Later queries leave it out again');
    }
  }

  @IsTest
  static void selectWithPayloadByIds_nullOrEmpty_returnsNothingWithoutQuerying() {
    InboundMessagesSelector selector = new InboundMessagesSelector();

    Assert.areEqual(0, selector.selectWithPayloadByIds(null).size(), 'Null Ids');
    Assert.areEqual(0, selector.selectWithPayloadByIds(new Set<Id>()).size(), 'Empty Ids');
    Assert.areEqual(0, Limits.getQueries(), 'No SOQL spent');
  }

  @IsTest
  static void buildClaimSoql_always_locksWithABoundLimitAndNoOrderBy() {
    String soql = new InboundMessagesSelector().buildClaimSoql();

    Assert.isTrue(soql.startsWith('SELECT Id, Name, Idempotency_Key__c,'), soql);
    Assert.isTrue(soql.contains('Attempts__c'), 'The lifecycle needs the attempt count');
    Assert.isFalse(soql.contains('Payload__c'), 'Dispatch loads payloads separately');
    Assert.isFalse(soql.contains('ORDER BY'), 'Rejected by the platform with FOR UPDATE');
    Assert.isTrue(soql.endsWith(' LIMIT :maxRows FOR UPDATE'), soql);
  }

  @IsTest
  static void selectClaimable_mixedStatuses_returnsReceivedAndDueFailedUpToTheLimit() {
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    System.runAs(processor) {
      Datetime now = Datetime.now();
      List<Inbound_Message__c> rows = new List<Inbound_Message__c>{
        row('RECEIVED'),
        row('FAILED-DUE'),
        row('FAILED-LATER'),
        row('PROCESSED'),
        row('DEAD')
      };
      rows[1].Status__c = MessageStatuses.FAILED;
      rows[1].Next_Attempt_At__c = now.addMinutes(-1);
      rows[2].Status__c = MessageStatuses.FAILED;
      rows[2].Next_Attempt_At__c = now.addMinutes(5);
      rows[3].Status__c = MessageStatuses.PROCESSED;
      rows[4].Status__c = MessageStatuses.DEAD;
      insert as user rows;
      InboundMessagesSelector selector = new InboundMessagesSelector();

      Test.startTest();
      List<Inbound_Message__c> claimed = selector.selectClaimable(now, 200);
      List<Inbound_Message__c> limited = selector.selectClaimable(now, 1);
      Test.stopTest();

      Set<String> keys = new Set<String>();
      for (Inbound_Message__c message : claimed) {
        keys.add(message.External_Message_Id__c);
      }
      Assert.areEqual(new Set<String>{ 'RECEIVED', 'FAILED-DUE' }, keys, 'Only what is due');
      Assert.areEqual(1, limited.size(), 'The limit is bound');
    }
  }

  @IsTest
  static void selectClaimable_userWithoutAccess_throwsQueryException() {
    User outsider = EventIngestionTestFactory.minimumAccessUser(null);
    System.runAs(outsider) {
      try {
        new InboundMessagesSelector().selectClaimable(Datetime.now(), 10);
        Assert.fail('Expected QueryException');
      } catch (QueryException e) {
        Assert.isNotNull(e.getMessage(), 'User mode refuses the claim');
      }
    }
  }

  @IsTest
  static void selectClaimable_invalidArguments_throwsIllegalArgumentException() {
    InboundMessagesSelector selector = new InboundMessagesSelector();
    Integer rejected = 0;
    for (Integer maxRows : new List<Integer>{ 0, 201, null }) {
      try {
        selector.selectClaimable(Datetime.now(), maxRows);
      } catch (IllegalArgumentException e) {
        rejected++;
      }
    }
    try {
      selector.selectClaimable(null, 10);
    } catch (IllegalArgumentException e) {
      rejected++;
    }
    Assert.areEqual(4, rejected, 'Out-of-range limits and a null time are rejected');
    Assert.areEqual(0, Limits.getQueries(), 'No SOQL spent');
  }

  @IsTest
  static void selectDue_mixedStatusesAndAges_returnsWhatWasDueByTheTime() {
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    Datetime now = Datetime.now();
    List<Inbound_Message__c> rows = new List<Inbound_Message__c>{
      row('RECEIVED-OLD'),
      row('RECEIVED-NEW'),
      row('FAILED-OVERDUE'),
      row('FAILED-RECENT'),
      row('FAILED-LATER'),
      row('PROCESSED-OLD')
    };
    rows[2].Status__c = MessageStatuses.FAILED;
    rows[2].Next_Attempt_At__c = now.addMinutes(-40);
    rows[3].Status__c = MessageStatuses.FAILED;
    rows[3].Next_Attempt_At__c = now.addMinutes(-5);
    rows[4].Status__c = MessageStatuses.FAILED;
    rows[4].Next_Attempt_At__c = now.addMinutes(5);
    rows[5].Status__c = MessageStatuses.PROCESSED;
    insert as system rows;
    Test.setCreatedDate(rows[0].Id, now.addMinutes(-40));
    Test.setCreatedDate(rows[5].Id, now.addMinutes(-40));

    System.runAs(processor) {
      InboundMessagesSelector selector = new InboundMessagesSelector();
      Test.startTest();
      Set<Id> dueBefore = new Map<Id, Inbound_Message__c>(selector.selectDue(now.addMinutes(-30), 200)).keySet();
      Set<Id> dueNow = new Map<Id, Inbound_Message__c>(selector.selectDue(now, 200)).keySet();
      List<Inbound_Message__c> limited = selector.selectDue(now, 1);
      Test.stopTest();

      Assert.areEqual(new Set<Id>{ rows[0].Id, rows[2].Id }, dueBefore, 'Due for over 30 minutes');
      Assert.areEqual(new Set<Id>{ rows[0].Id, rows[1].Id, rows[2].Id, rows[3].Id }, dueNow, 'Due now');
      Assert.areEqual(1, limited.size(), 'The limit is bound');
    }
  }

  @IsTest
  static void selectDue_sweeperPermissionSet_readsOnlyTheFieldsItNeeds() {
    User sweeper = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.SWEEPER);
    Inbound_Message__c message = row('RECEIVED');
    insert as system message;

    System.runAs(sweeper) {
      List<Inbound_Message__c> due = new InboundMessagesSelector().selectDue(Datetime.now().addMinutes(1), 10);

      Assert.areEqual(1, due.size(), 'View All shows a message another user owns');
      Assert.areEqual(MessageStatuses.RECEIVED, due[0].Status__c, 'Status is readable');
      Assert.isNotNull(due[0].CreatedDate, 'CreatedDate is selected');
    }
  }

  @IsTest
  static void selectDue_invalidArguments_throwsIllegalArgumentException() {
    InboundMessagesSelector selector = new InboundMessagesSelector();
    Integer rejected = 0;
    for (Integer maxRows : new List<Integer>{ 0, 201, null }) {
      try {
        selector.selectDue(Datetime.now(), maxRows);
      } catch (IllegalArgumentException e) {
        rejected++;
      }
    }
    try {
      selector.selectDue(null, 10);
    } catch (IllegalArgumentException e) {
      rejected++;
    }
    Assert.areEqual(4, rejected, 'Out-of-range limits and a null time are rejected');
    Assert.areEqual(0, Limits.getQueries(), 'No SOQL spent');
  }
}
