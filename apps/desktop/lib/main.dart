import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/rust/api/host.dart';
import 'src/rust/frb_generated.dart';
import 'local_agent_shell.dart';

Future<String> applicationDataDirectory() async {
  if (Platform.isMacOS) {
    final path = await const MethodChannel('orange_agent/platform')
        .invokeMethod<String>('applicationSupportDirectory');
    if (path == null || path.isEmpty) {
      throw StateError('DATA_DIRECTORY_UNAVAILABLE');
    }
    return path;
  }
  final base = Platform.isWindows
      ? Platform.environment['LOCALAPPDATA']
      : Platform.environment['XDG_DATA_HOME'] ??
            (Platform.environment['HOME'] == null
                ? null
                : '${Platform.environment['HOME']}/.local/share');
  if (base == null || base.isEmpty) {
    throw StateError('DATA_DIRECTORY_UNAVAILABLE');
  }
  return '$base${Platform.pathSeparator}OrangeAgent';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final nativeReady = RustLib.init();
  runApp(
    OrangeDesktopApp(
      connect: () async {
        await nativeReady;
        return initializeHost(
          applicationDataDirectory: await applicationDataDirectory(),
        );
      },
    ),
  );
}

class OrangeDesktopApp extends StatefulWidget {
  const OrangeDesktopApp({
    super.key,
    required this.connect,
    this.modelServiceDirectory,
  });
  final Future<HostView> Function() connect;
  final Future<String> Function()? modelServiceDirectory;
  @override
  State<OrangeDesktopApp> createState() => _OrangeDesktopAppState();
}

class _OrangeDesktopAppState extends State<OrangeDesktopApp> {
  late Future<HostView> host;
  @override
  void initState() {
    super.initState();
    host = widget.connect();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Orange Agent',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffed6b2d)),
      useMaterial3: true,
    ),
    home: Scaffold(
      appBar: AppBar(title: const Text('Orange Agent')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: FutureBuilder<HostView>(
              future: host,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 20),
                      Text('正在打开本地记录…'),
                    ],
                  );
                }
                if (snapshot.hasError || !snapshot.hasData) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_outline, size: 40),
                      const SizedBox(height: 20),
                      const Text('本地记录暂时无法打开'),
                      const SizedBox(height: 8),
                      const Text(
                        '请确认没有其他 Orange Agent 实例占用记录，并检查应用数据目录权限。',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: () =>
                            setState(() => host = widget.connect()),
                        child: const Text('重试'),
                      ),
                    ],
                  );
                }
                final info = snapshot.requireData;
                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.auto_awesome_outlined, size: 48),
                      const SizedBox(height: 24),
                      Text(
                        '本地记录已连接',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 12),
                      const Text('这是桌面端开发预览。可导入清单中的本地模型并运行只读会话；云端账户仍待接入。'),
                      const SizedBox(height: 28),
                      LocalAgentShell(
                        key: ValueKey(info.handle),
                        host: info,
                        manageService: widget.modelServiceDirectory == null,
                        serviceDirectory:
                            widget.modelServiceDirectory ??
                            () async => '${await applicationDataDirectory()}/m',
                      ),
                      const SizedBox(height: 16),
                      Card(
                        child: ExpansionTile(
                          title: const Text('运行环境详情'),
                          children: [
                            ListTile(
                              title: const Text('共享内核'),
                              subtitle: Text(info.runtimeVersion),
                            ),
                            ListTile(
                              title: const Text('构建来源'),
                              subtitle: SelectableText(
                                info.runtimeSourceCommit,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}
