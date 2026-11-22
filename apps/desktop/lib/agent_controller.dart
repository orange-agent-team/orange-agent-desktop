import 'dart:math';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'src/rust/api/host.dart' as api;
import 'src/rust/api/memory.dart' as mem;

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

abstract interface class LocalPackageCommands {
  Future<api.LocalPackageReview> reviewPackage(String manifest);
  Future<void> installPackage(String manifest, api.LocalPackageReview review);
  Future<void> uninstallPackage(api.LocalPackageReview review);
}

abstract interface class PatchSkillCommands {
  Future<api.AgentRunView> startPatchSkill(
    String workspace,
    String id,
    String prompt,
    api.LocalSkillChoice skill,
    api.EditingAccessView permission,
  );
}

abstract interface class LocalSkillCommands {
  Future<List<api.LocalSkillChoice>> listSkills();
  Future<String> setSkillEnabled(api.LocalSkillChoice choice, bool enabled);
  Future<api.AgentRunView> startSkill(
    String workspace,
    String id,
    String prompt,
    api.LocalSkillChoice choice,
  );
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

abstract interface class MemoryAgentCommands {
  Future<List<mem.TaskMemoryRequirement>> requirements(String run);
  Future<api.AgentRunView> restoreMemory(
    String run,
    mem.TaskMemorySelection selection,
  );

