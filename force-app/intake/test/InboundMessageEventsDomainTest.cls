/**
 * @description Unit tests for `InboundMessageEventsDomain`, called directly with delivered-event
 * fixtures. The retry count and the checkpoint go through the domain's `@TestVisible` seams,
 * because `EventBus.TriggerContext` exists only in a real delivery.
 *
 * Subject:  InboundMessageEventsDomain.onAfterInsert
 * Mocks:    IMessageStore, IProcessorQueue (via MessageProcessing), IAlertSink, ILogger (RecordingLogger)
 * Bulk:     200 events → 1 append of 200 messages, 1 enqueue, no checkpoint
 * Negative: duplicates only, a rejection, a store failure (first and last retry), over the count
 *           and payload limits
 */
@IsTest
private class InboundMessageEventsDomainTest {
  private static Mocks storeMock;
  private static Mocks queueMock;
  private static Mocks alertMock;
  private static RecordingLogger logger;

  private static void useMocks(Mocks store) {
    storeMock = store;
    Application.Service.setMock(IMessageStore.class, storeMock.stub(IMessageStore.class));
    queueMock = new Mocks();
    Application.Service.setMock(IProcessorQueue.class, queueMock.stub(IProcessorQueue.class));
    alertMock = new Mocks();
    Application.Service.setMock(IAlertSink.class, alertMock.stub(IAlertSink.class));
    logger = new RecordingLogger();
    Application.Service.setMock(ILogger.class, logger);
    InboundMessageEventsDomain.recordedCheckpoints = new List<String>();
    InboundMessageEventsDomain.retriesOverride = 0;
  }

  private static List<AppendResult> accepted(Integer count) {
    List<AppendResult> results = new List<AppendResult>();
    for (Integer i = 0; i < count; i++) {
      results.add(AppendResult.accepted('erp:' + i, FakeId.generate(Inbound_Message__c.SObjectType)));
    }
    return results;
  }

  private static List<Inbound_Message__c> appended() {
    return (List<Inbound_Message__c>) storeMock.argumentsOf('append', 0)[0];
  }

  @IsTest
  static void onAfterInsert_200Events_appendsThemOnceAndEnqueuesProcessing() {
    useMocks(new Mocks().stubReturn('append', accepted(200)));
    List<Inbound_Message_Event__e> events = EventIngestionTestFactory.deliveredEvents(200);

    Test.startTest();
    new InboundMessageEventsDomain(events).onAfterInsert();
    Test.stopTest();

    storeMock.verify('append', 1);
    List<Inbound_Message__c> messages = appended();
    Assert.areEqual(200, messages.size(), 'Every event in one append');
    Inbound_Message__c first = messages[0];
    Assert.areEqual(events[0].Source__c, first.Source__c, 'Source copied');
    Assert.areEqual(events[0].External_Message_Id__c, first.External_Message_Id__c, 'Id copied');
    Assert.areEqual(events[0].Message_Type__c, first.Message_Type__c, 'Type copied');
    Assert.areEqual(events[0].Payload__c, first.Payload__c, 'Payload copied');
    Assert.areEqual(events[0].Correlation_Id__c, first.Correlation_Id__c, 'Correlation Id copied');
    Assert.areEqual(events[0].Occurred_At__c, first.Occurred_At__c, 'Occurrence time copied');
    Assert.isNull(first.Status__c, 'The store sets the lifecycle fields');
    Assert.areEqual(new List<Object>{ 0 }, queueMock.argumentsOf('enqueue', 0), 'Processing starts at once');
    Assert.areEqual(new List<String>(), InboundMessageEventsDomain.recordedCheckpoints, 'Nothing left behind');
    Assert.areEqual(1, logger.flushCount(), 'Flushed');
  }

