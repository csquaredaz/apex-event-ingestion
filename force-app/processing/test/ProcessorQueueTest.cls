/**
 * @description Tests for `ProcessorQueue`: it queues one processor job, and the duplicate
 * signature turns a second enqueue into a no-op while the first is still queued.
 *
 * In a test context the rejected job still leaves a second `AsyncApexJob` row, so these tests
 * assert the returned Ids. In a real org the second enqueue creates no row (probe 3b, ADR 0006).
 *
 * Subject:  ProcessorQueue.enqueue
 * Mocks:    none (the platform queue)
 * Bulk:     not applicable (one job per call)
 * Negative: a second enqueue while one is queued, out-of-range and null delays
 */
@IsTest
private class ProcessorQueueTest {
  @IsTest
  static void enqueue_nothingQueued_queuesOneProcessorJob() {
    Id jobId = new ProcessorQueue().enqueue(0);

    List<AsyncApexJob> jobs = [SELECT Id, Status FROM AsyncApexJob WHERE ApexClass.Name = 'MessageProcessorJob'];
    Assert.areEqual(1, jobs.size(), 'One job');
    Assert.areEqual(jobId, jobs[0].Id, 'Its Id is returned');
    Assert.areEqual('Queued', jobs[0].Status, 'Waiting to run');
  }

  @IsTest
  static void enqueue_whileOneIsQueued_returnsNull() {
    ProcessorQueue queue = new ProcessorQueue();

    Assert.isNotNull(queue.enqueue(0), 'The first is queued');
    Assert.isNull(queue.enqueue(5), 'The duplicate signature rejects the second');
  }

  @IsTest
  static void enqueue_delayAboveTheMaximum_isClampedInsteadOfThrowing() {
    Assert.isNotNull(new ProcessorQueue().enqueue(25), 'More than 10 minutes is clamped to 10');
  }

  @IsTest
  static void enqueue_negativeOrNullDelay_isTreatedAsZero() {
    ProcessorQueue queue = new ProcessorQueue();

    Assert.isNotNull(queue.enqueue(-3), 'Negative is clamped to 0');
    Assert.isNull(queue.enqueue(null), 'Null means 0; the first is still queued');
  }

  @IsTest
  static void signature_always_fitsThePlatformLimitOf32Bytes() {
    Assert.isTrue(Blob.valueOf(ProcessorQueue.JOB_SIGNATURE).size() <= 32, ProcessorQueue.JOB_SIGNATURE);
  }

  @IsTest
  static void binding_forProcessorQueue_resolvesTheQueue() {
    Assert.isInstanceOfType(
      Application.Service.newInstance(IProcessorQueue.class),
      ProcessorQueue.class,
      'DI_Binding.Processor_Queue'
    );
  }
}
