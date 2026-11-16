/**
 * @description The `Inbound_Message__c.Status__c` picklist values, so code never repeats them as
 * literals (ADR 0002). Lifecycle: `Received → Processed`, or `Failed` (will retry) and then
 * `Dead` (out of attempts). There is no stored in-flight status: a processor job claims rows with
 * a row lock for the length of its transaction (ADR 0006).
 * @group Public API
 */
public with sharing class MessageStatuses {
  /** @description Stored and waiting to be dispatched. Every appended message starts here. */
  public static final String RECEIVED = 'Received';
  /** @description Every handler succeeded. */
  public static final String PROCESSED = 'Processed';
  /** @description A handler or the job failed; retried at `Next_Attempt_At__c`. */
  public static final String FAILED = 'Failed';
  /** @description Out of attempts, or failed with an error that retrying can't fix. */
  public static final String DEAD = 'Dead';
}
