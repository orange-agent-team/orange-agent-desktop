import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'agent_controller.dart';
import 'src/rust/api/host.dart' as api;

class ModelController extends ChangeNotifier {
  ModelController(this.handle, {required this.beforeStop});
  final String handle;
  final VoidCallback beforeStop;
  static const platform = MethodChannel('orange_agent/platform');
  api.ModelServiceView? view;
  String? error, notice;
  bool configuring = false,
      importing = false,
      downloading = false,
      starting = false,
      stopping = false;
  String? _importId, _downloadId, _startId;
  String? _lastInstance;
  bool _alive = true;
  int _epoch = 0;
  int _reads = 0;
  bool startUnconfirmed = false;
  Completer<void>? _configuration;
  bool get busy =>
      configuring || importing || downloading || starting || stopping;
  bool get canStop =>
      starting ||
      startUnconfirmed ||
      (view == null && _lastInstance != null) ||
      (view?.instanceId != null && !{'idle', 'stopped'}.contains(view!.phase));
  bool get canInstall =>
      _alive &&
      view != null &&
      !view!.installed &&
      {'idle', 'stopped'}.contains(view!.phase) &&
      !busy;
  bool get canStart =>
      _alive &&
      view?.installed == true &&
      {'idle', 'stopped', 'ready'}.contains(view!.phase) &&
      !busy;
  void changed() {
    if (_alive) notifyListeners();
  }

  bool current(int epoch) => _alive && epoch == _epoch;
  void publish(api.ModelServiceView value) {
    _reads++;
    view = value;
    _lastInstance = value.instanceId ?? _lastInstance;
    if ({'idle', 'stopped', 'ready'}.contains(value.phase)) {
      startUnconfirmed = false;
    }
  }

  String id() {
    final random = Random.secure();
    return 'model-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  Future<void> configure() async {
    if (configuring) {
      await _configuration?.future;
      return;
    }
    if (busy) return;
    final completion = Completer<void>();
    _configuration = completion;
    final epoch = ++_epoch;
    configuring = true;
    error = null;
    changed();
    try {
      final env = await platform.invokeMapMethod<String, dynamic>(
        'modelServiceEnvironment',
      );
      if (env == null ||
          env['contentsDirectory'] is! String ||
          env['ipcDirectory'] is! String ||
          env['osVersion'] is! String) {
        throw StateError('native model environment unavailable');
      }
      final result = await api.configureModelService(
        handle: handle,
        contentsDirectory: env['contentsDirectory'] as String,
        ipcDirectory: env['ipcDirectory'] as String,
        osVersion: env['osVersion'] as String,
      );
      if (current(epoch)) publish(result);
    } catch (failure) {
      if (current(epoch)) error = describeModelError(failure);
    } finally {
      completion.complete();
      if (identical(_configuration, completion)) _configuration = null;
      if (current(epoch)) {
        configuring = false;
        changed();
      }
    }
  }

  Future<void> refresh() async {
    final epoch = _epoch;
    final ticket = ++_reads;
    try {
      final result = await api.inspectModelService(handle: handle);
      if (current(epoch) && ticket == _reads) {
        view = result;
        _lastInstance = result.instanceId ?? _lastInstance;
        if ({'idle', 'stopped', 'ready'}.contains(result.phase)) {
          startUnconfirmed = false;
        }
        changed();
      }
    } catch (failure) {
      if (current(epoch) && ticket == _reads) {
        view = null;
        error = describeModelError(failure);
        changed();
      }
    }
  }

  Future<void> importFile() async {
    if (!canInstall) return;
    final epoch = ++_epoch;
    importing = true;
    error = null;
    notice = null;
    changed();
    String? selection;
    try {
      final chosen = await platform.invokeMapMethod<String, dynamic>(
        'chooseModelFile',
      );
      if (chosen == null) return;
      if (chosen['selectionId'] is! String || chosen['path'] is! String) {
        throw StateError('invalid native model selection');
      }
      selection = chosen['selectionId'] as String;
      _importId = selection;
      if (!current(epoch)) return;
      final result = await api.importModel(
        handle: handle,
        operationId: selection,
        selectedFile: chosen['path'] as String,
      );
      if (current(epoch)) {
        publish(result);
        notice = '模型文件已校验并保存到本机。';
      }
    } catch (failure) {
      if (current(epoch)) error = describeModelError(failure);
    } finally {
      if (selection != null) {
        try {
          try {
            await api.closeModelImport(handle: handle, operationId: selection);
          } on api.BridgeError catch (error) {
            if (error.code != 'STALE_HOST_HANDLE') rethrow;
          }
          await platform.invokeMethod<void>('releaseModelSelection', {
            'selectionId': selection,
          });
        } catch (failure) {
          if (_alive) error = '文件访问收尾尚未确认，请核对模型状态。';
        }
      }
      _importId = null;
      if (current(epoch)) {
        importing = false;
        changed();
      }
    }
  }

