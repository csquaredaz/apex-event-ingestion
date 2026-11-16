/**
 * @description Test data for the example handlers: in-memory messages and orders with fake Ids
 * for unit tests, and saved orders for integration tests.
 */
@IsTest
public class OrderTestFactory {
  /** @description The example's message type. */
  public static final String MESSAGE_TYPE = 'order.status_changed';
  /** @description The example's permission set. */
  public static final String EXAMPLE = 'Event_Ingestion_Example';

  /**
   * @description An `order.status_changed` payload.
   * @param orderNumber The order's reference number.
   * @param status The new status.
   * @param trackingNumber The tracking number, or null to leave it out.
   * @return The JSON.
   */
  public static String payload(String orderNumber, String status, String trackingNumber) {
    Map<String, String> body = new Map<String, String>{ 'orderNumber' => orderNumber, 'status' => status };
    if (trackingNumber != null) {
      body.put('trackingNumber', trackingNumber);
      body.put('carrier', 'Acme Freight');
    }
    return JSON.serialize(body);
  }

  /**
   * @description A handler's view of a stored message with a fake Id.
   * @param payload The payload.
   * @param occurredAt When it happened, or null.
   * @return The message.
   */
  public static InboundMessage message(String payload, Datetime occurredAt) {
    return InboundMessage.fromRecord(
      new Inbound_Message__c(
        Id = FakeId.generate(Inbound_Message__c.SObjectType),
        Message_Type__c = MESSAGE_TYPE,
        Payload__c = payload,
        Occurred_At__c = occurredAt
      )
    );
  }

  /**
   * @description An unsaved order with a fake Id, as the selector would return it.
   * @param orderNumber The reference number.
   * @param statusChangedAt When its status last changed, or null.
   * @return The order.
   */
  public static Order order(String orderNumber, Datetime statusChangedAt) {
    return new Order(
      Id = FakeId.generate(Order.SObjectType),
      OrderReferenceNumber = orderNumber,
      Status_Changed_At__c = statusChangedAt
    );
  }

  /**
   * @description Saves draft orders `<prefix>-0000`, `<prefix>-0001`, … under one account.
   * @param prefix The reference number prefix.
   * @param count How many.
   * @param ownerId The owner of the account and orders, or null for the running user.
   * @return The saved orders, in number order.
   */
  public static List<Order> insertOrders(String prefix, Integer count, Id ownerId) {
    Id owner = ownerId == null ? UserInfo.getUserId() : ownerId;
    Account customer = new Account(Name = 'Example customer', OwnerId = owner);
    insert customer;
    List<Order> orders = new List<Order>();
    for (Integer i = 0; i < count; i++) {
      orders.add(
        new Order(
          AccountId = customer.Id,
          OwnerId = owner,
          EffectiveDate = Date.today(),
          Status = 'Draft',
          OrderReferenceNumber = number(prefix, i)
        )
      );
    }
    insert orders;
    return orders;
  }

  /**
   * @description The reference number `insertOrders` gives the order at an index.
   * @param prefix The prefix.
   * @param index The index.
   * @return The number, for example `ORD-0007`.
   */
  public static String number(String prefix, Integer index) {
    return prefix + '-' + String.valueOf(index).leftPad(4, '0');
  }
}
