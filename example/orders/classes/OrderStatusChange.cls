/**
 * @description One `order.status_changed` message, parsed (example, not packaged). The payload is
 * JSON: `{"orderNumber": "ORD-1042", "status": "Shipped", "carrier": "Acme Freight",
 * "trackingNumber": "1Z999"}`. Only `orderNumber` and `status` are required; unknown keys are
 * ignored, so producers can add fields without breaking the handlers.
 * @group Example
 */
public with sharing class OrderStatusChange {
  /** @description The status that means the order left the warehouse. */
  public static final String SHIPPED = 'Shipped';

  private final InboundMessage message;
  private final String orderNumber;
  private final String status;
  private final String carrier;
  private final String trackingNumber;

  // The JSON shape. A private class, so JSON.deserialize can bind to it without exposing setters.
  private class Payload {
    private String orderNumber;
    private String status;
    private String carrier;
    private String trackingNumber;
  }

  private OrderStatusChange(InboundMessage message, Payload payload) {
    this.message = message;
    orderNumber = payload.orderNumber.trim();
    status = payload.status.trim();
    carrier = payload.carrier?.trim();
    trackingNumber = payload.trackingNumber?.trim();
  }

  /**
   * @description Parses a message's payload. A payload that can't be parsed never will be, so
   * handlers answer `FATAL` for it.
   * @param message The message.
   * @return The change.
   * @throws IllegalArgumentException If the payload is missing, isn't a JSON object, or has no
   * `orderNumber` or `status`. The message says which, without quoting the payload.
   */
  public static OrderStatusChange parse(InboundMessage message) {
    String json = message?.getPayload();
    if (String.isBlank(json)) {
      throw new IllegalArgumentException('The order.status_changed payload is empty.');
    }
    Payload payload;
    try {
      payload = (Payload) System.JSON.deserialize(json, Payload.class);
    } catch (JSONException e) {
      throw new IllegalArgumentException('The order.status_changed payload is not a JSON object.');
    }
    if (payload == null || String.isBlank(payload.orderNumber) || String.isBlank(payload.status)) {
      throw new IllegalArgumentException('The order.status_changed payload needs orderNumber and status.');
    }
    return new OrderStatusChange(message, payload);
  }

  /** @description @return The message this change came from. */
  public InboundMessage getMessage() {
    return message;
  }

  /** @description @return The order's `OrderReferenceNumber`, trimmed. */
  public String getOrderNumber() {
    return orderNumber;
  }

  /** @description @return The new fulfilment status, trimmed. */
  public String getStatus() {
    return status;
  }

  /** @description @return The carrier, or null. */
  public String getCarrier() {
    return carrier;
  }

  /** @description @return The tracking number, or null. */
  public String getTrackingNumber() {
    return trackingNumber;
  }

  /** @description @return True if the status is `Shipped`, ignoring case. */
  public Boolean isShipped() {
    return SHIPPED.equalsIgnoreCase(status);
  }

  /**
   * @description Whether this change happened strictly before another one (ADR 0005). Unknown
   * times prove nothing, so they aren't older.
   * @param other The other change.
   * @return True if this change is older and should lose.
   */
  public Boolean isOlderThan(OrderStatusChange other) {
    return message.isOlderThan(other.getMessage().getOccurredAt());
  }
}