  Future<void> download() async {
    if (!canInstall) return;
    final operation = id();
    final epoch = ++_epoch;
    _downloadId = operation;
    downloading = true;
    error = null;
    notice = null;
    changed();
    try {
      final result = await api.downloadModel(
        handle: handle,
        operationId: operation,
      );
      if (current(epoch)) {
        publish(result);
        notice = '已校验模型文件，可以启动本地推理。';
      }
    } catch (failure) {
      if (current(epoch)) error = describeModelError(failure);
    } finally {
      try {
        await api.closeModelDownload(handle: handle, operationId: operation);
      } on api.BridgeError catch (failure) {
        if (current(epoch) && failure.code != 'STALE_HOST_HANDLE') {
          error = describeModelError(failure);
        }
      } finally {
        if (_downloadId == operation) _downloadId = null;
        downloading = false;
        changed();
      }
    }
  }

  Future<void> cancelDownload() async {
    final operation = _downloadId;
    if (operation == null) return;
    try {
      await api.closeModelDownload(handle: handle, operationId: operation);
      if (_alive) {
        notice = '正在停止下载。';
        changed();
      }
    } catch (failure) {
      if (_alive) {
        error = describeModelError(failure);
        changed();
      }
    }
  }

  Future<void> cancelImport() async {
    final operation = _importId;
    if (operation == null) return;
    notice = '正在停止导入…';
    changed();
    try {
      await api.closeModelImport(handle: handle, operationId: operation);
      await refresh();
    } catch (failure) {
      if (_alive) {
        error = describeModelError(failure);
        changed();
      }
    }
  }

  Future<api.ModelServiceView> start() async {
    if (view == null) await configure();
    if (view?.phase == 'ready') return view!;
    if (!canStart) {
      throw api.BridgeError(
        code: view?.installed == true
            ? 'MODEL_SERVICE_BUSY'
            : 'MODEL_NOT_INSTALLED',
        correlationId: 'ui-preflight',
      );
    }
    final epoch = ++_epoch;
    starting = true;
    error = null;
    notice = '正在校验并启动本地模型…';
    _startId = id();
    startUnconfirmed = true;
    changed();
    try {
      final result = await api.startModelService(
        handle: handle,
        requestId: _startId!,
      );
      if (current(epoch)) {
        publish(result);
        notice = result.phase == 'ready' ? '本地模型已就绪。' : null;
      }
      if (!current(epoch) || result.phase != 'ready') {
        throw const api.BridgeError(
          code: 'MODEL_START_CANCELLED',
          correlationId: 'ui-transition',
        );
      }
      return result;
    } catch (failure) {
      if (current(epoch)) {
        view = null;
        _reads++;
        error = describeModelError(failure);
        await refresh();
      }
      rethrow;
    } finally {
      if (current(epoch)) {
        starting = false;
        changed();
      }
    }
  }

  Future<void> stop() async {
    if (stopping) return;
    final request = starting || startUnconfirmed ? _startId : null;
    final instance = view?.instanceId ?? _lastInstance;
    if (request == null && instance == null) return;
    beforeStop();
    final epoch = ++_epoch;
    stopping = true;
    starting = false;
    error = null;
    notice = '正在请求停止模型…';
    changed();
    try {
      final result = request != null
          ? await api.cancelModelStart(handle: handle, requestId: request)
          : await api.stopModelService(handle: handle, instanceId: instance!);
      if (current(epoch)) {
        publish(result);
        notice = {'idle', 'stopped'}.contains(result.phase)
            ? '模型已停止。'
            : '模型状态仍需核对。';
      }
    } catch (failure) {
      if (current(epoch)) {
        view = null;
        _reads++;
        error = describeModelError(failure);
        await refresh();
      }
    } finally {
      if (current(epoch)) {
        stopping = false;
        changed();
      }
    }
  }

