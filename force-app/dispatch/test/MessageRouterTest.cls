/**
 * @description Tests for `MessageRouter`, with a Stub API mock of `IMessageRoutesSelector`.
 *
 * Subject:  MessageRouter.handlersFor
 * Mocks:    IMessageRoutesSelector (in-memory route rows)
 * Bulk:     not applicable (one selector call per routing, asserted)
 * Negative: no route, a missing class, a class that isn't a handler, a constructor that throws,
 *           a blank class name, null and empty types
 */
@IsTest
private class MessageRouterTest {
  private static final String ORDER_TYPE = 'order.status_changed';
  private static Mocks routesMock;

  private static void useRoutes(List<Message_Route__mdt> routes) {
    routesMock = new Mocks().stubReturn('selectActiveByMessageTypes', routes);
    Application.Service.setMock(IMessageRoutesSelector.class, routesMock.stub(IMessageRoutesSelector.class));
  }

  private static List<HandlerResult> handleOne(IMessageHandler handler) {
    return handler.handle(DispatchTestHandlers.messages(1));
  }

  @IsTest
  static void binding_resolvesTheRouter() {
    Assert.isInstanceOfType(
      Application.Service.newInstance(IMessageRouter.class),
      MessageRouter.class,
      'DI_Binding.Message_Router'
    );
  }

  @IsTest
  static void handlersFor_oneRoute_returnsTheGuardedHandler() {
    useRoutes(
      new List<Message_Route__mdt>{
        DispatchTestHandlers.route('Orders', ORDER_TYPE, 'DispatchTestHandlers.SucceedAll')
      }
    );

    Map<String, IMessageHandler> handlers = new MessageRouter().handlersFor(new Set<String>{ ORDER_TYPE });

    Assert.isInstanceOfType(handlers.get(ORDER_TYPE), GuardedMessageHandler.class, 'Guarded, not a Composite');
    Assert.isTrue(handleOne(handlers.get(ORDER_TYPE))[0].isSuccess(), 'Calls the named class');
    Assert.areEqual(new List<String>{ 'SucceedAll:1' }, DispatchTestHandlers.calls, 'One call');
    routesMock.verify('selectActiveByMessageTypes', 1);
  }

  @IsTest
  static void handlersFor_twoRoutes_returnsACompositeInRouteOrder() {
    useRoutes(
      new List<Message_Route__mdt>{
        DispatchTestHandlers.route('Billing', ORDER_TYPE, 'DispatchTestHandlers.SucceedAll'),
        DispatchTestHandlers.ordered(
          DispatchTestHandlers.route('Shipping', ORDER_TYPE, 'DispatchTestHandlers.RetryAll'),
          2
        )
      }
    );

    IMessageHandler handler = new MessageRouter().handlersFor(new Set<String>{ ORDER_TYPE }).get(ORDER_TYPE);

    Assert.isInstanceOfType(handler, CompositeMessageHandler.class, 'Composite');
    Assert.isTrue(handleOne(handler)[0].isRetryable(), 'Worst result');
    Assert.areEqual(new List<String>{ 'SucceedAll:1', 'RetryAll:1' }, DispatchTestHandlers.calls, 'Route order');
  }

  @IsTest
  static void handlersFor_typeInAnotherCase_keysByTheTypeAsGiven() {
    useRoutes(
      new List<Message_Route__mdt>{
        DispatchTestHandlers.route('Orders', ORDER_TYPE, 'DispatchTestHandlers.SucceedAll')
      }
    );

    Map<String, IMessageHandler> handlers = new MessageRouter().handlersFor(new Set<String>{ 'Order.Status_Changed' });

    Assert.isTrue(handlers.containsKey('Order.Status_Changed'), 'Keyed as the caller spelled it');
  }

  @IsTest
  static void handlersFor_noRoute_leavesTheTypeOut() {
    useRoutes(new List<Message_Route__mdt>());

    Map<String, IMessageHandler> handlers = new MessageRouter().handlersFor(new Set<String>{ ORDER_TYPE });

    Assert.isFalse(handlers.containsKey(ORDER_TYPE), 'The dispatcher treats a missing type as unrouted');
  }

  @IsTest
  static void handlersFor_brokenRoutes_returnHandlersThatRetry() {
    useRoutes(
      new List<Message_Route__mdt>{
        DispatchTestHandlers.route('Missing', 'a', 'NoSuchHandler'),
        DispatchTestHandlers.route('Wrong_Type', 'b', 'DispatchTestHandlers.NotAHandler'),
        DispatchTestHandlers.route('Throws', 'c', 'DispatchTestHandlers.FailsToConstruct'),
        DispatchTestHandlers.route('Blank', 'd', '')
      }
    );

    Map<String, IMessageHandler> handlers = new MessageRouter().handlersFor(new Set<String>{ 'a', 'b', 'c', 'd' });

    HandlerResult missing = handleOne(handlers.get('a'))[0];
    HandlerResult wrongType = handleOne(handlers.get('b'))[0];
    HandlerResult failedConstructor = handleOne(handlers.get('c'))[0];
    HandlerResult blank = handleOne(handlers.get('d'))[0];
    Assert.isTrue(missing.isRetryable() && missing.getError().contains('NoSuchHandler'), missing.getError());
    Assert.isTrue(wrongType.isRetryable() && wrongType.getError().contains('IMessageHandler'), wrongType.getError());
    Assert.isTrue(
      failedConstructor.isRetryable() && failedConstructor.getError().contains('missing configuration'),
      failedConstructor.getError()
    );
    Assert.isTrue(blank.isRetryable() && blank.getError().contains('Blank'), blank.getError());
  }

  @IsTest
  static void handlersFor_nullOrEmpty_returnsNothingWithoutReadingRoutes() {
    useRoutes(new List<Message_Route__mdt>());

    Assert.areEqual(0, new MessageRouter().handlersFor(null).size(), 'Null types');
    Assert.areEqual(0, new MessageRouter().handlersFor(new Set<String>()).size(), 'Empty types');
    routesMock.verify('selectActiveByMessageTypes', 0);
  }
}
