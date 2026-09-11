/// Configuration for Mapbox Maps and Directions API.
class MapboxConfig {
  const MapboxConfig({required this.accessToken});

  const MapboxConfig.fromEnvironment()
    : accessToken = const String.fromEnvironment(
        'MAPBOX_ACCESS_TOKEN',
        defaultValue:
            'pk.eyJ1IjoiZGFuaWxvcHBzcyIsImEiOiJjbXR4YmMzNHAwM2szMnpvdjh5NzBia2ZmIn0.EFrchT9m-R5JcwmXJxNySg',
      );

  final String accessToken;

  /// High-resolution vector/raster streets tile URL template.
  String get streetsTileUrl =>
      'https://api.mapbox.com/styles/v1/mapbox/streets-v12/tiles/256/{z}/{x}/{y}@2x?access_token=$accessToken';

  /// Navigation-optimized daytime tile URL template.
  String get navigationTileUrl =>
      'https://api.mapbox.com/styles/v1/mapbox/navigation-day-v1/tiles/256/{z}/{x}/{y}@2x?access_token=$accessToken';

  /// Returns true if an access token is configured.
  bool get hasToken => accessToken.trim().isNotEmpty;
}
