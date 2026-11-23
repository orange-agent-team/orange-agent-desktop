/// Metadata carried by a marketplace job. Artifact access is resolved by the service.
enum JobInputKind { text, embedding, image, transcription }

Map<String, Object?> _fields(Object? value, Set<String> expected) {
  if (value is! Map<String, Object?> ||
      value.length != expected.length ||
      !expected.every(value.containsKey)) {
    throw const FormatException('Unexpected job input fields');
  }
  return value;
}

String _identifier(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 128 ||
      value.contains(RegExp(r'[^a-zA-Z0-9_.:\-]'))) {
    throw const FormatException('Invalid artifact identifier');
  }
  return value;
}

final class PinnedArtifactReference {
  const PinnedArtifactReference._(this.artifactId, this.versionId, this.sha256);

  final String artifactId;
  final String versionId;
  final String sha256;

  factory PinnedArtifactReference.fromJson(Object? value) {
    final fields = _fields(value, {'artifact_id', 'version_id', 'sha256'});
    final digest = fields['sha256'];
    if (digest is! String ||
        digest.length != 64 ||
        digest.contains(RegExp(r'[^a-f0-9]'))) {
      throw const FormatException('Invalid artifact digest');
    }
    return PinnedArtifactReference._(
      _identifier(fields['artifact_id']),
      _identifier(fields['version_id']),
      digest,
    );
  }

  Map<String, Object?> toJson() => {
    'artifact_id': artifactId,
    'version_id': versionId,
    'sha256': sha256,
  };
}

final class JobInputReference {
  const JobInputReference._(this.kind, this.source, this.durationMs);

  final JobInputKind kind;
  final PinnedArtifactReference source;
  final BigInt? durationMs;

  factory JobInputReference.fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('Expected job input object');
    }
    final kind = switch (value['kind']) {
      'text' => JobInputKind.text,
      'embedding' => JobInputKind.embedding,
      'image' => JobInputKind.image,
      'transcription' => JobInputKind.transcription,
      _ => throw const FormatException('Unknown job input kind'),
    };
    _fields(value, {
      'kind',
      'source',
      if (kind == JobInputKind.transcription) 'duration_ms',
    });
    BigInt? duration;
    if (kind == JobInputKind.transcription) {
      final text = value['duration_ms'];
      if (text is! String ||
          text.isEmpty ||
          text.length > 20 ||
          text.startsWith('0') ||
          text.contains(RegExp(r'[^0-9]'))) {
        throw const FormatException('Invalid transcription duration');
      }
      duration = BigInt.parse(text);
      if (duration.bitLength > 64) {
        throw const FormatException('Transcription duration exceeds u64');
      }
    }
    return JobInputReference._(
      kind,
      PinnedArtifactReference.fromJson(value['source']),
      duration,
    );
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'source': source.toJson(),
    if (durationMs != null) 'duration_ms': durationMs.toString(),
  };
}
