/**
 * @description What `IMessageStore.append` did with one message (ADR 0003): stored it
 * (`ACCEPTED`), found it already stored (`DUPLICATE`), or refused it (`REJECTED`). Immutable.
 * @group Public API
 */
public with sharing class AppendResult {
  /** @description The three outcomes of an append. */
  public enum Outcome {
    ACCEPTED,
    DUPLICATE,
    REJECTED
  }

  private final Outcome resultOutcome;
  private final String idempotencyKey;
  // Set once, by the factory method that builds the result; there are no setters.
  private Id messageId;
  private String error;

  private AppendResult(Outcome resultOutcome, String idempotencyKey) {
    this.resultOutcome = resultOutcome;
    this.idempotencyKey = idempotencyKey;
  }

  /**
   * @description A message stored as a new row.
   * @param idempotencyKey The message's key.
   * @param messageId The new row's Id.
   * @return The result.
   */
  public static AppendResult accepted(String idempotencyKey, Id messageId) {
    AppendResult result = new AppendResult(Outcome.ACCEPTED, idempotencyKey);
    result.messageId = messageId;
    return result;
  }

  /**
   * @description A message whose key is already stored, by an earlier call or earlier in the same batch.
   * @param idempotencyKey The message's key.
   * @param existingId The stored row's Id, or null if the running user can't see it.
   * @return The result.
   */
  public static AppendResult duplicate(String idempotencyKey, Id existingId) {
    AppendResult result = new AppendResult(Outcome.DUPLICATE, idempotencyKey);
    result.messageId = existingId;
    return result;
  }

  /**
   * @description A message the store refused. Retrying the same message gets the same answer.
   * @param idempotencyKey The message's key, or null if it has none.
   * @param error Why it was refused.
   * @return The result.
   */
  public static AppendResult rejected(String idempotencyKey, String error) {
    AppendResult result = new AppendResult(Outcome.REJECTED, idempotencyKey);
    result.error = error;
    return result;
  }

  /** @description @return The outcome. */
  public Outcome getOutcome() {
    return resultOutcome;
  }

  /** @description @return True if the message was stored as a new row. */
  public Boolean isAccepted() {
    return resultOutcome == Outcome.ACCEPTED;
  }

  /** @description @return True if the message's key was already stored. */
  public Boolean isDuplicate() {
    return resultOutcome == Outcome.DUPLICATE;
  }

  /** @description @return True if the store refused the message. */
  public Boolean isRejected() {
    return resultOutcome == Outcome.REJECTED;
  }

  /** @description @return The idempotency key, or null when rejected for a missing source or Id. */
  public String getIdempotencyKey() {
    return idempotencyKey;
  }

  /**
   * @description The stored row: the new one when accepted, the existing one when a duplicate
   * (null if the running user can't see it), null when rejected.
   * @return The row's Id.
   */
  public Id getMessageId() {
    return messageId;
  }

  /** @description @return Why the message was rejected; null for the other outcomes. */
  public String getError() {
    return error;
  }
}
