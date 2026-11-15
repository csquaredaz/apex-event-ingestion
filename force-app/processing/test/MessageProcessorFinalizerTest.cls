/**
 * @description Unit tests for `MessageProcessorFinalizer`, driven with a fake `FinalizerContext`:
 * a test can't force the `LimitException` this class exists for, because the exception ends the
 * test itself (probe 4, ADR 0006).
 *
 * Subject:  MessageProcessorFinalizer.execute, continuationDelay
 * Mocks:    IMessageLifecycle, IProcessorQueue, IAlertSink, ILogger (RecordingLogger), FinalizerContext
 * Bulk:     200 claimed Ids → 1 recordJobFailure call
 * Negative: a failure before anything was claimed, recovery that throws, retries too far away
 */
@IsTest
private class MessageProcessorFinalizerTest {
  private static Mocks lifecycleMock;
  private static Mocks alertMock;
  private static RecordingLogger logger;
  private static Mocks queueMock;

  private class FakeContext implements FinalizerContext {
    private final ParentJobResult result;
    private final Exception cause;

    private FakeContext(ParentJobResult result, Exception cause) {
      this.result = result;
      this.cause = cause;
    }

    public Id getAsyncApexJobId() {
      return FakeId.generate(AsyncApexJob.SObjectType);
    }

    public String getRequestId() {
      return 'fake-request';
    }

    public ParentJobResult getResult() {
      return result;
    }

    public Exception getException() {
      return cause;
    }
  }

  private static void useMocks(Mocks lifecycle) {
    lifecycleMock = lifecycle;
    Application.Service.setMock(IMessageLifecycle.class, lifecycleMock.stub(IMessageLifecycle.class));
    alertMock = new Mocks();
    Application.Service.setMock(IAlertSink.class, alertMock.stub(IAlertSink.class));
    logger = new RecordingLogger();
    Application.Service.setMock(ILogger.class, logger);
    queueMock = new Mocks();
    Application.Service.setMock(IProcessorQueue.class, queueMock.stub(IProcessorQueue.class));
  }

  private static Set<Id> fakeIds(Integer count) {
    Set<Id> ids = new Set<Id>();
    for (Integer i = 0; i < count; i++) {
      ids.add(FakeId.generate(Inbound_Message__c.SObjectType));
    }
    return ids;
  }

  /** The delay of each continuation the Finalizer asked the queue for. */
  private static List<Object> continuations() {
    List<Object> delays = new List<Object>();
    for (Integer i = 0; i < queueMock.callCount('enqueue'); i++) {
      delays.add(queueMock.argumentsOf('enqueue', i)[0]);
    }
    return delays;
  }

  private static FinalizerContext failed(String message) {
    return new FakeContext(ParentJobResult.UNHANDLED_EXCEPTION, new DmlException(message));
  }

  @IsTest
  static void execute_jobFailedHolding200Messages_recordsTheFailureAlertsAndContinues() {
    useMocks(new Mocks().stubReturn('recordJobFailure', Datetime.now().addMinutes(1)));
    Set<Id> ids = fakeIds(200);
    MessageProcessorFinalizer finalizer = new MessageProcessorFinalizer();
    finalizer.claimed(ids, 201);

    finalizer.execute(failed('Too many SOQL queries: 201'));

    lifecycleMock.verify('recordJobFailure', 1);
    List<Object> args = lifecycleMock.argumentsOf('recordJobFailure', 0);
    Assert.areEqual(ids, args[0], 'Every claimed Id');
    Assert.areEqual('The processor job failed: Too many SOQL queries: 201', args[1], 'The cause');
    Alert sent = ((List<Alert>) alertMock.argumentsOf('send', 0)[0])[0];
    Assert.areEqual(Alert.Severity.CRITICAL, sent.severity, 'A failed job is critical');
    Assert.isTrue(sent.title.startsWith('Processor job failed; 200 message(s)'), sent.title);
    Assert.isFalse(sent.detail.contains('SOQL'), 'No exception text in the alert');
    Assert.areEqual(1, logger.entries(LoggingLevel.ERROR).size(), 'Logged once');
    Assert.areEqual(new List<Object>{ 1 }, continuations(), 'The next job waits for the retry');
  }

