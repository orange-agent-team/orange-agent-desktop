import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'recovery_controller.dart' show RecoverySelection;
import 'src/rust/api/host.dart' as api;

abstract interface class ExportRestorationCommands {
  Future<RecoverySelection?> choose();
  Future<api.ExportRestorationAccessView> authorize(
    String reader,
    RecoverySelection selection,
  );
  Future<api.ExportRestorationReviewView> prepare(
    String token,
    String key,
    String retirementId,
    String fileName,
  );
  Future<api.ExportRestorationOutcomeView> approve(
    String token,
    String id,
    String digest,
  );
  Future<List<api.ExportRestorationOutcomeView>> list(
    api.ExportInspectionAccessView read,
    String retirementId,
    String? before,
  );
  Future<api.ExportRestorationInspectionView> inspect(String reader, String id);
  Future<void> release(String token);
}

class NativeExportRestorationCommands implements ExportRestorationCommands {
  NativeExportRestorationCommands(this.handle);
  final String handle;
  static const platform = MethodChannel('orange_agent/platform');
  @override
  Future<RecoverySelection?> choose() async {
    if (!Platform.isMacOS) {
      throw PlatformException(code: 'PLATFORM_NOT_VERIFIED');
    }
    final v = await platform.invokeMapMethod<String, dynamic>(
      'chooseExportRestorationDirectory',
    );
    if (v == null) return null;
    final token = v['selectionId'], path = v['path'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('Invalid restoration token');
    }
    if (path is! String || path.isEmpty) {
      await release(token);
      throw const FormatException('Invalid restoration directory');
    }
    return RecoverySelection(token, path);
  }

  @override
  Future<api.ExportRestorationAccessView> authorize(
    String reader,
    RecoverySelection choice,
  ) => api.authorizeExportRestoration(
    handle: handle,
    readSessionToken: reader,
    requestId: choice.token,
    selectedDirectory: choice.directory,
  );
  @override
  Future<api.ExportRestorationReviewView> prepare(
    String token,
    String key,
    String retirementId,
    String fileName,
  ) => api.prepareExportRestoration(
    handle: handle,
    sessionToken: token,
    requestId: key,
    retirementId: retirementId,
    fileName: fileName,
  );
  @override
  Future<api.ExportRestorationOutcomeView> approve(
    String token,
    String id,
    String digest,
  ) => api.approveExportRestoration(
    handle: handle,
    sessionToken: token,
    restorationId: id,
    expectedDigest: digest,
  );
  @override
  Future<List<api.ExportRestorationOutcomeView>> list(
    api.ExportInspectionAccessView read,
    String retirementId,
    String? before,
  ) => api.listExportRestorations(
    handle: handle,
    runId: read.runId,
    operationId: read.operationId,
    retirementId: retirementId,
    before: before,
    limit: 50,
  );
  @override
  Future<api.ExportRestorationInspectionView> inspect(
    String reader,
    String id,
  ) => api.inspectExportRestoration(
    handle: handle,
    readSessionToken: reader,
    restorationId: id,
  );
  @override
  Future<void> release(String token) async {
    await api.suspendExportRestoration(handle: handle, requestId: token);
    await platform.invokeMethod<void>('releaseExportRestorationSelection', {
      'selectionId': token,
    });
  }
}

