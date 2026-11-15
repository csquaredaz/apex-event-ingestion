/**
 * @description Tests for `MessageProcessing.enqueue`, the entry point intake calls.
 *
 * Subject:  MessageProcessing.enqueue
 * Mocks:    IProcessorQueue
 * Bulk:     not applicable (one job per call)
 * Negative: a job already queued (the queue returns null)
 */
@IsTest
private class MessageProcessingTest {
  @IsTest
  static void enqueue_always_asksTheBoundQueueForAJobAtOnce() {
    Id queuedId = FakeId.generate(AsyncApexJob.SObjectType);
    Mocks queueMock = new Mocks().stubReturn('enqueue', queuedId);
    Application.Service.setMock(IProcessorQueue.class, queueMock.stub(IProcessorQueue.class));

    Id jobId = MessageProcessing.enqueue();

    Assert.areEqual(queuedId, jobId, 'The queue answers');
    Assert.areEqual(0, queueMock.argumentsOf('enqueue', 0)[0], 'No delay');
  }

  @IsTest
  static void enqueue_jobAlreadyQueued_returnsNull() {
    Application.Service.setMock(IProcessorQueue.class, new Mocks().stub(IProcessorQueue.class));

    Assert.isNull(MessageProcessing.enqueue(), 'Nothing new was queued');
  }
}
