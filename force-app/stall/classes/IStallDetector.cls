/**
 * @description Finds messages that are due but not being processed, wakes processing and alerts on
 * stalls (ADR 0009). `StallSweeperSchedulable` calls it four times an hour. The
 * `DI_Binding.Stall_Detector` row binds `StallDetector`.
 * @group Stall detection
 */
public interface IStallDetector {
  /**
   * @description Sweeps once: requests a processor run when any message is due, and raises one
   * WARNING alert when any has been due for longer than `Stall_After_Minutes__c`.
   * @param now The time of the sweep.
   * @return What the sweep found.
   */
  StallReport sweep(Datetime now);
}