  @IsTest
  static void onAfterInsert_onlyDuplicates_doesNotEnqueue() {
    useMocks(
      new Mocks()
        .stubReturn(
          'append',
          new List<AppendResult>{
            AppendResult.duplicate('erp:ORD-0000', FakeId.generate(Inbound_Message__c.SObjectType))
          }
        )
    );

    new InboundMessageEventsDomain(EventIngestionTestFactory.deliveredEvents(1)).onAfterInsert();

    queueMock.verify('enqueue', 0);
    Assert.areEqual(0, logger.entries(LoggingLevel.WARN).size(), 'A duplicate is not a problem');
  }

  @IsTest
  static void onAfterInsert_rejectedMessage_logsItsKeyOnlyAndStillEnqueuesTheRest() {
    useMocks(
      new Mocks()
        .stubReturn(
          'append',
          new List<AppendResult>{
            AppendResult.rejected(null, 'Source is blank: {"secret":"payload"}'),
            AppendResult.accepted('erp:ORD-0001', FakeId.generate(Inbound_Message__c.SObjectType)),
            AppendResult.rejected('erp:ORD-0002', 'REQUIRED_FIELD_MISSING: Message_Type__c')
          }
        )
    );

    new InboundMessageEventsDomain(EventIngestionTestFactory.deliveredEvents(3)).onAfterInsert();

    List<RecordingLogger.Entry> warnings = logger.entries(LoggingLevel.WARN);
    Assert.areEqual(2, warnings.size(), 'Two rejections');
    Assert.areEqual(
      'Inbound_Message_Event__e rejected and not retried: EventUuid uuid-0.',
      warnings[0].message,
      'Named by the event UUID when there is no key'
    );
    Assert.areEqual(
      'Inbound_Message_Event__e rejected and not retried: erp:ORD-0002.',
      warnings[1].message,
      'Named by its key'
    );
    Assert.isFalse(warnings[0].message.contains('secret'), 'No error text, which can quote the payload');
    queueMock.verify('enqueue', 1);
  }

