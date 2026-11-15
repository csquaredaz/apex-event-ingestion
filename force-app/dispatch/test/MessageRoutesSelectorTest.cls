/**
 * @description Tests for `MessageRoutesSelector`, with injected rows (custom metadata can't be
 * inserted in a test).
 *
 * Subject:  MessageRoutesSelector.selectActiveByMessageTypes
 * Mocks:    injected Message_Route__mdt rows
 * Bulk:     not applicable (no SOQL; the cache read is asserted)
 * Negative: null and empty types, inactive rows, other types, a missing order
 */
@IsTest
private class MessageRoutesSelectorTest {
  private static final String ORDER_TYPE = 'order.status_changed';

  @IsTest
  static void binding_resolvesTheSelector() {
    Assert.isInstanceOfType(
      Application.Service.newInstance(IMessageRoutesSelector.class),
      MessageRoutesSelector.class,
      'DI_Binding.Message_Routes_Selector'
    );
  }

  @IsTest
  static void selectActiveByMessageTypes_mixedRows_returnsActiveMatchesInRunOrder() {
    Message_Route__mdt inactive = DispatchTestHandlers.route('Inactive', ORDER_TYPE, 'X');
    inactive.Is_Active__c = false;
    Message_Route__mdt unordered = DispatchTestHandlers.ordered(
      DispatchTestHandlers.route('Unordered', ORDER_TYPE, 'X'),
      null
    );
    MessageRoutesSelector selector = new MessageRoutesSelector(
      new List<Message_Route__mdt>{
        DispatchTestHandlers.ordered(DispatchTestHandlers.route('Shipping', ORDER_TYPE, 'X'), 20),
        unordered,
        inactive,
        DispatchTestHandlers.route('Other_Type', 'customer.updated', 'X'),
        DispatchTestHandlers.ordered(DispatchTestHandlers.route('Billing', 'Order.Status_Changed', 'X'), 10),
        DispatchTestHandlers.ordered(DispatchTestHandlers.route('Audit', ORDER_TYPE, 'X'), 10)
      }
    );

    List<Message_Route__mdt> routes = selector.selectActiveByMessageTypes(new Set<String>{ ORDER_TYPE });

    List<String> names = new List<String>();
    for (Message_Route__mdt route : routes) {
      names.add(route.DeveloperName);
    }
    Assert.areEqual(
      new List<String>{ 'Audit', 'Billing', 'Shipping', 'Unordered' },
      names,
      'Active, type matched ignoring case, by Order__c then name, a missing order last'
    );
  }

  @IsTest
  static void selectActiveByMessageTypes_nullOrEmpty_returnsNothing() {
    MessageRoutesSelector selector = new MessageRoutesSelector(
      new List<Message_Route__mdt>{ DispatchTestHandlers.route('Audit', ORDER_TYPE, 'X') }
    );

    Assert.areEqual(0, selector.selectActiveByMessageTypes(null).size(), 'Null types');
    Assert.areEqual(0, selector.selectActiveByMessageTypes(new Set<String>()).size(), 'Empty types');
    Assert.areEqual(0, selector.selectActiveByMessageTypes(new Set<String>{ null }).size(), 'A null type');
  }

  @IsTest
  static void selectActiveByMessageTypes_orgRows_readsTheCacheWithoutSoql() {
    // The package ships no routes; example/ adds them. An unknown type has none in any org.
    List<Message_Route__mdt> routes = new MessageRoutesSelector()
      .selectActiveByMessageTypes(new Set<String>{ 'no.such.type' });

    Assert.areEqual(0, routes.size(), 'No route for an unknown type');
    Assert.areEqual(0, Limits.getQueries(), 'getAll() spends no SOQL');
  }
}