class ExportRestorationController extends ChangeNotifier {
  ExportRestorationController(this.commands, {this.afterDispatch});
  final ExportRestorationCommands commands;
  final VoidCallback? afterDispatch;
  api.ExportInspectionAccessView? read;
  api.ExportRetirementOutcomeView? parent;
  api.ExportRestorationAccessView? access;
  api.ExportRestorationReviewView? review;
  api.ExportRestorationInspectionView? inspection;
  List<api.ExportRestorationOutcomeView> records = [];
  String fileName = 'recovered.orange-retained.json';
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
  static bool id(String v) =>
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(v);
  static bool name(String v) =>
      v.isNotEmpty &&
      v.length <= 200 &&
      v.endsWith('.orange-retained.json') &&
      !v.startsWith('.') &&
      !RegExp(r'[\\/\x00-\x1f:]').hasMatch(v);
  static bool regular(api.ExportObservedFileView v) =>
      v.kind == 'regular' &&
      v.reason == null &&
      hash(v.sha256) &&
      RegExp(r'^(0|[1-9][0-9]{0,9})$').hasMatch(v.bytes ?? '') &&
      BigInt.parse(v.bytes!) <= BigInt.from(3 * 1024 * 1024) &&
      (!v.matchesApprovedArtifact || v.validExportDocument);
  static bool observed(api.ExportObservedFileView v) =>
      regular(v) ||
      ((v.kind == 'missing' && v.reason == null ||
              v.kind == 'refused' &&
                  v.reason != null &&
                  v.reason!.isNotEmpty &&
                  v.reason!.length <= 128) &&
          v.bytes == null &&
          v.sha256 == null &&
          !v.matchesApprovedArtifact &&
          !v.validExportDocument);
  bool get canPrepare =>
      !busy &&
      read != null &&
      parent != null &&
      ['retained', 'unknown'].contains(parent!.state) &&
      name(fileName);
  void setFileName(String value) {
    if (busy || _disposed) return;
    fileName = value;
    review = null;
    error = null;
    notice = null;
    _notify();
  }

