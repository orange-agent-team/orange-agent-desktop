import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'recovery_controller.dart' show RecoverySelection;
import 'src/rust/api/host.dart' as api;
import 'export_inspection_controller.dart';
part 'retention_export_controller.dart';

abstract interface class RetentionCommands {
  Future<api.RunPage> runs(String? before);
  Future<List<String>> operations(String run, String? before);
  Future<List<api.WorkspaceView>> workspaces();
  Future<RecoverySelection?> choose();
  Future<api.RetentionAccessView> authorize(
    api.RunSummary run,
    String op,
    api.WorkspaceView workspace,
    RecoverySelection selected,
  );
  Future<api.RetentionInspectionView> inspect(String token);
  Future<api.RetentionReviewView> prepare(String token, String request);
  Future<String> approve(api.RetentionReviewView review);
  Future<String?> outcome(String run, String op);
  Future<void> release(String token);
}

class NativeRetentionCommands implements RetentionCommands {
  NativeRetentionCommands(this.handle);
  final String handle;
  static const platform = MethodChannel('orange_agent/platform');
  @override
  Future<api.RunPage> runs(String? before) =>
      api.listRuns(handle: handle, before: before, limit: 30);
  @override
  Future<List<String>> operations(String run, String? before) =>
      api.listRetainedEdits(
        handle: handle,
        runId: run,
        before: before,
        limit: 100,
      );
  @override
  Future<List<api.WorkspaceView>> workspaces() =>
      api.listWorkspaces(handle: handle, includeRevoked: true);
  @override
  Future<RecoverySelection?> choose() async {
    if (!Platform.isMacOS) {
      throw PlatformException(code: 'PLATFORM_NOT_VERIFIED');
    }
    final value = await platform.invokeMapMethod<String, dynamic>(
      'chooseRetentionWorkspace',
    );
    if (value == null) return null;
    final token = value['selectionId'], path = value['path'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('Invalid selection identity');
    }
    if (path is! String || path.isEmpty) {
      await release(token);
      throw const FormatException('Invalid directory');
    }
    return RecoverySelection(token, path);
  }

  @override
  Future<api.RetentionAccessView> authorize(
    api.RunSummary run,
    String op,
    api.WorkspaceView workspace,
    RecoverySelection selected,
  ) => api.authorizeRetentionAccess(
    handle: handle,
    runId: run.runId,
    operationId: op,
    requestId: selected.token,
    workspaceVersion: workspace.permissionVersion,
    selectedDirectory: selected.directory,
  );
  @override
  Future<api.RetentionInspectionView> inspect(String token) =>
      api.inspectRetention(handle: handle, sessionToken: token);
  @override
  Future<api.RetentionReviewView> prepare(String token, String request) =>
      api.prepareRetentionArchive(
        handle: handle,
        sessionToken: token,
        requestId: request,
      );
  @override
  Future<String> approve(api.RetentionReviewView review) =>
      api.approveRetentionArchive(
        handle: handle,
        sessionToken: review.sessionToken,
        reviewId: review.reviewId,
        expectedDigest: review.digest,
      );
  @override
  Future<String?> outcome(String run, String op) =>
      api.inspectRetentionOutcome(handle: handle, runId: run, operationId: op);
  @override
  Future<void> release(String token) async {
    await api.suspendRetentionAccess(handle: handle, requestId: token);
    await platform.invokeMethod<void>('releaseRetentionSelection', {
      'selectionId': token,
    });
  }
}

class RetentionController extends ChangeNotifier {
  RetentionController(
    this.commands, {
    ExportCommands? exportCommands,
    ExportInspectionCommands? inspectionCommands,
  }) : exportCommands =
           exportCommands ??
           (commands is NativeRetentionCommands
               ? NativeExportCommands(commands.handle)
               : null),
       exportInspection = inspectionCommands != null
           ? ExportInspectionController(inspectionCommands)
           : (commands is NativeRetentionCommands
                 ? ExportInspectionController(
                     NativeExportInspectionCommands(commands.handle),
                   )
                 : null);
  final ExportCommands? exportCommands;
  final ExportInspectionController? exportInspection;
  api.ExportAccessView? exportAccess;
  api.ExportReviewView? exportReview;
  api.ExportOutcomeView? exportOutcome;
  List<api.ExportOutcomeView> exportRecords = [];
  String? exportCursor, exportNotice;
  String exportFileName = 'retained.orange-retained.json',
      exportChoice = 'both';
  final _heldExports = <String>{}, _seenExports = <String>{};
  final _releasingExports = <String, Future<void>>{};
  final RetentionCommands commands;
  List<api.RunSummary> runs = [];
  List<String> operations = [];
  api.RunSummary? selected;
  String? operation, nextCursor, operationCursor, error, notice;
  api.RetentionAccessView? access;
  api.RetentionInspectionView? snapshot;
  api.RetentionReviewView? review;
  bool busy = false, loaded = false, _disposed = false;
  int _epoch = 0;
  final _held = <String>{}, _seen = <String>{};
  final _releasing = <String, Future<void>>{};
  bool _live(int epoch) => !_disposed && epoch == _epoch;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _hide() {
    exportInspection?.invalidate();
    exportAccess = null;
    exportReview = null;
    exportOutcome = null;
    exportNotice = null;
    exportRecords = [];
    exportCursor = null;
    access = null;
    snapshot = null;
    review = null;
    notice = null;
  }

