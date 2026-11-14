import 'dart:async';
import 'dart:io';
import 'dart:math';

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

abstract interface class WritingRecoveryCommands {
  Future<RecoverySelection?> chooseWrite();
  Future<api.RecoveryWriteAccessView> authorizeWrite(
    api.RecoveryInspectionAccessView read,
    RecoverySelection selected,
  );
  Future<api.RecoveryDecisionView> prepare(
    String reader,
    String writer,
    String request,
    String choice,
  );
  Future<api.RecoveryOutcomeView> approve(api.RecoveryDecisionView decision);
  Future<api.RecoveryOutcomeView> outcome(String run, String operation);
  Future<void> releaseWrite(String token);
}

class NativeRecoveryCommands
    implements RecoveryCommands, WritingRecoveryCommands {
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
    return _choose('chooseRecoveryInspectionWorkspace', release);
  }

  Future<RecoverySelection?> _choose(
    String method,
    Future<void> Function(String) close,
  ) async {
    if (!Platform.isMacOS) {
      throw PlatformException(code: 'PLATFORM_NOT_VERIFIED');
    }
    final value = await platform.invokeMapMethod<String, dynamic>(method);
    if (value == null) return null;
    final token = value['selectionId'], directory = value['path'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('Invalid native selection identity');
    }
    if (directory is! String || directory.isEmpty) {
      await close(token);
      throw const FormatException('Invalid native selection directory');
    }
    return RecoverySelection(token, directory);
  }

  @override
  Future<RecoverySelection?> chooseWrite() =>
      _choose('chooseRecoveryWriteWorkspace', releaseWrite);
  @override
  Future<api.RecoveryWriteAccessView> authorizeWrite(
    api.RecoveryInspectionAccessView read,
    RecoverySelection selected,
  ) => api.authorizeRecoveryWriteAccess(
    handle: handle,
    readSessionToken: read.sessionToken,
    requestId: selected.token,
    selectedDirectory: selected.directory,
  );
  @override
  Future<api.RecoveryDecisionView> prepare(
    String reader,
    String writer,
    String request,
    String choice,
  ) => api.prepareRecoveryDecision(
    handle: handle,
    readSessionToken: reader,
    writeSessionToken: writer,
    requestId: request,
    choice: choice,
  );
  @override
  Future<api.RecoveryOutcomeView> approve(api.RecoveryDecisionView decision) =>
      api.approveRecoveryDecision(
        handle: handle,
        readSessionToken: decision.readSessionToken,
        writeSessionToken: decision.writeSessionToken,
        recoveryId: decision.recoveryId,
        expectedDigest: decision.digest,
      );
  @override
  Future<api.RecoveryOutcomeView> outcome(String run, String operation) =>
      api.inspectRecoveryOutcome(
        handle: handle,
        runId: run,
        operationId: operation,
      );
  @override
  Future<void> releaseWrite(String token) async {
    await api.suspendRecoveryWriteSelection(handle: handle, requestId: token);
    await platform.invokeMethod<void>('releaseRecoveryWriteSelection', {
      'selectionId': token,
    });
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
  api.RecoveryWriteAccessView? writeAccess;
  api.RecoveryDecisionView? decision;
  api.RecoveryOutcomeView? outcome;
  String? notice;
  bool busy = false, loaded = false;
  bool _disposed = false;
  int _epoch = 0;
  final _held = <String>{};
  final _seen = <String>{};
  final _releasing = <String, Future<void>>{};
  final _heldWrites = <String>{};
  final _releasingWrites = <String, Future<void>>{};
  WritingRecoveryCommands? get writer => commands is WritingRecoveryCommands
      ? commands as WritingRecoveryCommands
      : null;

  bool _live(int epoch) => !_disposed && epoch == _epoch;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  int _begin() {
    final epoch = ++_epoch;
    snapshot = null;
    access = null;
    writeAccess = null;
    decision = null;
    outcome = null;
    notice = null;
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
    Object? failure;
    StackTrace? trace;
    try {
      await Future.wait(
        _heldWrites.toList().map(_releaseWrite),
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

  Future<void> _releaseWrite(String token) {
    if (!_heldWrites.contains(token)) return Future<void>.value();
    return _releasingWrites.putIfAbsent(
      token,
      () => Future<void>.sync(() => writer!.releaseWrite(token))
          .then((_) {
            _heldWrites.remove(token);
          })
          .whenComplete(() {
            _releasingWrites.remove(token);
          }),
    );
  }

  Future<void> stop() async {
    ++_epoch;
    snapshot = null;
    access = null;
    writeAccess = null;
    decision = null;
    outcome = null;
    notice = null;
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

  bool _validObservation(
    api.RecoveryInspectionView value,
    String run,
    String op,
  ) =>
      value.runId == run &&
      value.operationId == op &&
      value.executionState == 'unknown' &&
      value.path.isNotEmpty &&
      value.path.length <= 4096 &&
      !value.path.contains('\u0000') &&
      [value.target, value.staged, value.original].every(_validFile);
  bool _validOutcome(api.RecoveryOutcomeView value, String run, String op) =>
      value.runId == run &&
      value.operationId == op &&
      value.originalExecutionState == 'unknown' &&
      ((value.recoveryId == null && value.choice == null) ||
          (value.recoveryId?.isNotEmpty == true &&
              const [
                'keep_current_target',
                'restore_original_to_missing_target',
                'publish_staged_to_missing_target',
              ].contains(value.choice)));
  Future<void> chooseWrite() async {
    final read = access, writeCommands = writer;
    if (busy ||
        read == null ||
        snapshot == null ||
        writeCommands == null ||
        outcome?.recoveryId != null) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    error = null;
    decision = null;
    writeAccess = null;
    notice = null;
    _changed();
    String? token;
    bool retained = false;
    try {
      await Future.wait(
        _heldWrites.toList().map(_releaseWrite),
        eagerError: false,
      );
      if (!_live(epoch)) return;
      final selected = await writeCommands.chooseWrite();
      if (selected == null) return;
      token = selected.token;
      _heldWrites.add(token);
      if (!_seen.add(token)) {
        throw const FormatException('Reused native write selection');
      }
      if (!_live(epoch)) return;
      final granted = await writeCommands.authorizeWrite(read, selected);
      if (!_live(epoch)) return;
      if (granted.sessionToken != token ||
          granted.readSessionToken != read.sessionToken ||
          granted.runId != read.runId ||
          granted.operationId != read.operationId ||
          granted.workspaceId != read.workspaceId) {
        throw const FormatException('Mismatched write authority');
      }
      writeAccess = granted;
      retained = true;
    } catch (failure) {
      if (_live(epoch)) error = _describe(failure);
    } finally {
      if (token != null && !retained) {
        try {
          await _releaseWrite(token);
        } catch (_) {
          error = '恢复写入权限释放尚未确认，请重试结束检查。';
        }
      }
      if (_live(epoch)) busy = false;
      _changed();
    }
  }

  Future<void> inspectCurrent() async {
    final read = access;
    if (busy || read == null) return;
    final epoch = ++_epoch;
    busy = true;
    snapshot = null;
    decision = null;
    error = null;
    _changed();
    try {
      final view = await commands.inspect(read.sessionToken);
      if (!_live(epoch)) return;
      if (!_validObservation(view, read.runId, read.operationId)) {
        throw const FormatException('Mismatched current observation');
      }
      snapshot = view;
    } catch (failure) {
      if (_live(epoch)) error = _describe(failure);
    } finally {
      if (_live(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> prepareDecision(String choice) async {
    final read = access, write = writeAccess, writeCommands = writer;
    if (busy ||
        read == null ||
        write == null ||
        writeCommands == null ||
        outcome?.recoveryId != null) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    error = null;
    decision = null;
    notice = null;
    _changed();
    final request =
        'recovery-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    try {
      final view = await writeCommands.prepare(
        read.sessionToken,
        write.sessionToken,
        request,
        choice,
      );
      if (!_live(epoch)) return;
      if (view.readSessionToken != read.sessionToken ||
          view.writeSessionToken != write.sessionToken ||
          view.choice != choice ||
          view.recoveryId.isEmpty ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(view.digest) ||
          !_validObservation(view.inspection, read.runId, read.operationId)) {
        throw const FormatException('Mismatched decision preview');
      }
      snapshot = view.inspection;
      decision = view;
    } catch (failure) {
      if (_live(epoch)) {
        snapshot = null;
        error = _describe(failure);
      }
    } finally {
      if (_live(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> approveDecision() async {
    final view = decision,
        writeCommands = writer,
        read = access,
        write = writeAccess;
    if (busy ||
        view == null ||
        writeCommands == null ||
        read == null ||
        write == null) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    decision = null;
    snapshot = null;
    error = null;
    notice = null;
    _changed();
    try {
      api.RecoveryOutcomeView result;
      try {
        result = await writeCommands.approve(view);
      } catch (_) {
        if (!_live(epoch)) return;
        // A lost reply is reconciled by metadata, never by resending approval.
        result = await writeCommands.outcome(read.runId, read.operationId);
      }
      if (!_live(epoch)) return;
      if (!_validOutcome(result, read.runId, read.operationId)) {
        throw const FormatException('Mismatched outcome');
      }
      if (result.recoveryId == view.recoveryId &&
          result.choice != view.choice) {
        throw const FormatException('Immutable recovery decision changed');
      }
      if (result.recoveryId == null) {
        error = '恢复结果尚未确认。请重新检查文件，不要重复提交旧批准。';
        return;
      }
      outcome = result;
      notice =
          result.recoveryId == view.recoveryId && result.choice == view.choice
          ? '本次处理已记录；原操作仍标记未确认，旧任务不会继续。'
          : '该改动已有另一条处理记录，本次决定未确认执行。';
      try {
        final current = await commands.inspect(read.sessionToken);
        if (_live(epoch) &&
            _validObservation(current, read.runId, read.operationId)) {
          snapshot = current;
        }
      } catch (_) {
        if (_live(epoch)) error = '已有处理记录，但当前文件状态仍需核对。';
      }
    } catch (failure) {
      if (_live(epoch)) error = _describe(failure);
    } finally {
      try {
        await _releaseWrite(write.sessionToken);
      } catch (_) {
        error = '恢复写入权限释放尚未确认，请重试结束检查。';
      }
      if (writeAccess?.sessionToken == write.sessionToken) writeAccess = null;
      if (_live(epoch)) busy = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    snapshot = null;
    access = null;
    writeAccess = null;
    decision = null;
    outcome = null;
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
