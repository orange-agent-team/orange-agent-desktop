import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/model_controller.dart';
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:orange_desktop/src/rust/frb_generated.dart';

// Explicit transport substitute: verifies UI scheduling, not process cleanup.
class ExitApi implements RustLibApi {
  int advances = 0, reads = 0;
  final failure = const BridgeError(
    code: 'MODEL_SERVICE_UNAVAILABLE',
    correlationId: 'owned-failure',
  );
  @override
  Future<AgentRunView> crateApiHostAdvanceRun({
    required String handle,
    required String runId,
    required String expectedRevision,
  }) async {
    advances++;
    throw failure;
  }

  @override
  Future<ModelServiceView> crateApiHostInspectModelService({
    required String handle,
  }) async {
    reads++;
    return const ModelServiceView(
      phase: 'stopped',
      modelName: 'owned',
      modelBytes: '4',
      installed: true,
      instanceId: 'owned-instance',
      failure: 'MODEL_CONTROL_HEARTBEAT_LOST',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected command: ${invocation.memberName}');
}

void main() {
  test(
    'unavailable model refreshes stale ready state without replay or restart',
    () async {
      final api = ExitApi();
      RustLib.initMock(api: api);
      int stopSignals = 0;
      final models = ModelController(
        'host',
        beforeStop: () {
          stopSignals++;
        },
      );
      models.view = const ModelServiceView(
        phase: 'ready',
        modelName: 'owned',
        modelBytes: '4',
        installed: true,
        instanceId: 'owned-instance',
      );
      final commands = ManagedAgentCommands('host', models);
      await expectLater(
        commands.advance('run', '1'),
        throwsA(same(api.failure)),
      );
      expect(api.advances, 1);
      expect(api.reads, 1);
      expect(stopSignals, 0);
      expect(models.view!.phase, 'stopped');
      expect(models.view!.failure, 'MODEL_CONTROL_HEARTBEAT_LOST');
      expect(describeModelFailureCode(models.view!.failure!), contains('重新启动'));
      models.dispose();
      RustLib.dispose();
    },
  );
}
