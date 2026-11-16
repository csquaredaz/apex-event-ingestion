/**
 * @description Unit tests for `OrderStatusChange`: parsing and the stale-change rule.
 *
 * Subject:  OrderStatusChange.parse, isShipped, isOlderThan
 * Mocks:    none (in-memory messages)
 * Bulk:     n/a (one payload per call)
 * Negative: empty payload, not JSON, a JSON array, missing orderNumber or status
 */
@IsTest
private class OrderStatusChangeTest {
  private static void assertRejected(String payload, String expectedText) {
    try {
      OrderStatusChange.parse(OrderTestFactory.message(payload, null));
      Assert.fail('Expected IllegalArgumentException for ' + payload);
    } catch (IllegalArgumentException e) {
      Assert.isTrue(e.getMessage().contains(expectedText), e.getMessage());
      Assert.isFalse(payload != null && e.getMessage().contains(payload), 'The error never quotes the payload');
    }
  }

  @IsTest
  static void parse_fullPayload_readsAndTrimsEveryField() {
    InboundMessage message = OrderTestFactory.message(
      '{"orderNumber":" ORD-1 ","status":" Shipped ","carrier":" Acme ","trackingNumber":" T1 ","extra":1}',
      null
    );

    Test.startTest();
    OrderStatusChange change = OrderStatusChange.parse(message);
    Test.stopTest();

    Assert.areEqual('ORD-1', change.getOrderNumber(), 'Trimmed order number');
    Assert.areEqual('Shipped', change.getStatus(), 'Trimmed status');
    Assert.areEqual('Acme', change.getCarrier(), 'Trimmed carrier');
    Assert.areEqual('T1', change.getTrackingNumber(), 'Trimmed tracking number');
    Assert.areEqual(message, change.getMessage(), 'Keeps its message');
  }

  @IsTest
  static void parse_noShippingDetails_leavesThemNull() {
    OrderStatusChange change = OrderStatusChange.parse(
      OrderTestFactory.message(OrderTestFactory.payload('ORD-1', 'Picked', null), null)
    );

    Assert.isNull(change.getCarrier(), 'No carrier');
    Assert.isNull(change.getTrackingNumber(), 'No tracking number');
  }

  @IsTest
  static void parse_emptyPayload_throws() {
    Assert.isNotNull(OrderTestFactory.message(null, null), 'Fixture');
    assertRejected(null, 'empty');
    assertRejected('  ', 'empty');
  }

  @IsTest
  static void parse_notAJsonObject_throws() {
    Assert.isNotNull(OrderTestFactory.message('x', null), 'Fixture');
    assertRejected('not json', 'not a JSON object');
    assertRejected('[1, 2]', 'not a JSON object');
  }

  @IsTest
  static void parse_missingOrderNumberOrStatus_throws() {
    Assert.isNotNull(OrderTestFactory.message('{}', null), 'Fixture');
    assertRejected('{"status":"Shipped"}', 'needs orderNumber and status');
    assertRejected('{"orderNumber":"ORD-1","status":" "}', 'needs orderNumber and status');
    assertRejected('null', 'needs orderNumber and status');
  }

  @IsTest
  static void isShipped_ignoresCase() {
    Assert.isTrue(
      OrderStatusChange.parse(OrderTestFactory.message(OrderTestFactory.payload('O', 'sHiPpEd', null), null))
        .isShipped(),
      'Shipped in any case'
    );
    Assert.isFalse(
      OrderStatusChange.parse(OrderTestFactory.message(OrderTestFactory.payload('O', 'Delivered', null), null))
        .isShipped(),
      'Delivered is not shipped'
    );
  }

  @IsTest
  static void isOlderThan_comparesOccurrenceTimes() {
    Datetime now = Datetime.now();
    String body = OrderTestFactory.payload('O', 'Picked', null);
    OrderStatusChange older = OrderStatusChange.parse(OrderTestFactory.message(body, now.addMinutes(-1)));
    OrderStatusChange newer = OrderStatusChange.parse(OrderTestFactory.message(body, now));
    OrderStatusChange unknown = OrderStatusChange.parse(OrderTestFactory.message(body, null));

    Assert.isTrue(older.isOlderThan(newer), 'Strictly earlier is older');
    Assert.isFalse(newer.isOlderThan(older), 'Later is not older');
    Assert.isFalse(newer.isOlderThan(newer), 'Equal is not older');
    Assert.isFalse(unknown.isOlderThan(newer), 'An unknown time proves nothing');
    Assert.isFalse(older.isOlderThan(unknown), 'Against an unknown time, nothing is older');
  }
}
