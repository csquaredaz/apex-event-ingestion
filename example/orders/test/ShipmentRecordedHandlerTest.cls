/**
 * @description Unit tests for `ShipmentRecordedHandler`, with the selector and the Unit of Work
 * mocked.
 *
 * Subject:  ShipmentRecordedHandler.handle
 * Mocks:    IOrdersSelector, IUnitOfWork
 * Bulk:     200 shipped changes → 1 query, 1 upsert of 200 shipments keyed by tracking number
 * Negative: not shipped (SUCCESS, no query); no tracking number (FATAL); unknown order
 *           (RETRYABLE); a repeated tracking number (one row)
 */
@IsTest
private class ShipmentRecordedHandlerTest {
  private static Mocks selectorMock;
  private static Mocks uowMock;

  private static void useOrders(List<Order> orders) {
    selectorMock = new Mocks().stubReturn('selectByReferenceNumbers', orders);
    Application.Selector.setMock(Order.SObjectType, (ISelector) selectorMock.stub(IOrdersSelector.class));
    uowMock = new Mocks();
    Application.UnitOfWork.setMock((IUnitOfWork) uowMock.stub(IUnitOfWork.class));
  }

  private static InboundMessage shipped(String orderNumber, String trackingNumber, Datetime occurredAt) {
    return OrderTestFactory.message(
      OrderTestFactory.payload(orderNumber, OrderStatusChange.SHIPPED, trackingNumber),
      occurredAt
    );
  }

  private static List<Shipment__c> upserted() {
    Assert.areEqual(1, uowMock.callCount('registerUpsert'), 'One upsert registered');
    List<Object> args = uowMock.argumentsOf('registerUpsert', 0);
    Assert.areEqual(Shipment__c.Tracking_Number__c, args[1], 'Keyed on the tracking number');
    return (List<Shipment__c>) args[0];
  }

  @IsTest
  static void handle_200ShippedChanges_upsertsOneShipmentEach() {
    List<Order> orders = new List<Order>();
    List<InboundMessage> messages = new List<InboundMessage>();
    Datetime now = Datetime.now();
    for (Integer i = 0; i < 200; i++) {
      String orderNumber = OrderTestFactory.number('ORD', i);
      orders.add(OrderTestFactory.order(orderNumber, null));
      messages.add(shipped(orderNumber, 'TRK-' + i, now));
    }
    useOrders(orders);

    Test.startTest();
    List<HandlerResult> results = new ShipmentRecordedHandler().handle(messages);
    Test.stopTest();

    for (HandlerResult result : results) {
      Assert.isTrue(result.isSuccess(), 'Recorded: ' + result.getError());
    }
    Assert.areEqual(200, results.size(), 'One result per message');
    Assert.areEqual(1, selectorMock.callCount('selectByReferenceNumbers'), 'One query for the batch');
    List<Shipment__c> rows = upserted();
    Assert.areEqual(200, rows.size(), 'One shipment per tracking number');
    Assert.areEqual(orders[0].Id, rows[0].Order__c, 'Linked to its order');
    Assert.areEqual('Acme Freight', rows[0].Carrier__c, 'Carrier carried');
    Assert.areEqual(now, rows[0].Shipped_At__c, 'Shipped when the producer says');
    Assert.areEqual(1, uowMock.callCount('commitWork'), 'One commit');
  }

  @IsTest
  static void handle_resendWithoutCarrierOrTime_leavesThemAlone() {
    useOrders(new List<Order>{ OrderTestFactory.order('ORD-1', null) });
    InboundMessage bare = OrderTestFactory.message(
      '{"orderNumber":"ORD-1","status":"Shipped","trackingNumber":"TRK-1"}',
      null
    );

    new ShipmentRecordedHandler().handle(new List<InboundMessage>{ bare });

    Map<String, Object> written = upserted()[0].getPopulatedFieldsAsMap();
    Assert.isFalse(written.containsKey('Carrier__c'), 'An absent carrier is not written as null');
    Assert.isFalse(written.containsKey('Shipped_At__c'), 'An absent time is not written as null');
  }

  @IsTest
  static void handle_notShipped_succeedsWithoutQuerying() {
    useOrders(new List<Order>());
    InboundMessage picked = OrderTestFactory.message(OrderTestFactory.payload('ORD-1', 'Picked', null), null);

    List<HandlerResult> results = new ShipmentRecordedHandler().handle(new List<InboundMessage>{ picked });

    Assert.isTrue(results[0].isSuccess(), 'Nothing to record');
    Assert.areEqual(0, selectorMock.callCount('selectByReferenceNumbers'), 'No query');
    Assert.areEqual(0, uowMock.callCount('commitWork'), 'No commit');
  }

  @IsTest
  static void handle_shippedWithoutTrackingNumber_isFatal() {
    useOrders(new List<Order>{ OrderTestFactory.order('ORD-1', null) });

    List<HandlerResult> results = new ShipmentRecordedHandler()
      .handle(new List<InboundMessage>{ shipped('ORD-1', null, null) });

    Assert.isTrue(results[0].isFatal(), 'It can never be recorded');
    Assert.isTrue(results[0].getError().contains('trackingNumber'), results[0].getError());
    Assert.areEqual(0, uowMock.callCount('commitWork'), 'No commit');
  }

  @IsTest
  static void handle_unknownOrder_isRetryable() {
    useOrders(new List<Order>());

    List<HandlerResult> results = new ShipmentRecordedHandler()
      .handle(new List<InboundMessage>{ shipped('ORD-404', 'TRK-1', null) });

    Assert.isTrue(results[0].isRetryable(), 'The order may not have arrived yet');
  }

  @IsTest
  static void handle_trackingNumberRepeatedInAnotherCase_writesOneShipment() {
    useOrders(new List<Order>{ OrderTestFactory.order('ORD-1', null) });

    List<HandlerResult> results = new ShipmentRecordedHandler()
      .handle(new List<InboundMessage>{ shipped('ORD-1', 'trk-1', null), shipped('ORD-1', 'TRK-1', null) });

    Assert.isTrue(results[0].isSuccess() && results[1].isSuccess(), 'Both succeed');
    List<Shipment__c> rows = upserted();
    Assert.areEqual(1, rows.size(), 'One row: the key is unique ignoring case');
    Assert.areEqual('TRK-1', rows[0].Tracking_Number__c, 'The last one is written');
  }
}
