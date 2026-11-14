import 'dart:math';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'src/rust/api/host.dart' as api;

/// UI scheduling only. Authorization, approval, limits, effects and recovery
/// remain in Rust. Implementations used by tests live only under test/.
abstract interface class AgentCommands {
  Future<api.ModelConnectionView> connect(String directory);
  Future<void> disconnect();
  Future<api.AgentRunView> start(
    String workspace,
    String id,
    String prompt, {
    bool allowQuestions = false,
    api.CreationAccessView? creation,
  });
  Future<api.AgentRunView> inspect(String id);
  Future<api.AgentRunView> approve(
    String id,
    String operation,
    String digest, {
    bool create = false,
  });
  Future<api.AgentRunView> answer(
    String id,
    String question,
    String digest,
    List<String> answers,
  );
  Future<api.AgentRunView> advance(String id, String revision);
  Future<api.AgentRunView> cancel(String id);
}

abstract interface class EditingAgentCommands {
  Future<api.AgentRunView> startEditing(
    String workspace,
    String id,
    String prompt, {
    required api.EditingAccessView editing,
    api.CreationAccessView? creation,
    bool allowQuestions = false,
  });
  Future<api.EditPreviewView> previewEditing(String run, String operation);
  Future<api.AgentRunView> approveEditing(
    String run,
    String operation,
    String previewDigest,
  );
}

class NativeAgentCommands implements AgentCommands, EditingAgentCommands {
  NativeAgentCommands(this.handle);
  final String handle;
  @override
  Future<api.AgentRunView> startEditing(
    String workspace,
    String id,
    String prompt, {
    required api.EditingAccessView editing,
    api.CreationAccessView? creation,
    bool allowQuestions = false,
  }) => api.startEditingRun(
    handle: handle,
    workspaceId: workspace,
    requestId: id,
    prompt: prompt,
    editing: api.RunPermissionSelection(
      consentId: editing.consentId,
      permissionVersion: editing.permissionVersion,
    ),
    creation: creation == null
        ? null
        : api.RunPermissionSelection(
            consentId: creation.consentId,
            permissionVersion: creation.permissionVersion,
          ),
    userQuestions: allowQuestions,
  );
  @override
  Future<api.EditPreviewView> previewEditing(String run, String operation) =>
      api.previewEditingTool(
        handle: handle,
        runId: run,
        operationId: operation,
      );
  @override
  Future<api.AgentRunView> approveEditing(
    String run,
    String operation,
    String previewDigest,
  ) => api.approveEditingTool(
    handle: handle,
    runId: run,
    operationId: operation,
    previewDigest: previewDigest,
  );
  @override
  Future<api.ModelConnectionView> connect(String directory) =>
      api.connectLocalModel(handle: handle, selectedDirectory: directory);
  @override
  Future<void> disconnect() => api.disconnectLocalModel(handle: handle);
  @override
  Future<api.AgentRunView> start(
    String workspace,
    String id,
    String prompt, {
    bool allowQuestions = false,
    api.CreationAccessView? creation,
  }) => creation != null
      ? api.startCreationRun(
          handle: handle,
          workspaceId: workspace,
          requestId: id,
          prompt: prompt,
          consentId: creation.consentId,
          permissionVersion: creation.permissionVersion,
          userQuestions: allowQuestions,
        )
      : allowQuestions
      ? api.startInteractiveRun(
          handle: handle,
          workspaceId: workspace,
          requestId: id,
          prompt: prompt,
        )
      : api.startRun(
          handle: handle,
          workspaceId: workspace,
          requestId: id,
          prompt: prompt,
        );
  @override
  Future<api.AgentRunView> inspect(String id) =>
      api.inspectRun(handle: handle, runId: id);
  @override
  Future<api.AgentRunView> approve(
    String id,
    String operation,
    String digest, {
    bool create = false,
  }) => create
      ? api.approveCreationTool(
          handle: handle,
          runId: id,
          operationId: operation,
          expectedDigest: digest,
        )
      : api.approveTool(
          handle: handle,
          runId: id,
          operationId: operation,
          expectedDigest: digest,
        );
  @override
  Future<api.AgentRunView> answer(
    String id,
    String question,
    String digest,
    List<String> answers,
  ) => api.answerUserQuestion(
    handle: handle,
    runId: id,
    questionId: question,
    expectedDigest: digest,
    answers: answers,
  );
  @override
  Future<api.AgentRunView> advance(String id, String revision) =>
      api.advanceRun(handle: handle, runId: id, expectedRevision: revision);
  @override
  Future<api.AgentRunView> cancel(String id) =>
      api.cancelRun(handle: handle, runId: id);
}

