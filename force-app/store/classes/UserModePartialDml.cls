/**
 * @description The default `IPartialDml`: inserts with `allOrNone=false` in
 * `AccessLevel.USER_MODE`, so object permissions, field-level security and sharing apply per row.
 * A user without Create gets a failed result per row, not an exception, so callers check access
 * first (see `MessageStore`).
 * @group Public API
 */
public with sharing class UserModePartialDml implements IPartialDml {
  /**
   * @description Inserts in user mode, each row on its own. Limits: 1 DML statement.
   * @param records Records of one SObject type.
   * @return One save result per record, in the same order.
   */
  public List<Database.SaveResult> insertPartial(List<SObject> records) {
    return Database.insert(records, false, AccessLevel.USER_MODE);
  }
}
