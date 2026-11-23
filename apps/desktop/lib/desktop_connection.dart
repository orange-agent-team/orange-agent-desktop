import 'src/rust/api/host.dart';

class BridgeStartupFailure implements Exception {
  const BridgeStartupFailure(this.cause);
  final Object cause;
}

/// A bridge belongs to the application process. Opening its journal is a separate,
/// retryable operation and simultaneous callers share the same connection attempt.
class DesktopConnection {
  DesktopConnection({required this.initializeBridge, required this.openHost});
  final Future<void> Function() initializeBridge;
  final Future<HostView> Function() openHost;
  bool _bridgeReady = false;
  Future<HostView>? _pending;

  Future<HostView> connect() =>
      _pending ??= _open().whenComplete(() => _pending = null);

  Future<HostView> _open() async {
    if (!_bridgeReady) {
      try {
        await initializeBridge();
        _bridgeReady = true;
      } catch (error, stack) {
        Error.throwWithStackTrace(BridgeStartupFailure(error), stack);
      }
    }
    return openHost();
  }
}
