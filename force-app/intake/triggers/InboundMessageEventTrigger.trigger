/**
 * @description Stores inbound message events. All logic is in `InboundMessageEventsDomain`, bound
 * by `DI_Binding.Inbound_Message_Events_Domain`; a `Trigger_Setting__mdt` row can switch intake
 * off (ADR 0007).
 */
trigger InboundMessageEventTrigger on Inbound_Message_Event__e(after insert) {
  TriggerDispatcher.run();
}
