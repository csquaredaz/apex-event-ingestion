/**
 * @description What a handler did with one message (ADR 0004): handled it (`SUCCESS`), failed in
 * a way a later attempt might fix (`RETRYABLE`), or failed for good (`FATAL`). The outcomes are
 * declared in rising severity; a Composite keeps the most severe. Immutable.
 * @group Public API
 */
public with sharing class HandlerResult {
  /** @description The three outcomes, least severe first. */
  public enum Outcome {
    SUCCESS,
    RETRYABLE,
    FATAL
  }

  private final Id messageId;
  private final Outcome resultOutcome;
  private final String error;

  private HandlerResult(Id messageId, Outcome resultOutcome, String error) {
    if (messageId == null) {
      throw new IllegalArgumentException('A HandlerResult needs the message Id it answers for.');
    }
    this.messageId = messageId;
    this.resultOutcome = resultOutcome;
    this.error = error;
  }

  /**
   * @description The message was handled.
   * @param messageId `InboundMessage.getMessageId()`.
   * @return The result.
   * @throws IllegalArgumentException If the Id is null.
   */
  public static HandlerResult success(Id messageId) {
    return new HandlerResult(messageId, Outcome.SUCCESS, null);
  }

  /**
   * @description The message failed, and a later attempt might succeed: a locked row, a record
   * that hasn't arrived yet. It is retried with backoff until it runs out of attempts.
   * @param messageId `InboundMessage.getMessageId()`.
   * @param error Why, for `Last_Error__c`. Don't include personal data from the payload.
   * @return The result.
   * @throws IllegalArgumentException If the Id is null.
   */
  public static HandlerResult retryable(Id messageId, String error) {
    return new HandlerResult(messageId, Outcome.RETRYABLE, error);
  }

  /**
   * @description The message can never succeed as sent, for example a payload that doesn't
   * parse. It goes straight to `Dead`.
   * @param messageId `InboundMessage.getMessageId()`.
   * @param error Why, for `Last_Error__c`. Don't include personal data from the payload.
   * @return The result.
   * @throws IllegalArgumentException If the Id is null.
   */
  public static HandlerResult fatal(Id messageId, String error) {
    return new HandlerResult(messageId, Outcome.FATAL, error);
  }

  /** @description @return The message this result is for. */
  public Id getMessageId() {
    return messageId;
  }

  /** @description @return The outcome. */
  public Outcome getOutcome() {
    return resultOutcome;
  }

  /** @description @return Why it failed; null on success. */
  public String getError() {
    return error;
  }

  /** @description @return True if the message was handled. */
  public Boolean isSuccess() {
    return resultOutcome == Outcome.SUCCESS;
  }

  /** @description @return True if the message should be retried. */
  public Boolean isRetryable() {
    return resultOutcome == Outcome.RETRYABLE;
  }

  /** @description @return True if the message can never succeed. */
  public Boolean isFatal() {
    return resultOutcome == Outcome.FATAL;
  }
}
