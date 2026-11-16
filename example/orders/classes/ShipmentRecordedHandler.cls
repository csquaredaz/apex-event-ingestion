/**
 * @description Records a `Shipment__c` when `order.status_changed` says `Shipped` (example, not
 * packaged; route `Message_Route.Order_Status_Changed_Shipment`, run second). With
 * `OrderStatusChangedHandler` on the same type, the route is a Composite (ADR 0004): the worst
 * result per message wins, so a `Shipped` message with no tracking number goes `Dead` even
 * though the order handler applied it.
 *
 * Idempotent by its upsert key: `Tracking_Number__c` is a unique external Id, so a redelivered
 * message updates the same shipment instead of adding one. Of several messages for one tracking
 * number in a batch, the last is written (a repeated key would fail the whole upsert).
 * @group Example
 */
public with sharing class ShipmentRecordedHandler extends OrderMessageHandler {
  /**
   * @description Only shipped orders have a shipment.
   * @param change A parsed change.
   * @return True if the status is `Shipped`.
   */
  protected override Boolean actsOn(OrderStatusChange change) {
    return change.isShipped();
  }

  /**
   * @description Upserts one shipment per tracking number. Limits: 1 DML statement (Unit of Work,
   * user mode), none when no change has a tracking number.
   * @param changes The shipped changes, in message order.
   * @param orderByNumber Each change's order.
   * @return `FATAL` for a change with no tracking number, else `SUCCESS`.
   */
  protected override List<HandlerResult> apply(List<OrderStatusChange> changes, Map<String, Order> orderByNumber) {
    List<HandlerResult> results = new List<HandlerResult>();
    // Tracking_Number__c is unique ignoring case, so the batch dedupe ignores case too.
    Map<String, Shipment__c> shipmentByTracking = new Map<String, Shipment__c>();
    for (OrderStatusChange change : changes) {
      Id messageId = change.getMessage().getMessageId();
      if (String.isBlank(change.getTrackingNumber())) {
        results.add(HandlerResult.fatal(messageId, 'A Shipped order.status_changed needs trackingNumber.'));
        continue;
      }
      shipmentByTracking.put(change.getTrackingNumber().toLowerCase(), toShipment(change, orderByNumber));
      results.add(HandlerResult.success(messageId));
    }
    if (shipmentByTracking.isEmpty()) {
      return results;
    }
    IUnitOfWork unitOfWork = Application.UnitOfWork.newInstance(new List<SObjectType>{ Shipment__c.SObjectType });
    unitOfWork.registerUpsert(shipmentByTracking.values(), Shipment__c.Tracking_Number__c);
    unitOfWork.commitWork();
    return results;
  }

  // A value the message leaves out isn't set, so a resend without it keeps what the shipment has.
  private Shipment__c toShipment(OrderStatusChange change, Map<String, Order> orderByNumber) {
    Shipment__c row = new Shipment__c(
      Tracking_Number__c = change.getTrackingNumber(),
      Order__c = orderByNumber.get(key(change.getOrderNumber())).Id
    );
    if (change.getCarrier() != null) {
      row.Carrier__c = change.getCarrier();
    }
    if (change.getMessage().getOccurredAt() != null) {
      row.Shipped_At__c = change.getMessage().getOccurredAt();
    }
    return row;
  }
}