  @IsTest
  static void execute_jobFailedBeforeClaiming_alertsWithoutContinuing() {
    useMocks(new Mocks());
    MessageProcessorFinalizer finalizer = new MessageProcessorFinalizer();

    finalizer.execute(new FakeContext(ParentJobResult.UNHANDLED_EXCEPTION, null));

    Assert.areEqual(new Set<Id>(), lifecycleMock.argumentsOf('recordJobFailure', 0)[0], 'Nothing to recover');
    Assert.areEqual(
      'The processor job failed: unknown error',
      lifecycleMock.argumentsOf('recordJobFailure', 0)[1],
      'No exception'
    );
    alertMock.verify('send', 1);
    Assert.areEqual(new List<Object>(), continuations(), 'Nothing claimed, nothing to continue');
  }

  @IsTest
  static void execute_recoveryThrows_logsAlertsAndStops() {
    useMocks(new Mocks().stubThrow('recordJobFailure', new DmlException('UNABLE_TO_LOCK_ROW')));
    MessageProcessorFinalizer finalizer = new MessageProcessorFinalizer();
    finalizer.claimed(fakeIds(3), 3);

    finalizer.execute(failed('limit'));

    Assert.areEqual(2, logger.entries(LoggingLevel.ERROR).size(), 'The job failure and the recovery failure');
    Alert sent = ((List<Alert>) alertMock.argumentsOf('send', 0)[0])[0];
    Assert.areEqual('Processor recovery failed; 3 message(s) kept their state', sent.title, 'Explains');
    Assert.areEqual(new List<Object>(), continuations(), 'No continuation: the same rows would be claimed again');
    Assert.areEqual(1, logger.flushCount(), 'Flushed');
  }

  @IsTest
  static void execute_jobSucceededWithAFullBatch_continuesWithoutRecovery() {
    useMocks(new Mocks());
    MessageProcessorFinalizer finalizer = new MessageProcessorFinalizer();
    finalizer.claimed(fakeIds(2), 2);
    finalizer.completed(null);

    finalizer.execute(new FakeContext(ParentJobResult.SUCCESS, null));

    lifecycleMock.verify('recordJobFailure', 0);
    alertMock.verify('send', 0);
    Assert.areEqual(new List<Object>{ 0 }, continuations(), 'More work is probably waiting: at once');
  }

  @IsTest
  static void execute_jobSucceededWithNothingDue_stops() {
    useMocks(new Mocks());
    MessageProcessorFinalizer finalizer = new MessageProcessorFinalizer();
    finalizer.claimed(fakeIds(2), 200);
    finalizer.completed(Datetime.now().addMinutes(30));

    finalizer.execute(new FakeContext(ParentJobResult.SUCCESS, null));

    Assert.areEqual(new List<Object>(), continuations(), 'The retry is past the 10-minute delay');
  }

  @IsTest
  static void continuationDelay_eachCase_matchesTheRule() {
    Datetime now = Datetime.newInstanceGmt(2026, 11, 15, 12, 0, 0);

    Assert.areEqual(0, MessageProcessorFinalizer.continuationDelay(true, null, now), 'Full batch: at once');
    Assert.areEqual(0, MessageProcessorFinalizer.continuationDelay(true, now.addHours(1), now), 'Full wins');
    Assert.isNull(MessageProcessorFinalizer.continuationDelay(false, null, now), 'Nothing scheduled');
    Assert.areEqual(0, MessageProcessorFinalizer.continuationDelay(false, now.addSeconds(-5), now), 'Already due');
    Assert.areEqual(2, MessageProcessorFinalizer.continuationDelay(false, now.addSeconds(90), now), 'Rounded up');
    Assert.areEqual(10, MessageProcessorFinalizer.continuationDelay(false, now.addMinutes(10), now), 'At the limit');
    Assert.isNull(MessageProcessorFinalizer.continuationDelay(false, now.addMinutes(11), now), 'Too far');
  }
}
