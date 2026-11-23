import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/job_input_reference.dart';

void main() {
  final fixture = File('../../contracts/fixtures/job-input-interop.v1.json');
  final cases = jsonDecode(fixture.readAsStringSync()) as List<Object?>;
  for (final row in cases.cast<Map<String, Object?>>()) {
    test('job input reference ${row['name']}', () {
      if (row['accepted'] == true) {
        final input = JobInputReference.fromJson(row['wire']);
        expect(input.toJson(), equals(row['wire']));
      } else {
        expect(
          () => JobInputReference.fromJson(row['wire']),
          throwsFormatException,
        );
      }
    });
  }
}
