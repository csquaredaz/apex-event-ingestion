/**
 * @description Starts a processor job as the Automated Process user. All logic is in
 * `ProcessorWakeEventsDomain`, bound by `DI_Binding.Processor_Wake_Events_Domain` (ADR 0009).
 */
trigger ProcessorWakeEventTrigger on Processor_Wake_Event__e(after insert) {
  TriggerDispatcher.run();
}
