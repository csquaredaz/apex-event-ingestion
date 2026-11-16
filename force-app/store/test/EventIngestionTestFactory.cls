/**
 * @description Test data for the ingestion tests: unsaved messages with valid defaults, fake
 * save results for Stub API tests, and Minimum Access users with or without the feature's
 * permission sets. Public so later features' tests can reuse it.
 * @group Testing
 */
@IsTest
public class EventIngestionTestFactory {
  /** @description The source every default message comes from. */
  public static final String SOURCE = 'erp';
  /** @description The message type every default message carries. */
  public static final String MESSAGE_TYPE = 'order.status_changed';
  /** @description The permission set the ingestion user needs. */
  public static final String PROCESSOR = 'Event_Ingestion_Processor';
  /** @description The read-only operator permission set. */
  public static final String VIEWER = 'Event_Ingestion_Viewer';
  /** @description The permission set the stall sweeper's scheduling user needs. */
  public static final String SWEEPER = 'Event_Ingestion_Sweeper';

  /**
   * @description An unsaved order-status message.
   * @param source The producing system.
   * @param externalMessageId The producer's message Id.
   * @return The message, with a type, payload, correlation Id and occurrence time.
   */
  public static Inbound_Message__c message(String source, String externalMessageId) {
    return new Inbound_Message__c(
      Source__c = source,
      External_Message_Id__c = externalMessageId,
      Message_Type__c = MESSAGE_TYPE,
      Payload__c = '{"orderNumber":"' + externalMessageId + '","status":"Shipped"}',
      Correlation_Id__c = 'corr-' + externalMessageId,
      Occurred_At__c = Datetime.newInstanceGmt(2026, 11, 15, 12, 0, 0)
    );
  }

  /**
   * @description Unsaved messages from `SOURCE` with Ids `ORD-0000`, `ORD-0001`, …
   * @param count How many.
   * @return The messages.
   */
  public static List<Inbound_Message__c> messages(Integer count) {
    List<Inbound_Message__c> records = new List<Inbound_Message__c>();
    for (Integer i = 0; i < count; i++) {
      records.add(message(SOURCE, 'ORD-' + String.valueOf(i).leftPad(4, '0')));
    }
    return records;
  }

  /**
   * @description An unpublished intake event carrying the same fields as `message`.
   * @param source The producing system.
   * @param externalMessageId The producer's message Id.
   * @return The event.
   */
  public static Inbound_Message_Event__e event(String source, String externalMessageId) {
    Inbound_Message__c message = message(source, externalMessageId);
    return new Inbound_Message_Event__e(
      Source__c = message.Source__c,
      External_Message_Id__c = message.External_Message_Id__c,
      Message_Type__c = message.Message_Type__c,
      Payload__c = message.Payload__c,
      Correlation_Id__c = message.Correlation_Id__c,
      Occurred_At__c = message.Occurred_At__c
    );
  }

  /**
   * @description Delivered intake events from `SOURCE` with Ids `ORD-0000`, `ORD-0001`, …, and
   * replay Ids `1`, `2`, …, published by the running user. The read-only `ReplayId`, `EventUuid` and
   * `CreatedById` are set with `JSON.deserialize`.
   * @param count How many.
   * @return The events.
   */
  public static List<Inbound_Message_Event__e> deliveredEvents(Integer count) {
    List<Inbound_Message_Event__e> events = new List<Inbound_Message_Event__e>();
    for (Integer i = 0; i < count; i++) {
      Map<String, Object> fields = event(SOURCE, 'ORD-' + String.valueOf(i).leftPad(4, '0'))
        .getPopulatedFieldsAsMap()
        .clone();
      fields.put('ReplayId', String.valueOf(i + 1));
      fields.put('EventUuid', 'uuid-' + i);
      fields.put('CreatedById', UserInfo.getUserId());
      fields.put('attributes', new Map<String, Object>{ 'type' => 'Inbound_Message_Event__e' });
      events.add((Inbound_Message_Event__e) JSON.deserialize(JSON.serialize(fields), Inbound_Message_Event__e.class));
    }
    return events;
  }

  /**
   * @description Uploads a file as the running user, as a producer does for a claim check (ADR 0008).
   * @param body The file's text.
   * @return The new `ContentVersion` Id, which a message carries in `Payload_Ref__c`.
   */
  public static Id claimFile(String body) {
    ContentVersion version = new ContentVersion(
      Title = 'claim',
      PathOnClient = 'claim.json',
      VersionData = Blob.valueOf(body)
    );
    insert version;
    return version.Id;
  }

  /**
   * @description An in-memory `ContentVersion` with its read-only size and uploader set through
   * `JSON.deserialize`, for Stub API selector mocks.
   * @param uploadedById Who uploaded it.
   * @param size `ContentSize` in bytes.
   * @param data `VersionData`, or null to leave it out.
   * @return The version, with a fake Id.
   */
  public static ContentVersion version(Id uploadedById, Integer size, Blob data) {
    Map<String, Object> fields = new Map<String, Object>{
      'attributes' => new Map<String, Object>{ 'type' => 'ContentVersion' },
      'Id' => FakeId.generate(ContentVersion.SObjectType),
      'CreatedById' => uploadedById,
      'ContentSize' => size
    };
    ContentVersion version = (ContentVersion) JSON.deserialize(JSON.serialize(fields), ContentVersion.class);
    if (data != null) {
      version.VersionData = data;
    }
    return version;
  }

  /**
   * @description A successful save result, built with `JSON.deserialize` because the type has no
   * public constructor.
   * @param recordId The Id it reports.
   * @return The result.
   */
  public static Database.SaveResult savedResult(Id recordId) {
    return (Database.SaveResult) JSON.deserialize(
      JSON.serialize(new Map<String, Object>{ 'success' => true, 'id' => recordId, 'errors' => new List<Object>() }),
      Database.SaveResult.class
    );
  }

  /**
   * @description A failed save result with one error.
   * @param code The status code.
   * @param message The error message.
   * @return The result.
   */
  public static Database.SaveResult failedResult(StatusCode code, String message) {
    return (Database.SaveResult) JSON.deserialize(
      JSON.serialize(
        new Map<String, Object>{
          'success' => false,
          'errors' => new List<Object>{
            new Map<String, Object>{
              'statusCode' => String.valueOf(code),
              'message' => message,
              'fields' => new List<String>()
            }
          }
        }
      ),
      Database.SaveResult.class
    );
  }

  /**
   * @description Inserts a Minimum Access user, optionally with one permission set. Setup DML runs
   * as the current user, so insert test data afterwards inside `System.runAs` to avoid mixed DML.
   * @param permissionSetName The permission set to assign, or null for none.
   * @return The inserted user, for `System.runAs`.
   */
  public static User minimumAccessUser(String permissionSetName) {
    Profile minimumAccess = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1];
    String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
    User user = new User(
      Alias = 'aeitest',
      Email = 'aei-test@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Ingestion',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      TimeZoneSidKey = 'America/Phoenix',
      ProfileId = minimumAccess.Id,
      Username = 'aei-test-' + unique + '@example.com'
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert user;
      if (permissionSetName != null) {
        insert new PermissionSetAssignment(
          AssigneeId = user.Id,
          PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = :permissionSetName LIMIT 1]
          .Id
        );
      }
    }
    return user;
  }
}
