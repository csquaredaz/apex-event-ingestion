/**
 * @description Unit tests for `MessageDispatcher`, with Stub API mocks of the selector and the
 * router, so no row is read.
 *
 * Subject:  MessageDispatcher.dispatch
 * Mocks:    IInboundMessagesSelector (in-memory rows), IMessageRouter (test handlers)
 * Bulk:     200 messages of 2 types → 1 query call, 1 routing call, 2 handler calls, 200 results
 * Negative: null/empty Ids, no rows found, an unrouted type, a handler that skips a message, a
 *           claimed payload that can't be loaded (IPayloadResolver mock)
 */
@IsTest
private class MessageDispatcherTest {
  private static final String ORDER_TYPE = EventIngestionTestFactory.MESSAGE_TYPE;
  private static final String CUSTOMER_TYPE = 'customer.updated';
  private static Mocks selectorMock;
  private static Mocks routerMock;

  private static List<Inbound_Message__c> rows(Integer count, String messageType) {
    List<Inbound_Message__c> result = EventIngestionTestFactory.messages(count);
    for (Inbound_Message__c row : result) {
      row.Id = FakeId.generate(Inbound_Message__c.SObjectType);
      row.Message_Type__c = messageType;
    }
    return result;
  }

  private static Set<Id> idsOf(List<Inbound_Message__c> records) {
    return new Map<Id, Inbound_Message__c>(records).keySet();
  }

  private static void useMocks(List<Inbound_Message__c> stored, Map<String, IMessageHandler> handlers) {
    selectorMock = new Mocks().stubReturn('selectWithPayloadByIds', stored);
    Application.Selector.setMock(
      Inbound_Message__c.SObjectType,
      (ISelector) selectorMock.stub(IInboundMessagesSelector.class)
    );
    routerMock = new Mocks().stubReturn('handlersFor', handlers);
    Application.Service.setMock(IMessageRouter.class, routerMock.stub(IMessageRouter.class));
  }

  @IsTest
  static void binding_resolvesTheDispatcher() {
    Assert.isInstanceOfType(
      Application.Service.newInstance(IMessageDispatcher.class),
      MessageDispatcher.class,
      'DI_Binding.Message_Dispatcher'
    );
  }

  @IsTest
  static void dispatch_routedMessages_returnsTheHandlerResultsById() {
    List<Inbound_Message__c> stored = rows(2, ORDER_TYPE);
    useMocks(stored, new Map<String, IMessageHandler>{ ORDER_TYPE => new DispatchTestHandlers.SucceedAll() });

    Map<Id, HandlerResult> results = new MessageDispatcher().dispatch(idsOf(stored));

    Assert.areEqual(2, results.size(), 'One result per message');
    Assert.isTrue(results.get(stored[0].Id).isSuccess() && results.get(stored[1].Id).isSuccess(), 'Handled');
    Assert.areEqual(idsOf(stored), (Set<Id>) selectorMock.argumentsOf('selectWithPayloadByIds', 0)[0], 'Ids queried');
    Assert.areEqual(
      new Set<String>{ ORDER_TYPE },
      (Set<String>) routerMock.argumentsOf('handlersFor', 0)[0],
      'Types routed'
    );
    InboundMessage seen = DispatchTestHandlers.received[0][0];
    Assert.areEqual(stored[0].Payload__c, seen.getPayload(), 'The handler gets the payload');
  }

  @IsTest
  static void dispatch_unroutedType_isFatal() {
    List<Inbound_Message__c> stored = rows(1, CUSTOMER_TYPE);
    useMocks(stored, new Map<String, IMessageHandler>());

    HandlerResult result = new MessageDispatcher().dispatch(idsOf(stored)).get(stored[0].Id);

    Assert.isTrue(result.isFatal(), 'Nobody handles the type');
    Assert.areEqual('No active Message_Route__mdt for type customer.updated.', result.getError(), 'Says why');
  }

  @IsTest
  static void dispatch_handlerSkipsAMessage_retriesIt() {
    List<Inbound_Message__c> stored = rows(2, ORDER_TYPE);
    useMocks(stored, new Map<String, IMessageHandler>{ ORDER_TYPE => new DispatchTestHandlers.Sloppy() });

    Map<Id, HandlerResult> results = new MessageDispatcher().dispatch(idsOf(stored));

    Assert.areEqual(2, results.size(), 'The foreign result is dropped');
    Assert.isTrue(results.get(stored[0].Id).isSuccess(), 'Answered');
    Assert.isTrue(results.get(stored[1].Id).isRetryable(), 'Skipped, so retried');
  }

  @IsTest
  static void dispatch_handlerReturnsNull_retriesEveryMessage() {
    List<Inbound_Message__c> stored = rows(2, ORDER_TYPE);
    useMocks(stored, new Map<String, IMessageHandler>{ ORDER_TYPE => new DispatchTestHandlers.ReturnsNull() });

    Map<Id, HandlerResult> results = new MessageDispatcher().dispatch(idsOf(stored));

    Assert.isTrue(results.get(stored[0].Id).isRetryable(), 'Retried');
    Assert.areEqual('The handler returned no result.', results.get(stored[1].Id).getError(), 'Says why');
  }

