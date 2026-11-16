/**
 * @description Integration tests for processing: real rows, the real claim query, dispatcher,
 * lifecycle and Finalizer, run as Minimum Access users. Only the routes are injected (custom
 * metadata can't be inserted in a test), and, for the failure case, a dispatcher that throws.
 *
 * In a test, a job's exception is rethrown by `Test.stopTest()` and the Finalizer still runs, but
 * the test context refuses any job enqueued from the Finalizer of a job that succeeded, with an
 * uncatchable `LimitException` (probe 3, ADR 0006). So the first job is real and its continuation
 * goes to a mock `IProcessorQueue`. The job's own DML is not rolled back
 * before the Finalizer runs, unlike in production; the job writes nothing before dispatch, so the
 * tests still see the rows as they were claimed.
 *
 * Subject:  MessageProcessorJob → MessageProcessorFinalizer → IProcessorQueue
 * Mocks:    IMessageRoutesSelector (in-memory routes), IProcessorQueue; IMessageDispatcher on failure
 * Bulk:     200 stored messages of 3 types → Processed, Failed with backoff, Dead; continuation queued
 * Negative: a job that throws past the guard, a message on its last attempt, a retry not yet due,
 *           a user without the Processor permission set
 */
@IsTest
private class MessageProcessingIntegrationTest {
  private static final String RETRY_TYPE = 'order.retry_me';
  private static final String FATAL_TYPE = 'order.unparseable';

  private static Mocks queueMock;

  /** The first job is real; the Finalizer's continuation goes to a mock (see the class note). */
  private static void startJob() {
    queueMock = new Mocks();
    Application.Service.setMock(IProcessorQueue.class, queueMock.stub(IProcessorQueue.class));
    System.enqueueJob(new MessageProcessorJob());
  }

  private static void useRoutes() {
    Application.Service.setMock(
      IMessageRoutesSelector.class,
      new Mocks()
        .stubReturn(
          'selectActiveByMessageTypes',
          new List<Message_Route__mdt>{
            DispatchTestHandlers.route(
              'Orders',
              EventIngestionTestFactory.MESSAGE_TYPE,
              'DispatchTestHandlers.SucceedAll'
            ),
            DispatchTestHandlers.route('Retries', RETRY_TYPE, 'DispatchTestHandlers.RetryAll'),
            DispatchTestHandlers.route('Fatal', FATAL_TYPE, 'DispatchTestHandlers.FailAll')
          }
        )
        .stub(IMessageRoutesSelector.class)
    );
  }

  private static List<Id> store(List<Inbound_Message__c> messages) {
    List<Id> ids = new List<Id>();
    for (AppendResult result : new MessageStore().append(messages)) {
      Assert.isTrue(result.isAccepted(), 'Stored: ' + result.getError());
      ids.add(result.getMessageId());
    }
    return ids;
  }

  private static Map<String, List<Inbound_Message__c>> byStatus() {
    Map<String, List<Inbound_Message__c>> grouped = new Map<String, List<Inbound_Message__c>>();
    for (Inbound_Message__c row : [
      SELECT Id, Message_Type__c, Status__c, Attempts__c, Next_Attempt_At__c, Last_Error__c, Processed_At__c
      FROM Inbound_Message__c
      WITH SYSTEM_MODE
    ]) {
      if (!grouped.containsKey(row.Status__c)) {
        grouped.put(row.Status__c, new List<Inbound_Message__c>());
      }
      grouped.get(row.Status__c).add(row);
    }
    return grouped;
  }

  /** The delay of each continuation the Finalizer asked the queue for. */
  private static List<Object> continuations() {
    List<Object> delays = new List<Object>();
    for (Integer i = 0; i < queueMock.callCount('enqueue'); i++) {
      delays.add(queueMock.argumentsOf('enqueue', i)[0]);
    }
    return delays;
  }

