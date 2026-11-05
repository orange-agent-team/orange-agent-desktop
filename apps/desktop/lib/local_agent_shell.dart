import 'package:flutter/material.dart';

import 'agent_controller.dart';
import 'agent_panel.dart';
import 'src/rust/api/host.dart';
import 'workspaces.dart';

/// Scope-owning workspace widget remains mounted alongside conversation views.
/// Navigating history does not dispose its native directory selections.
class LocalAgentShell extends StatefulWidget {
  const LocalAgentShell({
    super.key,
    required this.host,
    required this.serviceDirectory,
  });
  final HostView host;
  final Future<String> Function() serviceDirectory;
  @override
  State<LocalAgentShell> createState() => _LocalAgentShellState();
}

class _LocalAgentShellState extends State<LocalAgentShell> {
  late final AgentController controller;
  List<WorkspaceView> workspaces = [];
  @override
  void initState() {
    super.initState();
    controller = AgentController(
      NativeAgentCommands(widget.host.handle),
      serviceDirectory: widget.serviceDirectory,
    );
  }

  @override
  void dispose() {
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
