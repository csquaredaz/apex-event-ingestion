/**
 * @description The default `IMessageLifecycle` (ADR 0006): a stateless service that writes status
 * changes through apex-core-lib's Unit of Work (user mode) and alerts through `IAlertSink` when
 * messages go `Dead`. Errors are cut to `Last_Error__c`'s 32,768 characters, because dispatch
 * joins the errors of every route without truncating them (ADR 0004).
 * @group Processing
 */
public with sharing class MessageLifecycle implements IMessageLifecycle {
  /** @description The length of `Inbound_Message__c.Last_Error__c`. */
  public static final Integer LAST_ERROR_LENGTH = 32768;

  private static final String NO_RESULT = 'Dispatch returned no result for this message.';
  private static final String NO_ERROR = 'No error message was given.';

  /**
   * @description See `IMessageLifecycle.recordResults`. Limits: 1 DML statement (Unit of Work),
   * no SOQL; bulk-safe at 200.
   * @param claimed The claimed rows.
   * @param results The results, keyed by message Id.
   * @return The earliest retry time scheduled, or null.
   */
  public Datetime recordResults(List<Inbound_Message__c> claimed, Map<Id, HandlerResult> results) {
    Map<Id, HandlerResult> resultsById = results == null ? new Map<Id, HandlerResult>() : results;
    List<Outcome> outcomes = new List<Outcome>();
    for (Inbound_Message__c row : claimed == null ? new List<Inbound_Message__c>() : claimed) {
      HandlerResult result = resultsById.get(row.Id);
      outcomes.add(new Outcome(row, result != null ? result : HandlerResult.retryable(row.Id, NO_RESULT)));
    }
    return write(outcomes);
  }

  /**
   * @description See `IMessageLifecycle.recordJobFailure`. Limits: 1 SOQL (selector, user mode),
   * 1 DML statement (Unit of Work); bulk-safe at 200.
   * @param messageIds The messages the failed job had claimed.
   * @param error Why the job failed.
   * @return The earliest retry time scheduled, or null.
   */
  public Datetime recordJobFailure(Set<Id> messageIds, String error) {
    if (messageIds == null || messageIds.isEmpty()) {
      return null;
    }
    IInboundMessagesSelector selector = (IInboundMessagesSelector) Application.Selector.newInstance(
      Inbound_Message__c.SObjectType
    );
    List<Outcome> outcomes = new List<Outcome>();
    for (Inbound_Message__c row : (List<Inbound_Message__c>) selector.selectSObjectsById(messageIds)) {
      // A real failure rolled the job back, so its rows are as they were when claimed. A terminal
      // row means its outcome already committed; counting another attempt would be wrong.
      if (row.Status__c == MessageStatuses.RECEIVED || row.Status__c == MessageStatuses.FAILED) {
        outcomes.add(new Outcome(row, HandlerResult.retryable(row.Id, error)));
      }
    }
    return write(outcomes);
  }

  /** Registers one update per outcome, commits once and alerts on any Dead message. */
  private static Datetime write(List<Outcome> outcomes) {
    if (outcomes.isEmpty()) {
      return null;
    }
    RetrySchedule schedule = IngestionSettings.current().getRetrySchedule();
    Datetime now = Datetime.now();
    Datetime earliestRetry;
    List<Inbound_Message__c> updates = new List<Inbound_Message__c>();
    List<Id> deadIds = new List<Id>();
    for (Outcome outcome : outcomes) {
      Inbound_Message__c change = outcome.toUpdate(schedule, now);
      updates.add(change);
      if (change.Status__c == MessageStatuses.DEAD) {
        deadIds.add(change.Id);
      } else if (change.Next_Attempt_At__c != null) {
        earliestRetry = earliestRetry == null ||
          change.Next_Attempt_At__c < earliestRetry
          ? change.Next_Attempt_At__c
          : earliestRetry;
      }
    }
    IUnitOfWork uow = Application.UnitOfWork.newInstance(new List<SObjectType>{ Inbound_Message__c.SObjectType });
    uow.registerDirty(updates);
    uow.commitWork();
    if (!deadIds.isEmpty()) {
      alertDead(deadIds);
    }
    return earliestRetry;
  }

  /** One alert per call, naming Ids only: errors can quote payload data. */
  private static void alertDead(List<Id> deadIds) {
    List<Id> sample = new List<Id>();
    for (Integer i = 0; i < Math.min(deadIds.size(), 10); i++) {
      sample.add(deadIds[i]);
    }
    ((IAlertSink) Application.Service.newInstance(IAlertSink.class))
      .send(
        new List<Alert>{
          new Alert(
            Alert.Severity.WARNING,
            deadIds.size() + ' inbound message(s) went Dead',
            'They will not be retried. Inbound_Message__c Ids (first 10): ' + String.join(sample, ', '),
            MessageLifecycle.class.getName()
          )
        }
      );
  }

  /**
   * @description @param error An error, possibly null or longer than the field.
   * @return The error cut to `Last_Error__c`'s length, or a placeholder if it was blank.
   */
  @TestVisible
  private static String truncate(String error) {
    return String.isBlank(error) ? NO_ERROR : error.abbreviate(LAST_ERROR_LENGTH);
  }

  /** One claimed row and what happened to it. */
  private class Outcome {
    private final Inbound_Message__c row;
    private final HandlerResult result;

    private Outcome(Inbound_Message__c row, HandlerResult result) {
      this.row = row;
      this.result = result;
    }

    /** The update for this row; null fields are cleared on purpose. */
    private Inbound_Message__c toUpdate(RetrySchedule schedule, Datetime now) {
      Integer attempts = (row.Attempts__c == null ? 0 : row.Attempts__c.intValue()) + 1;
      if (result.isSuccess()) {
        return new Inbound_Message__c(
          Id = row.Id,
          Attempts__c = attempts,
          Status__c = MessageStatuses.PROCESSED,
          Processed_At__c = now,
          Next_Attempt_At__c = null,
          Last_Error__c = null
        );
      }
      Boolean retry = result.isRetryable() && !schedule.isExhausted(attempts);
      return new Inbound_Message__c(
        Id = row.Id,
        Attempts__c = attempts,
        Status__c = retry ? MessageStatuses.FAILED : MessageStatuses.DEAD,
        Next_Attempt_At__c = retry ? schedule.nextAttemptAt(attempts, now) : null,
        Last_Error__c = truncate(result.getError())
      );
    }
  }
}