  void invalidate() {
    ++_epoch;
    read = null;
    parent = null;
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
      await Future.wait(_held.toList().map(_release), eagerError: false);
    } catch (_) {
      error = '恢复权限释放尚未确认，请重试结束恢复。';
      _notify();
      rethrow;
    }
  }

  Future<void> open(
    api.ExportInspectionAccessView grant,
    api.ExportRetirementOutcomeView selected,
  ) async {
    final closing = close();
    final epoch = _epoch;
    await closing;
    if (!_live(epoch)) return;
    if (selected.exportId != grant.exportId ||
        !id(selected.retirementId) ||
        !hash(selected.reviewDigest) ||
        ![
          'prepared',
          'dispatching',
          'retained',
          'unknown',
        ].contains(selected.state)) {
      error = '保留记录与当前检查不匹配。';
      _notify();
      return;
    }
    read = grant;
    parent = selected;
    fileName = 'recovered.orange-retained.json';
    await refresh();
  }

  Future<void> _load(int epoch, {bool more = false}) async {
    final source = read, selected = parent;
    if (source == null || selected == null) return;
    final page = await commands.list(
      source,
      selected.retirementId,
      more ? cursor : null,
    );
    if (!_live(epoch)) return;
    if (page.length > 50) {
      throw const FormatException('Restoration page exceeds limit');
    }
    final ids = <String>{};
    String? previous = more ? cursor : null;
    for (final v in page) {
      if (!id(v.restorationId) ||
          v.retirementId != selected.retirementId ||
          v.exportId != source.exportId ||
          !hash(v.reviewDigest) ||
          !name(v.fileName) ||
          ![
            'prepared',
            'dispatching',
            'succeeded',
            'unknown',
          ].contains(v.state) ||
          !ids.add(v.restorationId) ||
          (previous != null && v.restorationId.compareTo(previous) >= 0)) {
        throw const FormatException('Invalid restoration index');
      }
      previous = v.restorationId;
    }
    records = more ? [...records, ...page] : page;
    cursor = page.isEmpty ? cursor : page.last.restorationId;
    hasMore = page.length == 50;
  }

  Future<void> refresh({bool more = false}) async {
    if (_disposed || busy || read == null || parent == null) return;
    final epoch = _epoch;
    busy = true;
    error = null;
    _notify();
    try {
      await _load(epoch, more: more);
    } catch (_) {
      if (_live(epoch)) error = '恢复记录读取失败，请重试查询。';
    } finally {
      if (_live(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> prepare() async {
    if (_disposed || !canPrepare) return;
    final epoch = _epoch, source = read!, selected = parent!, target = fileName;
    busy = true;
    access = null;
    review = null;
    inspection = null;
    error = null;
    notice = null;
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
        throw const FormatException('Reused restore selection');
      }
      if (!_live(epoch)) return;
      final granted = await commands.authorize(source.sessionToken, choice);
      if (!_live(epoch)) return;
      if (granted.sessionToken != token ||
          granted.readSessionToken != source.sessionToken ||
          granted.runId != source.runId ||
          granted.operationId != source.operationId ||
          granted.exportId != source.exportId) {
        throw const FormatException('Mismatched restoration access');
      }
      final v = await commands.prepare(
        token,
        'restore-$token',
        selected.retirementId,
        target,
      );
      if (!_live(epoch)) return;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (v.sessionToken != token ||
          !id(v.restorationId) ||
          v.retirementId != selected.retirementId ||
          v.exportId != source.exportId ||
          v.fileName != target ||
          !hash(v.digest) ||
          !regular(v.source) ||
          !v.source.matchesApprovedArtifact ||
          !v.source.validExportDocument ||
          v.expiresAt.toInt() <= now ||
          v.expiresAt.toInt() > now + 301) {
        throw const FormatException('Mismatched recovery preview');
      }
      access = granted;
      review = v;
      kept = true;
    } catch (_) {
      if (_live(epoch)) error = '无法准备恢复：请检查保留项、目录权限和目标文件名；已有目标不会被覆盖。';
    } finally {
      if (token != null && !kept) {
        try {
          await _release(token);
        } catch (_) {
          error = '恢复权限释放尚未确认，请重试结束恢复。';
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
      error = '恢复预览已过期，请重新选择并预览。';
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
        v.restorationId,
        v.digest,
      );
      if (!_live(epoch)) return;
      if (result.restorationId != v.restorationId ||
          result.retirementId != v.retirementId ||
          result.exportId != v.exportId ||
          result.fileName != v.fileName ||
          result.reviewDigest != v.digest ||
          result.state != 'succeeded') {
        throw const FormatException('Unconfirmed restoration receipt');
      }
      notice = '恢复副本已创建，保留区原件仍保留。';
    } catch (_) {
      if (_live(epoch)) error = '恢复结果未确认，请查询记录并检查目标和暂存文件；不会自动重试。';
    } finally {
      if (_live(epoch)) {
        afterDispatch?.call();
        try {
          await _load(epoch);
        } catch (_) {
          if (_live(epoch)) error = '恢复记录读取失败，请重试查询；不会自动重放。';
        }
      }
      try {
        await _release(a.sessionToken);
      } catch (_) {
        if (_live(epoch)) error = '恢复权限释放尚未确认，请重试结束恢复。';
      }
      if (_live(epoch)) {
        access = null;
        busy = false;
        _notify();
      }
    }
  }

  Future<void> inspect(api.ExportRestorationOutcomeView record) async {
    if (_disposed || busy || read == null || parent == null) return;
    final epoch = _epoch, source = read!, selected = parent!;
    busy = true;
    inspection = null;
    error = null;
    _notify();
    try {
      final v = await commands.inspect(
        source.sessionToken,
        record.restorationId,
      );
      if (!_live(epoch)) return;
      if (v.sessionToken != source.sessionToken ||
          v.restorationId != record.restorationId ||
          v.retirementId != selected.retirementId ||
          v.exportId != source.exportId ||
          v.fileName != record.fileName ||
          v.recordedState != record.state ||
          !observed(v.target) ||
          !observed(v.staged)) {
        throw const FormatException('Mismatched restoration inspection');
      }
      inspection = v;
    } catch (_) {
      if (_live(epoch)) error = '恢复结果检查未完成，请核对记录及目录权限。';
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
    review = null;
    inspection = null;
    read = null;
    parent = null;
    unawaited(
      Future.wait(_held.toList().map(_release), eagerError: false).catchError((
        Object e,
        StackTrace s,
      ) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: e,
            stack: s,
            library: 'export restoration cleanup',
          ),
        );
        return <void>[];
      }),
    );
    super.dispose();
  }
}
