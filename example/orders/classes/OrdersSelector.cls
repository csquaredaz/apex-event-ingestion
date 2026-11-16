/**
 * @description Selects `Order` in user mode (apex-core-lib's `SObjectSelector`; example, not
 * packaged). `inherited sharing`, because handlers call it from the processor job's context.
 * @group Example
 */
public inherited sharing class OrdersSelector extends SObjectSelector implements IOrdersSelector {
  /**
   * @description The type this selector queries.
   * @return `Order.SObjectType`.
   */
  public override SObjectType getSObjectType() {
    return Order.SObjectType;
  }

  /**
   * @description The key and the fulfilment fields the handlers compare.
   * @return The field list.
   */
  public override List<SObjectField> getSObjectFieldList() {
    return new List<SObjectField>{ Order.OrderReferenceNumber, Order.Fulfilment_Status__c, Order.Status_Changed_At__c };
  }

  /**
   * @description See `IOrdersSelector.selectByReferenceNumbers`. Limits: 1 SOQL, none for an
   * empty set.
   * @param referenceNumbers `OrderReferenceNumber` values.
   * @return The matching orders.
   */
  public List<Order> selectByReferenceNumbers(Set<String> referenceNumbers) {
    if (referenceNumbers == null || referenceNumbers.isEmpty()) {
      return new List<Order>();
    }
    return (List<Order>) query(
      'OrderReferenceNumber IN :referenceNumbers',
      new Map<String, Object>{ 'referenceNumbers' => referenceNumbers }
    );
  }
}
