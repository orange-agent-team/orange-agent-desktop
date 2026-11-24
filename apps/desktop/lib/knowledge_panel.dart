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
  String? _workspace;
  api.KnowledgeSelection? _selection;
  api.KnowledgePage? _page;
  api.KnowledgePassage? _passage;
  String? _error;
  bool _busy = false;
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
      });
    }
  }

  @override
  void didUpdateWidget(KnowledgePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) {
      setState(() {
        _forget(widget.handle);
        _workspace = null;
        _files.clear();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _forget(widget.handle);
    _files.dispose();
    _query.dispose();
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
      await api.openKnowledgeCollection(
        handle: host,
        selection: selection,
        relativeFiles: files,
      );
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

  @override
  Widget build(BuildContext context) {
    final page = _page, passage = _passage;
    return Card(
      child: ExpansionTile(
        title: const Text('本地文档检索'),
        onExpansionChanged: (open) {
          if (!open) {
            setState(() {
              _forget(widget.handle);
            });
          }
        },
        childrenPadding: const EdgeInsets.all(16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
