enum OfflineRuleScope { work, shelf }

/// Device-local selection; shelf IDs refer to existing saved query views.
final class OfflineRule {
  const OfflineRule({
    required this.scope,
    required this.targetId,
    this.nextFiles = 3,
  });
  final OfflineRuleScope scope;
  final String targetId;
  final int nextFiles;
  String get key => '${scope.name}:$targetId';

  Map<String, Object?> toJson() => {
    'scope': scope.name,
    'target_id': targetId,
    'next_files': nextFiles,
  };
  static OfflineRule fromJson(Object? value) {
    if (value is! Map ||
        value['target_id'] is! String ||
        value['next_files'] is! int) {
      throw const FormatException('Ungültige Offline-Auswahl.');
    }
    final scope = OfflineRuleScope.values
        .where((item) => item.name == value['scope'])
        .firstOrNull;
    final target = value['target_id'] as String;
    final count = value['next_files'] as int;
    if (scope == null ||
        target.isEmpty ||
        target.length > 512 ||
        count < 1 ||
        count > 500) {
      throw const FormatException('Ungültige Offline-Auswahl.');
    }
    return OfflineRule(scope: scope, targetId: target, nextFiles: count);
  }
}
