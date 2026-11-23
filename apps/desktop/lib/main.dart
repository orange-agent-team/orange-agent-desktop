import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/rust/api/host.dart';
import 'src/rust/frb_generated.dart';
import 'local_agent_shell.dart';
import 'desktop_connection.dart';

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
  final connection = DesktopConnection(
    initializeBridge: () async {
      try {
        await RustLib.init();
      } catch (_) {
        // FRB may have opened its ports before running the Rust initializer.
        if (RustLib.instance.initialized) RustLib.dispose();
        rethrow;
      }
    },
    openHost: () async => initializeHost(
      applicationDataDirectory: await applicationDataDirectory(),
    ),
  );
  runApp(OrangeDesktopApp(connect: connection.connect));
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
  Future<HostView>? host;

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
              future: host ??= Future.sync(widget.connect),
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
                  final error = snapshot.error;
                  final bridgeError = error is BridgeStartupFailure;
                  final busy =
                      error is BridgeError && error.code == 'HOST_BUSY';
                  return SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          bridgeError
                              ? Icons.extension_off
                              : Icons.lock_outline,
                          size: 40,
                        ),
                        const SizedBox(height: 20),
                        Text(bridgeError ? '本地运行组件未能启动' : '本地记录暂时无法打开'),
                        const SizedBox(height: 8),
                        Text(
                          bridgeError
                              ? '请确认应用安装完整，再重试加载。'
                              : busy
                              ? '其他 Orange Agent 进程正在使用本地记录。关闭该进程后可以重试。'
                              : '请确认应用数据目录可用，并检查目录权限。',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        FilledButton(
                          autofocus: true,
                          onPressed: () => setState(() {
                            host = null;
                          }),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
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
                      const Text('可导入本地模型，按授权处理文件，或用个人只读密钥查看钱包和预算。'),
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
