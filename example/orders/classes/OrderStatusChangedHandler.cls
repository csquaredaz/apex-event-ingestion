/**
 * @description Applies `order.status_changed` to the order's fulfilment fields (example, not
 * packaged; route `Message_Route.Order_Status_Changed_Order`, run first).
 *
 * It follows the handler contract (`IMessageHandler`):
 * - **Order-free** (ADR 0005): a message older than the order's `Status_Changed_At__c` is skipped
 *   and answered `SUCCESS`. Of several messages for one order in the same batch, the newest wins.
 *   A message with no `Occurred_At__c` proves nothing, so it's applied (last writer wins) and
 *   leaves `Status_Changed_At__c` as it was.
 * - **Idempotent:** applying the same change twice writes the same values.
 * - **Bulk:** one upsert keyed on `OrderReferenceNumber` (apex-core-lib's `registerUpsert`), only
 *   for orders the base class found, so it never creates an order.
 * @group Example
 */
public with sharing class OrderStatusChangedHandler extends OrderMessageHandler {
  /**
   * @description Applies the newest fresh change per order. Limits: 1 DML statement (Unit of Work,
   * user mode), none when every change is stale.
   * @param changes The changes, in message order.
   * @param orderByNumber Each change's order.
   * @return `SUCCESS` for every change: applied, stale or superseded.
   */
  protected override List<HandlerResult> apply(List<OrderStatusChange> changes, Map<String, Order> orderByNumber) {
    List<HandlerResult> results = new List<HandlerResult>();
    Map<String, OrderStatusChange> newestByNumber = new Map<String, OrderStatusChange>();
    for (OrderStatusChange change : changes) {
      String orderKey = key(change.getOrderNumber());
      OrderStatusChange current = newestByNumber.get(orderKey);
      Boolean stale = change.getMessage().isOlderThan(orderByNumber.get(orderKey).Status_Changed_At__c);
      if (!stale && (current == null || !change.isOlderThan(current))) {
        newestByNumber.put(orderKey, change);
      }
      // Every change succeeds: a stale or superseded one is handled by doing nothing.
      results.add(HandlerResult.success(change.getMessage().getMessageId()));
    }
    if (newestByNumber.isEmpty()) {
      return results;
    }
    List<Order> updates = new List<Order>();
    for (String orderKey : newestByNumber.keySet()) {
      updates.add(toOrder(newestByNumber.get(orderKey), orderByNumber.get(orderKey)));
    }
    IUnitOfWork unitOfWork = Application.UnitOfWork.newInstance(new List<SObjectType>{ Order.SObjectType });
    unitOfWork.registerUpsert(updates, Order.OrderReferenceNumber);
    unitOfWork.commitWork();
    return results;
  }

  private Order toOrder(OrderStatusChange change, Order existing) {
    // The stored number, not the message's: the match is case-insensitive, the field isn't.
    Order row = new Order(
      OrderReferenceNumber = existing.OrderReferenceNumber,
      Fulfilment_Status__c = change.getStatus()
    );
    Datetime occurredAt = change.getMessage().getOccurredAt();
    if (occurredAt != null) {
      row.Status_Changed_At__c = occurredAt;
    }
    return row;
  }
}
