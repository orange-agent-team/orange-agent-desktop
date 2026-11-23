import 'package:flutter/material.dart';

import 'src/rust/api/account.dart' as api;
import 'src/rust/api/host.dart' show BridgeError;

class PersonalAccountPanel extends StatefulWidget {
  const PersonalAccountPanel({super.key, required this.handle});
  final String handle;
  @override
  State<PersonalAccountPanel> createState() => _PersonalAccountPanelState();
}

class _PersonalAccountPanelState extends State<PersonalAccountPanel>
    with WidgetsBindingObserver {
  final _keyText = TextEditingController();
  final _certificate = TextEditingController();
  final List<String?> _history = [];
  String? _cursor;
  api.PersonalApiEndpoint? _endpoint;
  api.RemoteWalletView? _wallet;
  api.RemoteBudgetPage? _budgets;
  String? _issue;
  String _scope = 'wallet';
  int _generation = 0;
  bool _open = false, _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _keyText.dispose();
    _certificate.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state != AppLifecycleState.resumed) {
      _forget();
    } else if (_open && _endpoint == null) {
      _loadEndpoint();
    }
  }

  @override
  void didUpdateWidget(covariant PersonalAccountPanel old) {
    super.didUpdateWidget(old);
    if (widget.handle != old.handle) {
      _forget();
      _endpoint = null;
      if (_open) _loadEndpoint();
    }
  }

  void _clear() {
    _generation++;
    _wallet = null;
    _budgets = null;
    _issue = null;
    _cursor = null;
    _history.clear();
    _busy = false;
  }

  void _forget() {
    setState(() {
      _clear();
      _keyText.clear();
    });
  }

  Future<void> _loadEndpoint() async {
    final ticket = ++_generation;
    try {
      final endpoint = await api.personalApiEndpoint(handle: widget.handle);
      if (mounted && _open && ticket == _generation) {
        setState(() => _endpoint = endpoint);
      }
    } catch (_) {
      if (mounted && ticket == _generation) {
        setState(() => _issue = '无法核对本应用的服务地址。');
      }
    }
  }

  Future<void> _read({String? cursor, bool previous = false}) async {
    if (!_open || _busy || _endpoint == null || _keyText.text.isEmpty) return;
    final prior = _budgets;
    final priorCursor = _cursor;
    final ticket = ++_generation;
    final pem = _certificate.text.trim();
    setState(() {
      _busy = true;
      _wallet = null;
      _budgets = null;
      _issue = null;
    });
    try {
      if (_scope == 'wallet') {
        final wallet = await api.readPersonalWallet(
          handle: widget.handle,
          credential: _keyText.text,
          localCertificatePem: pem.isEmpty ? null : pem,
        );
        if (mounted && ticket == _generation) setState(() => _wallet = wallet);
      } else {
        final page = await api.readPersonalBudgets(
          handle: widget.handle,
          credential: _keyText.text,
          localCertificatePem: pem.isEmpty ? null : pem,
          after: cursor,
          limit: 25,
        );
        if (!mounted || ticket != _generation) return;
        if (prior != null &&
            (page.ownerId != prior.ownerId || page.userId != prior.userId)) {
          _forget();
          setState(() => _issue = '账户身份已变化，请重新输入密钥。');
          return;
        }
        setState(() {
          if (previous) {
            _history.removeLast();
          } else if (cursor != null) {
            _history.add(priorCursor);
          } else {
            _history.clear();
          }
          _cursor = cursor;
          _budgets = page;
        });
      }
    } catch (e) {
      if (!mounted || ticket != _generation) return;
      final code = e is BridgeError ? e.code : '';
      setState(() {
        _cursor = null;
        _history.clear();
        if (code == 'ACCOUNT_KEY_INACTIVE') _keyText.clear();
        _issue = switch (code) {
          'ACCOUNT_KEY_INACTIVE' => '密钥已失效，请在用户 Web 核对有效期或重新登记。',
          'ACCOUNT_SCOPE_DENIED' => '这把密钥没有所选读取权限。',
          'ACCOUNT_KEY_INVALID' => '密钥格式无效，请重新粘贴完整密钥。',
          'ACCOUNT_CERTIFICATE_INVALID' => '请提供本机开发服务对应的单张公开证书。',
          'ACCOUNT_CONNECTION_FAILED' => '无法建立已验证的服务连接，请核对服务和证书。',
          'ACCOUNT_READ_BUSY' => '已有账户读取正在进行，请稍后再试。',
          'ACCOUNT_RATE_LIMITED' => '请求过于频繁，请稍后再试。',
          _ => '账户读取未确认，请重新核对。',
        };
      });
    } finally {
      if (mounted && ticket == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = _wallet;
    final page = _budgets;
    return Card(
      child: ExpansionTile(
        title: const Text('个人平台账户'),
        onExpansionChanged: (open) {
          _open = open;
          if (open) {
            _loadEndpoint();
          } else {
            _forget();
          }
        },
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_endpoint case final endpoint?) ...[
            Text('服务地址 ${endpoint.origin}'),
            if (endpoint.allowLocalDevelopmentCertificate)
              ExpansionTile(
                title: const Text('本机开发证书'),
                children: [
                  TextField(
                    key: const ValueKey('personal-account-ca'),
                    controller: _certificate,
                    maxLength: 16384,
                    maxLines: 3,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '公开 TLS 证书（PEM）',
                    ),
                    onChanged: (_) => _forget(),
                  ),
                ],
              ),
            TextField(
              key: const ValueKey('personal-account-key'),
              controller: _keyText,
              maxLength: 105,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: const InputDecoration(labelText: '个人只读密钥'),
              onChanged: (_) => setState(_clear),
            ),
            DropdownButton<String>(
              key: const ValueKey('personal-account-scope'),
              value: _scope,
              items: const [
                DropdownMenuItem(value: 'wallet', child: Text('个人钱包')),
                DropdownMenuItem(value: 'budgets', child: Text('个人预算')),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    _clear();
                    _scope = v;
                  });
                }
              },
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: _keyText.text.isEmpty || _busy
                      ? null
                      : () => _read(),
                  child: Text(_busy ? '读取中…' : '读取账户'),
                ),
                TextButton(
                  onPressed: _keyText.text.isEmpty ? null : _forget,
                  child: const Text('清除密钥和结果'),
                ),
              ],
            ),
          ] else if (_issue == null)
            const LinearProgressIndicator(),
          if (_issue case final message?) Text(message),
          if (w != null) ...[
            SelectableText('个人账户 ${w.ownerId}'),
            Text('可用（微积分）　赠送 ${w.gift} · 收益 ${w.earned} · 购买 ${w.purchased}'),
            Text(
              '预留（微积分）　赠送 ${w.reservedGift} · 收益 ${w.reservedEarned} · 购买 ${w.reservedPurchased}',
            ),
            Text('待确认收益　${w.pendingEarned} 微积分'),
          ],
          if (page != null) ...[
            SelectableText('个人账户 ${page.ownerId}'),
            if (page.data.isEmpty) const Text('当前页没有预算'),
            for (final item in page.data)
              ListTile(
                title: Text(item.scopeId),
                subtitle: Text(
                  '上限 ${item.limit} · 已用 ${item.spent} · 预留 ${item.reserved}（微积分）',
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                if (_history.isNotEmpty)
                  TextButton(
                    onPressed: () =>
                        _read(cursor: _history.last, previous: true),
                    child: const Text('上一页预算'),
                  ),
                if (page.nextCursor != null)
                  TextButton(
                    onPressed: () => _read(cursor: page.nextCursor),
                    child: const Text('下一页预算'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