  Future<api.AgentRunView> startWithMemory(
    String workspace,
    String id,
    String prompt,
    mem.TaskMemorySelection selection,
    bool questions,
  );
  Future<mem.TaskMemoryReview> previewMemory(String run, String operation);
  Future<api.AgentRunView> approveMemory(
    String run,
    String operation,
    String digest,
  );
}

abstract interface class MemoryRecoveryCommands {
  Future<List<mem.UncertainMemoryWrite>> uncertain(String run);
  Future<void> reconcile(
    String run,
    mem.UncertainMemoryWrite item,
    bool resume,
  );
}

class NativeAgentCommands
    implements
        AgentCommands,
        LocalSkillCommands,
        PatchSkillCommands,
        LocalPackageCommands,
        EditingAgentCommands,
        MemoryAgentCommands,
        MemoryRecoveryCommands {
  NativeAgentCommands(this.handle);
  final String handle;
  @override
  Future<api.LocalPackageReview> reviewPackage(String manifest) =>
      api.reviewLocalPackage(handle: handle, manifest: manifest);
  @override
  Future<void> installPackage(
    String manifest,
    api.LocalPackageReview review,
  ) async {
    await api.installLocalPackage(
      handle: handle,
      manifest: manifest,
      digest: review.digest,
      installationRevision: review.installationRevision,
    );
  }

  @override
  Future<void> uninstallPackage(api.LocalPackageReview review) async {
    await api.uninstallLocalPackage(
      handle: handle,
      installationRevision: review.installationRevision,
      selection: api.LocalSkillSelection(
        skillId: review.skillId,
        version: review.version,
        digest: review.digest,
        activationRevision: review.activationRevision,
      ),
    );
  }

  @override
  Future<List<api.LocalSkillChoice>> listSkills() =>
      api.listLocalSkills(handle: handle);
  @override
  Future<String> setSkillEnabled(api.LocalSkillChoice choice, bool enabled) =>
      api.setLocalSkillEnabled(
        handle: handle,
        skillId: choice.skillId,
        version: choice.version,
        digest: choice.digest,
        expectedRevision: choice.revision,
        enabled: enabled,
      );
  @override
  Future<api.AgentRunView> startPatchSkill(
    String workspace,
    String id,
    String prompt,
    api.LocalSkillChoice skill,
    api.EditingAccessView permission,
  ) => api.startLocalPatchSkillRun(
    handle: handle,
    workspaceId: workspace,
    requestId: id,
    prompt: prompt,
    editingConsentId: permission.consentId,
    editingVersion: permission.permissionVersion,
    selection: api.LocalSkillSelection(
      skillId: skill.skillId,
      version: skill.version,
      digest: skill.digest,
      activationRevision: skill.revision,
    ),
  );
  @override
  Future<api.AgentRunView> startSkill(
    String workspace,
    String id,
    String prompt,
    api.LocalSkillChoice choice,
  ) => api.startLocalSkillRun(
    handle: handle,
    workspaceId: workspace,
    requestId: id,
    prompt: prompt,
    selection: api.LocalSkillSelection(
      skillId: choice.skillId,
      version: choice.version,
      digest: choice.digest,
      activationRevision: choice.revision,
    ),
  );
  @override
  Future<List<mem.UncertainMemoryWrite>> uncertain(String run) =>
      mem.uncertainTaskWrites(handle: handle, runId: run, limit: 100);
  @override
  Future<void> reconcile(
    String run,
    mem.UncertainMemoryWrite item,
    bool resume,
  ) => mem.reconcileTaskWrite(
    handle: handle,
    runId: run,
    operationId: item.operationId,
    digest: item.outcome.digest,
    applied: item.outcome.state == 'approved',
    resume: resume,
  );
  @override
  Future<List<mem.TaskMemoryRequirement>> requirements(String run) =>
      mem.runMemoryRequirements(handle: handle, runId: run);
  @override
  Future<api.AgentRunView> restoreMemory(
    String run,
    mem.TaskMemorySelection selection,
  ) => mem.restoreRunMemory(handle: handle, runId: run, selection: selection);
  @override
  Future<api.AgentRunView> startWithMemory(
    String workspace,
    String id,
    String prompt,
    mem.TaskMemorySelection selection,
    bool questions,
  ) => mem.startMemoryRun(
    handle: handle,
    workspace: workspace,
    requestId: id,
    prompt: prompt,
    selection: selection,
    interactive: questions,
  );
  @override
  Future<mem.TaskMemoryReview> previewMemory(String run, String operation) =>
      mem.previewRunMemory(handle: handle, runId: run, operationId: operation);
  @override
  Future<api.AgentRunView> approveMemory(
    String run,
    String operation,
    String digest,
  ) => mem.approveRunMemory(
    handle: handle,
    runId: run,
    operationId: operation,
    digest: digest,
  );
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

String toolDisplayName(String name) => name == 'memory_read'
    ? '读取记忆'
    : name == 'memory_write'
    ? '修改记忆'
    : name == 'apply_patch'
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
  List<api.LocalSkillChoice> skills = [];
  bool skillBusy = false;
  String? skillError;
  bool get supportsSkills => commands is LocalSkillCommands;
  Future<void> refreshSkills() async {
    if (!_alive || skillBusy || !supportsSkills) return;
    skillBusy = true;
    skillError = null;
    _changed();
    try {
      final rows = await (commands as LocalSkillCommands).listSkills();
      if (_alive) skills = rows;
    } catch (_) {
      if (_alive) {
        skills = [];
        skillError = '无法读取当前宿主的模板目录。';
      }
    } finally {
      skillBusy = false;
      _changed();
    }
  }

  Future<void> toggleSkill(api.LocalSkillChoice choice) async {
    if (!_alive || skillBusy || !supportsSkills) return;
    skillBusy = true;
    skillError = null;
    _changed();
    final transport = commands as LocalSkillCommands;
    try {
      await transport.setSkillEnabled(choice, !choice.enabled);
      final rows = await transport.listSkills();
      if (_alive) skills = rows;
    } catch (_) {
      if (_alive) {
        skills = [];
        skillError = '模板状态已变化，请重新读取后核对。';
      }
    } finally {
      skillBusy = false;
      _changed();
    }
  }

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
    api.LocalSkillChoice? skill,
    api.CreationAccessView? creation,
    api.EditingAccessView? editing,
    mem.TaskMemorySelection? memory,
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
  mem.TaskMemoryReview? memoryReview;
  List<mem.TaskMemoryRequirement> memoryRequirements = [];
  bool usesMemory = false;
  List<mem.UncertainMemoryWrite> uncertainWrites = [];
  Future<void> inspectUncertainWrites() async {
    final id = runId, transport = commands;
    if (id == null ||
        busy ||
        cancelling ||
        transport is! MemoryRecoveryCommands) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    error = null;
    _changed();
    try {
      final items = await (transport as MemoryRecoveryCommands).uncertain(id);
      if (_current(epoch)) {
        uncertainWrites = items;
        notice = items.isEmpty ? '没有待核对的记忆写入。' : null;
      }
    } catch (e) {
      if (_current(epoch)) _failed(e);
    } finally {
      if (_current(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> resolveMemory(mem.UncertainMemoryWrite item, bool resume) async {
    final id = runId, transport = commands;
    if (id == null ||
        busy ||
        cancelling ||
        !uncertainWrites.contains(item) ||
        transport is! MemoryRecoveryCommands) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    error = null;
    _changed();
    try {
      await (transport as MemoryRecoveryCommands).reconcile(id, item, resume);
      if (!_current(epoch)) return;
      uncertainWrites = uncertainWrites
          .where((v) => v.operationId != item.operationId)
          .toList();
      view = null;
      notice = resume ? '已按回执恢复，可继续会话。' : '已按回执结束会话。';
      if (resume) {
        final current = await commands.inspect(id);
        if (_current(epoch)) view = current;
      } else {
        runId = null;
        usesMemory = false;
        memoryRequirements = [];
      }
    } catch (e) {
      if (_current(epoch)) _failed(e);
    } finally {
      if (_current(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  Future<void> restoreMemory(mem.MemorySelection selected) async {
    final id = runId, transport = commands;
    if (id == null ||
        busy ||
        cancelling ||
        transport is! MemoryAgentCommands ||
        memoryRequirements.length != 1) {
      return;
    }
    final required = memoryRequirements.single;
    if (required.scopeId != selected.scopeId) return;
    final epoch = ++_epoch;
    busy = true;
    view = null;
    error = null;
    _changed();
    try {
      final restored = await (transport as MemoryAgentCommands).restoreMemory(
        id,
        mem.TaskMemorySelection(
          scopes: [
            mem.TaskMemoryScope(
              scopeId: required.scopeId,
              write: required.write,
              sessionToken: selected.sessionToken,
            ),
          ],
          sources: selected.sources,
        ),
      );
      if (!_current(epoch)) return;
      view = restored;
      workspaceId = restored.workspaceId;
      notice = '已重新验证任务访问权限。';
    } catch (e) {
      if (_current(epoch)) _failed(e);
    } finally {
      if (_current(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  bool get memoryReviewMatches {
    final op = view?.pending.firstOrNull;
    return op?.toolName == 'memory_write' &&
        op!.operationId == memoryReview?.operationId &&
        op.argumentDigest == memoryReview?.argumentDigest;
  }

  Future<void> previewMemoryWrite() async {
    final current = view, op = view?.pending.firstOrNull, transport = commands;
    if (busy ||
        cancelling ||
        op?.toolName != 'memory_write' ||
        current == null ||
        transport is! MemoryAgentCommands) {
      return;
    }
    final epoch = ++_epoch;
    busy = true;
    error = null;
    memoryReview = null;
    _changed();
    try {
      final review = await (transport as MemoryAgentCommands).previewMemory(
        current.runId,
        op!.operationId,
      );
      if (!_current(epoch)) return;
      if (review.operationId != op.operationId ||
          review.argumentDigest != op.argumentDigest) {
        throw const FormatException('Memory preview changed');
      }
      memoryReview = review;
    } catch (e) {
      if (_current(epoch)) _failed(e);
    } finally {
      if (_current(epoch)) {
        busy = false;
        _changed();
      }
    }
  }

  bool get supportedPreview =>
      view != null &&
      view!.pending.isNotEmpty &&
      (editPreviewMatches ||
          memoryReviewMatches ||
          (commands is MemoryAgentCommands &&
              view!.pending.first.toolName == 'memory_read') ||
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
  String get approvalLabel => memoryReviewMatches
      ? '确认这次记忆修改'
      : view?.pending.firstOrNull?.toolName == 'apply_patch'
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
    if (!memoryReviewMatches) memoryReview = null;
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
    api.LocalSkillChoice? skill,
    api.CreationAccessView? creation,
    api.EditingAccessView? editing,
    mem.TaskMemorySelection? memory,
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
    if (skill != null) {
      if (!supportsSkills ||
          !skills.any(
            (v) =>
                v.digest == skill.digest &&
                v.enabled &&
                v.revision == skill.revision,
          )) {
        return;
      }
      allowQuestions = false;
      creation = null;
      if (skill.requiredModelProfile != null &&
          model?.qualifiedSkills != true) {
        return;
      }
      if (skill.skillId == 'orange.reviewed-patch') {
        if (editing == null || commands is! PatchSkillCommands) return;
      } else {
        editing = null;
      }
      memory = null;
    }
    memoryRequirements = [];
    usesMemory = memory != null;
    _submission = (
      skill: skill,
      memory: memory,
      workspace: workspace,
      id: id,
      prompt: prompt,
      allowQuestions: allowQuestions,
      creation: creation,
      editing: editing,
    );
    workspaceId = workspace;
    runId = id;
    uncertainWrites = [];
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
      if (submission.skill != null) {
        final transport = commands;
        if (transport is! LocalSkillCommands) {
          throw UnsupportedError('Local skill transport unavailable');
        }
        if (submission.skill!.skillId == 'orange.reviewed-patch') {
          final permission = submission.editing;
          if (permission == null || transport is! PatchSkillCommands) {
            throw StateError('缺少本次补丁的编辑授权');
          }
          created = await (transport as PatchSkillCommands).startPatchSkill(
            submission.workspace,
            submission.id,
            submission.prompt,
            submission.skill!,
            permission,
          );
        } else {
          created = await (transport as LocalSkillCommands).startSkill(
            submission.workspace,
            submission.id,
            submission.prompt,
            submission.skill!,
          );
        }
      } else if (submission.memory != null) {
        final transport = commands;
        if (transport is! MemoryAgentCommands) {
          throw UnsupportedError('Memory transport unavailable');
        }
        created = await (transport as MemoryAgentCommands).startWithMemory(
          submission.workspace,
          submission.id,
          submission.prompt,
          submission.memory!,
          submission.allowQuestions,
        );
      } else if (submission.editing != null) {
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
      if (preview.toolName == 'memory_read' ||
          preview.toolName == 'memory_write') {
        final transport = commands as MemoryAgentCommands;
        approved = await transport.approveMemory(
          current.runId,
          preview.operationId,
          preview.toolName == 'memory_write'
              ? memoryReview!.approvalDigest
              : preview.argumentDigest,
        );
      } else if (preview.toolName == 'apply_patch') {
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
    uncertainWrites = [];
    workspaceId = expectedWorkspace ?? workspaceId;
    view = null;
    busy = true;
    error = null;
    notice = null;
    _changed();
    try {
      final transport = commands;
      memoryRequirements = [];
      if (transport is MemoryAgentCommands) {
        final required = await (transport as MemoryAgentCommands).requirements(
          id,
        );
        if (!_current(epoch)) return;
        memoryRequirements = required;
        usesMemory = required.isNotEmpty;
      }
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
    'SKILL_ACTIVATION_CHANGED' => '所选模板已停用或启用修订已变化。请核对原运行，再选择当前模板版本。',
    'INVALID_SKILL_SELECTION' => '模板选择与当前宿主的目录不一致。',
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
