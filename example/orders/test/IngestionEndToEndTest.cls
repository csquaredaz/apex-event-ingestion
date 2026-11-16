/**
 * @description End-to-end tests of the whole package with the example handlers: a producer
 * publishes `Inbound_Message_Event__e`, the intake trigger stores each message once, the processor
 * job dispatches through the real `Message_Route__mdt` rows (a Composite of
 * `OrderStatusChangedHandler` then `ShipmentRecordedHandler`), and the lifecycle records the
 * outcome. Nothing is mocked. The producer is a Minimum Access user with only
 * `Event_Ingestion_Publisher`; orders are saved beforehand. Rows are read `WITH SYSTEM_MODE`.
 *
 * Subject:  publish → InboundMessageEventTrigger → MessageStore → MessageProcessorJob → handlers
 * Mocks:    none
 * Bulk:     200 changes for 200 orders, half shipped → 200 Processed, 100 shipments
 * Negative: a repeated delivery and a resent shipment (one row each); a stale change (order
 *           unchanged); an unknown order (Failed, retried); a shipment with no tracking number
 *           (Dead, though the order handler applied it)
 */
@IsTest
private class IngestionEndToEndTest {
  private static final String PUBLISHER = 'Event_Ingestion_Publisher';

  private static Inbound_Message_Event__e event(String externalId, String payload, Datetime occurredAt) {
    return new Inbound_Message_Event__e(
      Source__c = 'erp',
      External_Message_Id__c = externalId,
      Message_Type__c = OrderTestFactory.MESSAGE_TYPE,
      Payload__c = payload,
      Occurred_At__c = occurredAt
    );
  }

  private static void publishAndProcess(List<Inbound_Message_Event__e> events) {
    User producer = EventIngestionTestFactory.minimumAccessUser(PUBLISHER);
    System.runAs(producer) {
      Test.startTest();
      for (Database.SaveResult save : EventBus.publish(events)) {
        Assert.isTrue(save.isSuccess(), 'Published: ' + save.getErrors());
      }
      Test.getEventBus().deliver();
      Test.stopTest();
    }
  }

  private static Map<String, Inbound_Message__c> messagesByExternalId() {
    Map<String, Inbound_Message__c> byId = new Map<String, Inbound_Message__c>();
    for (Inbound_Message__c row : [
      SELECT External_Message_Id__c, Status__c, Attempts__c, Next_Attempt_At__c, Last_Error__c
      FROM Inbound_Message__c
      WITH SYSTEM_MODE
    ]) {
      byId.put(row.External_Message_Id__c, row);
    }
    return byId;
  }

  private static Order orderByNumber(String orderNumber) {
    return [
      SELECT Fulfilment_Status__c, Status_Changed_At__c
      FROM Order
      WHERE OrderReferenceNumber = :orderNumber
      WITH SYSTEM_MODE
    ];
  }

  @IsTest
  static void publish_200ChangesHalfShipped_updatesEveryOrderAndRecordsTheShipments() {
    OrderTestFactory.insertOrders('ORD', 200, null);
    Datetime now = Datetime.now();
    List<Inbound_Message_Event__e> events = new List<Inbound_Message_Event__e>();
    for (Integer i = 0; i < 200; i++) {
      String orderNumber = OrderTestFactory.number('ORD', i);
      Boolean ships = Math.mod(i, 2) == 0;
      events.add(
        event(
          orderNumber + '-status',
          OrderTestFactory.payload(orderNumber, ships ? 'Shipped' : 'Picked', ships ? 'TRK-' + i : null),
          now
        )
      );
    }

    publishAndProcess(events);

    Map<String, Inbound_Message__c> messages = messagesByExternalId();
    Assert.areEqual(200, messages.size(), 'Each stored once');
    for (Inbound_Message__c message : messages.values()) {
      Assert.areEqual(MessageStatuses.PROCESSED, message.Status__c, 'Processed: ' + message.Last_Error__c);
      Assert.areEqual(1, message.Attempts__c, 'In one attempt');
    }
    Assert.areEqual('Shipped', orderByNumber('ORD-0000').Fulfilment_Status__c, 'Shipped order updated');
    Assert.areEqual('Picked', orderByNumber('ORD-0001').Fulfilment_Status__c, 'Picked order updated');
    Assert.areEqual(now, orderByNumber('ORD-0199').Status_Changed_At__c, 'Change time recorded');
    Assert.areEqual(100, [SELECT COUNT() FROM Shipment__c WITH SYSTEM_MODE], 'One shipment per shipped order');
  }

