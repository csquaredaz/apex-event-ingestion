/**
 * @description The `Inbound_Message__c.Status__c` picklist values, so code never repeats them as
 * literals (ADR 0002). Lifecycle: `Received → Processing → Processed`, or `Failed` (will retry)
 * and then `Dead` (out of attempts).
 * @group Public API
 */
public with sharing class MessageStatuses {
  /** @description Stored and waiting to be dispatched. Every appended message starts here. */
  public static final String RECEIVED = 'Received';
  /** @description Claimed by a processor job, which holds a lock until `Locked_Until__c`. */
  public static final String PROCESSING = 'Processing';
  /** @description Every handler succeeded. */
  public static final String PROCESSED = 'Processed';
  /** @description A handler or the job failed; retried at `Next_Attempt_At__c`. */
  public static final String FAILED = 'Failed';
  /** @description Out of attempts, or failed with an error that retrying can't fix. */
  public static final String DEAD = 'Dead';
}
