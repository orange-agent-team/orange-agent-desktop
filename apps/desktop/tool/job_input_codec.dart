// JSON peer for the pinned Rust protocol interop fixture.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:orange_desktop/job_input_reference.dart';

Future<void> main() async {
  final input = BytesBuilder(copy: false);
  await for (final chunk in stdin) {
    if (input.length + chunk.length > 1048576) {
      throw const FormatException('Fixture corpus exceeds 1 MiB');
    }
    input.add(chunk);
  }
  final cases = jsonDecode(utf8.decode(input.takeBytes())) as List<Object?>;
  final normalized = cases.map((value) {
    try {
      return JobInputReference.fromJson(value).toJson();
    } on FormatException {
      return null;
    }
  }).toList();
  stdout.write(jsonEncode(normalized));
}