const supportedReadTools = <String, String>{
  'read_file': '读取文件',
  'list_directory': '列出目录',
  'search_files': '搜索文件',
  'search_text': '搜索文本',
};

String toolDisplayName(String name) => name == 'apply_patch'
    ? '修改现有文件'
    : name == 'write_file'
    ? '新建文件'
    : supportedReadTools[name] ?? name;

({String path, String content})? parseCreationPreview(String arguments) {
  try {
    final value = jsonDecode(arguments);
    if (value is! Map<String, dynamic> ||
        value.length != 2 ||
        value['path'] is! String ||
        value['content'] is! String) {
      return null;
    }
    final path = value['path'] as String, content = value['content'] as String;
    if (path.isEmpty ||
        utf8.encode(path).length > 4096 ||
        utf8.encode(content).length > 65536 ||
        content.contains('\u0000')) {
      return null;
    }
    return (path: path, content: content);
  } catch (_) {
    return null;
  }
}

class AgentController extends ChangeNotifier {
  AgentController(this.commands, {required this.serviceDirectory});
  final AgentCommands commands;
  final Future<String> Function() serviceDirectory;
  api.ModelConnectionView? model;
  api.AgentRunView? view;
  api.EditPreviewView? editPreview;
  String? runId, workspaceId, error, notice;
  bool busy = false, connecting = false, cancelling = false;
  bool _alive = true;
  int _epoch = 0;
  ({
    String workspace,
    String id,
    String prompt,
    bool allowQuestions,
    api.CreationAccessView? creation,
    api.EditingAccessView? editing,
  })?
  _submission;
  bool get startUnconfirmed => _submission != null;
  bool get active =>
      runId != null &&
      (view == null ||
          !{
            'completed',
            'cancelled',
            'limited',
            'failed',
            'recovery_required',
          }.contains(view!.phase));
  bool get canAdvance =>
      view != null &&
      view!.pending.isEmpty &&
      {'ready', 'tools_pending'}.contains(view!.phase);
  bool get matchingModel => view == null || view!.modelId == model?.modelId;
  bool get supportedPreview =>
      view != null &&
      view!.pending.isNotEmpty &&
      (editPreviewMatches ||
          supportedReadTools.containsKey(view!.pending.first.toolName) ||
          (view!.pending.first.toolName == 'write_file' &&
              view!.creationConsentId != null &&
              parseCreationPreview(view!.pending.first.argumentsJson) != null));
  bool get editPreviewMatches =>
      view?.editingConsentId != null &&
      editPreview != null &&
      view!.phase == 'tools_pending' &&
      view!.pending.firstOrNull?.toolName == 'apply_patch' &&
      editPreview!.runId == view!.runId &&
      editPreview!.operationId == view!.pending.first.operationId &&
      editPreview!.argumentDigest == view!.pending.first.argumentDigest;
  String get approvalLabel =>
      view?.pending.firstOrNull?.toolName == 'apply_patch'
      ? '批准这次精确修改'
      : view?.pending.firstOrNull?.toolName == 'write_file'
      ? '批准新建这个文件'
      : view != null &&
            view!.pending.isNotEmpty &&
            {
              'search_files',
              'search_text',
            }.contains(view!.pending.first.toolName)
      ? '批准这一次搜索'
      : '批准这一次读取';
  void creationStopping(String consentId) {
    if (view?.creationConsentId == consentId ||
        _submission?.creation?.consentId == consentId) {
      hideContent(stoppingWorkspace: workspaceId);
    }
  }

  void editingStopping(String consentId) {
    if (view?.editingConsentId == consentId ||
        _submission?.editing?.consentId == consentId) {
      hideContent(stoppingWorkspace: workspaceId);
    }
  }

