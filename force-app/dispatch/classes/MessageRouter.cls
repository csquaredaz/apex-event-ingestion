/**
 * @description The default `IMessageRouter`: reads `Message_Route__mdt` through
 * `IMessageRoutesSelector` and builds handlers with `Type.forName`. Handler classes may live
 * outside this package, for example in the unpackaged `example/` folder: with no namespace, a
 * `public` class resolves from packaged code (probed 2026-11-15).
 * @group Dispatch
 */
public with sharing class MessageRouter implements IMessageRouter {
  /**
   * @description See `IMessageRouter.handlersFor`. Limits: no SOQL; one `Type.forName` and one
   * constructor call per route.
   * @param messageTypes The message types to route.
   * @return Handlers keyed by the type as given.
   */
  public Map<String, IMessageHandler> handlersFor(Set<String> messageTypes) {
    Map<String, IMessageHandler> handlersByType = new Map<String, IMessageHandler>();
    if (messageTypes == null || messageTypes.isEmpty()) {
      return handlersByType;
    }
    IMessageRoutesSelector routes = (IMessageRoutesSelector) Application.Service.newInstance(
      IMessageRoutesSelector.class
    );
    Map<String, List<IMessageHandler>> childrenByLowerType = new Map<String, List<IMessageHandler>>();
    for (Message_Route__mdt route : routes.selectActiveByMessageTypes(messageTypes)) {
      String lowerType = route.Message_Type__c.toLowerCase();
      if (!childrenByLowerType.containsKey(lowerType)) {
        childrenByLowerType.put(lowerType, new List<IMessageHandler>());
      }
      childrenByLowerType.get(lowerType).add(guarded(route));
    }
    for (String messageType : messageTypes) {
      List<IMessageHandler> children = messageType == null ? null : childrenByLowerType.get(messageType.toLowerCase());
      if (children != null) {
        handlersByType.put(messageType, children.size() == 1 ? children[0] : new CompositeMessageHandler(children));
      }
    }
    return handlersByType;
  }

  private static IMessageHandler guarded(Message_Route__mdt route) {
    String routeName = route.DeveloperName;
    Type handlerType = String.isBlank(route.Handler_Class__c) ? null : Type.forName(route.Handler_Class__c);
    if (handlerType == null) {
      return GuardedMessageHandler.misconfigured(
        routeName,
        'Route ' + routeName + ' names handler ' + route.Handler_Class__c + ', which does not exist or is not public.'
      );
    }
    if (!IMessageHandler.class.isAssignableFrom(handlerType)) {
      return GuardedMessageHandler.misconfigured(
        routeName,
        'Route ' + routeName + ' names ' + handlerType.getName() + ', which does not implement IMessageHandler.'
      );
    }
    try {
      return GuardedMessageHandler.of(routeName, (IMessageHandler) handlerType.newInstance());
    } catch (Exception e) {
      return GuardedMessageHandler.misconfigured(
        routeName,
        'Route ' + routeName + ' could not construct ' + handlerType.getName() + ': ' + e.getMessage()
      );
    }
  }
}
