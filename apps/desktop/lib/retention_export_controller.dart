part of 'retention_controller.dart';

abstract interface class ExportCommands {
  Future<RecoverySelection?> choose();
  Future<api.ExportAccessView> authorize(
    api.RetentionAccessView reader,
    RecoverySelection selected,
  );
  Future<api.ExportReviewView> prepare(
    String token,
    String request,
    String fileName,
    String choice,
  );
  Future<api.ExportOutcomeView> approve(api.ExportReviewView review);
  Future<api.ExportOutcomeView?> outcome(
    String run,
    String op,
    String exportId,
  );
  Future<List<api.ExportOutcomeView>> records(
    String run,
    String op,
    String? before,
  );
  Future<void> release(String token);
}

class NativeExportCommands implements ExportCommands {
  NativeExportCommands(this.handle);
  final String handle;
  static const platform = MethodChannel('orange_agent/platform');
  @override
  Future<RecoverySelection?> choose() async {
    if (!Platform.isMacOS) {
      throw PlatformException(code: 'PLATFORM_NOT_VERIFIED');
    }
    final result = await platform.invokeMapMethod<String, dynamic>(
      'chooseExportDestination',
    );
    if (result == null) return null;
    final token = result['selectionId'], path = result['path'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('Invalid export selection');
    }
    if (path is! String || path.isEmpty) {
      await release(token);
      throw const FormatException('Invalid destination');
    }
    return RecoverySelection(token, path);
  }

  @override
  Future<api.ExportAccessView> authorize(
    api.RetentionAccessView reader,
    RecoverySelection selected,
  ) => api.authorizeExportDestination(
    handle: handle,
    readSessionToken: reader.sessionToken,
    requestId: selected.token,
    selectedDirectory: selected.directory,
  );
  @override
  Future<api.ExportReviewView> prepare(
    String token,
    String request,
    String fileName,
    String choice,
  ) => api.prepareExport(
    handle: handle,
    sessionToken: token,
    requestId: request,
    fileName: fileName,
    choice: choice,
  );
  @override
  Future<api.ExportOutcomeView> approve(api.ExportReviewView review) =>
      api.approveExport(
        handle: handle,
        sessionToken: review.sessionToken,
        exportId: review.exportId,
        expectedDigest: review.digest,
      );
  @override
  Future<api.ExportOutcomeView?> outcome(
    String run,
    String op,
    String exportId,
  ) => api.inspectExportOutcome(
    handle: handle,
    runId: run,
    operationId: op,
    exportId: exportId,
  );
  @override
  Future<List<api.ExportOutcomeView>> records(
    String run,
    String op,
    String? before,
  ) => api.listExportOutcomes(
    handle: handle,
    runId: run,
    operationId: op,
    before: before,
    limit: 100,
  );
  @override
  Future<void> release(String token) async {
    await api.suspendExportDestination(handle: handle, requestId: token);
    await platform.invokeMethod<void>('releaseExportDestinationSelection', {
      'selectionId': token,
    });
  }
}

