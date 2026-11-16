/**
 * @description Unit tests for `StallDetector` with a mocked selector. The wake event it publishes is
 * delivered by `Test.stopTest()` to `ProcessorWakeEventTrigger`, whose enqueue reaches a mocked
 * `IProcessorQueue`, so each test sees whether processing was requested.
 *
 * Subject:  StallDetector.sweep
 * Mocks:    IInboundMessagesSelector, IProcessorQueue, IAlertSink, ILogger (RecordingLogger)
 * Bulk:     200 stalled messages → 1 selector call, 1 wake, 1 alert naming "200 or more" and 10 Ids
 * Negative: nothing due (2 queries, no wake, no alert); a selector failure propagates; a null time
 */
@IsTest
private class StallDetectorTest {
  private static final Datetime NOW = Datetime.newInstanceGmt(2026, 11, 16, 12, 0, 0);

  private static Mocks selectorMock;
  private static Mocks queueMock;
  private static Mocks alertMock;
  private static RecordingLogger logger;

  private static void useMocks(List<Inbound_Message__c> due) {
    selectorMock = new Mocks().stubReturn('selectDue', due);
    Application.Selector.setMock(
      Inbound_Message__c.SObjectType,
      (ISelector) selectorMock.stub(IInboundMessagesSelector.class)
    );
    queueMock = new Mocks();
    Application.Service.setMock(IProcessorQueue.class, queueMock.stub(IProcessorQueue.class));
    alertMock = new Mocks();
    Application.Service.setMock(IAlertSink.class, alertMock.stub(IAlertSink.class));
    logger = new RecordingLogger();
    Application.Service.setMock(ILogger.class, logger);
  }

  private static List<Inbound_Message__c> rows(Integer count) {
    List<Inbound_Message__c> result = new List<Inbound_Message__c>();
    for (Integer i = 0; i < count; i++) {
      result.add(new Inbound_Message__c(Id = FakeId.generate(Inbound_Message__c.SObjectType)));
    }
    return result;
  }

  private static StallReport sweep() {
    Test.startTest();
    StallReport report = new StallDetector().sweep(NOW);
    Test.stopTest();
    return report;
  }

  @IsTest
  static void sweep_stalledMessages_requestsARunAndAlertsWithIdsOnly() {
    List<Inbound_Message__c> stalled = rows(3);
    useMocks(stalled);

    StallReport report = sweep();

    selectorMock.verify('selectDue', 1);
    Assert.areEqual(
      new List<Object>{ NOW.addMinutes(-IngestionSettings.DEFAULT_STALL_AFTER_MINUTES), StallReport.MAX_STALLED },
      selectorMock.argumentsOf('selectDue', 0),
      'Due for longer than the stall threshold, up to the cap'
    );
    Assert.isTrue(report.hasDueMessages(), 'Stalled messages are due');
    Assert.areEqual(3, report.getStalledIds().size(), 'Every stalled message');
    queueMock.verify('enqueue', 1);
    alertMock.verify('send', 1);
    Alert sent = ((List<Alert>) alertMock.argumentsOf('send', 0)[0])[0];
    Assert.areEqual(Alert.Severity.WARNING, sent.severity, 'A stall, not lost data');
    Assert.areEqual('3 inbound message(s) stalled', sent.title, 'Counted');
    Assert.isTrue(sent.detail.startsWith('Due since 2026-11-16 11:30 UTC or earlier'), sent.detail);
    Assert.isTrue(sent.detail.endsWith(stalled[0].Id + ', ' + stalled[1].Id + ', ' + stalled[2].Id), sent.detail);
    Assert.areEqual(StallDetector.class.getName(), sent.source, 'Named source');
    Assert.areEqual(
      'StallDetector: processing requested; 3 stalled.',
      logger.entries(LoggingLevel.INFO)[0].message,
      'Logged before the wake trigger logs its own line'
    );
  }

  @IsTest
  static void sweep_200StalledMessages_reportsTheCapAndNamesTheFirstTen() {
    List<Inbound_Message__c> stalled = rows(200);
    useMocks(stalled);

    StallReport report = sweep();

    Assert.isTrue(report.isCapped(), 'There may be more');
    Alert sent = ((List<Alert>) alertMock.argumentsOf('send', 0)[0])[0];
    Assert.areEqual('200 or more inbound message(s) stalled', sent.title, 'Capped count');
    Assert.isTrue(sent.detail.contains(String.valueOf(stalled[9].Id)), 'The tenth Id');
    Assert.isFalse(sent.detail.contains(String.valueOf(stalled[10].Id)), 'Not the eleventh');
    selectorMock.verify('selectDue', 1);
  }

  @IsTest
  static void sweep_nothingDue_neitherRequestsARunNorAlerts() {
    useMocks(new List<Inbound_Message__c>());

    StallReport report = sweep();

    selectorMock.verify('selectDue', 2);
    Assert.areEqual(new List<Object>{ NOW, 1 }, selectorMock.argumentsOf('selectDue', 1), 'Anything due now');
    Assert.isFalse(report.hasDueMessages(), 'Nothing due');
    queueMock.verify('enqueue', 0);
    alertMock.verify('send', 0);
    Assert.isTrue(logger.entries(LoggingLevel.INFO)[0].message.contains('nothing due'), 'Logged');
  }

  @IsTest
  static void sweep_customThreshold_usesTheSetting() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Stall_After_Minutes__c = 90);
    useMocks(new List<Inbound_Message__c>());

    StallReport report = sweep();

    Assert.areEqual(NOW.addMinutes(-90), report.getStalledBefore(), 'Ingestion_Setting__mdt.Stall_After_Minutes__c');
  }

  @IsTest
  static void sweep_selectorFails_propagatesWithoutWakingOrAlerting() {
    useMocks(null);
    selectorMock.stubThrow('selectDue', new QueryException('No access'));

    try {
      new StallDetector().sweep(NOW);
      Assert.fail('Expected QueryException');
    } catch (QueryException e) {
      Assert.areEqual('No access', e.getMessage(), 'The scheduled job fails visibly in Apex Jobs');
    }
    alertMock.verify('send', 0);
  }

  @IsTest
  static void binding_forTheDetector_resolvesStallDetector() {
    Assert.isInstanceOfType(
      Application.Service.newInstance(IStallDetector.class),
      StallDetector.class,
      'DI_Binding.Stall_Detector'
    );
  }

  @IsTest
  static void sweep_nullTime_throwsIllegalArgumentException() {
    useMocks(new List<Inbound_Message__c>());

    try {
      new StallDetector().sweep(null);
      Assert.fail('Expected IllegalArgumentException');
    } catch (IllegalArgumentException e) {
      Assert.areEqual('sweep needs the time of the sweep.', e.getMessage(), 'Named');
    }
    Assert.areEqual(0, selectorMock.callCount('selectDue'), 'Nothing read');
  }
}
