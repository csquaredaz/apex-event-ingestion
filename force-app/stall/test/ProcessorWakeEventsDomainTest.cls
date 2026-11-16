/**
 * @description Unit tests for `ProcessorWakeEventsDomain`, called directly and through a real
 * delivery of `Processor_Wake_Event__e`.
 *
 * Subject:  ProcessorWakeEventsDomain.onAfterInsert
 * Mocks:    IProcessorQueue, ILogger (RecordingLogger)
 * Bulk:     200 wake events in one run → 1 enqueue
 * Negative: a job already queued; the enqueue throws (logged, not rethrown)
 */
@IsTest
private class ProcessorWakeEventsDomainTest {
  private static Mocks queueMock;
  private static RecordingLogger logger;

  private static void useMocks(Mocks queue) {
    queueMock = queue;
    Application.Service.setMock(IProcessorQueue.class, queueMock.stub(IProcessorQueue.class));
    logger = new RecordingLogger();
    Application.Service.setMock(ILogger.class, logger);
  }

  private static List<Processor_Wake_Event__e> events(Integer count) {
    List<Processor_Wake_Event__e> result = new List<Processor_Wake_Event__e>();
    for (Integer i = 0; i < count; i++) {
      result.add(new Processor_Wake_Event__e());
    }
    return result;
  }

  @IsTest
  static void publish_200WakeEvents_enqueuesOneJobAtOnce() {
    useMocks(new Mocks().stubReturn('enqueue', FakeId.generate(AsyncApexJob.SObjectType)));

    Test.startTest();
    List<Database.SaveResult> saves = EventBus.publish(events(200));
    Test.stopTest();

    Assert.isTrue(saves[0].isSuccess(), 'Published: ' + saves[0].getErrors());
    queueMock.verify('enqueue', 1);
    Assert.areEqual(new List<Object>{ 0 }, queueMock.argumentsOf('enqueue', 0), 'No delay');
    Assert.isTrue(
      logger.entries(LoggingLevel.INFO)[0].message.startsWith('Processor wake (200 event(s)): enqueued'),
      'Logged'
    );
  }

  @IsTest
  static void onAfterInsert_jobAlreadyQueued_logsIt() {
    useMocks(new Mocks());

    new ProcessorWakeEventsDomain(events(1)).onAfterInsert();

    Assert.areEqual(
      'Processor wake (1 event(s)): a processor job was already queued.',
      logger.entries(LoggingLevel.INFO)[0].message,
      'The duplicate signature absorbed it'
    );
  }

  @IsTest
  static void onAfterInsert_enqueueFails_logsTheErrorWithoutRethrowing() {
    useMocks(new Mocks().stubThrow('enqueue', new AsyncException('Too many queueable jobs')));

    new ProcessorWakeEventsDomain(events(1)).onAfterInsert();

    Assert.areEqual(1, logger.entries(LoggingLevel.ERROR).size(), 'Logged; the next sweep asks again');
    Assert.areEqual(1, logger.flushCount(), 'Flushed');
  }

  @IsTest
  static void constructor_buildsTheDomainForTheEventType() {
    IDomain domain = new ProcessorWakeEventsDomain.Constructor().construct(events(1));

    Assert.isInstanceOfType(domain, ProcessorWakeEventsDomain.class, 'The bound domain');
    Assert.areEqual(
      Processor_Wake_Event__e.SObjectType,
      ((ProcessorWakeEventsDomain) domain).getSObjectType(),
      'Owns the wake event'
    );
  }
}
