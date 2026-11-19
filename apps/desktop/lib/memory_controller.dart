import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'src/rust/api/host.dart' show BridgeError;
import 'src/rust/api/memory.dart' as api;

abstract interface class MemoryCommands {
  Future<api.MemoryScopePage> scopes(String? cursor);
  Future<api.MemoryScopeView> create(String id, bool shared);
  Future<api.MemoryAccessView> authorize(
    api.MemoryScopeView scope,
    String token,
    bool write,
  );
  Future<void> release(String token);
  Future<api.MemoryMemberPage> members(
    api.MemoryScopeView scope,
    String? cursor,
  );
  Future<api.MemoryScopeView> member(
    api.MemoryScopeView scope,
    String principal,
    String access,
  );
  Future<api.MemoryScopeView> enable(api.MemoryScopeView scope, bool enabled);
  Future<api.MemoryPage> entries(
    api.MemorySelection selected,
    String? cursor,
    bool disabled,
  );
  Future<api.MemoryEntry> read(
    api.MemorySelection selected,
    String id,
    String version,
    int start,
  );
  Future<api.MemoryReview> prepare(
    api.MemorySelection selected,
    api.MemoryEdit edit,
  );
  Future<api.MemoryReview> review(api.MemorySelection selected, String draft);
  Future<api.MemoryOutcome> approve(
    api.MemorySelection selected,
    api.MemoryReview review,
  );
  Future<api.MemoryOutcome?> outcome(String scope, String request);
}

abstract interface class MemoryDraftDirectory {
  Future<List<api.MemoryOutcome>> pendingDrafts(String scope, String? after);
  Future<api.MemoryOutcome> discardDraft(api.MemoryOutcome receipt);
}

class NativeMemoryCommands implements MemoryCommands, MemoryDraftDirectory {
  NativeMemoryCommands(this.handle);
  final String handle;
  @override
  Future<List<api.MemoryOutcome>> pendingDrafts(String scope, String? after) =>
      api.pendingUserDrafts(
        handle: handle,
        scopeId: scope,
        after: after,
        limit: 30,
      );
  @override
  Future<api.MemoryOutcome> discardDraft(api.MemoryOutcome receipt) =>
      api.discardUserDraft(
        handle: handle,
        scopeId: receipt.scopeId,
        draftId: receipt.draftId,
        digest: receipt.digest,
      );
  @override
  Future<api.MemoryScopePage> scopes(String? cursor) =>
      api.listScopes(handle: handle, cursor: cursor, limit: 100);
  @override
  Future<api.MemoryScopeView> create(String id, bool shared) =>
      api.createScope(handle: handle, scopeId: id, shared: shared);
  @override
  Future<api.MemoryAccessView> authorize(
    api.MemoryScopeView scope,
    String token,
    bool write,
  ) => api.authorizeScope(
    handle: handle,
    scopeId: scope.scopeId,
    revision: scope.revision,
    requestId: token,
    write: write,
  );
  @override
  Future<api.MemoryMemberPage> members(
    api.MemoryScopeView scope,
    String? cursor,
  ) => api.listMembers(
    handle: handle,
    scopeId: scope.scopeId,
    revision: scope.revision,
    cursor: cursor,
    limit: 64,
  );
  @override
  Future<api.MemoryScopeView> member(
    api.MemoryScopeView scope,
    String principal,
    String access,
  ) => api.setMember(
    handle: handle,
    scopeId: scope.scopeId,
    revision: scope.revision,
    principal: principal,
    access: access,
  );
  @override
  Future<void> release(String token) =>
      api.suspendAccess(handle: handle, requestId: token);
  @override
  Future<api.MemoryScopeView> enable(api.MemoryScopeView scope, bool enabled) =>
      api.setScopeEnabled(
        handle: handle,
        scopeId: scope.scopeId,
        revision: scope.revision,
        enabled: enabled,
      );
  @override
  Future<api.MemoryPage> entries(
    api.MemorySelection selected,
    String? cursor,
    bool disabled,
  ) => api.listEntries(
    handle: handle,
    selection: selected,
    cursor: cursor,
    limit: 30,
    includeDisabled: disabled,
  );
  @override
  Future<api.MemoryEntry> read(
    api.MemorySelection selected,
    String id,
    String version,
    int start,
  ) => api.readEntry(
    handle: handle,
    selection: selected,
    entryId: id,
    expectedVersion: version,
    startByte: start,
    maxBytes: 4096,
    includeDisabled: true,
  );
  @override
  Future<api.MemoryReview> prepare(
    api.MemorySelection selected,
    api.MemoryEdit edit,
  ) => api.prepareEdit(handle: handle, selection: selected, edit: edit);
  @override
  Future<api.MemoryReview> review(api.MemorySelection selected, String draft) =>
      api.reviewEdit(handle: handle, selection: selected, draftId: draft);
  @override
  Future<api.MemoryOutcome> approve(
    api.MemorySelection selected,
    api.MemoryReview review,
  ) => api.approveEdit(
    handle: handle,
    selection: selected,
    draftId: review.draftId,
    approvalDigest: review.approvalDigest,
  );
  @override
  Future<api.MemoryOutcome?> outcome(String scope, String request) =>
      api.inspectEdit(handle: handle, scopeId: scope, requestId: request);
}

