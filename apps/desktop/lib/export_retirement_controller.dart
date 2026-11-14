import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'export_restoration_controller.dart';
import 'recovery_controller.dart' show RecoverySelection;
import 'src/rust/api/host.dart' as api;

abstract interface class ExportRetirementCommands {
  Future<RecoverySelection?> choose();
  Future<api.ExportRetirementAccessView> authorize(
    String reader,
    RecoverySelection choice,
  );
  Future<api.ExportRetirementReviewView> prepare(
    String token,
    String key,
    String choice,
  );
  Future<api.ExportRetirementOutcomeView> approve(
    String token,
    String id,
    String digest,
  );
  Future<List<api.ExportRetirementOutcomeView>> list(
    api.ExportInspectionAccessView read,
    String? before,
  );
  Future<api.ExportRetirementInspectionView> inspect(String reader, String id);
  Future<void> release(String token);
}

class NativeExportRetirementCommands implements ExportRetirementCommands {
  NativeExportRetirementCommands(this.handle);
  final String handle;
  static const platform = MethodChannel('orange_agent/platform');
  @override
  Future<RecoverySelection?> choose() async {
    if (!Platform.isMacOS) {
      throw PlatformException(code: 'PLATFORM_NOT_VERIFIED');
    }
    final v = await platform.invokeMapMethod<String, dynamic>(
      'chooseExportRetirementDirectory',
    );
    if (v == null) return null;
    final token = v['selectionId'], path = v['path'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('Invalid retirement selection');
    }
    if (path is! String || path.isEmpty) {
      await release(token);
      throw const FormatException('Invalid retirement directory');
    }
    return RecoverySelection(token, path);
  }

  @override
  Future<api.ExportRetirementAccessView> authorize(
    String reader,
    RecoverySelection choice,
  ) => api.authorizeExportRetirement(
    handle: handle,
    readSessionToken: reader,
    requestId: choice.token,
    selectedDirectory: choice.directory,
  );
  @override
  Future<api.ExportRetirementReviewView> prepare(
    String token,
    String key,
    String choice,
  ) => api.prepareExportRetirement(
    handle: handle,
    sessionToken: token,
    requestId: key,
    choice: choice,
  );
  @override
  Future<api.ExportRetirementOutcomeView> approve(
    String token,
    String id,
    String digest,
  ) => api.approveExportRetirement(
    handle: handle,
    sessionToken: token,
    retirementId: id,
    expectedDigest: digest,
  );
  @override
  Future<List<api.ExportRetirementOutcomeView>> list(
    api.ExportInspectionAccessView read,
    String? before,
  ) => api.listExportRetirements(
    handle: handle,
    runId: read.runId,
    operationId: read.operationId,
    exportId: read.exportId,
    before: before,
    limit: 50,
  );
  @override
  Future<api.ExportRetirementInspectionView> inspect(
    String reader,
    String id,
  ) => api.inspectExportRetirement(
    handle: handle,
    readSessionToken: reader,
    retirementId: id,
  );
  @override
  Future<void> release(String token) async {
    await api.suspendExportRetirement(handle: handle, requestId: token);
    await platform.invokeMethod<void>('releaseExportRetirementSelection', {
      'selectionId': token,
    });
  }
}

