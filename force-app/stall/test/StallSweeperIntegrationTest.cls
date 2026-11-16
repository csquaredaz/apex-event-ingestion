/**
 * @description Integration tests for the stall sweep with real rows, as a Minimum Access user who
 * holds only `Event_Ingestion_Sweeper`: the real selector reads messages another user owns, the wake
 * event is published and delivered through `ProcessorWakeEventTrigger`, and the processor queue and
 * alert sink are mocked at the edge.
 *
 * Subject:  StallSweeperSchedulable → StallDetector → InboundMessagesSelector.selectDue → wake event
 * Mocks:    IProcessorQueue, IAlertSink, ILogger (RecordingLogger)
 * Bulk:     200 stalled messages → 1 SOQL, 1 wake, 1 alert
 * Negative: only fresh messages (wake, no alert); nothing due; a user without the permission set
 *           (QueryException); a user who can read but not publish (AsyncException)
 */
@IsTest
private class StallSweeperIntegrationTest {
  private static Mocks queueMock;
  private static Mocks alertMock;

  private static void useMocks() {
    queueMock = new Mocks();
    Application.Service.setMock(IProcessorQueue.class, queueMock.stub(IProcessorQueue.class));
    alertMock = new Mocks();
    Application.Service.setMock(IAlertSink.class, alertMock.stub(IAlertSink.class));
    Application.Service.setMock(ILogger.class, new RecordingLogger());
  }

  /** Inserted by the test user, so the sweeper user owns none of them. */
  private static List<Inbound_Message__c> store(Integer count, Integer ageMinutes) {
    List<Inbound_Message__c> rows = EventIngestionTestFactory.messages(count);
    for (Inbound_Message__c row : rows) {
      row.Idempotency_Key__c = IdempotencyKey.of(row.Source__c, row.External_Message_Id__c + '-' + ageMinutes);
      row.External_Message_Id__c += '-' + ageMinutes;
    }
    insert as system rows;
    for (Inbound_Message__c row : rows) {
      Test.setCreatedDate(row.Id, Datetime.now().addMinutes(-ageMinutes));
    }
    return rows;
  }

  private static void sweepAs(User sweeper) {
    System.runAs(sweeper) {
      Test.startTest();
      new StallSweeperSchedulable().execute(null);
      Test.stopTest();
    }
    Test.getEventBus().deliver();
  }

  @IsTest
  static void sweep_200StalledMessagesOwnedByAnotherUser_wakesProcessingOnceAndAlerts() {
    User sweeper = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.SWEEPER);
    List<Inbound_Message__c> stalled = store(200, 45);
    store(1, 0);
    useMocks();

    sweepAs(sweeper);

    queueMock.verify('enqueue', 1);
    alertMock.verify('send', 1);
    Alert sent = ((List<Alert>) alertMock.argumentsOf('send', 0)[0])[0];
    Assert.areEqual('200 or more inbound message(s) stalled', sent.title, 'Read through View All');
    Assert.isTrue(sent.detail.contains(String.valueOf(stalled[0].Id)), 'Oldest Id first: ' + sent.detail);
  }

  @IsTest
  static void sweep_failedMessagePastItsRetry_countsAsStalled() {
    User sweeper = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.SWEEPER);
    List<Inbound_Message__c> rows = store(2, 0);
    rows[0].Status__c = MessageStatuses.FAILED;
    rows[0].Next_Attempt_At__c = Datetime.now().addMinutes(-31);
    rows[1].Status__c = MessageStatuses.FAILED;
    rows[1].Next_Attempt_At__c = Datetime.now().addMinutes(20);
    update as system rows;
    useMocks();

    sweepAs(sweeper);

    Alert sent = ((List<Alert>) alertMock.argumentsOf('send', 0)[0])[0];
    Assert.areEqual('1 inbound message(s) stalled', sent.title, 'Only the overdue retry');
    Assert.isTrue(sent.detail.endsWith(String.valueOf(rows[0].Id)), sent.detail);
  }

  @IsTest
  static void sweep_onlyFreshMessages_wakesProcessingWithoutAlerting() {
    User sweeper = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.SWEEPER);
    store(3, 5);
    useMocks();

    sweepAs(sweeper);

    Assert.areEqual(1, queueMock.callCount('enqueue'), 'Due, so processing was requested');
    Assert.areEqual(0, alertMock.callCount('send'), 'Not stalled yet');
  }

  @IsTest
  static void sweep_nothingDue_doesNotWakeProcessing() {
    User sweeper = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.SWEEPER);
    List<Inbound_Message__c> rows = store(2, 60);
    rows[0].Status__c = MessageStatuses.PROCESSED;
    rows[1].Status__c = MessageStatuses.DEAD;
    update as system rows;
    useMocks();

    sweepAs(sweeper);

    Assert.areEqual(0, queueMock.callCount('enqueue'), 'Terminal messages are not due');
    Assert.areEqual(0, alertMock.callCount('send'), 'Nothing stalled');
  }

  @IsTest
  static void sweep_userWithoutThePermissionSet_throwsQueryException() {
    User outsider = EventIngestionTestFactory.minimumAccessUser(null);
    store(1, 60);
    useMocks();

    System.runAs(outsider) {
      try {
        new StallSweeperSchedulable().execute(null);
        Assert.fail('Expected QueryException');
      } catch (QueryException e) {
        Assert.isNotNull(e.getMessage(), 'User mode refuses the read');
      }
    }
    alertMock.verify('send', 0);
  }

  @IsTest
  static void sweep_userWhoCanReadButNotPublish_throwsAsyncException() {
    User viewer = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.VIEWER);
    store(1, 5);
    useMocks();

    System.runAs(viewer) {
      try {
        new StallSweeperSchedulable().execute(null);
        Assert.fail('Expected AsyncException');
      } catch (AsyncException e) {
        Assert.isTrue(e.getMessage().startsWith('Processor_Wake_Event__e was not published'), e.getMessage());
      }
    }
  }
}
