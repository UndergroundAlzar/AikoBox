import 'dart:convert';

enum ProfileSource { localFile, httpsUrl, pasted }

class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.json,
    required this.source,
    required this.createdAt,
    this.sourceHost,
    this.path,
  });

  factory Profile.fromJson(Map<String, Object?> map) {
    return Profile(
      id: map['id']! as String,
      name: map['name']! as String,
      json: map['json'] as String? ?? '',
      source: ProfileSource.values.byName(map['source']! as String),
      createdAt: DateTime.parse(map['createdAt']! as String),
      sourceHost: map['sourceHost'] as String?,
      path: map['path'] as String?,
    );
  }

  final String id;
  final String name;
  final String json;
  final ProfileSource source;
  final DateTime createdAt;
  final String? sourceHost;
  final String? path;

  Profile copyWith({String? path}) {
    return Profile(
      id: id,
      name: name,
      json: json,
      source: source,
      createdAt: createdAt,
      sourceHost: sourceHost,
      path: path ?? this.path,
    );
  }

  Map<String, Object?> toMetadataJson() => {
    'id': id,
    'name': name,
    'source': source.name,
    'createdAt': createdAt.toIso8601String(),
    'sourceHost': sourceHost,
    'path': path,
  };

  static String encodeList(List<Profile> profiles) {
    return jsonEncode(
      profiles.map((profile) => profile.toMetadataJson()).toList(),
    );
  }

  static List<Profile> decodeList(String value) {
    final decoded = jsonDecode(value) as List<Object?>;
    return decoded
        .map((item) => Profile.fromJson((item! as Map).cast<String, Object?>()))
        .toList(growable: false);
  }
}
