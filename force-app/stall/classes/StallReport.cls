/**
 * @description What one stall sweep found (ADR 0009). Immutable.
 * @group Stall detection
 */
public with sharing class StallReport {
  /** @description The most stalled messages one sweep reads; a full list means there may be more. */
  public static final Integer MAX_STALLED = 200;

  private final Datetime stalledBefore;
  private final List<Id> stalledIds;
  private final Boolean due;

  /**
   * @description Creates a report.
   * @param stalledBefore Messages due at or before this time count as stalled.
   * @param stalledIds The stalled messages found, at most `MAX_STALLED`; null means none.
   * @param dueIds Other due messages found; null means none. Any stalled message is also due.
   */
  public StallReport(Datetime stalledBefore, List<Id> stalledIds, List<Id> dueIds) {
    this.stalledBefore = stalledBefore;
    this.stalledIds = stalledIds == null ? new List<Id>() : stalledIds.clone();
    this.due = !this.stalledIds.isEmpty() || (dueIds != null && !dueIds.isEmpty());
  }

  /** @description @return True if any message is due, so processing was requested. */
  public Boolean hasDueMessages() {
    return due;
  }

  /** @description @return The stalled messages found, oldest Id first, at most `MAX_STALLED`. */
  public List<Id> getStalledIds() {
    return stalledIds.clone();
  }

  /** @description @return True if the sweep read `MAX_STALLED` stalled messages, so there may be more. */
  public Boolean isCapped() {
    return stalledIds.size() >= MAX_STALLED;
  }

  /** @description @return The time a message must have been due by to count as stalled. */
  public Datetime getStalledBefore() {
    return stalledBefore;
  }
}
