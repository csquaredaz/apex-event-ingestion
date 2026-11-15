/**
 * @description Reads `Message_Route__mdt`. Bound to `MessageRoutesSelector` by the
 * `DI_Binding.Message_Routes_Selector` row, so router tests can stand in routes, which custom
 * metadata can't be inserted to provide.
 * @group Dispatch
 */
public interface IMessageRoutesSelector {
  /**
   * @description Selects the active routes for the given message types, matched
   * case-insensitively, in run order: `Order__c` ascending, then `DeveloperName`.
   * @param messageTypes Message types; null or empty returns an empty list.
   * @return The active routes.
   */
  List<Message_Route__mdt> selectActiveByMessageTypes(Set<String> messageTypes);
}