extension ExportFlow on RetentionController {
  bool _validExportOutcome(api.ExportOutcomeView value) =>
      value.exportId.isNotEmpty &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value.reviewDigest) &&
      ['prepared', 'dispatching', 'succeeded', 'unknown'].contains(value.state);
  Future<void> _loadExportRecords(int epoch, {String? before}) async {
    final commands = exportCommands, run = selected, op = operation;
    if (commands == null || run == null || op == null) return;
    final records = await commands.records(run.runId, op, before);
    if (!_live(epoch)) return;
    if (records.length > 100 ||
        records.map((r) => r.exportId).toSet().length != records.length ||
        !records.every(_validExportOutcome)) {
      throw const FormatException('Invalid export outcomes');
    }
    exportRecords = records;
    exportCursor = records.length == 100 ? records.last.exportId : null;
  }

  Future<void> refreshExports({bool older = false}) async {
    if (busy || exportCommands == null || (older && exportCursor == null)) {
      return;
    }
    final epoch = _epoch, before = older ? exportCursor : null;
    busy = true;
    error = null;
    _notify();
    try {
      await _loadExportRecords(epoch, before: before);
    } catch (_) {
      if (_live(epoch)) error = '导出记录读取未完成。';
    } finally {
      if (_live(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> _releaseExport(String token) {
    if (!_heldExports.contains(token)) return Future.value();
    return _releasingExports.putIfAbsent(
      token,
      () => Future<void>.sync(() => exportCommands!.release(token))
          .then((_) {
            _heldExports.remove(token);
          })
          .whenComplete(() {
            _releasingExports.remove(token);
          }),
    );
  }

  Future<void> closeExport() async {
    ++_epoch;
    exportAccess = null;
    exportReview = null;
    exportOutcome = null;
    exportNotice = null;
    busy = false;
    error = null;
    _notify();
    try {
      await Future.wait(
        _heldExports.toList().map(_releaseExport),
        eagerError: false,
      );
    } catch (_) {
      error = '导出目录权限释放尚未确认，请重试关闭目标。';
      _notify();
      rethrow;
    }
  }

  void setExportFileName(String value) {
    if (busy) return;
    exportFileName = value;
    exportReview = null;
    exportOutcome = null;
    exportNotice = null;
    _notify();
  }

  void setExportChoice(String value) {
    if (busy || !['original', 'staged', 'both'].contains(value)) return;
    exportChoice = value;
    exportReview = null;
    exportOutcome = null;
    exportNotice = null;
    _notify();
  }

  Future<void> chooseExportDestination() async {
    final reader = access, commands = exportCommands;
    if (busy || reader == null || commands == null) return;
    final epoch = ++_epoch;
    exportAccess = null;
    exportReview = null;
    exportOutcome = null;
    exportNotice = null;
    error = null;
    busy = true;
    _notify();
    String? token;
    bool retained = false;
    try {
      await Future.wait(
        _heldExports.toList().map(_releaseExport),
        eagerError: false,
      );
      if (!_live(epoch)) return;
      final choice = await commands.choose();
      if (choice == null) return;
      token = choice.token;
      _heldExports.add(token);
      if (!_seenExports.add(token)) {
        throw const FormatException('Reused export selection');
      }
      if (!_live(epoch)) return;
      final value = await commands.authorize(reader, choice);
      if (!_live(epoch)) return;
      if (value.sessionToken != token ||
          value.readSessionToken != reader.sessionToken ||
          value.runId != reader.runId ||
          value.operationId != reader.operationId ||
          value.workspaceId != reader.workspaceId) {
        throw const FormatException('Mismatched export selection');
      }
      exportAccess = value;
      retained = true;
    } catch (e) {
      if (_live(epoch)) error = _describe(e);
    } finally {
      if (token != null && !retained) {
        try {
          await _releaseExport(token);
        } catch (_) {
          error = '导出目录权限释放尚未确认，请重试关闭目标。';
        }
      }
      if (_live(epoch)) busy = false;
      _notify();
    }
  }

  Future<void> prepareExport() async {
    final destination = exportAccess,
        reader = access,
        commands = exportCommands;
    if (busy || destination == null || reader == null || commands == null) {
      return;
    }
    final epoch = _epoch;
    exportReview = null;
    exportOutcome = null;
    exportNotice = null;
    error = null;
    busy = true;
    _notify();
    final name = exportFileName, choice = exportChoice;
    try {
      final request = List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final value = await commands.prepare(
        destination.sessionToken,
        request,
        name,
        choice,
      );
      if (!_live(epoch)) return;
      final hash = RegExp(r'^[0-9a-f]{64}$'),
          decimal = RegExp(r'^(0|[1-9][0-9]*)$');
      if (value.sessionToken != destination.sessionToken ||
          value.readSessionToken != reader.sessionToken ||
          value.runId != reader.runId ||
          value.operationId != reader.operationId ||
          value.fileName != name ||
          value.choice != choice ||
          value.sourcePath != snapshot?.path ||
          value.exportId.isEmpty ||
          !hash.hasMatch(value.digest) ||
          !hash.hasMatch(value.artifactSha256) ||
          !decimal.hasMatch(value.artifactBytes) ||
          BigInt.parse(value.artifactBytes) > BigInt.from(3 * 1024 * 1024) ||
          value.entries.isEmpty ||
          value.entries.length > 2 ||
          value.entries.map((e) => e.role).toSet().length !=
              value.entries.length ||
          !value.entries.every(
            (e) =>
                ['original', 'staged'].contains(e.role) &&
                (choice == 'both' || choice == e.role) &&
                hash.hasMatch(e.sha256) &&
                decimal.hasMatch(e.bytes) &&
                BigInt.parse(e.bytes) <= BigInt.from(1024 * 1024),
          ) ||
          BigInt.parse(value.expiresAt.toString()) <=
              BigInt.from(DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
        throw const FormatException('Mismatched export preview');
      }
      exportReview = value;
    } catch (e) {
      if (_live(epoch)) error = _describe(e);
    } finally {
      if (_live(epoch)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> approveExport() async {
    final commands = exportCommands, review = exportReview;
    if (busy || commands == null || review == null) return;
    final epoch = _epoch;
    exportReview = null;
    exportOutcome = null;
    exportNotice = null;
    error = null;
    busy = true;
    _notify();
    try {
      api.ExportOutcomeView? result;
      try {
        result = await commands.approve(review);
      } catch (_) {
        if (!_live(epoch)) return;
        result = await commands.outcome(
          review.runId,
          review.operationId,
          review.exportId,
        );
      }
      if (!_live(epoch)) return;
      if (result == null ||
          !_validExportOutcome(result) ||
          result.exportId != review.exportId ||
          result.reviewDigest != review.digest) {
        error = '导出结果未确认，未自动重发。可刷新导出记录核对。';
        return;
      }
      exportOutcome = result;
      if (result.state == 'succeeded') {
        exportNotice = '已确认导出 ${review.fileName}，原件未删除。';
      } else {
        error = '导出结果待核对，未自动重发或删除文件。';
      }
      try {
        await _loadExportRecords(epoch);
      } catch (_) {
        if (_live(epoch)) {
          error = result.state == 'succeeded'
              ? '导出已确认，但记录列表未能刷新。'
              : '导出结果待核对，记录列表未能刷新。';
        }
      }
    } catch (_) {
      if (_live(epoch)) error = '导出结果未确认，未自动重发。可刷新导出记录核对。';
    } finally {
      if (_live(epoch)) {
        busy = false;
        _notify();
      }
    }
  }
}
