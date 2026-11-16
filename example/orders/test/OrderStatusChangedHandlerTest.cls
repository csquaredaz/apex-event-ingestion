/**
 * @description Unit tests for `OrderStatusChangedHandler` and the shared steps in
 * `OrderMessageHandler`, with the selector and the Unit of Work mocked.
 *
 * Subject:  OrderStatusChangedHandler.handle
 * Mocks:    IOrdersSelector, IUnitOfWork
 * Bulk:     200 changes for 200 orders → 1 query, 1 upsert of 200 rows, 1 commit
 * Negative: unparseable payload (FATAL, no query); unknown order (RETRYABLE); an ambiguous
 *           reference number (FATAL); a stale change (SUCCESS, no write)
 */
@IsTest
private class OrderStatusChangedHandlerTest {
  private static Mocks selectorMock;
  private static Mocks uowMock;

  private static void useOrders(List<Order> orders) {
    selectorMock = new Mocks().stubReturn('selectByReferenceNumbers', orders);
    Application.Selector.setMock(Order.SObjectType, (ISelector) selectorMock.stub(IOrdersSelector.class));
    uowMock = new Mocks();
    Application.UnitOfWork.setMock((IUnitOfWork) uowMock.stub(IUnitOfWork.class));
  }

  private static InboundMessage change(String orderNumber, String status, Datetime occurredAt) {
    return OrderTestFactory.message(OrderTestFactory.payload(orderNumber, status, null), occurredAt);
  }

  private static Map<Id, HandlerResult> byId(List<HandlerResult> results) {
    Map<Id, HandlerResult> byId = new Map<Id, HandlerResult>();
    for (HandlerResult result : results) {
      byId.put(result.getMessageId(), result);
    }
    return byId;
  }

  private static List<Order> upserted() {
    Assert.areEqual(1, uowMock.callCount('registerUpsert'), 'One upsert registered');
    List<Object> args = uowMock.argumentsOf('registerUpsert', 0);
    Assert.areEqual(Order.OrderReferenceNumber, args[1], 'Keyed on OrderReferenceNumber');
    return (List<Order>) args[0];
  }

  @IsTest
  static void handle_200FreshChanges_upsertsEachOrderOnceInOneCommit() {
    List<Order> orders = new List<Order>();
    List<InboundMessage> messages = new List<InboundMessage>();
    Datetime now = Datetime.now();
    for (Integer i = 0; i < 200; i++) {
      String orderNumber = OrderTestFactory.number('ORD', i);
      orders.add(OrderTestFactory.order(orderNumber, now.addHours(-1)));
      messages.add(change(orderNumber, 'Picked', now));
    }
    useOrders(orders);

    Test.startTest();
    List<HandlerResult> results = new OrderStatusChangedHandler().handle(messages);
    Test.stopTest();

    Assert.areEqual(200, results.size(), 'One result per message');
    for (HandlerResult result : results) {
      Assert.isTrue(result.isSuccess(), 'Applied: ' + result.getError());
    }
    Assert.areEqual(1, selectorMock.callCount('selectByReferenceNumbers'), 'One query for the batch');
    List<Order> rows = upserted();
    Assert.areEqual(200, rows.size(), 'Every order written once');
    Assert.areEqual('Picked', rows[0].Fulfilment_Status__c, 'The new status');
    Assert.areEqual(now, rows[0].Status_Changed_At__c, 'The change time is recorded');
    Assert.areEqual(1, uowMock.callCount('commitWork'), 'One commit');
  }

  @IsTest
  static void handle_staleChange_succeedsWithoutWriting() {
    Datetime now = Datetime.now();
    useOrders(new List<Order>{ OrderTestFactory.order('ORD-1', now) });
    InboundMessage stale = change('ORD-1', 'Picked', now.addMinutes(-5));

    List<HandlerResult> results = new OrderStatusChangedHandler().handle(new List<InboundMessage>{ stale });

    Assert.isTrue(results[0].isSuccess(), 'A stale change is handled by doing nothing');
    Assert.areEqual(0, uowMock.callCount('registerUpsert'), 'Nothing written');
    Assert.areEqual(0, uowMock.callCount('commitWork'), 'No commit');
  }

