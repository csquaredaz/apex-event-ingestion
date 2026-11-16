/**
 * @description Integration tests for intake: real `Inbound_Message_Event__e` publishes delivered
 * with `Test.getEventBus().deliver()`, through `InboundMessageEventTrigger`, apex-core-lib's
 * `TriggerDispatcher` and the bound domain, into the real store, and on to the processor job.
 * Stored rows are read `WITH SYSTEM_MODE`.
 *
 * Subject:  InboundMessageEventTrigger → InboundMessageEventsDomain → MessageStore → MessageProcessorJob
 * Mocks:    IMessageRoutesSelector (no routes); IProcessorQueue in the checkpoint test
 * Bulk:     200 events with one repeat → 200 stored once each, processed in one job
 * Negative: a publisher without Event_Ingestion_Publisher; more events than the intake batch; a
 *           store failure redelivered by the event bus
 */
@IsTest
private class InboundMessageIntakeIntegrationTest {
  private static final String PUBLISHER = 'Event_Ingestion_Publisher';

  private static void useNoRoutes() {
    Application.Service.setMock(
      IMessageRoutesSelector.class,
      new Mocks()
        .stubReturn('selectActiveByMessageTypes', new List<Message_Route__mdt>())
        .stub(IMessageRoutesSelector.class)
    );
  }

  private static List<Inbound_Message_Event__e> events(Integer count) {
    List<Inbound_Message_Event__e> events = new List<Inbound_Message_Event__e>();
    for (Integer i = 0; i < count; i++) {
      events.add(
        EventIngestionTestFactory.event(EventIngestionTestFactory.SOURCE, 'ORD-' + String.valueOf(i).leftPad(4, '0'))
      );
    }
    return events;
  }

  private static Integer storedCount() {
    return [SELECT COUNT() FROM Inbound_Message__c WITH SYSTEM_MODE];
  }

  @IsTest
  static void publish_200EventsWithARepeat_storesEachOnceAndProcessesThem() {
    useNoRoutes();
    User publisher = EventIngestionTestFactory.minimumAccessUser(PUBLISHER);
    List<Inbound_Message_Event__e> published = events(200);
    published.add(published[0].clone());

    System.runAs(publisher) {
      Test.startTest();
      List<Database.SaveResult> saves = EventBus.publish(published);
      Test.getEventBus().deliver();
      Test.stopTest();
      Assert.isTrue(saves[0].isSuccess(), 'Published: ' + saves[0].getErrors());
    }

    List<Inbound_Message__c> stored = [
      SELECT Idempotency_Key__c, Status__c, Attempts__c, Last_Error__c, Payload__c
      FROM Inbound_Message__c
      WITH SYSTEM_MODE
      ORDER BY Idempotency_Key__c
    ];
    Assert.areEqual(200, stored.size(), 'The repeat is stored once');
    Assert.areEqual('erp:ORD-0000', stored[0].Idempotency_Key__c, 'Keyed by source and Id');
    Assert.areEqual(published[0].Payload__c, stored[0].Payload__c, 'Payload carried through');
    for (Inbound_Message__c message : stored) {
      Assert.areEqual(MessageStatuses.DEAD, message.Status__c, 'The job ran: no route is fatal');
      Assert.areEqual(1, message.Attempts__c, 'One attempt');
    }
    Assert.isTrue(stored[0].Last_Error__c.contains('No active Message_Route__mdt'), stored[0].Last_Error__c);
  }

  @IsTest
  static void publish_withoutPublisherPermission_isRefusedAndStoresNothing() {
    User producer = EventIngestionTestFactory.minimumAccessUser(null);

    System.runAs(producer) {
      Test.startTest();
      Database.SaveResult save = EventBus.publish(events(1)[0]);
      Test.getEventBus().deliver();
      Test.stopTest();
      Assert.isFalse(save.isSuccess(), 'EventBus.publish checks Create on the event');
      Assert.areEqual(
        StatusCode.CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY,
        save.getErrors()[0].getStatusCode(),
        save.getErrors()[0].getMessage()
      );
    }
    Assert.areEqual(0, storedCount(), 'Nothing reached the store');
  }

  @IsTest
  static void publish_moreEventsThanTheIntakeBatch_resumesFromTheCheckpointOnTheNextDelivery() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Intake_Batch_Size__c = 2);
    Application.Service.setMock(IProcessorQueue.class, new Mocks().stub(IProcessorQueue.class));

    Test.startTest();
    EventBus.publish(events(3));
    Test.getEventBus().deliver();
    Integer afterFirst = storedCount();
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.areEqual(2, afterFirst, 'The first run takes the intake batch');
    Assert.areEqual(3, storedCount(), 'The next run resumes after the checkpoint');
  }

  @IsTest
  static void publish_storeFails_isRedeliveredWithTheRetryCountUntilItSucceeds() {
    RecordingLogger logger = new RecordingLogger();
    Application.Service.setMock(ILogger.class, logger);
    Application.Service.setMock(IProcessorQueue.class, new Mocks().stub(IProcessorQueue.class));
    Application.Service.setMock(
      IMessageStore.class,
      new Mocks().stubThrow('append', new MessageStoreException('Not yet')).stub(IMessageStore.class)
    );

    Test.startTest();
    EventBus.publish(events(1));
    Test.getEventBus().deliver();
    Test.getEventBus().deliver();
    Application.Service.setMock(IMessageStore.class, new MessageStore());
    Test.getEventBus().deliver();
    Test.stopTest();

    List<RecordingLogger.Entry> errors = logger.entries(LoggingLevel.ERROR);
    Assert.areEqual(2, errors.size(), 'Two failed runs');
    Assert.isTrue(errors[0].message.startsWith('Intake failed on attempt 1 of 10'), errors[0].message);
    Assert.isTrue(errors[1].message.startsWith('Intake failed on attempt 2 of 10'), errors[1].message);
    Assert.areEqual(1, storedCount(), 'The third delivery stores it');
  }
}
