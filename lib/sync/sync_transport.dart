/// Where the synced copy lives.
///
/// An interface rather than Drive calls scattered through the engine, so the
/// engine can be tested against races and failures that a real server would
/// only produce by accident.
library;

/// What is known about the remote copy without downloading it.
class RemoteInfo {
  /// Identifies this version, for a conditional write and for noticing that
  /// nothing has changed. Opaque to the engine.
  final String version;

  /// When the copy was last written, if the remote reports it.
  final DateTime? modifiedAt;

  /// Size in bytes, if the remote reports it. Used only for progress.
  final int? size;

  const RemoteInfo({required this.version, this.modifiedAt, this.size});
}

/// Called as a download arrives. [total] is null when the size is unknown.
typedef ByteProgress = void Function(int received, int? total);

/// Someone else wrote the remote copy between our read and our write.
class SyncConflict implements Exception {
  const SyncConflict();
}

/// The remote could not be reached, or refused the request.
class SyncTransportError implements Exception {
  final String message;
  const SyncTransportError(this.message);

  @override
  String toString() => message;
}

abstract class SyncTransport {
  /// The remote copy's current version, or null if there is none. Cheap: it
  /// must not download the content.
  Future<RemoteInfo?> info();

  /// Downloads the copy described by [info].
  Future<String> fetch(RemoteInfo info, {ByteProgress? onBytes});

  /// Replaces the remote copy and returns its new version.
  ///
  /// When [ifVersion] is given the write must fail with [SyncConflict] if the
  /// remote has moved on since that version was read. A null [ifVersion]
  /// means "create; fail if something already exists". Transports that
  /// cannot enforce this should still try: the engine is built to recover
  /// from a lost race, just more slowly.
  Future<String> upload(String content, {required String? ifVersion});

  /// Removes the remote copy entirely.
  Future<void> delete();
}