  @IsTest
  static void process_200MessagesOfThreeTypes_recordsEachOutcomeAndQueuesTheNextBatch() {
    useRoutes();
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    System.runAs(processor) {
      List<Inbound_Message__c> messages = EventIngestionTestFactory.messages(200);
      for (Integer i = 100; i < 200; i++) {
        messages[i].Message_Type__c = i < 160 ? RETRY_TYPE : FATAL_TYPE;
      }
      store(messages);
      Datetime before = Datetime.now();

      Test.startTest();
      startJob();
      Test.stopTest();

      Map<String, List<Inbound_Message__c>> grouped = byStatus();
      Assert.areEqual(100, grouped.get(MessageStatuses.PROCESSED).size(), 'Handled');
      Assert.areEqual(60, grouped.get(MessageStatuses.FAILED).size(), 'Retryable');
      Assert.areEqual(40, grouped.get(MessageStatuses.DEAD).size(), 'Fatal');
      Assert.isFalse(grouped.containsKey(MessageStatuses.RECEIVED), 'All 200 claimed in one batch');
      Assert.isNotNull(grouped.get(MessageStatuses.PROCESSED)[0].Processed_At__c, 'Processed time');
      Inbound_Message__c failed = grouped.get(MessageStatuses.FAILED)[0];
      Assert.areEqual(1, failed.Attempts__c, 'First attempt counted');
      // Datetime fields keep whole seconds, so compare from the second before.
      Assert.isTrue(failed.Next_Attempt_At__c >= before.addMinutes(1).addSeconds(-1), 'Backoff of one minute');
      Assert.areEqual('busy', failed.Last_Error__c, 'The handler error');
      Assert.areEqual('bad payload', grouped.get(MessageStatuses.DEAD)[0].Last_Error__c, 'The fatal error');
      Assert.areEqual(new List<Object>{ 0 }, continuations(), 'A full batch continues at once');
    }
  }

  @IsTest
  static void process_retryOnTheLastAttemptAndARetryNotYetDue_deadensOneAndLeavesTheOther() {
    useRoutes();
    IngestionSettings.row = new Ingestion_Setting__mdt(Max_Attempts__c = 3);
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    System.runAs(processor) {
      List<Inbound_Message__c> messages = EventIngestionTestFactory.messages(2);
      for (Inbound_Message__c message : messages) {
        message.Message_Type__c = RETRY_TYPE;
      }
      List<Id> ids = store(messages);
      Datetime now = Datetime.now();
      update as user new List<Inbound_Message__c>{
        new Inbound_Message__c(
          Id = ids[0],
          Status__c = MessageStatuses.FAILED,
          Attempts__c = 2,
          Next_Attempt_At__c = now.addMinutes(-1)
        ),
        new Inbound_Message__c(
          Id = ids[1],
          Status__c = MessageStatuses.FAILED,
          Attempts__c = 1,
          Next_Attempt_At__c = now.addMinutes(30)
        )
      };

      Test.startTest();
      startJob();
      Test.stopTest();

      Map<String, List<Inbound_Message__c>> grouped = byStatus();
      Assert.areEqual(ids[0], grouped.get(MessageStatuses.DEAD)[0].Id, 'Third of three attempts');
      Assert.areEqual(3, grouped.get(MessageStatuses.DEAD)[0].Attempts__c, 'Counted');
      Inbound_Message__c waiting = grouped.get(MessageStatuses.FAILED)[0];
      Assert.areEqual(ids[1], waiting.Id, 'Not due yet, so not claimed');
      Assert.areEqual(1, waiting.Attempts__c, 'Untouched');
      Assert.areEqual(new List<Object>(), continuations(), 'Nothing due within 10 minutes');
    }
  }

  @IsTest
  static void process_dispatchThrowsPastTheGuard_finalizerSchedulesEveryClaimedMessageForRetry() {
    useRoutes();
    Application.Service.setMock(
      IMessageDispatcher.class,
      new Mocks()
        .stubThrow('dispatch', new DmlException('Simulated failure past the guard'))
        .stub(IMessageDispatcher.class)
    );
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    System.runAs(processor) {
      store(EventIngestionTestFactory.messages(3));

      Test.startTest();
      startJob();
      try {
        Test.stopTest();
        Assert.fail('Expected the job exception to surface at stopTest');
      } catch (DmlException e) {
        Assert.areEqual('Simulated failure past the guard', e.getMessage(), 'The job failed');
      }

      List<Inbound_Message__c> failed = byStatus().get(MessageStatuses.FAILED);
      Assert.areEqual(3, failed.size(), 'Every claimed message is recovered');
      Assert.areEqual(1, failed[0].Attempts__c, 'The failed run counts as an attempt');
      Assert.areEqual(
        'The processor job failed: Simulated failure past the guard',
        failed[0].Last_Error__c,
        'The job error'
      );
      Assert.isNotNull(failed[0].Next_Attempt_At__c, 'Backoff');
      Assert.areEqual(new List<Object>{ 1 }, continuations(), 'The Finalizer continues at the retry');
    }
  }

  @IsTest
  static void process_userWithoutProcessorAccess_claimsNothing() {
    useRoutes();
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    System.runAs(processor) {
      store(EventIngestionTestFactory.messages(1));
    }
    User outsider = EventIngestionTestFactory.minimumAccessUser(null);
    System.runAs(outsider) {
      Test.startTest();
      startJob();
      Test.stopTest();
    }

    Assert.areEqual(1, byStatus().get(MessageStatuses.RECEIVED).size(), 'User mode refuses the claim');
    Assert.areEqual(0, DispatchTestHandlers.calls.size(), 'Nothing dispatched');
  }
}