/// Owns current selection tokens and rejects late content by request generation.
class MemoryController extends ChangeNotifier {
  MemoryController(this.commands, {String Function()? token})
    : _token = token ?? _newToken;
  final MemoryCommands commands;
  final String Function() _token;
  static String _newToken() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  List<api.MemoryScopeView> scopes = [];
  String? scopeCursor, selectedScope;
  api.MemoryAccessView? access;
  final Map<String, api.MemoryAccessView> sourceAccess = {};
  final Set<String> sourceWorkspaces = {};
  List<api.MemoryMemberView> memberRows = [];
  String? memberCursor;
  List<api.MemorySummary> entries = [];
  String? entryCursor;
  bool omitted = false,
      scanLimited = false,
      includeDisabled = false,
      busy = false;
  api.MemoryEntry? entry;
  api.MemoryReview? preview;
  api.MemoryOutcome? receipt;
  String? error, notice, pendingRequest, pendingScope;
  String? _targetEntry, targetVersion;
  int visibilityEpoch = 0, _epoch = 0;
  bool _disposed = false;
  final Set<String> _held = {};
  final Map<String, Future<void>> _releasing = {};
  bool _live(int n) => !_disposed && n == _epoch;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  api.MemoryScopeView? get scope {
    for (final v in scopes) {
      if (v.scopeId == selectedScope) return v;
    }
    return null;
  }

  bool get canWrite =>
      access?.write == true && access?.scopeId == selectedScope;
  api.MemorySelection? get selection {
    final a = access;
    if (a == null || a.scopeId != selectedScope) return null;
    return api.MemorySelection(
      scopeId: a.scopeId,
      sessionToken: a.sessionToken,
      sources: api.MemorySources(
        workspaceIds: sourceWorkspaces.toList()..sort(),
        memoryTokens: sourceAccess.values.map((v) => v.sessionToken).toList()
          ..sort(),
      ),
    );
  }

  void _hide() {
    visibilityEpoch++;
    drafts = [];
    draftAfter = null;
    entries = [];
    entryCursor = null;
    entry = null;
    _targetEntry = null;
    targetVersion = null;
    preview = null;
    omitted = false;
    scanLimited = false;
  }

  void invalidateSources() {
    _epoch++;
    busy = false;
    _hide();
    notice = null;
    _notify();
  }

  void workspaceStopping(String id) {
    if (sourceWorkspaces.remove(id)) invalidateSources();
  }

