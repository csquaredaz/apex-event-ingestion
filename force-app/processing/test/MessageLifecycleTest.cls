/**
 * @description Unit tests for `MessageLifecycle`, with Stub API mocks of the Unit of Work, the
 * selector and the alert sink, so no row is written.
 *
 * Subject:  MessageLifecycle.recordResults, MessageLifecycle.recordJobFailure
 * Mocks:    IUnitOfWork, IInboundMessagesSelector, IAlertSink
 * Bulk:     200 claimed messages → 1 registerDirty call, 1 commit, no SOQL
 * Negative: a missing result, the last attempt, a blank and an oversized error, terminal rows,
 *           null and empty input
 */
@IsTest
private class MessageLifecycleTest {
  private static Mocks uowMock;
  private static Mocks alertMock;

  private static void useMocks() {
    uowMock = new Mocks();
    Application.UnitOfWork.setMock((IUnitOfWork) uowMock.stub(IUnitOfWork.class));
    alertMock = new Mocks();
    Application.Service.setMock(IAlertSink.class, alertMock.stub(IAlertSink.class));
    IngestionSettings.row = new Ingestion_Setting__mdt(
      Max_Attempts__c = 3,
      Base_Delay_Minutes__c = 1,
      Max_Delay_Minutes__c = 60
    );
  }

  private static List<Inbound_Message__c> claimed(Integer count, Integer attemptsMade) {
    List<Inbound_Message__c> rows = EventIngestionTestFactory.messages(count);
    for (Inbound_Message__c row : rows) {
      row.Id = FakeId.generate(Inbound_Message__c.SObjectType);
      row.Status__c = MessageStatuses.RECEIVED;
      row.Attempts__c = attemptsMade;
    }
    return rows;
  }

  private static Map<Id, Inbound_Message__c> registered() {
    uowMock.verify('commitWork', 1);
    return new Map<Id, Inbound_Message__c>((List<Inbound_Message__c>) uowMock.argumentsOf('registerDirty', 0)[0]);
  }

  @IsTest
  static void recordResults_200MessagesWithEachOutcome_writesTheirStatusesInOneCommit() {
    useMocks();
    List<Inbound_Message__c> rows = claimed(200, 0);
    Map<Id, HandlerResult> results = new Map<Id, HandlerResult>();
    for (Integer i = 0; i < rows.size(); i++) {
      Id messageId = rows[i].Id;
      results.put(
        messageId,
        i < 100
          ? HandlerResult.success(messageId)
          : i < 150 ? HandlerResult.retryable(messageId, 'busy') : HandlerResult.fatal(messageId, 'bad payload')
      );
    }
    Datetime before = Datetime.now();

    Test.startTest();
    Datetime earliestRetry = new MessageLifecycle().recordResults(rows, results);
    Test.stopTest();

    Map<Id, Inbound_Message__c> written = registered();
    Assert.areEqual(200, written.size(), 'One update per message');
    Assert.areEqual(1, uowMock.callCount('registerDirty'), 'Registered as one list');
    Assert.areEqual(0, Limits.getQueries(), 'No SOQL');

    Inbound_Message__c processed = written.get(rows[0].Id);
    Assert.areEqual(MessageStatuses.PROCESSED, processed.Status__c, 'SUCCESS → Processed');
    Assert.isNotNull(processed.Processed_At__c, 'Processed time set');
    Assert.isNull(processed.Last_Error__c, 'Error cleared');
    Assert.isTrue(processed.isSet(Inbound_Message__c.Next_Attempt_At__c), 'Next attempt cleared on purpose');
    Assert.areEqual(1, processed.Attempts__c, 'An attempt counted');

    Inbound_Message__c failed = written.get(rows[100].Id);
    Assert.areEqual(MessageStatuses.FAILED, failed.Status__c, 'RETRYABLE → Failed');
    Assert.areEqual('busy', failed.Last_Error__c, 'The handler error');
    Assert.isTrue(failed.Next_Attempt_At__c >= before.addMinutes(1), 'Backoff of the base delay');
    Assert.areEqual(failed.Next_Attempt_At__c, earliestRetry, 'The earliest retry is returned');

    Inbound_Message__c dead = written.get(rows[150].Id);
    Assert.areEqual(MessageStatuses.DEAD, dead.Status__c, 'FATAL → Dead');
    Assert.isNull(dead.Next_Attempt_At__c, 'Never retried');
    Assert.areEqual('bad payload', dead.Last_Error__c, 'The handler error');

    alertMock.verify('send', 1);
    Alert sent = ((List<Alert>) alertMock.argumentsOf('send', 0)[0])[0];
    Assert.areEqual(Alert.Severity.WARNING, sent.severity, 'Dead messages warn');
    Assert.areEqual('50 inbound message(s) went Dead', sent.title, 'Counted once per call');
    Assert.isFalse(sent.detail.contains('bad payload'), 'No error text in the alert');
  }

  @IsTest
  static void recordResults_retryableOnTheLastAttempt_goesDead() {
    useMocks();
    List<Inbound_Message__c> rows = claimed(1, 2);

    Datetime earliestRetry = new MessageLifecycle()
      .recordResults(rows, new Map<Id, HandlerResult>{ rows[0].Id => HandlerResult.retryable(rows[0].Id, 'busy') });

    Inbound_Message__c written = registered().get(rows[0].Id);
    Assert.areEqual(MessageStatuses.DEAD, written.Status__c, 'Third of three attempts');
    Assert.areEqual(3, written.Attempts__c, 'Counted');
    Assert.isNull(earliestRetry, 'Nothing scheduled');
    alertMock.verify('send', 1);
  }

