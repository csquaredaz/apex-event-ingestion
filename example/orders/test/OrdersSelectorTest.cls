/**
 * @description Integration tests for `OrdersSelector`: real orders, read in user mode by a
 * Minimum Access user with and without `Event_Ingestion_Example`.
 *
 * Subject:  OrdersSelector.selectByReferenceNumbers
 * Mocks:    none (real DML)
 * Bulk:     n/a (one indexed IN filter)
 * Negative: an empty set (no query); a user without the permission set (refused)
 */
@IsTest
private class OrdersSelectorTest {
  @IsTest
  static void selectByReferenceNumbers_withExamplePermission_returnsTheMatches() {
    User reader = EventIngestionTestFactory.minimumAccessUser(OrderTestFactory.EXAMPLE);
    System.runAs(new User(Id = UserInfo.getUserId())) {
      OrderTestFactory.insertOrders('ORD', 3, reader.Id);
    }

    List<Order> rows;
    System.runAs(reader) {
      Test.startTest();
      rows = new OrdersSelector().selectByReferenceNumbers(new Set<String>{ 'ORD-0000', 'ord-0002', 'ORD-9999' });
      Test.stopTest();
    }

    Assert.areEqual(2, rows.size(), 'Matches ignoring case; unknown numbers return nothing');
    Assert.areEqual('ORD-0000', rows[0].OrderReferenceNumber, 'Id order, with the key');
    Assert.isNull(rows[0].Fulfilment_Status__c, 'The fulfilment fields are selected');
  }

  @IsTest
  static void selectByReferenceNumbers_withoutPermission_isRefused() {
    User stranger = EventIngestionTestFactory.minimumAccessUser(null);

    System.runAs(stranger) {
      try {
        new OrdersSelector().selectByReferenceNumbers(new Set<String>{ 'ORD-0000' });
        Assert.fail('Expected a user-mode refusal');
      } catch (QueryException e) {
        Assert.isNotNull(e.getMessage(), 'User mode refuses an object the user can\'t read');
      }
    }
  }

  @IsTest
  static void selectByReferenceNumbers_emptyOrNull_queriesNothing() {
    OrdersSelector selector = new OrdersSelector();

    Test.startTest();
    Assert.isTrue(selector.selectByReferenceNumbers(new Set<String>()).isEmpty(), 'Empty in, empty out');
    Assert.isTrue(selector.selectByReferenceNumbers(null).isEmpty(), 'Null in, empty out');
    Assert.areEqual(0, Limits.getQueries(), 'No SOQL spent');
    Test.stopTest();

    Assert.areEqual(Order.SObjectType, selector.getSObjectType(), 'Selects Order');
  }
}