  @IsTest
  static void dispatch_nullOrEmpty_returnsNothingWithoutQuerying() {
    useMocks(new List<Inbound_Message__c>(), new Map<String, IMessageHandler>());

    Assert.areEqual(0, new MessageDispatcher().dispatch(null).size(), 'Null Ids');
    Assert.areEqual(0, new MessageDispatcher().dispatch(new Set<Id>()).size(), 'Empty Ids');
    selectorMock.verify('selectWithPayloadByIds', 0);
  }

  @IsTest
  static void dispatch_noRowsFound_returnsNothingWithoutRouting() {
    useMocks(new List<Inbound_Message__c>(), new Map<String, IMessageHandler>());

    Map<Id, HandlerResult> results = new MessageDispatcher()
      .dispatch(new Set<Id>{ FakeId.generate(Inbound_Message__c.SObjectType) });

    Assert.areEqual(0, results.size(), 'Ids not found are left out');
    routerMock.verify('handlersFor', 0);
  }

  @IsTest
  static void dispatch_200MessagesOfTwoTypes_callsEachHandlerOnce() {
    List<Inbound_Message__c> orders = rows(120, ORDER_TYPE);
    List<Inbound_Message__c> customers = rows(80, CUSTOMER_TYPE);
    List<Inbound_Message__c> stored = new List<Inbound_Message__c>(orders);
    stored.addAll(customers);
    useMocks(
      stored,
      new Map<String, IMessageHandler>{
        ORDER_TYPE => new DispatchTestHandlers.SucceedAll(),
        CUSTOMER_TYPE => new DispatchTestHandlers.FailAll()
      }
    );

    Test.startTest();
    Map<Id, HandlerResult> results = new MessageDispatcher().dispatch(idsOf(stored));
    Test.stopTest();

    Assert.areEqual(200, results.size(), 'One result per message');
    selectorMock.verify('selectWithPayloadByIds', 1);
    routerMock.verify('handlersFor', 1);
    Set<String> calls = new Set<String>(DispatchTestHandlers.calls);
    Assert.areEqual(new Set<String>{ 'SucceedAll:120', 'FailAll:80' }, calls, 'One bulk call per type');
    Assert.isTrue(results.get(orders[0].Id).isSuccess(), 'Orders handled');
    Assert.isTrue(results.get(customers[79].Id).isFatal(), 'Customers failed');
  }

  private static Mocks useResolver(Map<String, String> payloads) {
    Mocks resolverMock = new Mocks().stubReturn('resolve', payloads);
    Application.Service.setMock(IPayloadResolver.class, resolverMock.stub(IPayloadResolver.class));
    return resolverMock;
  }

  @IsTest
  static void dispatch_noClaims_neverResolves() {
    List<Inbound_Message__c> stored = rows(2, ORDER_TYPE);
    useMocks(stored, new Map<String, IMessageHandler>{ ORDER_TYPE => new DispatchTestHandlers.SucceedAll() });
    Mocks resolverMock = useResolver(new Map<String, String>());

    Map<Id, HandlerResult> results = new MessageDispatcher().dispatch(idsOf(stored));

    Assert.areEqual(2, results.size(), 'Inline messages dispatch as before');
    resolverMock.verify('resolve', 0);
  }

  @IsTest
  static void dispatch_claimedAndInlineMessages_handlerGetsEachPayload() {
    List<Inbound_Message__c> stored = rows(2, ORDER_TYPE);
    String ref = FakeId.generate(ContentVersion.SObjectType);
    stored[1].Payload__c = null;
    stored[1].Payload_Ref__c = ref;
    useMocks(stored, new Map<String, IMessageHandler>{ ORDER_TYPE => new DispatchTestHandlers.SucceedAll() });
    Mocks resolverMock = useResolver(new Map<String, String>{ ref => '{"large":true}' });

    Map<Id, HandlerResult> results = new MessageDispatcher().dispatch(idsOf(stored));

    Assert.isTrue(results.get(stored[1].Id).isSuccess(), 'Handled');
    List<InboundMessage> seen = DispatchTestHandlers.received[0];
    Assert.areEqual(stored[0].Payload__c, seen[0].getPayload(), 'Inline payload as stored');
    Assert.areEqual('{"large":true}', seen[1].getPayload(), 'Claimed payload resolved');
    Assert.areEqual(ref, seen[1].getPayloadRef(), 'The claim is visible to the handler');
    Assert.areEqual(new Set<String>{ ref }, resolverMock.argumentsOf('resolve', 0)[0], 'Only claims resolved');
  }

  @IsTest
  static void dispatch_claimThatCannotBeLoaded_isFatalWithoutReachingTheHandler() {
    List<Inbound_Message__c> stored = rows(1, ORDER_TYPE);
    stored[0].Payload__c = null;
    stored[0].Payload_Ref__c = FakeId.generate(ContentVersion.SObjectType);
    useMocks(stored, new Map<String, IMessageHandler>{ ORDER_TYPE => new DispatchTestHandlers.SucceedAll() });
    useResolver(new Map<String, String>());

    Map<Id, HandlerResult> results = new MessageDispatcher().dispatch(idsOf(stored));

    HandlerResult result = results.get(stored[0].Id);
    Assert.isTrue(result.isFatal(), 'A missing file cannot heal by retrying');
    Assert.isTrue(result.getError().contains('could not be loaded'), result.getError());
    Assert.areEqual(0, DispatchTestHandlers.received.size(), 'The handler never ran');
    routerMock.verify('handlersFor', 0);
  }
}