class ExportRetirementController extends ChangeNotifier {
  ExportRetirementController(
    this.commands, {
    this.afterDispatch,
    ExportRestorationCommands? restorationCommands,
  }) {
    final source =
        restorationCommands ??
        (commands is NativeExportRetirementCommands
            ? NativeExportRestorationCommands(
                (commands as NativeExportRetirementCommands).handle,
              )
            : null);
    if (source != null) {
      restoration = ExportRestorationController(
        source,
        afterDispatch: () {
          snapshot = null;
          inspection = null;
          afterDispatch?.call();
          _notify();
        },
      );
    }
  }
  ExportRestorationController? restoration;
  Future<void> openRestoration(api.ExportRetirementOutcomeView record) async {
    final source = read, target = restoration;
    if (_disposed || busy || source == null || target == null) return;
    final epoch = _epoch;
    busy = true;
    review = null;
    access = null;
    error = null;
    _notify();
    try {
      await Future.wait(_held.toList().map(_release), eagerError: false);
      if (!_live(epoch)) return;
      await target.open(source, record);
    } catch (_) {
      if (_live(epoch)) error = '权限释放或恢复记录查询未完成，请重试。';
    } finally {
      if (_live(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  final ExportRetirementCommands commands;
  final VoidCallback? afterDispatch;
  api.ExportInspectionAccessView? read;
  api.ExportInspectionView? snapshot;
  api.ExportRetirementAccessView? access;
  api.ExportRetirementReviewView? review;
  api.ExportRetirementInspectionView? inspection;
  List<api.ExportRetirementOutcomeView> records = [];
  String? error, notice, cursor;
  bool busy = false, hasMore = false, _disposed = false;
  int _epoch = 0;
  final _held = <String>{}, _seen = <String>{};
  final _releasing = <String, Future<void>>{};
  bool _live(int epoch) => !_disposed && epoch == _epoch;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static bool hash(String? v) => RegExp(r'^[0-9a-f]{64}$').hasMatch(v ?? '');
  static bool _regular(api.ExportObservedFileView v) =>
      v.kind == 'regular' &&
      v.reason == null &&
      hash(v.sha256) &&
      RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(v.bytes ?? '') &&
      BigInt.parse(v.bytes!) <= BigInt.from(3 * 1024 * 1024) &&
      (!v.matchesApprovedArtifact || v.validExportDocument);
  bool canPrepare(String choice) {
    final s = snapshot;
    if (s == null ||
        busy ||
        !['succeeded', 'unknown'].contains(s.recordedState)) {
      return false;
    }
    final f = choice == 'target' ? s.target : s.staged;
    return _regular(f) && f.matchesApprovedArtifact && f.validExportDocument;
  }

  void invalidate() {
    restoration?.invalidate();
    ++_epoch;
    read = null;
    snapshot = null;
    access = null;
    review = null;
    inspection = null;
    records = [];
    error = null;
    notice = null;
    cursor = null;
    hasMore = false;
    busy = false;
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
      await restoration?.close();
      await Future.wait(_held.toList().map(_release), eagerError: false);
    } catch (_) {
      error = '移出权限释放尚未确认，请重试结束检查。';
      _notify();
      rethrow;
    }
  }

  Future<void> attach(
    api.ExportInspectionAccessView grant,
    api.ExportInspectionView view,
  ) async {
    final closing = close();
    final epoch = _epoch;
    await closing;
    if (!_live(epoch)) return;
    read = grant;
    snapshot = view;
    await refresh();
  }

  Future<void> _load(int epoch, {bool more = false}) async {
    final source = read;
    if (source == null) return;
    final page = await commands.list(source, more ? cursor : null);
    if (!_live(epoch)) return;
    final ids = <String>{};
    String? previous = more ? cursor : null;
    for (final v in page) {
      if (v.exportId != source.exportId ||
          !hash(v.reviewDigest) ||
          ![
            'prepared',
            'dispatching',
            'retained',
            'unknown',
          ].contains(v.state) ||
          !RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ).hasMatch(v.retirementId) ||
          !ids.add(v.retirementId) ||
          (previous != null && v.retirementId.compareTo(previous) >= 0)) {
        throw const FormatException('Invalid retirement index');
      }
      previous = v.retirementId;
    }
    if (page.length > 50) {
      throw const FormatException('Retirement page exceeds limit');
    }
    records = more ? [...records, ...page] : page;
    cursor = page.isEmpty ? cursor : page.last.retirementId;
    hasMore = page.length == 50;
  }

  Future<void> refresh({bool more = false}) async {
    if (_disposed || busy || read == null) return;
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      await _load(epoch, more: more);
    } catch (_) {
      if (_live(epoch)) error = '移出记录读取失败，请重试查询。';
    } finally {
      if (_live(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> prepare(String choice) async {
    if (!canPrepare(choice) || _disposed) return;
    final epoch = _epoch, source = read!, old = snapshot!;
    busy = true;
    review = null;
    access = null;
    inspection = null;
    error = null;
    notice = null;
    _notify();
    String? token;
    bool kept = false;
    try {
      await restoration?.close();
      await Future.wait(_held.toList().map(_release), eagerError: false);
      if (!_live(epoch)) return;
      final selected = await commands.choose();
      if (selected == null) return;
      token = selected.token;
      _held.add(token);
      if (!_seen.add(token)) {
        throw const FormatException('Reused write selection');
      }
      if (!_live(epoch)) return;
      final granted = await commands.authorize(source.sessionToken, selected);
      if (!_live(epoch)) return;
      if (granted.sessionToken != token ||
          granted.readSessionToken != source.sessionToken ||
          granted.runId != source.runId ||
          granted.operationId != source.operationId ||
          granted.exportId != source.exportId) {
        throw const FormatException('Mismatched retirement access');
      }
      final prepared = await commands.prepare(token, 'retire-$token', choice);
      if (!_live(epoch)) return;
      if (!RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          ).hasMatch(prepared.retirementId) ||
          prepared.sessionToken != token ||
          prepared.exportId != source.exportId ||
          prepared.choice != choice ||
          prepared.fileName != old.fileName ||
          !hash(prepared.digest) ||
          !_regular(prepared.observed) ||
          !prepared.observed.matchesApprovedArtifact ||
          !prepared.observed.validExportDocument ||
          prepared.expiresAt.toInt() <=
              DateTime.now().millisecondsSinceEpoch ~/ 1000) {
        throw const FormatException('Mismatched retirement preview');
      }
      access = granted;
      review = prepared;
      kept = true;
    } catch (_) {
      if (_live(epoch)) error = '不能准备移出：请核对目录、文件状态和写入者是否已停止。';
    } finally {
      if (token != null && !kept) {
        try {
          await _release(token);
        } catch (_) {
          error = '移出权限释放尚未确认，请重试结束检查。';
        }
      }
      if (_live(epoch)) busy = false;
      _notify();
    }
  }

  Future<void> approve() async {
    final v = review, a = access;
    if (_disposed || busy || v == null || a == null) return;
    if (v.expiresAt.toInt() <= DateTime.now().millisecondsSinceEpoch ~/ 1000) {
      review = null;
      error = '预览已过期，请重新选择并预览。';
      _notify();
      return;
    }
    final epoch = _epoch;
    busy = true;
    review = null;
    inspection = null;
    error = null;
    notice = null;
    _notify();
    try {
      final result = await commands.approve(
        a.sessionToken,
        v.retirementId,
        v.digest,
      );
      if (!_live(epoch)) return;
      if (result.retirementId != v.retirementId ||
          result.exportId != v.exportId ||
          result.reviewDigest != v.digest ||
          result.state != 'retained') {
        throw const FormatException('Unconfirmed retirement receipt');
      }
      notice = '已移入保留区，数据仍保留。';
    } catch (_) {
      if (_live(epoch)) error = '移出结果未确认。请查询记录并检查保留区；不会自动重试。';
    } finally {
      if (_live(epoch)) {
        snapshot = null;
        afterDispatch?.call();
        try {
          await _load(epoch);
        } catch (_) {
          if (_live(epoch)) error = '结果记录读取失败，请重试查询；不会自动重放。';
        }
      }
      try {
        await _release(a.sessionToken);
      } catch (_) {
        if (_live(epoch)) error = '移出权限释放尚未确认，请重试结束检查。';
      }
      if (_live(epoch)) {
        access = null;
        busy = false;
        _notify();
      }
    }
  }

  Future<void> inspect(api.ExportRetirementOutcomeView record) async {
    if (_disposed || busy || read == null) return;
    final epoch = _epoch, source = read!;
    busy = true;
    inspection = null;
    error = null;
    _notify();
    try {
      final v = await commands.inspect(
        source.sessionToken,
        record.retirementId,
      );
      if (!_live(epoch)) return;
      final f = v.retained;
      if (v.sessionToken != source.sessionToken ||
          v.retirementId != record.retirementId ||
          v.exportId != source.exportId ||
          v.recordedState != record.state ||
          !['target', 'staged'].contains(v.choice) ||
          (!v.capsuleBound && f != null) ||
          (v.capsuleBound && f == null) ||
          (f != null &&
              !(_regular(f) ||
                  (f.kind == 'missing' &&
                      f.bytes == null &&
                      f.sha256 == null &&
                      !f.matchesApprovedArtifact &&
                      !f.validExportDocument) ||
                  (f.kind == 'refused' &&
                      f.reason != null &&
                      f.bytes == null &&
                      f.sha256 == null &&
                      !f.matchesApprovedArtifact &&
                      !f.validExportDocument)))) {
        throw const FormatException('Mismatched capsule inspection');
      }
      inspection = v;
    } catch (_) {
      if (_live(epoch)) error = '保留区检查未完成：目录绑定或文件状态可能已变化。';
    } finally {
      if (_live(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  @override
  void dispose() {
    restoration?.dispose();
    _disposed = true;
    ++_epoch;
    read = null;
    review = null;
    inspection = null;
    unawaited(
      Future.wait(_held.toList().map(_release), eagerError: false).catchError((
        Object e,
        StackTrace s,
      ) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: e,
            stack: s,
            library: 'export retirement cleanup',
          ),
        );
        return <void>[];
      }),
    );
    super.dispose();
  }
}