  Future<void> previewFirstEdit() async {
    final current = view;
    final op = current?.pending.firstOrNull;
    final editing = commands;
    if (busy ||
        cancelling ||
        current == null ||
        current.editingConsentId == null ||
        op?.toolName != 'apply_patch' ||
        editing is! EditingAgentCommands) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    error = null;
    editPreview = null;
    _changed();
    try {
      final result = await (editing as EditingAgentCommands).previewEditing(
        current.runId,
        op!.operationId,
      );
      if (!_current(epoch)) return;
      if (result.runId != current.runId ||
          result.operationId != op.operationId ||
          result.argumentDigest != op.argumentDigest) {
        throw const FormatException('Preview identity mismatch');
      }
      editPreview = result;
    } catch (failure) {
      if (_current(epoch)) _failed(failure);
    } finally {
      if (_current(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  bool _current(int epoch) => _alive && epoch == _epoch;
  void _changed() {
    if (!editPreviewMatches) editPreview = null;
    if (_alive) notifyListeners();
  }

  void _failed(Object failure) {
    view = null;
    error = describeAgentError(failure);
    notice = null;
  }

  Future<void> connect() async {
    if (connecting || busy || cancelling) return;
    final epoch = _epoch;
    connecting = true;
    error = null;
    model = null;
    _changed();
    try {
      final result = await commands.connect(await serviceDirectory());
      if (_current(epoch)) model = result;
    } catch (failure) {
      if (_current(epoch)) _failed(failure);
    } finally {
      if (_current(epoch)) {
        connecting = false;
        _changed();
      }
    }
  }

  Future<void> start(
    String workspace,
    String prompt, {
    bool allowQuestions = false,
    api.CreationAccessView? creation,
    api.EditingAccessView? editing,
  }) async {
    if (busy ||
        cancelling ||
        active ||
        model == null ||
        prompt.trim().isEmpty) {
      return;
    }
    final random = Random.secure();
    final id =
        'run-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    _submission = (
      workspace: workspace,
      id: id,
      prompt: prompt,
      allowQuestions: allowQuestions,
      creation: creation,
      editing: editing,
    );
    workspaceId = workspace;
    runId = id;
    await retryStart();
  }

  Future<void> retryStart() async {
    final submission = _submission;
    if (submission == null || busy || cancelling) return;
    final epoch = ++_epoch;
    busy = true;
    view = null;
    error = null;
    notice = null;
    _changed();
    try {
      final api.AgentRunView created;
      if (submission.editing != null) {
        final editing = commands;
        if (editing is! EditingAgentCommands) {
          throw UnsupportedError('Editing transport unavailable');
        }
        created = await (editing as EditingAgentCommands).startEditing(
          submission.workspace,
          submission.id,
          submission.prompt,
          editing: submission.editing!,
          creation: submission.creation,
          allowQuestions: submission.allowQuestions,
        );
      } else {
        created = await commands.start(
          submission.workspace,
          submission.id,
          submission.prompt,
          creation: submission.creation,
          allowQuestions: submission.allowQuestions,
        );
      }
      if (!_current(epoch)) return;
      _submission = null;
      view = created;
      _changed();
      await _pump(epoch);
    } catch (failure) {
      if (_current(epoch)) _failed(failure);
    } finally {
      if (_current(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> _pump(int epoch) async {
    // The UI stops at every intent. Rust enforces limits and controls effects.
    for (var count = 0; count < 64 && _current(epoch) && canAdvance; count++) {
      final current = view!;
      final result = await commands.advance(current.runId, current.revision);
      if (!_current(epoch)) return;
      view = result;
      _changed();
    }
    if (_current(epoch) && canAdvance) notice = '已暂停自动推进，可检查状态后继续。';
  }

  Future<void> continueRun() async {
    if (busy || cancelling || model == null || !matchingModel || !canAdvance) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    error = null;
    notice = null;
    _changed();
    try {
      await _pump(epoch);
    } catch (failure) {
      if (_current(epoch)) _failed(failure);
    } finally {
      if (_current(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> answerQuestion(List<String> answers) async {
    final current = view;
    final question = current?.userQuestion;
    if (busy ||
        cancelling ||
        current == null ||
        question == null ||
        current.phase != 'awaiting_user' ||
        answers.length != question.questions.length ||
        answers.any(
          (a) =>
              a.trim().isEmpty ||
              a.contains('\u0000') ||
              utf8.encode(a).length > 4096,
        )) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    error = null;
    notice = null;
    _changed();
    try {
      final answered = await commands.answer(
        current.runId,
        question.questionId,
        question.argumentDigest,
        List<String>.of(answers),
      );
      if (!_current(epoch)) return;
      view = answered;
      _changed();
      if (model != null && matchingModel) await _pump(epoch);
    } catch (failure) {
      if (_current(epoch)) _failed(failure);
    } finally {
      if (_current(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> approveFirst() async {
    if (busy ||
        cancelling ||
        model == null ||
        !matchingModel ||
        view == null ||
        view!.pending.isEmpty ||
        !supportedPreview) {
      return;
    }
    final current = view!;
    final preview = current.pending.first;
    final epoch = ++_epoch;
    busy = true;
    error = null;
    notice = null;
    _changed();
    try {
      final api.AgentRunView approved;
      if (preview.toolName == 'apply_patch') {
        final editing = commands;
        final exact = editPreview;
        if (editing is! EditingAgentCommands || exact == null) {
          throw StateError('Actual edit preview required');
        }
        approved = await (editing as EditingAgentCommands).approveEditing(
          current.runId,
          preview.operationId,
          exact.previewDigest,
        );
      } else {
        approved = await commands.approve(
          current.runId,
          preview.operationId,
          preview.argumentDigest,
          create: preview.toolName == 'write_file',
        );
      }
      if (!_current(epoch)) return;
      // One explicit approval permits one requested transition, never a batch
      // approval of future model intents. The backend may reject expired rights.
      final result = await commands.advance(approved.runId, approved.revision);
      if (!_current(epoch)) return;
      view = result;
      _changed();
      await _pump(epoch);
    } catch (failure) {
      if (_current(epoch)) _failed(failure);
    } finally {
      if (_current(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> load(
    String id, {
    bool reopen = false,
    String? expectedWorkspace,
  }) async {
    if (busy || cancelling || (reopen && active && id != runId)) return;
    final epoch = ++_epoch;
    runId = id;
    workspaceId = expectedWorkspace ?? workspaceId;
    view = null;
    busy = true;
    error = null;
    notice = null;
    _changed();
    try {
      final result = await commands.inspect(id);
      if (!_current(epoch)) return;
      view = result;
      workspaceId = result.workspaceId;
      _submission = null;
    } catch (failure) {
      if (_current(epoch)) _failed(failure);
    } finally {
      if (_current(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> cancel() async {
    final id = runId;
    if (id == null || cancelling) return;
    final epoch = ++_epoch;
    view = null;
    busy = false;
    cancelling = true;
    error = null;
    notice = '正在请求停止…';
    _changed();
    try {
      final result = await commands.cancel(id);
      if (!_current(epoch)) return;
      view = result;
      _submission = null;
      notice = '停止请求已确认。';
    } catch (failure) {
      if (_current(epoch)) {
        _failed(failure);
        notice = '停止尚未确认，请核对状态或重试停止。';
      }
    } finally {
      if (_current(epoch)) {
        cancelling = false;
        _changed();
      }
    }
  }

  void hideContent({String? stoppingWorkspace}) {
    if (runId == null) return;
    if (stoppingWorkspace != null &&
        workspaceId != stoppingWorkspace &&
        !busy) {
      return;
    }
    _epoch++;
    view = null;
    busy = false;
    connecting = false;
    cancelling = false;
    notice = '内容已隐藏，重新查看时会再次验证访问权限。';
    error = null;
    _changed();
  }

  void clearModel() {
    model = null;
    if (runId == null) {
      _changed();
    } else {
      hideContent();
    }
  }

  @override
  void dispose() {
    _alive = false;
    _epoch++;
    // Workspace scope ownership cancels in-flight work before native access is
    // released. This controller never releases native scopes by itself.
    super.dispose();
  }
}

String describeAgentError(Object error) {
  if (error is! api.BridgeError) return '操作结果尚未确认，请核对状态后重试。';
  return switch (error.code) {
    'MODEL_NOT_CONFIGURED' ||
    'MODEL_SERVICE_UNAVAILABLE' => '没有可用的本地模型，请先连接模型服务。',
    'INVALID_MODEL_SERVICE' ||
    'PRIVATE_MODEL_SERVICE_REQUIRED' ||
    'MODEL_SERVICE_OUTSIDE_HOST_STORAGE' => '模型服务配置未通过验证，无法连接。',
    'MODEL_CONTEXT_CHANGED' => '该会话使用的模型版本与当前模型不一致。',
    'WORKSPACE_SESSION_ACCESS_REQUIRED' ||
    'WORKSPACE_REVOKED' => '工作区访问已停止，请重新选择目录。',
    'WORKSPACE_RECOVERY_REQUIRED' ||
    'RUN_RECOVERY_REQUIRED' => '存在未确认的执行结果，已停止自动重试，需要处理恢复记录。',
    'RUN_SOURCE_UNAVAILABLE' => '来源文件已改变或不可访问，结果内容已隐藏。',
    'TOOL_PREVIEW_CHANGED' || 'RUN_VERSION_CHANGED' => '操作内容或版本已改变，请重新核对状态。',
    'TOOL_APPROVAL_REQUIRED' => '工具尚未获得有效批准，请重新核对请求。',
    'HOST_BUSY' => '本地执行器暂忙，请稍后核对状态。',
    'STALE_HOST_HANDLE' => '本地连接已关闭，请重新打开应用。',
    'INVALID_RUN_REQUEST' => '输入不符合要求，请检查文本长度和内容。',
    _ => '操作未完成，请核对状态。错误编号：${error.code}',
  };
}
