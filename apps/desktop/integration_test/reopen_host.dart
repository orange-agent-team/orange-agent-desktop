import 'package:orange_desktop/src/rust/api/host.dart';

Future<HostView> reopenHost(String directory) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (true) {
    try {
      return await initializeHost(applicationDataDirectory: directory);
    } on BridgeError catch (error) {
      if (error.code != 'HOST_BUSY' || DateTime.now().isAfter(deadline)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}