  String _describe(Object e) => switch (e) {
    api.BridgeError(code: 'EXPORT_CONFLICT') => '目标文件已存在，或预览已变化。请换文件名并重新预览。',
    api.BridgeError(code: 'INVALID_EXPORT_REQUEST') => '请检查导出文件名、所选版本和大小限制。',
    api.BridgeError(code: 'EXPORT_SELECTION_CLOSED') => '导出授权已关闭，请重新选择目标目录。',
    api.BridgeError(code: 'EXPORT_DIRECTORY_CHANGED') => '导出目录身份已变化，请重新选择。',
    api.BridgeError(code: 'EXPORT_PREVIEW_CHANGED') => '导出预览已失效，请重新生成。',

    api.BridgeError(code: 'RETENTION_LIMIT') => '保留额度已达上限，无法登记更多归档。不会自动删除文件。',
    api.BridgeError(code: 'RETENTION_FILES_CHANGED') => '保留文件已经变化，请重新检查并生成预览。',
    api.BridgeError(code: 'WORKSPACE_CONFLICT') => '目录授权版本已变化，请重新选择。',
    api.BridgeError(code: 'RETENTION_SELECTION_CLOSED') => '目录授权已关闭，请重新选择。',
    _ => '操作未完成，请重新检查记录和目录状态。',
  };
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

  Future<void> _releaseAll() async {
    await Future.wait([
      _releaseDependentScopes(),
      if (exportInspection != null) exportInspection!.close(),
    ], eagerError: false);
  }