  @override
  void dispose() {
    _alive = false;
    _epoch++;
    Future<void> finish() async {
      try {
        if (_downloadId != null) {
          await api.closeModelDownload(
            handle: handle,
            operationId: _downloadId!,
          );
        }
        if (_importId != null) {
          await api.closeModelImport(handle: handle, operationId: _importId!);
        }
        if ((starting || startUnconfirmed) && _startId != null) {
          await api.cancelModelStart(handle: handle, requestId: _startId!);
        } else if (_lastInstance != null &&
            (view == null || !{'idle', 'stopped'}.contains(view!.phase))) {
          await api.stopModelService(
            handle: handle,
            instanceId: _lastInstance!,
          );
        }
      } on api.BridgeError catch (error) {
        if (!{
          'STALE_HOST_HANDLE',
          'MODEL_INSTANCE_CHANGED',
        }.contains(error.code)) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              library: 'model ownership cleanup',
            ),
          );
        }
      }
    }

    unawaited(finish());
    super.dispose();
  }
}

class ManagedAgentCommands extends NativeAgentCommands {
  ManagedAgentCommands(super.handle, this.models);
  final ModelController models;
  @override
  Future<api.AgentRunView> advance(String id, String revision) async {
    try {
      return await super.advance(id, revision);
    } on api.BridgeError catch (failure) {
      if (failure.code == 'MODEL_SERVICE_UNAVAILABLE') {
        // Refresh status only. Never restart the model or repeat the command.
        await models.refresh();
      }
      rethrow;
    }
  }

  @override
  Future<api.ModelConnectionView> connect(String directory) async {
    try {
      await models.start();
      return await api.currentModelConnection(handle: handle);
    } catch (_) {
      await models.refresh();
      rethrow;
    }
  }
}

String describeModelError(Object failure) {
  if (failure is! api.BridgeError) return '无法完成本地模型操作，请重试或核对状态。';
  return describeModelFailureCode(failure.code);
}

String describeModelFailureCode(String code) {
  return switch (code) {
    'MODEL_CONTROL_HEARTBEAT_LOST' ||
    'MODEL_CONTROL_SEND_FAILED' => '本地模型连接已中断，请核对状态后重新启动。',
    'MODEL_HOST_EXITED' || 'MODEL_BACKEND_EXITED' => '本地模型进程已退出，请核对状态后重新启动。',
    'MODEL_CONTROL_AUTH_FAILED' => '模型控制连接未通过验证，服务已停止。',
    'MODEL_DIAGNOSTIC_UNAVAILABLE' => '模型已停止，但退出诊断未能保存。',
    'MODEL_SERVICE_NOT_PACKAGED' => '此构建未包含本地模型组件。',
    'MODEL_PLATFORM_UNAVAILABLE' => '本机系统版本或架构不满足模型组件要求。',
    'MODEL_NOT_INSTALLED' => '请先导入清单中指定的模型文件。',
    'MODEL_INTEGRITY' => '文件或模型组件未通过完整性校验。',
    'MODEL_DOWNLOAD_CANCELLED' => '模型下载已停止，可重新选择下载以继续。自己的工作区仍在本机。',
    'MODEL_DOWNLOAD_SOURCE_DENIED' => '模型下载地址不在当前目录允许的来源中。可导入已取得的同版本文件。',
    'MODEL_DOWNLOAD_CONNECTION' => '未能建立与模型来源的连接。',
    'MODEL_DOWNLOAD_TIMEOUT' => '模型传输超时。可重试以继续下载。',
    'MODEL_DOWNLOAD_INTERRUPTED' => '模型传输中断。可重试以继续下载。',
    'MODEL_DOWNLOAD_ACCESS_DENIED' => '模型来源拒绝了读取请求。',
    'MODEL_DOWNLOAD_RATE_LIMIT' => '模型来源暂时限制请求，请稍后重试。',
    'MODEL_DOWNLOAD_HTTP_FAILURE' => '模型来源返回了失败状态。',
    'MODEL_DOWNLOAD_RANGE_INVALID' => '模型来源返回的下载范围与原文件不符。',
    'MODEL_CACHE_QUOTA' => '模型缓存空间限额不足。',
    'MODEL_CACHE_BUSY' || 'MODEL_SERVICE_BUSY' => '本地模型正忙，请核对状态后重试。',
    'MODEL_IMPORT_CANCELLED' || 'MODEL_IMPORT_CLOSED' => '导入已停止；已经完成校验的缓存仍会保留。',
    'MODEL_START_CANCELLED' => '启动未完成，请核对服务状态。',
    'MODEL_RECOVERY_REQUIRED' ||
    'MODEL_CLEANUP_UNCONFIRMED' => '模型进程状态尚未确认，已禁止重新启动。',
    'MODEL_INSTANCE_CHANGED' => '模型实例已经改变，请重新核对状态。',
    'MODEL_COMMAND_LIMIT' => '模型控制记录已达到当前限额。',
    _ => '模型操作未完成，错误编号：$code',
  };
}
