import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/rust/api/host.dart' as api;

class RecoverySelection {
  const RecoverySelection(this.token, this.directory);
  final String token, directory;
}

/// UI scheduling only; actual ownership, file observations and authority are
/// checked by Rust. Test implementations are explicit transport substitutes.
abstract interface class RecoveryCommands {
  Future<api.RunPage> runs(String? before);
  Future<List<String>> operations(String run);
  Future<List<api.WorkspaceView>> workspaces();
  Future<RecoverySelection?> choose();
  Future<api.RecoveryInspectionAccessView> authorize(
    api.RunSummary run,
    String operation,
    api.WorkspaceView workspace,
    RecoverySelection selection,
  );
  Future<api.RecoveryInspectionView> inspect(String token);
  Future<void> release(String token);
}

class NativeRecoveryCommands implements RecoveryCommands {
  NativeRecoveryCommands(this.handle);
  final String handle;
  static const platform = MethodChannel('orange_agent/platform');
  @override
  Future<api.RunPage> runs(String? before) =>
      api.listRuns(handle: handle, before: before, limit: 30);
  @override
  Future<List<String>> operations(String run) =>
      api.listUnresolvedEdits(handle: handle, runId: run, limit: 100);
  @override
  Future<List<api.WorkspaceView>> workspaces() =>
      api.listWorkspaces(handle: handle, includeRevoked: true);
  @override
  Future<RecoverySelection?> choose() async {
    if (!Platform.isMacOS) {
      throw PlatformException(code: 'PLATFORM_NOT_VERIFIED');
    }
    final value = await platform.invokeMapMethod<String, dynamic>(
      'chooseRecoveryInspectionWorkspace',
    );
    if (value == null) return null;
    final token = value['selectionId'], directory = value['path'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('Invalid native selection identity');
    }
    if (directory is! String || directory.isEmpty) {
      await release(token);
      throw const FormatException('Invalid native selection directory');
    }
    return RecoverySelection(token, directory);
  }

  @override
  Future<api.RecoveryInspectionAccessView> authorize(
    api.RunSummary run,
    String operation,
    api.WorkspaceView workspace,
    RecoverySelection selection,
  ) => api.authorizeRecoveryInspection(
    handle: handle,
    runId: run.runId,
    operationId: operation,
    requestId: selection.token,
    workspaceVersion: workspace.permissionVersion,
    selectedDirectory: selection.directory,
  );
  @override
  Future<api.RecoveryInspectionView> inspect(String token) =>
      api.inspectRecovery(handle: handle, sessionToken: token);
  @override
  Future<void> release(String token) async {
    // Keep native rights if Rust drain cannot be confirmed, including Host
    // closure. The native window retains ownership until cleanup or app exit.
    await api.suspendRecoveryInspection(handle: handle, requestId: token);
    await platform.invokeMethod<void>('releaseRecoveryInspectionSelection', {
      'selectionId': token,
    });
  }
}

class RecoveryController extends ChangeNotifier {
  RecoveryController(this.commands);
  final RecoveryCommands commands;
  List<api.RunSummary> runs = [];
  List<String> operations = [];
  Map<String, String> workspacePaths = {};
  int navigationRevision = 0;
  api.RunSummary? selected;
  String? operation, nextCursor, error;
  api.RecoveryInspectionAccessView? access;
  api.RecoveryInspectionView? snapshot;
  bool busy = false, loaded = false;
  bool _disposed = false;
  int _epoch = 0;
  final _held = <String>{};
  final _seen = <String>{};
  final _releasing = <String, Future<void>>{};

  bool _live(int epoch) => !_disposed && epoch == _epoch;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  int _begin() {
    final epoch = ++_epoch;
    snapshot = null;
    access = null;
    error = null;
    busy = true;
    _changed();
    return epoch;
  }