  @IsTest
  static void onAfterInsert_moreEventsThanTheIntakeBatch_takesTheBatchAndCheckpointsItsLastEvent() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Intake_Batch_Size__c = 2);
    useMocks(new Mocks().stubReturn('append', accepted(2)));

    new InboundMessageEventsDomain(EventIngestionTestFactory.deliveredEvents(5)).onAfterInsert();

    Assert.areEqual(2, appended().size(), 'The intake batch size');
    Assert.areEqual('ORD-0001', appended()[1].External_Message_Id__c, 'In delivery order');
    Assert.areEqual(new List<String>{ '2' }, InboundMessageEventsDomain.recordedCheckpoints, 'After the second event');
  }

  @IsTest
  static void onAfterInsert_payloadsOverTheBudget_stopsBeforeTheBudgetButTakesAtLeastOne() {
    List<Inbound_Message_Event__e> events = EventIngestionTestFactory.deliveredEvents(3);
    Integer size = events[0].Payload__c.length();
    IngestionSettings.row = new Ingestion_Setting__mdt(Intake_Payload_Budget__c = size * 2);
    useMocks(new Mocks().stubReturn('append', accepted(2)));

    new InboundMessageEventsDomain(events).onAfterInsert();

    Assert.areEqual(2, appended().size(), 'Two payloads fit the budget, a third would not');
    Assert.areEqual(new List<String>{ '2' }, InboundMessageEventsDomain.recordedCheckpoints, 'The rest wait');

    IngestionSettings.row = new Ingestion_Setting__mdt(Intake_Payload_Budget__c = 1);
    useMocks(new Mocks().stubReturn('append', accepted(1)));

    new InboundMessageEventsDomain(events).onAfterInsert();

    Assert.areEqual(1, appended().size(), 'One oversized payload is still taken, so the stream moves');
  }

  @IsTest
  static void onAfterInsert_storeFails_asksForRedeliveryWithoutAlerting() {
    useMocks(new Mocks().stubThrow('append', new MessageStoreException('Assign Event_Ingestion_Processor.')));
    InboundMessageEventsDomain.retriesOverride = 2;

    try {
      new InboundMessageEventsDomain(EventIngestionTestFactory.deliveredEvents(3)).onAfterInsert();
      Assert.fail('Expected EventBus.RetryableException');
    } catch (EventBus.RetryableException e) {
      Assert.isTrue(e.getMessage().startsWith('Intake failed on attempt 3: MessageStoreException'), e.getMessage());
    }
    Assert.areEqual(1, logger.entries(LoggingLevel.ERROR).size(), 'Logged');
    alertMock.verify('send', 0);
    queueMock.verify('enqueue', 0);
    Assert.areEqual(new List<String>(), InboundMessageEventsDomain.recordedCheckpoints, 'The whole run returns');
  }

  @IsTest
  static void onAfterInsert_enqueueFails_asksForRedelivery() {
    useMocks(new Mocks().stubReturn('append', accepted(1)));
    queueMock.stubThrow('enqueue', new AsyncException('Too many queueable jobs'));

    try {
      new InboundMessageEventsDomain(EventIngestionTestFactory.deliveredEvents(1)).onAfterInsert();
      Assert.fail('Expected EventBus.RetryableException');
    } catch (EventBus.RetryableException e) {
      Assert.isTrue(e.getMessage().contains('AsyncException'), e.getMessage());
    }
  }

  @IsTest
  static void onAfterInsert_storeFailsOnTheLastRetry_raisesOneCriticalAlertAndStillAsksForRedelivery() {
    useMocks(new Mocks().stubThrow('append', new DmlException('UNABLE_TO_LOCK_ROW {"secret":"payload"}')));
    InboundMessageEventsDomain.retriesOverride = InboundMessageEventsDomain.FINAL_RETRY;

    try {
      new InboundMessageEventsDomain(EventIngestionTestFactory.deliveredEvents(4)).onAfterInsert();
      Assert.fail('Expected EventBus.RetryableException');
    } catch (EventBus.RetryableException e) {
      Assert.isTrue(e.getMessage().startsWith('Intake failed on attempt 10'), e.getMessage());
    }
    alertMock.verify('send', 1);
    Alert sent = ((List<Alert>) alertMock.argumentsOf('send', 0)[0])[0];
    Assert.areEqual(Alert.Severity.CRITICAL, sent.severity, 'Messages are at risk');
    Assert.areEqual('Intake failed on its last retry; 4 event(s) wait in a suspended trigger', sent.title, 'Counts');
    Assert.isFalse(sent.detail.contains('secret'), 'No exception text in the alert');
  }

  @IsTest
  static void constructor_buildsTheDomainForTheEventType() {
    IDomain domain = new InboundMessageEventsDomain.Constructor()
      .construct(EventIngestionTestFactory.deliveredEvents(1));

    Assert.isInstanceOfType(domain, InboundMessageEventsDomain.class, 'The bound domain');
    Assert.areEqual(
      Inbound_Message_Event__e.SObjectType,
      ((InboundMessageEventsDomain) domain).getSObjectType(),
      'Owns the intake event'
    );
  }

  @IsTest
  static void onAfterInsert_claimedEvent_passesTheClaimAndEachPublisherToTheStore() {
    useMocks(new Mocks().stubReturn('append', accepted(2)));
    List<Inbound_Message_Event__e> events = EventIngestionTestFactory.deliveredEvents(2);
    String ref = FakeId.generate(ContentVersion.SObjectType);
    events[1].Payload__c = null;
    events[1].Payload_Ref__c = ref;

    new InboundMessageEventsDomain(events).onAfterInsert();

    Assert.areEqual(ref, appended()[1].Payload_Ref__c, 'The claim is copied');
    Assert.isNull(appended()[0].Payload_Ref__c, 'An inline event has none');
    Assert.areEqual(
      new List<Id>{ UserInfo.getUserId(), UserInfo.getUserId() },
      storeMock.argumentsOf('append', 0)[1],
      'Each event\'s publisher, so the store checks the claim against it, not the Automated Process user'
    );
  }
}
