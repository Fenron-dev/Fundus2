/// Set by GitHub for every distributed preview; local tests stay explicit.
abstract final class BuildInfo {
  static const version = String.fromEnvironment(
    'FUNDUS_VERSION',
    defaultValue: '0.1.0-dev',
  );
  static const commit = String.fromEnvironment(
    'FUNDUS_COMMIT',
    defaultValue: 'lokal',
  );
  static const number = String.fromEnvironment(
    'FUNDUS_BUILD',
    defaultValue: '—',
  );
  static String get label =>
      '$version · Build $number · ${commit.length > 12 ? commit.substring(0, 12) : commit}';
}