  @IsTest
  static void publish_repeatedDeliveryAndResentShipment_storesOnceAndRecordsOneShipment() {
    OrderTestFactory.insertOrders('ORD', 1, null);
    String shippedPayload = OrderTestFactory.payload('ORD-0000', 'Shipped', 'TRK-1');
    List<Inbound_Message_Event__e> events = new List<Inbound_Message_Event__e>{
      event('ORD-0000-shipped', shippedPayload, null),
      event('ORD-0000-shipped', shippedPayload, null),
      // The producer resent the shipment under a new message Id: the shipment's key absorbs it.
      event('ORD-0000-shipped-resend', shippedPayload, null)
    };

    publishAndProcess(events);

    Map<String, Inbound_Message__c> messages = messagesByExternalId();
    Assert.areEqual(2, messages.size(), 'The repeated delivery is stored once');
    Assert.areEqual(MessageStatuses.PROCESSED, messages.get('ORD-0000-shipped-resend').Status__c, 'Processed');
    List<Shipment__c> shipments = [SELECT Tracking_Number__c, Order__c FROM Shipment__c WITH SYSTEM_MODE];
    Assert.areEqual(1, shipments.size(), 'One shipment per tracking number');
  }

  @IsTest
  static void publish_changeOlderThanTheOrder_leavesTheOrderAlone() {
    Order saved = OrderTestFactory.insertOrders('ORD', 1, null)[0];
    Datetime applied = Datetime.now().addMinutes(-1);
    update new Order(Id = saved.Id, Fulfilment_Status__c = 'Delivered', Status_Changed_At__c = applied);

    publishAndProcess(
      new List<Inbound_Message_Event__e>{
        event('ORD-0000-picked', OrderTestFactory.payload('ORD-0000', 'Picked', null), applied.addMinutes(-30))
      }
    );

    Assert.areEqual(
      MessageStatuses.PROCESSED,
      messagesByExternalId().get('ORD-0000-picked').Status__c,
      'A stale change is handled'
    );
    Order after = orderByNumber('ORD-0000');
    Assert.areEqual('Delivered', after.Fulfilment_Status__c, 'The newer status stays (ADR 0005)');
    Assert.areEqual(applied, after.Status_Changed_At__c, 'The change time stays');
  }

  @IsTest
  static void publish_changeForAnUnknownOrder_failsAndIsRetried() {
    publishAndProcess(
      new List<Inbound_Message_Event__e>{
        event('ORD-404-picked', OrderTestFactory.payload('ORD-404', 'Picked', null), null)
      }
    );

    Inbound_Message__c message = messagesByExternalId().get('ORD-404-picked');
    Assert.areEqual(MessageStatuses.FAILED, message.Status__c, 'Retryable: the order may arrive later');
    Assert.areEqual(1, message.Attempts__c, 'One attempt counted');
    Assert.isNotNull(message.Next_Attempt_At__c, 'A retry is scheduled');
    Assert.isTrue(message.Last_Error__c.contains('ORD-404'), message.Last_Error__c);
  }

  @IsTest
  static void publish_shippedWithoutTrackingNumber_updatesTheOrderButGoesDead() {
    OrderTestFactory.insertOrders('ORD', 1, null);

    publishAndProcess(
      new List<Inbound_Message_Event__e>{
        event('ORD-0000-shipped', OrderTestFactory.payload('ORD-0000', 'Shipped', null), null)
      }
    );

    Inbound_Message__c message = messagesByExternalId().get('ORD-0000-shipped');
    Assert.areEqual(MessageStatuses.DEAD, message.Status__c, 'The Composite keeps the worst result (ADR 0004)');
    Assert.isTrue(message.Last_Error__c.contains('trackingNumber'), message.Last_Error__c);
    Assert.areEqual(
      'Shipped',
      orderByNumber('ORD-0000').Fulfilment_Status__c,
      'A FATAL result in one handler does not undo another handler\'s write'
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Shipment__c WITH SYSTEM_MODE], 'No shipment recorded');
  }
}