  @IsTest
  static void handle_twoChangesForOneOrder_appliesOnlyTheNewest() {
    Datetime now = Datetime.now();
    useOrders(new List<Order>{ OrderTestFactory.order('ORD-1', null) });
    InboundMessage newer = change('ORD-1', 'Delivered', now);
    InboundMessage older = change('ORD-1', 'Shipped', now.addMinutes(-5));

    List<HandlerResult> results = new OrderStatusChangedHandler().handle(new List<InboundMessage>{ newer, older });

    Assert.areEqual(2, results.size(), 'Both answered');
    Assert.isTrue(results[0].isSuccess() && results[1].isSuccess(), 'Both succeed');
    List<Order> rows = upserted();
    Assert.areEqual(1, rows.size(), 'One row per order: a repeated key would fail the whole upsert');
    Assert.areEqual('Delivered', rows[0].Fulfilment_Status__c, 'The newest wins, whatever the arrival order');
  }

  @IsTest
  static void handle_changeWithoutOccurredAt_isAppliedAndKeepsTheChangeTime() {
    useOrders(new List<Order>{ OrderTestFactory.order('ORD-1', Datetime.now()) });

    new OrderStatusChangedHandler().handle(new List<InboundMessage>{ change('ORD-1', 'Picked', null) });

    Order row = upserted()[0];
    Assert.areEqual('Picked', row.Fulfilment_Status__c, 'Applied: an unknown time proves nothing');
    Assert.isFalse(
      row.getPopulatedFieldsAsMap().containsKey('Status_Changed_At__c'),
      'The stored change time is left alone'
    );
  }

  @IsTest
  static void handle_numberInAnotherCase_writesTheStoredNumber() {
    useOrders(new List<Order>{ OrderTestFactory.order('ORD-ABC', null) });

    List<HandlerResult> results = new OrderStatusChangedHandler()
      .handle(new List<InboundMessage>{ change('ord-abc', 'Picked', null) });

    Assert.isTrue(results[0].isSuccess(), 'Matched ignoring case, like SOQL');
    Assert.areEqual('ORD-ABC', upserted()[0].OrderReferenceNumber, 'The upsert key is the stored value');
  }

  @IsTest
  static void handle_unknownOrder_isRetryable() {
    useOrders(new List<Order>());
    InboundMessage message = change('ORD-404', 'Picked', null);

    List<HandlerResult> results = new OrderStatusChangedHandler().handle(new List<InboundMessage>{ message });

    Assert.isTrue(results[0].isRetryable(), 'The order may not have arrived yet');
    Assert.isTrue(results[0].getError().contains('ORD-404'), results[0].getError());
    Assert.areEqual(0, uowMock.callCount('commitWork'), 'Nothing written');
  }

  @IsTest
  static void handle_numberSharedByTwoOrders_isFatal() {
    useOrders(new List<Order>{ OrderTestFactory.order('ORD-1', null), OrderTestFactory.order('ORD-1', null) });

    List<HandlerResult> results = new OrderStatusChangedHandler()
      .handle(new List<InboundMessage>{ change('ORD-1', 'Picked', null) });

    Assert.isTrue(results[0].isFatal(), 'Guessing would update the wrong order');
    Assert.isTrue(results[0].getError().contains('2 orders'), results[0].getError());
  }

  @IsTest
  static void handle_unparseablePayload_isFatalWithoutQuerying() {
    useOrders(new List<Order>());
    InboundMessage broken = OrderTestFactory.message('not json', null);

    List<HandlerResult> results = new OrderStatusChangedHandler().handle(new List<InboundMessage>{ broken });

    Assert.isTrue(results[0].isFatal(), 'It will never parse');
    Assert.areEqual(broken.getMessageId(), results[0].getMessageId(), 'Answered by Id');
    Assert.areEqual(0, selectorMock.callCount('selectByReferenceNumbers'), 'No query when nothing parsed');
  }

  @IsTest
  static void handle_mixedBatch_answersEveryMessageById() {
    useOrders(new List<Order>{ OrderTestFactory.order('ORD-1', null) });
    InboundMessage good = change('ORD-1', 'Picked', null);
    InboundMessage missing = change('ORD-2', 'Picked', null);
    InboundMessage broken = OrderTestFactory.message('{}', null);

    Map<Id, HandlerResult> results = byId(
      new OrderStatusChangedHandler().handle(new List<InboundMessage>{ good, missing, broken })
    );

    Assert.areEqual(3, results.size(), 'Every message answered');
    Assert.isTrue(results.get(good.getMessageId()).isSuccess(), 'Applied');
    Assert.isTrue(results.get(missing.getMessageId()).isRetryable(), 'Unknown order');
    Assert.isTrue(results.get(broken.getMessageId()).isFatal(), 'Unparseable');
    Assert.areEqual(1, upserted().size(), 'Only the good one written');
  }
}