  String _describe(Object e) => switch (e) {
    BridgeError(code: 'MEMORY_LIMIT') => '记忆或权限记录已达到限额。',
    BridgeError(
      code: 'MEMORY_SCOPE_CHANGED' ||
          'MEMORY_VERSION_CHANGED' ||
          'RUN_RECOVERY_REQUIRED',
    ) =>
      '记录、权限或来源已变化，请重新授权并读取当前版本。',
    BridgeError(
      code: 'MEMORY_SOURCE_REQUIRED' ||
          'RUN_SOURCE_UNAVAILABLE' ||
          'HOST_EXECUTION_ENVIRONMENT_UNAVAILABLE',
    ) =>
      '原始来源尚未授权或已变化，请检查验证来源。',
    BridgeError(
      code: 'MEMORY_SESSION_ACCESS_REQUIRED' ||
          'MEMORY_SELECTION_CLOSED' ||
          'MEMORY_FORBIDDEN' ||
          'RUN_FORBIDDEN',
    ) =>
      '本次访问已关闭或权限不足，请重新选择访问权限。',
    BridgeError(code: 'MEMORY_APPROVAL_REQUIRED' || 'TOOL_APPROVAL_REQUIRED') =>
      '预览已失效，请重新预览后确认。',
    _ => '操作未完成，请检查当前记录和访问权限。',
  };
  Future<void> _run(Future<void> Function(int) work) async {
    if (busy || _disposed) return;
    final generation = ++_epoch;
    busy = true;
    error = null;
    notice = null;
    _notify();
    try {
      await work(generation);
    } catch (e) {
      if (_live(generation)) {
        _hide();
        error = _describe(e);
      }
    } finally {
      if (_live(generation)) {
        busy = false;
        _notify();
      }
    }
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

  Future<void> closeAccess() async {
    _epoch++;
    busy = false;
    _hide();
    access = null;
    sourceAccess.clear();
    sourceWorkspaces.clear();
    notice = null;
    _notify();
    final generation = _epoch;
    try {
      await Future.wait(_held.toList().map(_release));
    } catch (e) {
      if (_live(generation)) {
        error = _describe(e);
        _notify();
      }
    }
  }

  Future<void> refresh({bool more = false}) async {
    if (!more) {
      final closing = closeAccess();
      final generation = _epoch;
      await closing;
      if (!_live(generation)) return;
    }
    await _run((n) async {
      final page = await commands.scopes(more ? scopeCursor : null);
      if (!_live(n)) return;
      final combined = {
        for (final s in (more ? scopes : <api.MemoryScopeView>[])) s.scopeId: s,
        for (final s in page.scopes) s.scopeId: s,
      };
      scopes = combined.values.toList()
        ..sort((a, b) => a.scopeId.compareTo(b.scopeId));
      scopeCursor = page.nextCursor;
      if (!scopes.any((v) => v.scopeId == selectedScope)) selectedScope = null;
    });
  }

  Future<void> chooseScope(String? id) async {
    final closing = closeAccess();
    final generation = _epoch;
    await closing;
    if (!_live(generation)) return;
    selectedScope = id;
    memberRows = [];
    memberCursor = null;
    error = null;
    receipt = null;
    _notify();
  }

  Future<void> createScope(String id, bool shared) => _run((n) async {
    final created = await commands.create(id, shared);
    if (!_live(n)) return;
    scopes = [...scopes.where((v) => v.scopeId != created.scopeId), created]
      ..sort((a, b) => a.scopeId.compareTo(b.scopeId));
    notice = '记忆空间已创建，请明确选择访问权限。';
  });
  Future<void> open({required bool write}) async {
    final target = scope;
    if (target == null || !target.enabled) return;
    final closing = closeAccess();
    final generation = _epoch;
    await closing;
    if (!_live(generation) || selectedScope != target.scopeId) return;
    await _run((n) async {
      final token = _token();
      _held.add(token);
      try {
        final value = await commands.authorize(target, token, write);
        if (!_live(n)) {
          _held.add(token);
          await _release(token);
          return;
        }
        if (value.scopeId != target.scopeId ||
            value.revision != target.revision ||
            value.sessionToken != token ||
            value.write != write) {
          throw const FormatException('Selection mismatch');
        }
        access = value;
        await _entries(n, false);
      } catch (_) {
        await _release(token);
        if (_live(n) && access?.sessionToken == token) access = null;
        rethrow;
      }
    });
  }

  Future<void> setSourceWorkspace(String id, bool enabled) async {
    if (busy && enabled) return;
    if (enabled &&
        !sourceWorkspaces.contains(id) &&
        sourceWorkspaces.length >= 17) {
      error = '最多选择17个来源工作区。';
      _notify();
      return;
    }
    invalidateSources();
    if (enabled) {
      sourceWorkspaces.add(id);
    } else {
      sourceWorkspaces.remove(id);
    }
    _notify();
    if (selection != null) await loadEntries();
  }

  Future<void> setSourceMemory(api.MemoryScopeView target, bool enabled) async {
    if ((busy && enabled) || target.scopeId == selectedScope) return;
    if (enabled &&
        !sourceAccess.containsKey(target.scopeId) &&
        sourceAccess.length >= 23) {
      error = '最多选择23个来源记忆空间。';
      _notify();
      return;
    }
    invalidateSources();
    final generation = _epoch;
    if (!enabled) {
      final old = sourceAccess.remove(target.scopeId);
      if (old != null) {
        try {
          await _release(old.sessionToken);
        } catch (e) {
          error = _describe(e);
          _notify();
        }
      }
      if (_live(generation) && selection != null) await loadEntries();
      return;
    }
    await _run((n) async {
      final token = _token();
      _held.add(token);
      try {
        final value = await commands.authorize(target, token, false);
        if (!_live(n)) {
          _held.add(token);
          await _release(token);
          return;
        }
        if (value.scopeId != target.scopeId ||
            value.revision != target.revision ||
            value.sessionToken != token ||
            value.write) {
          throw const FormatException('Source selection mismatch');
        }
        sourceAccess[target.scopeId] = value;
        await _entries(n, false);
      } catch (_) {
        await _release(token);
        if (_live(n) && sourceAccess[target.scopeId]?.sessionToken == token) {
          sourceAccess.remove(target.scopeId);
        }
        rethrow;
      }
    });
  }

  Future<void> _entries(int n, bool more) async {
    final selected = selection;
    if (selected == null) return;
    final page = await commands.entries(
      selected,
      more ? entryCursor : null,
      includeDisabled,
    );
    if (!_live(n)) return;
    if (page.scopeId != selected.scopeId) {
      throw const FormatException('Wrong scope');
    }
    entries = more
        ? [
            ...entries,
            ...page.entries.where(
              (v) => !entries.any((old) => old.entryId == v.entryId),
            ),
          ]
        : page.entries;
    entryCursor = page.nextCursor;
    omitted = page.omittedUnavailable;
    scanLimited = page.scanLimited;
  }

  Future<void> loadEntries({bool more = false}) => _run((n) async {
    if (!more) {
      _hide();
      _notify();
    }
    await _entries(n, more);
  });
  Future<void> showDisabled(bool value) async {
    includeDisabled = value;
    await loadEntries();
  }

  Future<void> readEntry(api.MemorySummary summary) => _run((n) async {
    final selected = selection;
    if (selected == null) return;
    _hide();
    _notify();
    final buffer = StringBuffer();
    api.MemoryEntry? first;
    int start = 0;
    for (int count = 0; count < 16; count++) {
      final part = await commands.read(
        selected,
        summary.entryId,
        summary.version,
        start,
      );
      if (!_live(n)) return;
      if (part.scopeId != selected.scopeId ||
          part.entryId != summary.entryId ||
          part.version != summary.version ||
          part.startByte != start.toString()) {
        throw const FormatException('Entry changed');
      }
      first ??= part;
      if (part.title != first.title ||
          part.totalBytes != first.totalBytes ||
          part.origin != first.origin ||
          part.enabled != first.enabled) {
        throw const FormatException('Entry metadata changed');
      }
      buffer.write(part.content);
      final bytes = utf8.encode(buffer.toString()).length;
      final total = int.tryParse(part.totalBytes);
      if (total == null || total < 0 || total > 32768 || bytes > total) {
        throw const FormatException('Entry bound');
      }
      if (part.nextByte == null) {
        if (bytes != total) throw const FormatException('Partial entry');
        entry = api.MemoryEntry(
          scopeId: part.scopeId,
          entryId: part.entryId,
          version: part.version,
          title: part.title,
          content: buffer.toString(),
          enabled: part.enabled,
          origin: part.origin,
          sourceActor: part.sourceActor,
          sourceRun: part.sourceRun,
          totalBytes: part.totalBytes,
          startByte: '0',
        );
        _targetEntry = part.entryId;
        targetVersion = part.version;
        return;
      }
      final next = int.tryParse(part.nextByte!);
      if (next == null || next <= start || next != bytes || next > total) {
        throw const FormatException('Invalid range');
      }
      start = next;
    }
    throw const FormatException('Too many entry segments');
  });
  void beginNew() {
    if (busy) return;
    _hide();
    notice = null;
    _notify();
  }

  Future<void> prepare({
    required String title,
    required String content,
    required bool enabled,
    bool delete = false,
  }) => _run((n) async {
    final selected = selection;
    if (selected == null || !canWrite) return;
    if (delete && (_targetEntry == null || targetVersion == null)) return;
    final request = _token();
    pendingRequest = request;
    pendingScope = selected.scopeId;
    preview = null;
    receipt = null;
    _notify();
    final edit = api.MemoryEdit(
      requestId: request,
      entryId: _targetEntry ??= 'entry-${_token()}',
      expectedVersion: targetVersion,
      delete: delete,
      title: delete ? null : title,
      content: delete ? null : content,
      enabled: delete ? null : enabled,
    );
    final value = await commands.prepare(selected, edit);
    if (!_live(n)) return;
    if (value.scopeId != selected.scopeId ||
        value.entryId != edit.entryId ||
        value.expectedVersion != edit.expectedVersion ||
        value.delete != delete) {
      throw const FormatException('Review mismatch');
    }
    preview = value;
  });
  api.MemoryReview? editPreview() {
    if (busy || preview == null) return null;
    final value = preview!;
    _targetEntry = value.entryId;
    targetVersion = value.expectedVersion;
    preview = null;
    _notify();
    return value;
  }

  Future<void> approve() => _run((n) async {
    final selected = selection, review = preview;
    if (selected == null || review == null || !canWrite) return;
    preview = null;
    final value = await commands.approve(selected, review);
    if (!_live(n)) return;
    if (value.draftId != review.draftId ||
        value.scopeId != selected.scopeId ||
        value.entryId != review.entryId ||
        value.state != 'approved') {
      throw const FormatException('Unconfirmed outcome');
    }
    _hide();
    receipt = value;
    notice = review.delete ? '删除已确认。' : '保存已确认。';
    await _entries(n, false);
  });
  List<api.MemoryOutcome> drafts = [];
  String? draftAfter;
  Future<void> discoverDrafts({bool more = false}) => _run((n) async {
    final id = selectedScope, directory = commands;
    if (id == null || directory is! MemoryDraftDirectory) return;
    final rows = await (directory as MemoryDraftDirectory).pendingDrafts(
      id,
      more ? draftAfter : null,
    );
    if (!_live(n)) return;
    drafts = more ? [...drafts, ...rows] : rows;
    draftAfter = rows.length == 30 ? rows.last.draftId : null;
    notice = drafts.isEmpty ? '当前空间没有待确认草稿。' : null;
  });
  Future<void> openDraft(api.MemoryOutcome draft) async {
    if (draft.scopeId != selectedScope || !canWrite || busy) return;
    receipt = draft;
    await reviewPending();
  }

  Future<void> discardDraft(api.MemoryOutcome draft) => _run((n) async {
    final directory = commands;
    if (draft.scopeId != selectedScope || directory is! MemoryDraftDirectory) {
      return;
    }
    final result = await (directory as MemoryDraftDirectory).discardDraft(
      draft,
    );
    if (!_live(n)) return;
    if (result.state != 'invalidated' ||
        result.digest != draft.digest ||
        result.draftId != draft.draftId) {
      throw const FormatException('Discard receipt changed');
    }
    _hide();
    receipt = result;
    notice = '草稿已作废。';
  });
  Future<void> inspectPending() => _run((n) async {
    final request = pendingRequest, id = pendingScope;
    if (request == null || id == null) return;
    final value = await commands.outcome(id, request);
    if (!_live(n)) return;
    receipt = value;
    notice = value == null
        ? '尚未找到这次请求的草稿。'
        : value.state == 'approved'
        ? '已确认这次请求提交成功，不会重复执行。'
        : value.state == 'pending'
        ? '草稿仍待确认，恢复访问后可重新审阅。'
        : '草稿已失效。';
  });
  Future<void> reviewPending() => _run((n) async {
    final selected = selection, known = receipt;
    if (selected == null ||
        !canWrite ||
        known == null ||
        known.state != 'pending' ||
        known.scopeId != selected.scopeId) {
      return;
    }
    final value = await commands.review(selected, known.draftId);
    if (!_live(n)) return;
    preview = value;
  });
  Future<void> _members(int n, bool more) async {
    final target = scope;
    if (target == null || !target.canAdminister || !target.shared) return;
    final page = await commands.members(target, more ? memberCursor : null);
    if (!_live(n)) return;
    if (page.scopeId != target.scopeId || page.revision != target.revision) {
      throw const FormatException('Member revision changed');
    }
    memberRows = more
        ? [
            ...memberRows,
            ...page.members.where(
              (v) => !memberRows.any((old) => old.principal == v.principal),
            ),
          ]
        : page.members;
    memberCursor = page.nextCursor;
  }

  Future<void> loadMembers({bool more = false}) =>
      _run((n) => _members(n, more));
  Future<void> setMember(String principal, String permission) async {
    final target = scope;
    if (target == null || !target.canAdminister || !target.shared || busy) {
      return;
    }
    final closing = closeAccess();
    final generation = _epoch;
    await closing;
    if (!_live(generation) || selectedScope != target.scopeId) return;
    await _run((n) async {
      final updated = await commands.member(target, principal, permission);
      if (!_live(n)) return;
      if (updated.scopeId != target.scopeId) {
        throw const FormatException('Wrong scope');
      }
      scopes = [
        for (final v in scopes)
          if (v.scopeId == updated.scopeId) updated else v,
      ];
      memberRows = [];
      memberCursor = null;
      await _members(n, false);
      notice = '成员权限已更新，请重新选择访问权限。';
    });
  }

  Future<void> setEnabled(bool enabled) async {
    final target = scope;
    if (target == null || !target.canAdminister) return;
    final closing = closeAccess();
    final generation = _epoch;
    await closing;
    if (!_live(generation) || selectedScope != target.scopeId) return;
    await _run((n) async {
      final value = await commands.enable(target, enabled);
      if (!_live(n)) return;
      scopes = [
        for (final v in scopes)
          if (v.scopeId == value.scopeId) value else v,
      ];
      notice = enabled ? '空间已启用，请重新选择访问权限。' : '空间已停用。';
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _hide();
    for (final token in _held.toList()) {
      unawaited(
        _release(token).catchError((Object e, StackTrace stack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: e,
              stack: stack,
              library: 'memory access cleanup',
            ),
          );
        }),
      );
    }
    super.dispose();
  }
}
