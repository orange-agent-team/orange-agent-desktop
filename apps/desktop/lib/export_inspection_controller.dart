import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'recovery_controller.dart' show RecoverySelection;
import 'src/rust/api/host.dart' as api;

abstract interface class ExportInspectionCommands {
  Future<RecoverySelection?> choose();
  Future<api.ExportInspectionAccessView> authorize(
    String run,
    String operation,
    String exportId,
    RecoverySelection choice,
  );
  Future<api.ExportInspectionView> inspect(String token);
  Future<void> release(String token);
}

class NativeExportInspectionCommands implements ExportInspectionCommands {
  NativeExportInspectionCommands(this.handle);
  final String handle;
  static const platform = MethodChannel('orange_agent/platform');
  @override
  Future<RecoverySelection?> choose() async {
    if (!Platform.isMacOS) {
      throw PlatformException(code: 'PLATFORM_NOT_VERIFIED');
    }
    final value = await platform.invokeMapMethod<String, dynamic>(
      'chooseExportInspectionDirectory',
    );
    if (value == null) return null;
    final token = value['selectionId'], path = value['path'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('Invalid inspection token');
    }
    if (path is! String || path.isEmpty) {
      await release(token);
      throw const FormatException('Invalid inspection directory');
    }
    return RecoverySelection(token, path);
  }

  @override
  Future<api.ExportInspectionAccessView> authorize(
    String run,
    String operation,
    String exportId,
    RecoverySelection choice,
  ) => api.authorizeExportInspection(
    handle: handle,
    runId: run,
    operationId: operation,
    exportId: exportId,
    requestId: choice.token,
    selectedDirectory: choice.directory,
  );
  @override
  Future<api.ExportInspectionView> inspect(String token) =>
      api.inspectExportFiles(handle: handle, sessionToken: token);
  @override
  Future<void> release(String token) async {
    await api.suspendExportInspection(handle: handle, requestId: token);
    await platform.invokeMethod<void>('releaseExportInspectionSelection', {
      'selectionId': token,
    });
  }
}

class ExportInspectionController extends ChangeNotifier {
  ExportInspectionController(this.commands);
  final ExportInspectionCommands commands;
  api.ExportInspectionAccessView? access;
  api.ExportInspectionView? view;
  String? error;
  bool busy = false, _disposed = false;
  int _epoch = 0;
  final _held = <String>{}, _seen = <String>{};
  final _releasing = <String, Future<void>>{};
  bool _live(int epoch) => !_disposed && epoch == _epoch;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void invalidate() {
    ++_epoch;
    access = null;
    view = null;
    busy = false;
    error = null;
    _notify();
  }

  Future<void> _release(String token) {
    if (!_held.contains(token)) return Future.value();
    return _releasing.putIfAbsent(
      token,
      () => Future<void>.sync(() => commands.release(token))
          .then((_) {
            _held.remove(token);
          })
          .whenComplete(() {
            _releasing.remove(token);
          }),
    );
  }

  Future<void> close() async {
    invalidate();
    try {
      await Future.wait(_held.toList().map(_release), eagerError: false);
    } catch (_) {
      error = '检查目录权限释放尚未确认，请重试结束检查。';
      _notify();
      rethrow;
    }
  }

  bool _validFile(api.ExportObservedFileView file) {
    if (file.kind == 'regular') {
      final size = file.bytes;
      return file.reason == null &&
          size != null &&
          RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(size) &&
          BigInt.parse(size) <= BigInt.from(3 * 1024 * 1024) &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(file.sha256 ?? '') &&
          (!file.matchesApprovedArtifact || file.validExportDocument);
    }
    return ((file.kind == 'missing' && file.reason == null) ||
            (file.kind == 'refused' &&
                file.reason != null &&
                file.reason!.isNotEmpty &&
                file.reason!.length <= 128)) &&
        file.bytes == null &&
        file.sha256 == null &&
        !file.matchesApprovedArtifact &&
        !file.validExportDocument;
  }

  Future<void> open(
    String run,
    String operation,
    api.ExportOutcomeView record,
  ) async {
    if (busy || _disposed) return;
    final epoch = ++_epoch;
    access = null;
    view = null;
    error = null;
    busy = true;
    _notify();
    String? token;
    bool kept = false;
    try {
      await Future.wait(_held.toList().map(_release), eagerError: false);
      if (!_live(epoch)) return;
      final choice = await commands.choose();
      if (choice == null) return;
      token = choice.token;
      _held.add(token);
      if (!_seen.add(token)) {
        throw const FormatException('Reused inspection token');
      }
      if (!_live(epoch)) return;
      final granted = await commands.authorize(
        run,
        operation,
        record.exportId,
        choice,
      );
      if (!_live(epoch)) return;
      if (granted.sessionToken != token ||
          granted.runId != run ||
          granted.operationId != operation ||
          granted.exportId != record.exportId) {
        throw const FormatException('Mismatched export inspection scope');
      }
      final snapshot = await commands.inspect(token);
      if (!_live(epoch)) return;
      if (snapshot.sessionToken != token ||
          snapshot.runId != run ||
          snapshot.operationId != operation ||
          snapshot.exportId != record.exportId ||
          snapshot.reviewDigest != record.reviewDigest ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(snapshot.reviewDigest) ||
          ![
            'prepared',
            'dispatching',
            'succeeded',
            'unknown',
          ].contains(snapshot.recordedState) ||
          (['succeeded', 'unknown'].contains(record.state) &&
              snapshot.recordedState != record.state) ||
          snapshot.fileName.length > 200 ||
          !snapshot.fileName.endsWith('.orange-retained.json') ||
          RegExp(r'[\\/\x00-\x1f:]').hasMatch(snapshot.fileName) ||
          !_validFile(snapshot.target) ||
          !_validFile(snapshot.staged)) {
        throw const FormatException('Mismatched export inspection');
      }
      access = granted;
      view = snapshot;
      kept = true;
    } catch (failure) {
      if (_live(epoch)) {
        error = switch (failure) {
          api.BridgeError(code: 'EXPORT_INSPECTION_DIRECTORY_CHANGED') =>
            '所选目录与这条导出记录不匹配，请重新选择。',
          api.BridgeError(code: 'EXPORT_INSPECTION_FILES_CHANGED') =>
            '文件在检查期间发生变化，请重新检查。',
          _ => '导出检查未完成，请核对记录和目录权限。',
        };
      }
    } finally {
      if (token != null && !kept) {
        try {
          await _release(token);
        } catch (_) {
          error = '检查目录权限释放尚未确认，请重试结束检查。';
        }
      }
      if (_live(epoch)) busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    access = null;
    view = null;
    unawaited(
      Future.wait(_held.toList().map(_release), eagerError: false).catchError((
        Object e,
        StackTrace s,
      ) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: e,
            stack: s,
            library: 'export inspection cleanup',
          ),
        );
        return <void>[];
      }),
    );
    super.dispose();
  }
}
