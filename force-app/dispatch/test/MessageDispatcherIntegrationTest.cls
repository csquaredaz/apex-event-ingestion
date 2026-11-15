/**
 * @description Integration tests for dispatch: real rows, the real selector, router and guarded
 * handlers, run as Minimum Access users. Only the routes are injected, because custom metadata
 * can't be inserted in a test.
 *
 * Subject:  MessageDispatcher.dispatch through MessageRouter and InboundMessagesSelector
 * Mocks:    IMessageRoutesSelector (in-memory routes)
 * Bulk:     200 stored messages → 1 SOQL, 1 composite call per route, 200 results
 * Negative: a user without the Processor permission set can't read payloads
 */
@IsTest
private class MessageDispatcherIntegrationTest {
  private static final String ORDER_TYPE = EventIngestionTestFactory.MESSAGE_TYPE;

  private static void useRoutes(List<Message_Route__mdt> routes) {
    Application.Service.setMock(
      IMessageRoutesSelector.class,
      new Mocks().stubReturn('selectActiveByMessageTypes', routes).stub(IMessageRoutesSelector.class)
    );
  }

  private static Set<Id> store(List<Inbound_Message__c> messages) {
    Set<Id> ids = new Set<Id>();
    for (AppendResult result : new MessageStore().append(messages)) {
      Assert.isTrue(result.isAccepted(), 'Stored: ' + result.getError());
      ids.add(result.getMessageId());
    }
    return ids;
  }

  @IsTest
  static void dispatch_200StoredMessagesOnACompositeRoute_handlesEachWithItsPayload() {
    useRoutes(
      new List<Message_Route__mdt>{
        DispatchTestHandlers.route('Billing', ORDER_TYPE, 'DispatchTestHandlers.SucceedAll'),
        DispatchTestHandlers.ordered(
          DispatchTestHandlers.route('Shipping', ORDER_TYPE, 'DispatchTestHandlers.SucceedAll'),
          2
        )
      }
    );
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    System.runAs(processor) {
      Set<Id> ids = store(EventIngestionTestFactory.messages(200));

      Test.startTest();
      Integer queriesBefore = Limits.getQueries();
      Map<Id, HandlerResult> results = new MessageDispatcher().dispatch(ids);
      Integer queries = Limits.getQueries() - queriesBefore;
      Test.stopTest();

      Assert.areEqual(200, results.size(), 'One result per message');
      for (HandlerResult result : results.values()) {
        Assert.isTrue(result.isSuccess(), 'Both handlers succeeded');
      }
      Assert.areEqual(1, queries, 'One query for 200 messages');
      Assert.areEqual(new List<String>{ 'SucceedAll:200', 'SucceedAll:200' }, DispatchTestHandlers.calls, 'Bulk');
      InboundMessage seen = DispatchTestHandlers.received[0][0];
      Assert.isTrue(seen.getPayload().startsWith('{"orderNumber":"ORD-'), 'Payload read in user mode');
      Assert.areEqual(1, seen.getAttempt(), 'First attempt');
    }
  }

  @IsTest
  static void dispatch_throwingRouteNextToAWorkingOne_rollsBackOnlyTheThrowingRoute() {
    useRoutes(
      new List<Message_Route__mdt>{
        DispatchTestHandlers.route('Fails', ORDER_TYPE, 'DispatchTestHandlers.WriteThenThrow'),
        DispatchTestHandlers.ordered(
          DispatchTestHandlers.route('Works', ORDER_TYPE, 'DispatchTestHandlers.SucceedAll'),
          2
        )
      }
    );
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    System.runAs(processor) {
      Set<Id> ids = store(EventIngestionTestFactory.messages(2));

      Test.startTest();
      Map<Id, HandlerResult> results = new MessageDispatcher().dispatch(ids);
      Test.stopTest();

      for (HandlerResult result : results.values()) {
        Assert.isTrue(result.isRetryable(), 'The throwing route makes every message retryable');
        Assert.isTrue(result.getError().startsWith('Route Fails threw'), result.getError());
      }
      Assert.areEqual(2, DispatchTestHandlers.calls.size(), 'The working route still ran');
      Assert.areEqual(2, [SELECT COUNT() FROM Inbound_Message__c WITH SYSTEM_MODE], 'Stored rows survive');
    }
  }

  @IsTest
  static void dispatch_userWithoutProcessorAccess_throwsQueryException() {
    useRoutes(new List<Message_Route__mdt>());
    Set<Id> ids;
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    System.runAs(processor) {
      ids = store(EventIngestionTestFactory.messages(1));
    }
    User outsider = EventIngestionTestFactory.minimumAccessUser(null);
    System.runAs(outsider) {
      try {
        new MessageDispatcher().dispatch(ids);
        Assert.fail('Expected QueryException');
      } catch (QueryException e) {
        Assert.isNotNull(e.getMessage(), 'User mode refuses the query: ' + e.getMessage());
      }
    }
  }
}
