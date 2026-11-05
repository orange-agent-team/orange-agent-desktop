import 'package:flutter/material.dart';

import 'agent_controller.dart';
import 'agent_panel.dart';
import 'model_controller.dart';
import 'model_panel.dart';
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
  ModelController? models;
  List<WorkspaceView> workspaces = [];
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
    models?.configure();
  }

  @override
  void dispose() {
    models?.dispose();
    controller.dispose();
    super.dispose();
  }

  void changed(List<WorkspaceView> rows) {
    if (!mounted) return;
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
      WorkspacePanel(
        host: widget.host,
        onChanged: changed,
        onAccessStopping: (id) => controller.hideContent(stoppingWorkspace: id),
        onOpenRun: (run) => controller.load(
          run.runId,
          reopen: true,
          expectedWorkspace: run.workspaceId,
        ),
      ),
      const SizedBox(height: 16),
      AgentPanel(controller: controller, workspaces: workspaces),
    ],
  );
}
