/**
 * @description The port that queues processor jobs (ADR 0006). `MessageProcessing` and
 * `MessageProcessorFinalizer` enqueue through it, so tests can stand in a mock: a test context
 * refuses, with an uncatchable `LimitException`, any job enqueued from the Finalizer of a job that
 * succeeded. The `DI_Binding.Processor_Queue` row binds `ProcessorQueue`.
 * @group Processing
 */
public interface IProcessorQueue {
  /**
   * @description Enqueues a `MessageProcessorJob` under the shared duplicate signature.
   * @param delayMinutes Minutes to wait, from 0 to 10; null or negative means 0, more means 10.
   * @return The job Id, or null if a processor job is already queued.
   */
  Id enqueue(Integer delayMinutes);
}
