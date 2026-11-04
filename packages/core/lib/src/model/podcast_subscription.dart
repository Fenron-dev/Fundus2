/// A podcast whose new episodes Fundus fetches on its own.
final class PodcastSubscription {
  const PodcastSubscription({
    required this.workId,
    required this.title,
    required this.feedUrl,
    required this.subscribedAt,
    this.keepLatest = 0,
    this.lastCheckedAt,
    this.lastError,
    this.seen = const {},
  });

  final String workId;
  final String title;
  final String feedUrl;

  /// Episodes published before this are the back catalogue, not new ones.
  final DateTime subscribedAt;

  /// 0 keeps every episode; otherwise only this many of the newest stay.
  final int keepLatest;
  final DateTime? lastCheckedAt;
  final String? lastError;

  /// Episode identities already handled, so none is fetched twice.
  final Set<String> seen;
}
