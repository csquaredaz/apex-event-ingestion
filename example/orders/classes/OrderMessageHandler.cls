/**
 * @description The shared steps of the example `order.status_changed` handlers (Template Method,
 * GoF; example, not packaged). `handle` parses every message, asks the subclass which changes it
 * acts on, finds their orders in one query, and passes the rest to `apply`:
 *
 * - a payload that can't be parsed → `FATAL` (it never will be);
 * - a change the subclass doesn't act on → `SUCCESS` (nothing to do);
 * - no order with that reference number → `RETRYABLE` (the order may not have arrived yet);
 * - more than one order with it → `FATAL` (`OrderReferenceNumber` isn't unique, and guessing
 *   would update the wrong order).
 *
 * Subclasses are bulk Commands (ADR 0004): one query here, one Unit of Work commit in `apply`,
 * no callouts. A DML failure in `apply` throws, and the dispatcher's guard rolls this handler back
 * and retries every message in the call.
 * @group Example
 */
public abstract with sharing class OrderMessageHandler implements IMessageHandler {
  /**
   * @description See `IMessageHandler.handle`. Limits: 1 SOQL (orders), plus what `apply` spends.
   * @param messages The messages, never null or empty.
   * @return One result per message.
   */
  public List<HandlerResult> handle(List<InboundMessage> messages) {
    List<HandlerResult> results = new List<HandlerResult>();
    List<OrderStatusChange> changes = new List<OrderStatusChange>();
    Set<String> orderNumbers = new Set<String>();
    for (InboundMessage message : messages) {
      try {
        OrderStatusChange change = OrderStatusChange.parse(message);
        if (actsOn(change)) {
          changes.add(change);
          orderNumbers.add(change.getOrderNumber());
        } else {
          results.add(HandlerResult.success(message.getMessageId()));
        }
      } catch (IllegalArgumentException e) {
        results.add(HandlerResult.fatal(message.getMessageId(), e.getMessage()));
      }
    }
    if (changes.isEmpty()) {
      return results;
    }
    Map<String, List<Order>> ordersByNumber = ordersByNumber(orderNumbers);
    List<OrderStatusChange> found = new List<OrderStatusChange>();
    Map<String, Order> orderByNumber = new Map<String, Order>();
    for (OrderStatusChange change : changes) {
      Id messageId = change.getMessage().getMessageId();
      List<Order> orders = ordersByNumber.get(key(change.getOrderNumber()));
      if (orders == null) {
        results.add(
          HandlerResult.retryable(messageId, 'No order has reference number ' + change.getOrderNumber() + '.')
        );
      } else if (orders.size() > 1) {
        results.add(
          HandlerResult.fatal(
            messageId,
            orders.size() + ' orders have reference number ' + change.getOrderNumber() + '.'
          )
        );
      } else {
        found.add(change);
        orderByNumber.put(key(change.getOrderNumber()), orders[0]);
      }
    }
    if (!found.isEmpty()) {
      results.addAll(apply(found, orderByNumber));
    }
    return results;
  }

  /**
   * @description Whether this handler has anything to do for a change. Defaults to every change.
   * @param change A parsed change.
   * @return False to answer `SUCCESS` without looking the order up.
   */
  protected virtual Boolean actsOn(OrderStatusChange change) {
    return true;
  }

  /**
   * @description Applies the changes whose order was found, in bulk.
   * @param changes The changes, in message order.
   * @param orderByNumber Each change's order, keyed by `key(change.getOrderNumber())`.
   * @return One result per change.
   */
  protected abstract List<HandlerResult> apply(List<OrderStatusChange> changes, Map<String, Order> orderByNumber);

  /**
   * @description The map key for a reference number. SOQL matches text case-insensitively, so
   * keys are lower case.
   * @param orderNumber A reference number.
   * @return The key.
   */
  protected String key(String orderNumber) {
    return orderNumber.toLowerCase();
  }

  private Map<String, List<Order>> ordersByNumber(Set<String> orderNumbers) {
    IOrdersSelector selector = (IOrdersSelector) Application.Selector.newInstance(Order.SObjectType);
    Map<String, List<Order>> byNumber = new Map<String, List<Order>>();
    for (Order row : selector.selectByReferenceNumbers(orderNumbers)) {
      String rowKey = key(row.OrderReferenceNumber);
      if (!byNumber.containsKey(rowKey)) {
        byNumber.put(rowKey, new List<Order>());
      }
      byNumber.get(rowKey).add(row);
    }
    return byNumber;
  }
}