  Future<void> _releaseDependentScopes() async {
    Object? failure;
    StackTrace? trace;
    try {
      await Future.wait(
        _heldExports.toList().map(_releaseExport),
        eagerError: false,
      );
    } catch (e, s) {
      failure = e;
      trace = s;
    }
    try {
      await Future.wait(_held.toList().map(_release), eagerError: false);
    } catch (e, s) {
      failure ??= e;
      trace ??= s;
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }

  Future<void> stop() async {
    ++_epoch;
    _hide();
    busy = false;
    error = null;
    _notify();
    try {
      await _releaseAll();
    } catch (_) {
      error = '目录权限释放尚未确认，请重试结束管理。';
      _notify();
      rethrow;
    }
  }

  void workspaceStopping(String id) {
    if (selected?.workspaceId == id || access?.workspaceId == id) {
      unawaited(
        stop().catchError((Object e, StackTrace s) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: e,
              stack: s,
              library: 'retention cleanup',
            ),
          );
        }),
      );
    }
  }

  Future<void> refresh({bool older = false}) async {
    if (busy || (older && nextCursor == null)) return;
    final before = older ? nextCursor : null;
    final epoch = ++_epoch;
    _hide();
    selected = null;
    operation = null;
    operations = [];
    operationCursor = null;
    busy = true;
    error = null;
    _notify();
    try {
      await _releaseAll();
      if (!_live(epoch)) return;
      final page = await commands.runs(before);
      if (!_live(epoch)) return;
      runs = page.runs.where((r) => r.workspaceId != null).toList();
      nextCursor = page.nextCursor;
      loaded = true;
    } catch (e) {
      if (_live(epoch)) error = _describe(e);
    } finally {
      if (_live(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> selectRun(api.RunSummary run, {bool older = false}) async {
    if (busy || (older && operationCursor == null)) return;
    final before = older ? operationCursor : null;
    final epoch = ++_epoch;
    _hide();
    selected = run;
    operation = null;
    operations = [];
    busy = true;
    error = null;
    _notify();
    try {
      await _releaseAll();
      if (!_live(epoch)) return;
      final ids = await commands.operations(run.runId, before);
      if (!_live(epoch)) return;
      if (ids.length > 100 ||
          ids.toSet().length != ids.length ||
          ids.any((id) => id.isEmpty)) {
        throw const FormatException('Invalid index');
      }
      operations = ids;
      operation = ids.length == 1 ? ids.single : null;
      operationCursor = ids.length == 100 ? ids.last : null;
      await _loadExportRecords(epoch);
    } catch (e) {
      if (_live(epoch)) error = _describe(e);
    } finally {
      if (_live(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> selectOperation(String id) async {
    if (!operations.contains(id)) return;
    final epoch = _epoch + 1;
    await stop();
    if (!_live(epoch)) return;
    operation = id;
    try {
      await _loadExportRecords(_epoch);
    } catch (_) {
      if (_live(epoch)) error = '导出记录读取未完成。';
    }
    _notify();
  }

  void _check(
    api.RetentionInspectionView value,
    api.RetentionAccessView scope,
  ) {
    if (value.sessionToken != scope.sessionToken ||
        value.runId != scope.runId ||
        value.operationId != scope.operationId ||
        value.path.isEmpty ||
        value.path.contains('\u0000') ||
        value.path.length > 4096 ||
        !['succeeded', 'unknown'].contains(value.executionState)) {
      throw const FormatException('Mismatched retained observation');
    }
  }

  Future<void> chooseAndInspect() async {
    final run = selected, op = operation;
    if (busy || run == null || run.workspaceId == null || op == null) return;
    final epoch = ++_epoch;
    _hide();
    busy = true;
    error = null;
    _notify();
    String? token;
    bool keep = false;
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
        throw const FormatException('Mismatched selection');
      }
      final value = await commands.inspect(token);
      if (!_live(epoch)) return;
      _check(value, granted);
      access = granted;
      snapshot = value;
      keep = true;
    } catch (e) {
      if (_live(epoch)) error = _describe(e);
    } finally {
      if (token != null && !keep) {
        try {
          await _release(token);
        } catch (_) {
          error = '目录权限释放尚未确认，请重试结束管理。';
        }
      }
      if (_live(epoch)) busy = false;
      _notify();
    }
  }

  Future<void> prepare() async {
    final scope = access;
    if (busy || scope == null || snapshot?.archivedReviewId != null) return;
    final epoch = _epoch;
    review = null;
    notice = null;
    busy = true;
    error = null;
    _notify();
    try {
      final request = List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final value = await commands.prepare(scope.sessionToken, request);
      if (!_live(epoch)) return;
      if (value.sessionToken != scope.sessionToken ||
          value.operationId != scope.operationId ||
          value.reviewId.isEmpty ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(value.digest) ||
          value.path != snapshot?.path ||
          BigInt.parse(value.expiresAt.toString()) <=
              BigInt.from(DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
        throw const FormatException('Invalid archive preview');
      }
      review = value;
    } catch (e) {
      if (_live(epoch)) {
        snapshot = null;
        error = _describe(e);
      }
    } finally {
      if (_live(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> approve() async {
    final scope = access, current = review;
    if (busy || scope == null || current == null) return;
    final epoch = _epoch;
    review = null;
    snapshot = null;
    busy = true;
    error = null;
    _notify();
    try {
      String? committed;
      try {
        committed = await commands.approve(current);
      } catch (_) {
        if (!_live(epoch)) return;
        committed = await commands.outcome(scope.runId, scope.operationId);
      }
      if (!_live(epoch)) return;
      if (committed != current.reviewId) {
        error = '归档结果未确认，未自动重发批准。请重新检查记录。';
        return;
      }
      notice = '已登记原地保留，文件未移动或删除，原任务状态未改变。';
      try {
        final value = await commands.inspect(scope.sessionToken);
        if (!_live(epoch)) return;
        _check(value, scope);
        if (value.archivedReviewId != current.reviewId) {
          throw const FormatException('Archive receipt mismatch');
        }
        snapshot = value;
      } catch (_) {
        if (_live(epoch)) error = '归档登记已确认，当前文件状态未能重新读取。';
      }
    } catch (_) {
      if (_live(epoch)) error = '归档结果未确认，未自动重发批准。请重新检查记录。';
    } finally {
      if (_live(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _hide();
    unawaited(
      _releaseAll().catchError((Object e, StackTrace s) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: e,
            stack: s,
            library: 'retention cleanup',
          ),
        );
      }),
    );
    exportInspection?.dispose();
    super.dispose();
  }
}
