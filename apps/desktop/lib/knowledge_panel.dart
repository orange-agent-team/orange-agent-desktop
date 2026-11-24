import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'src/rust/api/host.dart' show BridgeError, WorkspaceView;
import 'src/rust/api/knowledge.dart' as api;

/// A collection lives only while the host holds this workspace's current OS grant.
class KnowledgePanel extends StatefulWidget {
  const KnowledgePanel({
    super.key,
    required this.handle,
    required this.workspaces,
  });
  final String handle;
  final List<WorkspaceView> workspaces;
  @override
  State<KnowledgePanel> createState() => KnowledgePanelState();
}

class KnowledgePanelState extends State<KnowledgePanel>
    with WidgetsBindingObserver {
  final _files = TextEditingController();
  final _query = TextEditingController();
  final _name = TextEditingController();
  bool _save = false;
  bool _confirmRetirement = false;
  List<String> _savedNames = [];
  String? _notice;

  void _clearSavedControls() {
    _save = false;
    _name.clear();
    _savedNames = [];
    _notice = null;
  }

  String? _workspace;
  api.KnowledgeSelection? _selection;
  api.KnowledgePage? _page;
  api.KnowledgePassage? _passage;
  String? _error;
  bool _busy = false;
  bool _cleanupPending = false;
  int _cleanupTicket = 0;
  int _generation = 0;
  Timer? _timer;
  List<WorkspaceView> get _available => widget.workspaces
      .where(
        (w) => w.permissionActive && w.sessionAccess && w.sessionToken != null,
      )
      .toList();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  static Future<void> _release(
    String handle,
    api.KnowledgeSelection selection,
  ) async {
    try {
      await api.closeKnowledgeCollection(handle: handle, selection: selection);
    } on BridgeError catch (e) {
      if (e.code != 'STALE_HOST_HANDLE') {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: e,
            library: 'knowledge collection cleanup',
          ),
        );
      }
    }
  }

  void _clearResults() {
    _generation++;
    _busy = false;
    _error = null;
    _notice = null;
    _confirmRetirement = false;
    _page = null;
    _passage = null;
    _timer?.cancel();
    _timer = null;
  }

  void _forget(String handle) {
    final old = _selection;
    _selection = null;
    _clearResults();
    _query.clear();
    if (old != null) unawaited(_release(handle, old));
  }

  void workspaceStopping(String id) {
    if (mounted && _workspace == id) {
      setState(() {
        _forget(widget.handle);
        _workspace = null;
        _files.clear();
        _clearSavedControls();
      });
    }
  }

  @override
  void didUpdateWidget(KnowledgePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final activeIds = widget.workspaces
        .where((w) => w.permissionActive)
        .map((w) => w.workspaceId)
        .toSet();
    if (oldWidget.handle != widget.handle ||
        oldWidget.workspaces.any(
          (w) => w.permissionActive && !activeIds.contains(w.workspaceId),
        )) {
      unawaited(_reconcileCleanup());
    }
    final current = _selection;
    if (oldWidget.handle != widget.handle ||
        _workspace != null &&
            !_available.any(
              (w) =>
                  w.workspaceId == _workspace &&
                  (current == null || current.sessionToken == w.sessionToken),
            )) {
      _forget(oldWidget.handle);
      _workspace = null;
      _files.clear();
      _clearSavedControls();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) {
      setState(() {
        _forget(widget.handle);
        _workspace = null;
        _files.clear();
        _clearSavedControls();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _forget(widget.handle);
    _files.dispose();
    _query.dispose();
    _name.dispose();
    super.dispose();
  }

  String _message(Object error) {
    final code = error is BridgeError ? error.code : 'KNOWLEDGE_UNAVAILABLE';
    return switch (code) {
      'KNOWLEDGE_CITATION_STALE' => '来源已变化，请重新检索。',
      'KNOWLEDGE_ACCESS_DENIED' ||
      'KNOWLEDGE_COLLECTION_CLOSED' ||
      'STALE_HOST_HANDLE' => '工作区授权已失效，请重新选择。',
      'KNOWLEDGE_REQUEST_INVALID' => '请核对已选文件的相对路径和查询条件。',
      'KNOWLEDGE_NAME_RETIRED' => '此名称已撤销，请使用新名称。',
      'KNOWLEDGE_COLLECTION_BUSY' => '集合仍在使用。请关闭后重试。',
      'KNOWLEDGE_LIMIT' => '已达到单次检索上限。',
      _ => '暂时无法核对来源，请重试。',
    };
  }

  void _failed(Object error) {
    if (error is BridgeError &&
        [
          'KNOWLEDGE_ACCESS_DENIED',
          'KNOWLEDGE_COLLECTION_CLOSED',
          'STALE_HOST_HANDLE',
        ].contains(error.code)) {
      _forget(widget.handle);
      _workspace = null;
      _files.clear();
      _clearSavedControls();
    } else {
      _page = null;
      _passage = null;
      _timer?.cancel();
      _timer = null;
    }
    _error = _message(error);
  }

  Future<void> _open() async {
    if (_busy || _selection != null) return;
    final row = _available
        .where((w) => w.workspaceId == _workspace)
        .firstOrNull;
    if (row == null) return;
    final files = _files.text
        .split('\n')
        .map((s) => s.endsWith('\r') ? s.substring(0, s.length - 1) : s)
        .where((s) => s.isNotEmpty)
        .toList();
    if (files.isEmpty ||
        files.length > 32 ||
        files.toSet().length != files.length) {
      setState(() => _error = '请选择 1 至 32 个不同的相对文件路径。');
      return;
    }
    final name = _name.text.trim();
    if (_save && !RegExp(r'^[A-Za-z0-9_.:-]{1,128}$').hasMatch(name)) {
      setState(() => _error = '集合名称可用字母、数字和 _.:-，最长 128 个字符。');
      return;
    }
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final selection = api.KnowledgeSelection(
      workspaceId: row.workspaceId,
      sessionToken: row.sessionToken!,
      collectionId: id,
    );
    final host = widget.handle;
    final ticket = ++_generation;
    setState(() {
      _selection = selection;
      _error = null;
      _busy = true;
    });
    try {
      if (_save) {
        await api.openSavedKnowledgeCollection(
          handle: host,
          selection: selection,
          relativeFiles: files,
          name: name,
        );
      } else {
        await api.openKnowledgeCollection(
          handle: host,
          selection: selection,
          relativeFiles: files,
        );
      }
      if (!mounted || ticket != _generation) await _release(host, selection);
    } catch (e) {
      if (mounted && ticket == _generation) {
        setState(() {
          _selection = null;
          _error = _message(e);
        });
      }
      await _release(host, selection);
    } finally {
      if (mounted && ticket == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _search() async {
    final s = _selection;
    if (s == null || _busy || _query.text.trim().isEmpty) return;
    setState(() {
      _clearResults();
      _busy = true;
    });
    final ticket = _generation;
    try {
      final rows = await api.searchSelectedKnowledge(
        handle: widget.handle,
        selection: s,
        query: _query.text,
        limit: 12,
      );
      if (mounted && ticket == _generation) setState(() => _page = rows);
    } catch (e) {
      if (mounted && ticket == _generation) setState(() => _failed(e));
    } finally {
      if (mounted && ticket == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _read(api.KnowledgeHit hit, {bool refresh = false}) async {
    final s = _selection;
    if (s == null || _busy) return;
    _timer?.cancel();
    _timer = null;
    final ticket = ++_generation;
    if (!refresh) {
      setState(() {
        _passage = null;
        _error = null;
        _busy = true;
      });
    }
    try {
      final excerpt = await api.readKnowledgeCitation(
        handle: widget.handle,
        selection: s,
        hitId: hit.hitId,
        expectedSha256: hit.sourceSha256,
      );
      if (!mounted || ticket != _generation) return;
      if (excerpt.citation.hitId != hit.hitId ||
          excerpt.citation.path != hit.path ||
          excerpt.citation.sourceSha256 != hit.sourceSha256) {
        throw StateError('source changed');
      }
      if (!refresh) setState(() => _passage = excerpt);
      _timer = Timer(
        const Duration(seconds: 2),
        () => unawaited(_read(hit, refresh: true)),
      );
    } catch (e) {
      if (mounted && ticket == _generation) setState(() => _failed(e));
    } finally {
      if (!refresh && mounted && ticket == _generation) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _checkCleanup() async {
    final ticket = ++_cleanupTicket;
    try {
      final pending = await api.savedKnowledgeCleanupPending(
        handle: widget.handle,
      );
      if (mounted && ticket == _cleanupTicket && pending != _cleanupPending) {
        setState(() => _cleanupPending = pending);
      }
    } on BridgeError catch (e) {
      if (mounted &&
          ticket == _cleanupTicket &&
          e.code != 'STALE_HOST_HANDLE') {
        setState(() => _cleanupPending = true);
      }
    }
  }

  Future<void> _reconcileCleanup() async {
    final ticket = ++_cleanupTicket;
    try {
      await api.reconcileSavedKnowledgeCleanup(handle: widget.handle);
      if (mounted && ticket == _cleanupTicket && _cleanupPending) {
        setState(() => _cleanupPending = false);
      }
    } on BridgeError catch (e) {
      if (e.code != 'STALE_HOST_HANDLE' &&
          mounted &&
          ticket == _cleanupTicket) {
        setState(() => _cleanupPending = true);
      }
    }
  }

  Future<void> _showSaved() async {
    final row = _available
        .where((w) => w.workspaceId == _workspace)
        .firstOrNull;
    if (row == null || _busy) return;
    final ticket = ++_generation;
    setState(() {
      _error = null;
      _notice = null;
      _busy = true;
    });
    try {
      final names = await api.listSavedKnowledgeCollections(
        handle: widget.handle,
        workspaceId: row.workspaceId,
        sessionToken: row.sessionToken!,
      );
      if (mounted && ticket == _generation) {
        setState(() {
          _savedNames = names;
          if (names.isEmpty) _notice = '此工作区没有已保存的集合。';
        });
      }
    } catch (e) {
      if (mounted && ticket == _generation) setState(() => _failed(e));
    } finally {
      if (mounted && ticket == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _retireSaved() async {
    final row = _available
        .where((w) => w.workspaceId == _workspace)
        .firstOrNull;
    final name = _name.text.trim();
    if (row == null || _busy || !_confirmRetirement || name.isEmpty) return;
    final host = widget.handle;
    final ticket = ++_generation;
    setState(() {
      _error = null;
      _notice = null;
      _busy = true;
    });
    try {
      await api.retireSavedKnowledgeCollection(
        handle: host,
        workspaceId: row.workspaceId,
        sessionToken: row.sessionToken!,
        name: name,
      );
      if (mounted && ticket == _generation) {
        setState(() {
          _forget(host);
          _savedNames = _savedNames.where((item) => item != name).toList();
          _name.clear();
          _notice = '已撤销集合「$name」。';
        });
      }
    } catch (e) {
      if (mounted && ticket == _generation) setState(() => _failed(e));
    } finally {
      if (mounted && ticket == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page, passage = _passage;
    return Card(
      child: ExpansionTile(
        title: const Text('本地文档检索'),
        onExpansionChanged: (open) {
          if (open) unawaited(_checkCleanup());
          if (!open) {
            setState(() {
              _forget(widget.handle);
            });
          }
        },
        childrenPadding: const EdgeInsets.all(16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_cleanupPending) ...[
            const Text('已撤销的集合仍有本机索引等待清理。'),
            TextButton(onPressed: _reconcileCleanup, child: const Text('重试清理')),
          ],
          if (_available.isEmpty)
            const Text('先在工作区面板授权一个本地目录。')
          else ...[
            DropdownButtonFormField<String>(
              key: ValueKey(_workspace),
              initialValue: _workspace,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '检索工作区'),
              selectedItemBuilder: (context) => _available
                  .map(
                    (w) => Text(w.displayPath, overflow: TextOverflow.ellipsis),
                  )
                  .toList(),
              items: _available
                  .map(
                    (w) => DropdownMenuItem(
                      value: w.workspaceId,
                      child: Text(
                        w.displayPath,
                        key: ValueKey('knowledge-option-${w.workspaceId}'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() {
                _forget(widget.handle);
                _files.clear();
                _clearSavedControls();
                _workspace = value;
              }),
            ),
            TextField(
              key: const ValueKey('knowledge-files'),
              controller: _files,
              readOnly: _selection != null,
              minLines: 1,
              maxLines: 4,
              maxLength: 8192,
              decoration: const InputDecoration(
                labelText: '授权文档',
                hintText: '每行一个工作区内的相对路径',
              ),
            ),
            if (_workspace != null) ...[
              CheckboxListTile(
                title: const Text('在本机保存索引'),
                value: _save,
                onChanged: _selection != null || _busy
                    ? null
                    : (v) => setState(() {
                        _clearResults();
                        _save = v ?? false;
                        _savedNames = [];
                        _name.clear();
                      }),
              ),
              if (_save) ...[
                TextField(
                  key: const ValueKey('knowledge-saved-name'),
                  controller: _name,
                  readOnly: _busy || _selection != null,
                  maxLength: 128,
                  decoration: const InputDecoration(
                    labelText: '集合名称',
                    helperText: '重新打开时，选择同一工作区并填写原文件清单。',
                  ),
                  onChanged: (_) => setState(() {
                    _error = null;
                    _notice = null;
                    _confirmRetirement = false;
                  }),
                ),
                if (_selection == null)
                  TextButton(
                    onPressed: _busy ? null : _showSaved,
                    child: const Text('查看已保存的集合'),
                  ),
                if (_selection == null && _savedNames.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final name in _savedNames)
                        ActionChip(
                          label: Text(name),
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _name.text = name;
                                  _notice = null;
                                  _error = null;
                                  _confirmRetirement = false;
                                }),
                        ),
                    ],
                  ),
                if (_name.text.trim().isNotEmpty && !_confirmRetirement)
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _confirmRetirement = true),
                    child: const Text('撤销已保存的集合'),
                  ),
                if (_confirmRetirement) ...[
                  Text('撤销「${_name.text.trim()}」会清除本机索引，使已有引用失效。'),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _confirmRetirement = false),
                        child: const Text('取消撤销'),
                      ),
                      FilledButton(
                        onPressed: _busy ? null : _retireSaved,
                        child: const Text('确认撤销集合'),
                      ),
                    ],
                  ),
                ],
              ],
            ],
            if (_selection == null)
              FilledButton(
                onPressed: _workspace == null || _busy ? null : _open,
                child: const Text('启用所选文档'),
              )
            else ...[
              OutlinedButton(
                onPressed: () => setState(() {
                  _forget(widget.handle);
                }),
                child: const Text('关闭文档集合'),
              ),
              TextField(
                key: const ValueKey('knowledge-query'),
                controller: _query,
                maxLength: 256,
                decoration: const InputDecoration(labelText: '查找内容'),
                enabled: !_busy,
                onChanged: (_) => setState(_clearResults),
                onSubmitted: (_) => unawaited(_search()),
              ),
              FilledButton(
                onPressed: _busy || _query.text.trim().isEmpty ? null : _search,
                child: const Text('检索所选文档'),
              ),
            ],
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_notice != null) Text(_notice!),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (page != null) ...[
            if (page.unavailableSources > 0)
              Text('本次有 ${page.unavailableSources} 个所选来源无法索引。'),
            if (page.hits.isEmpty) const Text('没有匹配的片段。'),
            for (final hit in page.hits)
              ListTile(
                title: Text(hit.path),
                subtitle: Text('字节 ${hit.startByte}–${hit.endByte}'),
                onTap: _busy ? null : () => unawaited(_read(hit)),
              ),
            if (page.truncated) const Text('已显示前 12 个匹配片段，请缩小查询范围。'),
          ],
          if (passage != null) ...[
            Text('来源 ${passage.citation.path}'),
            SelectableText('SHA-256 ${passage.citation.sourceSha256}'),
            SelectableText(passage.text),
          ],
        ],
      ),
    );
  }
}
