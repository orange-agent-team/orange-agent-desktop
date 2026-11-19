import 'dart:convert';
import 'dart:io';

/// Explicit model-protocol substitute, confined to native integration tests.
/// Flutter, FRB, Unix IPC, SQLite and filesystem tools are real in this test.
class LocalModelFixture {
  LocalModelFixture._(
    this.root,
    this.ipc,
    this.server,
    this.expected,
    this.askFirst,
    this.readPath,
    this.createAfterRead,
    this.editAfterRead,
    this.taskMemory,
  );
  final Directory root, ipc;
  final HttpServer server;
  final String expected;
  final bool askFirst;
  final String readPath;
  final bool createAfterRead;
  final bool editAfterRead;
  final bool taskMemory;
  int calls = 0;
  final failures = <String>[];
  static const key = 'fixtureonly0123456789fixtureonly0123456789';
  static Future<LocalModelFixture> start(
    Directory hostRoot,
    String expected, {
    bool askFirst = false,
    String readPath = 'proof.txt',
    bool createAfterRead = false,
    bool editAfterRead = false,
    bool taskMemory = false,
  }) async {
    final root = await Directory('${hostRoot.path}/m').create();
    final ipc = await Directory.systemTemp.createTemp('oi');
    final path = '${await ipc.resolveSymbolicLinks()}/engine.sock';
    if (utf8.encode(path).length > 100) {
      throw StateError('Private fixture socket exceeds100 bytes');
    }
    final hash = 'a' * 64;
    final profile = File('${root.path}/profile.json');
    final record = File('${root.path}/process.json');
    final secret = File('${root.path}/api.key');
    await profile.writeAsString(
      jsonEncode({
        'protocol': 1,
        'runtime_directory': await root.resolveSymbolicLinks(),
        'socket_directory': await ipc.resolveSymbolicLinks(),
        'model_version': 'native-fixture-v1',
        'context_tokens': 4096,
        'model_sha256': hash,
        'executable_sha256': hash,
        'instance_id': 'native-fixture-instance',
      }),
    );
    await record.writeAsString(
      jsonEncode({
        'phase': 'ready',
        'cpu_only': true,
        'model_version': 'native-fixture-v1',
        'model_sha256': hash,
        'executable_sha256': hash,
        'instance_id': 'native-fixture-instance',
        'pid': null,
        'exit_code': null,
      }),
    );
    await secret.writeAsString(key);
    for (final arguments in [
      ['700', root.path, ipc.path],
      ['600', profile.path, record.path, secret.path],
    ]) {
      final result = await Process.run('/bin/chmod', arguments);
      if (result.exitCode != 0) {
        throw StateError('Cannot protect test-owned fixture files');
      }
    }
    final server = await HttpServer.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final fixture = LocalModelFixture._(
      root,
      ipc,
      server,
      expected,
      askFirst,
      readPath,
      createAfterRead,
      editAfterRead,
      taskMemory,
    );
    server.listen(
      fixture._handle,
      onError: (Object error) =>
          fixture.failures.add('fixture listener failed'),
    );
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $key') {
        request.response.statusCode = 401;
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/health') {
        request.response.write('{"status":"ok"}');
      } else if (request.uri.path == '/v1/chat/completions/input_tokens') {
        jsonDecode(body);
        request.response.write('{"input_tokens":4}');
      } else if (request.uri.path == '/v1/chat/completions') {
        final input = jsonDecode(body) as Map<String, dynamic>;
        if (input['model'] != 'native-fixture-v1') {
          throw StateError('model alias mismatch');
        }
        calls++;
        final Map<String, dynamic> delta;
        String finish;
        if (taskMemory) {
          final history = (input['messages'] as List)
              .where((m) => m['role'] == 'tool')
              .toList();
          if (calls == 1 || calls == 2) {
            final name = calls == 1 ? 'memory_write' : 'memory_read';
            if (!(input['tools'] as List).any(
              (tool) => tool['function']['name'] == name,
            )) {
              throw StateError('Missing selected memory tool');
            }
            final args = <String, dynamic>{'scope_id': 'personal'};
            if (calls == 1) {
              args.addAll({
                'mutation': 'put',
                'payload': {
                  'title': 'Preference',
                  'content': expected,
                  'enabled': true,
                },
              });
            } else {
              final receipt = jsonDecode(history.single['content'] as String);
              if (receipt['kind'] != 'memory_write' ||
                  receipt['data']['state'] != 'approved') {
                throw StateError('Missing approved write receipt');
              }
              args.addAll({
                'mode': 'entry',
                'entry_id': receipt['data']['entry_id'],
                'expected_version': '1',
              });
            }
            delta = {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'memory-call-$calls',
                  'type': 'function',
                  'function': {'name': name, 'arguments': jsonEncode(args)},
                },
              ],
            };
            finish = 'tool_calls';
          } else if (calls == 3 &&
              history.length == 2 &&
              jsonDecode(
                    history.last['content'] as String,
                  )['data']['value']['content'] ==
                  expected) {
            delta = {'content': expected};
            finish = 'stop';
          } else {
            throw StateError('Missing actual memory output');
          }
        } else if (askFirst && calls == 1) {
          delta = {
            'tool_calls': [
              {
                'index': 0,
                'id': 'native-question',
                'type': 'function',
                'function': {
                  'name': 'ask_user',
                  'arguments': '{"questions":[{"prompt":"Which file should I read?","choices":["proof.txt","other.txt"]}]}',
                },
              },
            ],
          };
          finish = 'tool_calls';
        } else if (calls == (askFirst ? 2 : 1)) {
          if (askFirst) {
            final messages = input['messages'] as List<dynamic>;
            if (!messages.any(
              (m) =>
                  m['role'] == 'tool' &&
                  m['tool_call_id'] == 'native-question' &&
                  jsonEncode(jsonDecode(m['content'] as String)) ==
                      '{"answers":["proof.txt"]}',
            )) {
              throw StateError('Actual committed user answer missing');
            }
          }
          delta = {
            'tool_calls': [
              {
                'index': 0,
                'id': 'native-fixture-call',
                'type': 'function',
                'function': {
                  'name': 'read_file',
                  'arguments': jsonEncode({'path': readPath}),
                },
              },
            ],
          };
          finish = 'tool_calls';
        } else if (editAfterRead && calls == (askFirst ? 3 : 2)) {
          final messages = input['messages'] as List<dynamic>;
          final prior = messages
              .where(
                (m) =>
                    m['role'] == 'tool' &&
                    m['tool_call_id'] == 'native-fixture-call',
              )
              .toList();
          if (prior.length != 1 ||
              !(input['tools'] as List<dynamic>).any(
                (t) => t['function']['name'] == 'apply_patch',
              )) {
            throw StateError(
              'Missing read result or explicit editing capability',
            );
          }
          final result = jsonDecode(
            prior.single['content'] as String,
          ) as Map<String, dynamic>;
          if (result['data']['content'] != expected) {
            throw StateError('Wrong actual read result');
          }
          delta = {
            'tool_calls': [
              {
                'index': 0,
                'id': 'native-edit-call',
                'type': 'function',
                'function': {
                  'name': 'apply_patch',
                  'arguments': jsonEncode({
                    'path': readPath,
                    'expected_sha256': result['data']['sha256'],
                    'patch':
                        '@@ -1 +1 @@\n-$expected\n\\ No newline at end of file\n+${expected}_EDITED\n\\ No newline at end of file\n',
                  }),
                },
              },
            ],
          };
          finish = 'tool_calls';
        } else if (createAfterRead && calls == (askFirst ? 3 : 2)) {
          final messages = input['messages'] as List<dynamic>;
          if (!messages.any(
            (m) =>
                m['role'] == 'tool' &&
                m['tool_call_id'] == 'native-fixture-call' &&
                (m['content'] as String).contains(expected),
          )) {
            throw StateError('Actual source result missing before creation');
          }
          if (!(input['tools'] as List<dynamic>).any(
            (t) => t['function']['name'] == 'write_file',
          )) {
            throw StateError(
              'Creation capability was not explicitly negotiated',
            );
          }
          delta = {
            'tool_calls': [
              {
                'index': 0,
                'id': 'native-create-call',
                'type': 'function',
                'function': {
                  'name': 'write_file',
                  'arguments': jsonEncode({
                    'path': 'created.txt',
                    'content': expected,
                  }),
                },
              },
            ],
          };
          finish = 'tool_calls';
        } else if (calls ==
            (askFirst ? 3 : 2) + ((createAfterRead || editAfterRead) ? 1 : 0)) {
          final messages = input['messages'] as List<dynamic>;
          if (!messages.any(
            (m) =>
                m['role'] == 'tool' &&
                (m['content'] as String).contains(expected),
          )) {
            throw StateError('real tool result missing');
          }
          if (editAfterRead) {
            final results = messages
                .where(
                  (m) =>
                      m['role'] == 'tool' &&
                      m['tool_call_id'] == 'native-edit-call',
                )
                .toList();
            if (results.length != 1) {
              throw StateError('Missing committed edit receipt');
            }
            final edited = jsonDecode(
              results.single['content'] as String,
            ) as Map<String, dynamic>;
            if (edited['kind'] != 'apply_patch' ||
                edited['data']['path'] != readPath ||
                (edited['data'] as Map).containsKey('retained_original')) {
              throw StateError('Wrong or private edit projection');
            }
          }
          if (createAfterRead) {
            final receipts = messages
                .where(
                  (m) =>
                      m['role'] == 'tool' &&
                      m['tool_call_id'] == 'native-create-call',
                )
                .toList();
            if (receipts.length != 1) {
              throw StateError('Missing single committed creation receipt');
            }
            final receipt = jsonDecode(receipts.single['content'] as String);
            if (receipt['kind'] != 'write_file' ||
                receipt['data']['path'] != 'created.txt') {
              throw StateError('Wrong creation receipt');
            }
          }
          delta = {'content': 'Native fixture observed: $expected'};
          finish = 'stop';
        } else {
          throw StateError('unexpected replay');
        }
        request.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/event-stream; charset=utf-8',
        );
        final id = 'native-response-$calls';
        request.response.write(
          'data: ${jsonEncode({
            'id': id,
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': null},
            ],
          })}\n\n',
        );
        request.response.write(
          'data: ${jsonEncode({
            'id': id,
            'choices': [
              {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': finish},
            ],
            'usage': {'prompt_tokens': 4, 'completion_tokens': 4},
          })}\n\ndata: [DONE]\n\n',
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    } catch (error) {
      failures.add(error.toString());
      request.response.statusCode = 500;
      await request.response.close();
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    await ipc.delete(recursive: true);
  }
}
