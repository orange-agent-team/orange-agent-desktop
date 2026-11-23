import 'package:flutter/material.dart';

import 'agent_controller.dart';
import 'agent_panel.dart';
import 'creation_panel.dart';
import 'editing_panel.dart';
import 'model_controller.dart';
import 'model_panel.dart';
import 'personal_account_panel.dart';
import 'memory_controller.dart';
import 'memory_panel.dart';
import 'recovery_controller.dart';
import 'recovery_panel.dart';
import 'retention_controller.dart';
import 'retention_panel.dart';
import 'src/rust/api/host.dart';
import 'workspaces.dart';

/// Scope-owning workspace widget remains mounted alongside conversation views.
/// Navigating history does not dispose its native directory selections.
class LocalAgentShell extends StatefulWidget {
  const LocalAgentShell({
    super.key,
    required this.host,
    required this.serviceDirectory,
    this.manageService = true,
  });
  final HostView host;
  final Future<String> Function() serviceDirectory;
  final bool manageService;
  @override
  State<LocalAgentShell> createState() => _LocalAgentShellState();
}

class _LocalAgentShellState extends State<LocalAgentShell> {
  late final AgentController controller;
  late final RecoveryController recovery;
  late final RetentionController retention;
  late final MemoryController memory;
  ModelController? models;
  List<WorkspaceView> workspaces = [];
  List<CreationAccessView> creations = [];
  List<EditingAccessView> editings = [];
  @override
  void initState() {
    super.initState();
    if (widget.manageService) {
      models = ModelController(
        widget.host.handle,
        beforeStop: () {
          controller.clearModel();
        },
      );
    }
    controller = AgentController(
      models == null
          ? NativeAgentCommands(widget.host.handle)
          : ManagedAgentCommands(widget.host.handle, models!),
      serviceDirectory: models == null
          ? widget.serviceDirectory
          : () async => 'managed',
    );
    recovery = RecoveryController(NativeRecoveryCommands(widget.host.handle));
    retention = RetentionController(
      NativeRetentionCommands(widget.host.handle),
    );
    memory = MemoryController(NativeMemoryCommands(widget.host.handle));
    memory.addListener(memoryChanged);
    memory.refresh();
    models?.configure();
  }

  @override
  void dispose() {
    models?.dispose();
    controller.dispose();
    recovery.dispose();
    retention.dispose();
    memory.removeListener(memoryChanged);
    memory.dispose();
    super.dispose();
  }

  String? memoryIdentity;
  void memoryChanged() {
    final selection = memory.selection;
    final identity = selection == null
        ? null
        : [
            selection.sessionToken,
            ...selection.sources.memoryTokens,
            ...selection.sources.workspaceIds,
          ].join('|');
    if (identity == memoryIdentity || !mounted) return;
    memoryIdentity = identity;
    if (controller.usesMemory) controller.hideContent();
    setState(() {});
  }

  void changed(List<WorkspaceView> rows) {
    if (!mounted) return;
    for (final old in workspaces) {
      final current = rows.where((w) => w.workspaceId == old.workspaceId);
      if (current.isEmpty ||
          current.single.permissionVersion != old.permissionVersion ||
          (old.sessionAccess && !current.single.sessionAccess)) {
        recovery.workspaceStopping(old.workspaceId);
        retention.workspaceStopping(old.workspaceId);
        memory.workspaceStopping(old.workspaceId);
      }
    }
    setState(() => workspaces = rows);
    if (controller.workspaceId != null &&
        !rows.any(
          (w) =>
              w.workspaceId == controller.workspaceId &&
              w.sessionAccess &&
              w.permissionActive,
        )) {
      controller.hideContent(stoppingWorkspace: controller.workspaceId);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (models != null) ...[
        ModelPanel(controller: models!),
        const SizedBox(height: 16),
      ],
      PersonalAccountPanel(handle: widget.host.handle),
      const SizedBox(height: 16),
      WorkspacePanel(
        host: widget.host,
        onChanged: changed,
        onAccessStopping: (id) {
          controller.hideContent(stoppingWorkspace: id);
          recovery.workspaceStopping(id);
          retention.workspaceStopping(id);
          memory.workspaceStopping(id);
        },
        onOpenRun: (run) {
          if (run.phase == 'recovery_required') {
            controller.hideContent();
            recovery.selectRun(run);
            controller.load(
              run.runId,
              reopen: true,
              expectedWorkspace: run.workspaceId,
            );
          } else {
            controller.load(
              run.runId,
              reopen: true,
              expectedWorkspace: run.workspaceId,
            );
          }
        },
      ),
      const SizedBox(height: 16),
      CreationPanel(
        host: widget.host,
        workspaces: workspaces,
        onChanged: (rows) {
          if (mounted) setState(() => creations = rows);
        },
        onStopping: controller.creationStopping,
      ),
      const SizedBox(height: 16),
      EditingPanel(
        host: widget.host,
        workspaces: workspaces,
        onChanged: (rows) {
          if (mounted) setState(() => editings = rows);
        },
        onStopping: controller.editingStopping,
      ),
      const SizedBox(height: 16),
      RecoveryPanel(
        controller: recovery,
        supported: widget.host.availableEditTools.contains('apply_patch'),
      ),
      const SizedBox(height: 16),
      RetentionPanel(
        controller: retention,
        supported: widget.host.availableEditTools.contains('apply_patch'),
      ),
      const SizedBox(height: 16),
      MemoryPanel(controller: memory, workspaces: workspaces),
      const SizedBox(height: 16),
      AgentPanel(
        memory: memory.selection,
        memoryWrite: memory.canWrite,
        controller: controller,
        workspaces: workspaces,
        creations: creations,
        editings: editings,
      ),
    ],
  );
}
