/**
 * @description Unit tests for `MessageProcessorJob`, run through `System.enqueueJob` (a Finalizer
 * can only be attached inside a Queueable) with Stub API mocks of every collaborator.
 *
 * Subject:  MessageProcessorJob.execute
 * Mocks:    IInboundMessagesSelector, IMessageDispatcher, IMessageLifecycle, IProcessorQueue, ILogger
 * Bulk:     200 claimed messages → 1 claim, 1 dispatch of 200 Ids, 1 recordResults call
 * Negative: nothing due, a claim that times out on another job's lock, payloads over the dispatch
 *           budget (ADR 0008)
 */
@IsTest
private class MessageProcessorJobTest {
  private static Mocks selectorMock;
  private static Mocks dispatcherMock;
  private static Mocks lifecycleMock;
  private static Mocks queueMock;
  private static RecordingLogger logger;

  private static void useMocks(Mocks selector, Map<Id, HandlerResult> results) {
    selectorMock = selector;
    Application.Selector.setMock(
      Inbound_Message__c.SObjectType,
      (ISelector) selectorMock.stub(IInboundMessagesSelector.class)
    );
    dispatcherMock = new Mocks().stubReturn('dispatch', results);
    Application.Service.setMock(IMessageDispatcher.class, dispatcherMock.stub(IMessageDispatcher.class));
    lifecycleMock = new Mocks();
    Application.Service.setMock(IMessageLifecycle.class, lifecycleMock.stub(IMessageLifecycle.class));
    logger = new RecordingLogger();
    Application.Service.setMock(ILogger.class, logger);
    // The Finalizer runs at stopTest; a test context can't take the job it would enqueue.
    queueMock = new Mocks();
    Application.Service.setMock(IProcessorQueue.class, queueMock.stub(IProcessorQueue.class));
  }

  private static List<Inbound_Message__c> claimed(Integer count) {
    List<Inbound_Message__c> rows = EventIngestionTestFactory.messages(count);
    for (Inbound_Message__c row : rows) {
      row.Id = FakeId.generate(Inbound_Message__c.SObjectType);
    }
    return rows;
  }

  private static void runJob() {
    Test.startTest();
    System.enqueueJob(new MessageProcessorJob());
    Test.stopTest();
  }

  @IsTest
  static void execute_200DueMessages_claimsDispatchesAndRecordsThem() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Batch_Size__c = 200);
    List<Inbound_Message__c> rows = claimed(200);
    Map<Id, HandlerResult> results = new Map<Id, HandlerResult>{ rows[0].Id => HandlerResult.success(rows[0].Id) };
    useMocks(new Mocks().stubReturn('selectClaimable', rows), results);
    Datetime before = Datetime.now();

    runJob();

    List<Object> claimArgs = selectorMock.argumentsOf('selectClaimable', 0);
    Assert.isTrue(((Datetime) claimArgs[0]) >= before, 'Claims what is due now');
    Assert.areEqual(200, claimArgs[1], 'The batch size from the settings');
    Set<Id> ids = new Map<Id, Inbound_Message__c>(rows).keySet();
    Assert.areEqual(ids, dispatcherMock.argumentsOf('dispatch', 0)[0], 'Dispatches exactly the claimed Ids');
    List<Object> recordArgs = lifecycleMock.argumentsOf('recordResults', 0);
    Assert.areEqual(rows, recordArgs[0], 'Records the claimed rows');
    Assert.areEqual(results, recordArgs[1], 'With the dispatch results');
    lifecycleMock.verify('recordJobFailure', 0);
    Assert.areEqual(1, logger.entries(LoggingLevel.INFO).size(), 'Logs the batch');
  }

  @IsTest
  static void execute_smallerBatchSize_claimsOnlyThatMany() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Batch_Size__c = 25);
    useMocks(new Mocks().stubReturn('selectClaimable', claimed(3)), new Map<Id, HandlerResult>());

    runJob();

    Assert.areEqual(25, selectorMock.argumentsOf('selectClaimable', 0)[1], 'Batch size 25');
  }

  @IsTest
  static void execute_nothingDue_dispatchesNothing() {
    useMocks(new Mocks().stubReturn('selectClaimable', new List<Inbound_Message__c>()), null);

    runJob();

    dispatcherMock.verify('dispatch', 0);
    lifecycleMock.verify('recordResults', 0);
    Assert.areEqual(2, logger.flushCount(), 'The job and its Finalizer each flush');
  }

  @IsTest
  static void execute_claimTimesOutOnAnotherJobsLock_endsQuietly() {
    useMocks(new Mocks().stubThrow('selectClaimable', new QueryException('Record Currently Unavailable')), null);

    runJob();

    dispatcherMock.verify('dispatch', 0);
    lifecycleMock.verify('recordJobFailure', 0);
    List<RecordingLogger.Entry> warnings = logger.entries(LoggingLevel.WARN);
    Assert.areEqual(1, warnings.size(), 'One warning');
    Assert.isTrue(warnings[0].message.endsWith('Record Currently Unavailable'), warnings[0].message);
  }

  private static List<Inbound_Message__c> sized(List<Integer> sizes) {
    List<Inbound_Message__c> rows = claimed(sizes.size());
    for (Integer i = 0; i < sizes.size(); i++) {
      rows[i].Payload_Size__c = sizes[i];
    }
    return rows;
  }

  @IsTest
  static void execute_payloadsOverTheBudget_dispatchesWhatFitsAndContinuesAtOnce() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Batch_Size__c = 200, Dispatch_Payload_Budget__c = 100);
    List<Inbound_Message__c> rows = sized(new List<Integer>{ 60, 40, 1, 1 });
    useMocks(new Mocks().stubReturn('selectClaimable', rows), new Map<Id, HandlerResult>());

    runJob();

    Set<Id> dispatched = (Set<Id>) dispatcherMock.argumentsOf('dispatch', 0)[0];
    Assert.areEqual(new Set<Id>{ rows[0].Id, rows[1].Id }, dispatched, 'In claim order, up to the budget');
    Assert.areEqual(
      2,
      ((List<Inbound_Message__c>) lifecycleMock.argumentsOf('recordResults', 0)[0]).size(),
      'Only those are recorded'
    );
    Assert.areEqual(new List<Object>{ 0 }, queueMock.argumentsOf('enqueue', 0), 'The rest go to the next job at once');
    Assert.isTrue(logger.entries(LoggingLevel.INFO)[0].message.contains('2 left for the next job'), 'Logged');
  }

  @IsTest
  static void execute_firstPayloadAloneOverTheBudget_isStillTaken() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Dispatch_Payload_Budget__c = 100);
    List<Inbound_Message__c> rows = sized(new List<Integer>{ 500, 1 });
    useMocks(new Mocks().stubReturn('selectClaimable', rows), new Map<Id, HandlerResult>());

    runJob();

    Assert.areEqual(
      new Set<Id>{ rows[0].Id },
      dispatcherMock.argumentsOf('dispatch', 0)[0],
      'One big payload cannot stall processing'
    );
  }

  @IsTest
  static void execute_payloadsWithinTheBudget_takesThemAllWithoutContinuing() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Batch_Size__c = 200, Dispatch_Payload_Budget__c = 100);
    List<Inbound_Message__c> rows = sized(new List<Integer>{ 50, 50 });
    useMocks(new Mocks().stubReturn('selectClaimable', rows), new Map<Id, HandlerResult>());

    runJob();

    Assert.areEqual(2, ((Set<Id>) dispatcherMock.argumentsOf('dispatch', 0)[0]).size(), 'Both fit exactly');
    queueMock.verify('enqueue', 0);
  }
}