  @IsTest
  static void recordResults_secondAttempt_waitsTwiceTheBaseDelay() {
    useMocks();
    List<Inbound_Message__c> rows = claimed(1, 1);
    Datetime before = Datetime.now();

    new MessageLifecycle()
      .recordResults(rows, new Map<Id, HandlerResult>{ rows[0].Id => HandlerResult.retryable(rows[0].Id, 'busy') });

    Inbound_Message__c written = registered().get(rows[0].Id);
    Assert.areEqual(2, written.Attempts__c, 'Second attempt');
    Assert.isTrue(written.Next_Attempt_At__c >= before.addMinutes(2), 'Doubled');
    Assert.isTrue(written.Next_Attempt_At__c < before.addMinutes(3), 'Not more');
    alertMock.verify('send', 0);
  }

  @IsTest
  static void recordResults_messageWithoutAResult_isRetried() {
    useMocks();
    List<Inbound_Message__c> rows = claimed(1, 0);

    Datetime earliestRetry = new MessageLifecycle().recordResults(rows, null);

    Inbound_Message__c written = registered().get(rows[0].Id);
    Assert.areEqual(MessageStatuses.FAILED, written.Status__c, 'Missing result → retry');
    Assert.areEqual('Dispatch returned no result for this message.', written.Last_Error__c, 'Explained');
    Assert.isNotNull(earliestRetry, 'Scheduled');
  }

  @IsTest
  static void recordResults_oversizedOrBlankError_fitsTheField() {
    useMocks();
    List<Inbound_Message__c> rows = claimed(2, 0);
    String huge = 'x'.repeat(MessageLifecycle.LAST_ERROR_LENGTH + 500);

    new MessageLifecycle()
      .recordResults(
        rows,
        new Map<Id, HandlerResult>{
          rows[0].Id => HandlerResult.fatal(rows[0].Id, huge),
          rows[1].Id => HandlerResult.fatal(rows[1].Id, ' ')
        }
      );

    Map<Id, Inbound_Message__c> written = registered();
    String cut = written.get(rows[0].Id).Last_Error__c;
    Assert.areEqual(MessageLifecycle.LAST_ERROR_LENGTH, cut.length(), 'Cut to 32,768 characters');
    Assert.isTrue(cut.endsWith('...'), 'Marked as cut');
    Assert.areEqual('No error message was given.', written.get(rows[1].Id).Last_Error__c, 'Placeholder');
  }

  @IsTest
  static void recordResults_nothingClaimed_writesNothing() {
    useMocks();

    Assert.isNull(new MessageLifecycle().recordResults(new List<Inbound_Message__c>(), null), 'Empty');
    Assert.isNull(new MessageLifecycle().recordResults(null, null), 'Null');
    uowMock.verify('commitWork', 0);
  }

  @IsTest
  static void recordJobFailure_claimedRows_countsARetryableAttemptExceptOnTerminalRows() {
    useMocks();
    List<Inbound_Message__c> rows = claimed(4, 0);
    rows[1].Status__c = MessageStatuses.FAILED;
    rows[1].Attempts__c = 1;
    rows[2].Status__c = MessageStatuses.PROCESSED;
    rows[3].Status__c = MessageStatuses.DEAD;
    Mocks selectorMock = new Mocks().stubReturn('selectSObjectsById', rows);
    Application.Selector.setMock(
      Inbound_Message__c.SObjectType,
      (ISelector) selectorMock.stub(IInboundMessagesSelector.class)
    );
    Set<Id> ids = new Map<Id, Inbound_Message__c>(rows).keySet();

    Datetime earliestRetry = new MessageLifecycle().recordJobFailure(ids, 'The processor job failed: limit');

    Assert.areEqual(ids, selectorMock.argumentsOf('selectSObjectsById', 0)[0], 'Re-reads the claimed rows');
    Map<Id, Inbound_Message__c> written = registered();
    Assert.areEqual(2, written.size(), 'Processed and Dead rows are left alone');
    Assert.areEqual(MessageStatuses.FAILED, written.get(rows[0].Id).Status__c, 'Retried');
    Assert.areEqual('The processor job failed: limit', written.get(rows[0].Id).Last_Error__c, 'Why');
    Assert.areEqual(2, written.get(rows[1].Id).Attempts__c, 'An earlier failure counts on');
    Assert.isNotNull(earliestRetry, 'Scheduled');
  }

  @IsTest
  static void recordJobFailure_noIds_queriesNothing() {
    useMocks();

    Assert.isNull(new MessageLifecycle().recordJobFailure(new Set<Id>(), 'x'), 'Empty');
    Assert.isNull(new MessageLifecycle().recordJobFailure(null, 'x'), 'Null');
    Assert.areEqual(0, Limits.getQueries(), 'No SOQL');
    uowMock.verify('commitWork', 0);
  }

  @IsTest
  static void binding_forMessageLifecycle_resolvesTheService() {
    Assert.isInstanceOfType(
      Application.Service.newInstance(IMessageLifecycle.class),
      MessageLifecycle.class,
      'DI_Binding.Message_Lifecycle'
    );
  }
}
