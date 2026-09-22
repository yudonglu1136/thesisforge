import 'dart:typed_data';

Future<void> downloadAiInsightsBytes(
  Uint8List bytes,
  String filename,
  String mimeType,
) async {
  throw UnsupportedError('File downloads require the web application.');
}

Map<String, String> readBrowserQuery() => Uri.base.queryParameters;

bool _portfolioPrivacyPreference = false;
bool readPortfolioPrivacyPreference() => _portfolioPrivacyPreference;
bool writePortfolioPrivacyPreference(bool hidden) {
  _portfolioPrivacyPreference = hidden;
  return true;
}

String readBrowserPath() => Uri.base.path;

void replaceBrowserQuery(
  Map<String, String?> updates, {
  bool replaceCurrent = false,
}) {}

void openBrowserPath(String path) {}
