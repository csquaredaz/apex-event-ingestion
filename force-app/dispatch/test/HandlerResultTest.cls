/**
 * @description Tests for `HandlerResult`, all in memory.
 *
 * Subject:  HandlerResult.success, retryable, fatal
 * Mocks:    none
 * Bulk:     not applicable (a value object)
 * Negative: a null message Id
 */
@IsTest
private class HandlerResultTest {
  private static final Id MESSAGE_ID = FakeId.generate(Inbound_Message__c.SObjectType);

  @IsTest
  static void success_reportsSuccessWithoutError() {
    HandlerResult result = HandlerResult.success(MESSAGE_ID);

    Assert.areEqual(MESSAGE_ID, result.getMessageId(), 'Id');
    Assert.areEqual(HandlerResult.Outcome.SUCCESS, result.getOutcome(), 'Outcome');
    Assert.isTrue(result.isSuccess() && !result.isRetryable() && !result.isFatal(), 'Only success');
    Assert.isNull(result.getError(), 'No error');
  }

  @IsTest
  static void retryable_reportsTheError() {
    HandlerResult result = HandlerResult.retryable(MESSAGE_ID, 'row locked');

    Assert.areEqual(HandlerResult.Outcome.RETRYABLE, result.getOutcome(), 'Outcome');
    Assert.isTrue(result.isRetryable() && !result.isSuccess() && !result.isFatal(), 'Only retryable');
    Assert.areEqual('row locked', result.getError(), 'Error');
  }

  @IsTest
  static void fatal_reportsTheError() {
    HandlerResult result = HandlerResult.fatal(MESSAGE_ID, 'bad payload');

    Assert.areEqual(HandlerResult.Outcome.FATAL, result.getOutcome(), 'Outcome');
    Assert.isTrue(result.isFatal() && !result.isSuccess() && !result.isRetryable(), 'Only fatal');
    Assert.areEqual('bad payload', result.getError(), 'Error');
  }

  @IsTest
  static void outcomes_areDeclaredInRisingSeverity() {
    Assert.isTrue(
      HandlerResult.Outcome.SUCCESS.ordinal() < HandlerResult.Outcome.RETRYABLE.ordinal() &&
        HandlerResult.Outcome.RETRYABLE.ordinal() < HandlerResult.Outcome.FATAL.ordinal(),
      'The Composite relies on this order'
    );
  }

  @IsTest
  static void success_nullId_throwsIllegalArgument() {
    try {
      HandlerResult.success(null);
      Assert.fail('Expected IllegalArgumentException');
    } catch (IllegalArgumentException e) {
      Assert.isTrue(e.getMessage().contains('message Id'), e.getMessage());
    }
  }
}
