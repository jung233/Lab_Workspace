import 'dart:math';

typedef VaultId = String;
typedef DeviceId = String;
typedef ProjectId = String;
typedef ExperimentId = String;
typedef RunId = String;
typedef ProtocolId = String;
typedef ProtocolVersionId = String;
typedef StepId = String;
typedef StepEventId = String;
typedef SampleId = String;
typedef GroupId = String;
typedef TreatmentId = String;
typedef MeasurementId = String;
typedef CalculationId = String;
typedef CalculationJobId = String;
typedef CalculationTraceId = String;
typedef TaskId = String;
typedef ReminderId = String;
typedef MutationId = String;
typedef CommandId = String;
typedef DeletionId = String;
typedef BackupId = String;
typedef RemoteTargetId = String;
typedef SkillRef = String;

/// Creates an RFC 9562 UUIDv7. The timestamp is UTC milliseconds and the
/// remaining bits come from the platform's cryptographically secure RNG.
String newUuidV7({DateTime? at, Random? random}) {
  final timestamp =
      (at ?? DateTime.now().toUtc()).toUtc().millisecondsSinceEpoch;
  if (timestamp < 0 || timestamp > 0xFFFFFFFFFFFF) {
    throw ArgumentError.value(at, 'at', 'UUIDv7 timestamp is out of range');
  }

  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[0] = (timestamp >> 40) & 0xff;
  bytes[1] = (timestamp >> 32) & 0xff;
  bytes[2] = (timestamp >> 24) & 0xff;
  bytes[3] = (timestamp >> 16) & 0xff;
  bytes[4] = (timestamp >> 8) & 0xff;
  bytes[5] = timestamp & 0xff;
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return hex.substring(0, 8) +
      '-' +
      hex.substring(8, 12) +
      '-' +
      hex.substring(12, 16) +
      '-' +
      hex.substring(16, 20) +
      '-' +
      hex.substring(20);
}
