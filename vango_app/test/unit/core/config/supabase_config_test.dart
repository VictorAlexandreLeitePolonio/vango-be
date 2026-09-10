import 'package:flutter_test/flutter_test.dart';
import 'package:vango_app/core/config/supabase_config.dart';

void main() {
  test('accepts an absolute Supabase URL and a publishable key', () {
    const config = SupabaseConfig(
      url: 'https://example.supabase.co',
      publishableKey: 'public-key',
    );

    expect(config.validate, returnsNormally);
  });

  test('rejects an empty publishable key', () {
    const config = SupabaseConfig(
      url: 'https://example.supabase.co',
      publishableKey: '',
    );

    expect(config.validate, throwsArgumentError);
  });

  test('rejects a non-HTTP Supabase URL', () {
    const config = SupabaseConfig(
      url: 'supabase.local',
      publishableKey: 'public-key',
    );

    expect(config.validate, throwsArgumentError);
  });
}
