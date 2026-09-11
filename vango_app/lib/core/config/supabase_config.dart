class SupabaseConfig {
  const SupabaseConfig({required this.url, required this.publishableKey});

  const SupabaseConfig.fromEnvironment()
    : url = const String.fromEnvironment('SUPABASE_URL'),
      publishableKey = const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  final String url;
  final String publishableKey;

  void validate() {
    final parsedUrl = Uri.tryParse(url.trim());
    final hasValidScheme =
        parsedUrl?.scheme == 'http' || parsedUrl?.scheme == 'https';

    if (parsedUrl == null ||
        !parsedUrl.hasScheme ||
        !parsedUrl.hasAuthority ||
        !hasValidScheme) {
      throw ArgumentError.value(url, 'url', 'Must be an absolute HTTP(S) URL.');
    }

    if (publishableKey.trim().isEmpty) {
      throw ArgumentError.value(
        publishableKey,
        'publishableKey',
        'Must not be empty.',
      );
    }
  }
}