  String _describe(Object failure) => switch (failure) {
    api.BridgeError(code: 'RECOVERY_SELECTION_CLOSED') => '检查权限已关闭，请重新选择目录。',
    api.BridgeError(code: 'RECOVERY_WORKSPACE_CHANGED') => '目录与该运行不匹配或已发生变化。',
    api.BridgeError(code: 'WORKSPACE_CONFLICT') => '工作区权限已变化，请刷新记录。',
    api.BridgeError(code: 'RECOVERY_FILES_CHANGED') => '文件在检查期间发生变化，请重新核对。',
    _ => '检查未完成，请核对记录、目录权限和当前状态。',
  };
  Future<void> _release(String token) {
    if (!_held.contains(token)) return Future<void>.value();
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

  Future<void> _releaseAll() async {
    await Future.wait(_held.toList().map(_release), eagerError: false);
  }

  Future<void> stop() async {
    ++_epoch;
    snapshot = null;
    access = null;
    busy = false;
    error = null;
    _changed();
    try {
      await _releaseAll();
    } catch (_) {
      error = '目录权限释放尚未确认，请重试结束检查。';
      _changed();
      rethrow;
    }
  }

  void workspaceStopping(String id) {
    if (selected?.workspaceId != id && access?.workspaceId != id) return;
    unawaited(
      stop().catchError((Object failure, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: failure,
            stack: stack,
            library: 'recovery inspection cleanup',
          ),
        );
      }),
    );
  }

  Future<void> refresh({bool older = false}) async {
    if (busy || (older && nextCursor == null)) return;
    final before = older ? nextCursor : null;
    final epoch = _begin();
    selected = null;
    operation = null;
    operations = [];
    try {
      await _releaseAll();
      if (!_live(epoch)) return;
      final page = await commands.runs(before);
      if (!_live(epoch)) return;
      runs = page.runs
          .where(
            (r) =>
                r.workspaceId != null &&
                (r.phase == 'recovery_required' || r.phase == 'cancelled'),
          )
          .toList();
      nextCursor = page.nextCursor;
      loaded = true;
    } catch (failure) {
      if (_live(epoch)) error = _describe(failure);
    } finally {
      if (_live(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> selectRun(api.RunSummary run) async {
    selected = run;
    operation = null;
    operations = [];
    navigationRevision++;
    final epoch = _begin();
    try {
      await _releaseAll();
      if (!_live(epoch)) return;
      final ids = await commands.operations(run.runId);
      if (!_live(epoch)) return;
      final places = await commands.workspaces();
      if (!_live(epoch)) return;
      workspacePaths = {
        for (final place in places) place.workspaceId: place.displayPath,
      };
      if (ids.length > 100 || ids.toSet().length != ids.length) {
        throw const FormatException('Invalid bounded operation index');
      }
      operations = ids;
      operation = ids.length == 1 ? ids.single : null;
    } catch (failure) {
      if (_live(epoch)) error = _describe(failure);
    } finally {
      if (_live(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> selectOperation(String id) async {
    if (!operations.contains(id)) return;
    await stop();
    if (_disposed) return;
    operation = id;
    _changed();
  }

  Future<void> chooseAndInspect() async {
    final run = selected, op = operation;
    if (busy || run == null || run.workspaceId == null || op == null) return;
    final epoch = _begin();
    String? token;
    bool retained = false;
    try {
      await _releaseAll();
      if (!_live(epoch)) return;
      final rows = await commands.workspaces();
      if (!_live(epoch)) return;
      final workspace = rows.singleWhere(
        (w) => w.workspaceId == run.workspaceId,
      );
      final choice = await commands.choose();
      if (choice == null) return;
      token = choice.token;
      _held.add(token);
      if (!_seen.add(token)) {
        throw const FormatException('Reused native selection');
      }
      if (!_live(epoch)) return;
      final granted = await commands.authorize(run, op, workspace, choice);
      if (!_live(epoch)) return;
      if (granted.sessionToken != token ||
          granted.runId != run.runId ||
          granted.operationId != op ||
          granted.workspaceId != run.workspaceId) {
        throw const FormatException('Mismatched inspection authority');
      }
      final result = await commands.inspect(token);
      if (!_live(epoch)) return;
      if (result.runId != run.runId ||
          result.operationId != op ||
          result.executionState != 'unknown' ||
          result.path.isEmpty ||
          result.path.length > 4096 ||
          result.path.contains('\u0000') ||
          ![result.target, result.staged, result.original].every(_validFile)) {
        throw const FormatException('Mismatched recovery observation');
      }
      access = granted;
      snapshot = result;
      retained = true;
    } catch (failure) {
      if (_live(epoch)) error = _describe(failure);
    } finally {
      if (token != null && !retained) {
        try {
          await _release(token);
        } catch (_) {
          error = '目录权限释放尚未确认，请重试结束检查。';
        }
      }
      if (_live(epoch)) busy = false;
      _changed();
    }
  }

  bool _validFile(api.RecoveryFileStatusView file) {
    if (file.kind == 'regular') {
      final hash = RegExp(r'^[0-9a-f]{64}$');
      final bytes = file.bytes;
      return file.refusal == null &&
          bytes != null &&
          RegExp(r'^(0|[1-9][0-9]{0,6})$').hasMatch(bytes) &&
          int.parse(bytes) <= 1024 * 1024 &&
          hash.hasMatch(file.sha256 ?? '') &&
          hash.hasMatch(file.securitySha256 ?? '') &&
          !(file.matchesOriginalContent && file.matchesResultContent);
    }
    return ((file.kind == 'missing' && file.refusal == null) ||
            (file.kind == 'refused' &&
                file.refusal != null &&
                file.refusal!.isNotEmpty &&
                file.refusal!.length <= 128)) &&
        file.bytes == null &&
        file.sha256 == null &&
        file.securitySha256 == null &&
        !file.reviewedOriginalInode &&
        !file.matchesOriginalContent &&
        !file.matchesResultContent;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    snapshot = null;
    access = null;
    unawaited(
      _releaseAll().catchError((Object failure, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: failure,
            stack: stack,
            library: 'recovery inspection cleanup',
          ),
        );
      }),
    );
    super.dispose();
  }
}
