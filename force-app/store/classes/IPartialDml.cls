/**
 * @description Partial-success DML (Strategy), the seam that lets `MessageStore` be unit tested
 * with a Stub API mock. apex-core-lib's `IDml` and `IUnitOfWork` are all-or-none by contract, and
 * the store needs each row to succeed or fail on its own (ADR 0003). Bound to
 * `UserModePartialDml` by the `DI_Binding.User_Mode_Partial_Dml` row.
 * @group Public API
 */
public interface IPartialDml {
  /**
   * @description Inserts the records with `allOrNone=false`. Inserted Ids are set on the records.
   * @param records Records of one SObject type.
   * @return One save result per record, in the same order.
   */
  List<Database.SaveResult> insertPartial(List<SObject> records);
}
