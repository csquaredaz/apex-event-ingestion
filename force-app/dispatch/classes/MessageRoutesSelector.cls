/**
 * @description The default `IMessageRoutesSelector`. It reads routes with
 * `Message_Route__mdt.getAll()`, which uses the metadata cache: no SOQL and no object access
 * check, so the Automated Process user needs no permission for it. `inherited sharing` because it
 * reads no records.
 * @group Dispatch
 */
public inherited sharing class MessageRoutesSelector implements IMessageRoutesSelector {
  private final List<Message_Route__mdt> rows;

  /** @description Reads the org's routes. */
  public MessageRoutesSelector() {
    this(null);
  }

  /**
   * @description Test seam: custom metadata can't be inserted in a test, so rows are injected.
   * @param rows Rows to use instead of `getAll()`; null means read the org.
   */
  @TestVisible
  private MessageRoutesSelector(List<Message_Route__mdt> rows) {
    this.rows = rows;
  }

  /**
   * @description See `IMessageRoutesSelector.selectActiveByMessageTypes`. Limits: no SOQL.
   * @param messageTypes Message types.
   * @return The active routes in run order.
   */
  public List<Message_Route__mdt> selectActiveByMessageTypes(Set<String> messageTypes) {
    List<Message_Route__mdt> matches = new List<Message_Route__mdt>();
    Set<String> wanted = lowerCased(messageTypes);
    if (wanted.isEmpty()) {
      return matches;
    }
    for (Message_Route__mdt row : rows != null ? rows : Message_Route__mdt.getAll().values()) {
      if (row.Is_Active__c && row.Message_Type__c != null && wanted.contains(row.Message_Type__c.toLowerCase())) {
        matches.add(row);
      }
    }
    matches.sort(new RunOrder());
    return matches;
  }

  private static Set<String> lowerCased(Set<String> messageTypes) {
    Set<String> lower = new Set<String>();
    for (String messageType : messageTypes == null ? new Set<String>() : messageTypes) {
      if (messageType != null) {
        lower.add(messageType.toLowerCase());
      }
    }
    return lower;
  }

  /** `Order__c` ascending, a missing order last, then `DeveloperName`, so the order is stable. */
  private class RunOrder implements Comparator<Message_Route__mdt> {
    public Integer compare(Message_Route__mdt left, Message_Route__mdt right) {
      Decimal leftOrder = left.Order__c == null ? 10000 : left.Order__c;
      Decimal rightOrder = right.Order__c == null ? 10000 : right.Order__c;
      if (leftOrder != rightOrder) {
        return leftOrder < rightOrder ? -1 : 1;
      }
      return (left.DeveloperName == null ? '' : left.DeveloperName)
        .compareTo(right.DeveloperName == null ? '' : right.DeveloperName);
    }
  }
}
