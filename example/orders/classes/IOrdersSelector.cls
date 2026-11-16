/**
 * @description Selects `Order` for the example handlers (example, not packaged). Bound by
 * `DI_Binding.Orders_Selector`.
 * @group Example
 */
public interface IOrdersSelector extends ISelector {
  /**
   * @description The orders with these reference numbers, in user mode. `OrderReferenceNumber`
   * isn't unique, so a number can match more than one order.
   * @param referenceNumbers `OrderReferenceNumber` values.
   * @return The matching orders with their fulfilment fields; empty for an empty or null set.
   */
  List<Order> selectByReferenceNumbers(Set<String> referenceNumbers);
}
