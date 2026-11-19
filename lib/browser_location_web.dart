import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<void> downloadAiInsightsBytes(
  Uint8List bytes,
  String filename,
  String mimeType,
) async {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  // Let the browser consume the object URL before releasing its memory.
  Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
}

// Only a display preference is persisted, never portfolio values or credentials.
bool readPortfolioPrivacyPreference() {
  try {
    return web.window.localStorage.getItem(
          'thesisforge.portfolio.privacy.v1',
        ) ==
        'on';
  } catch (_) {
    return true; // Do not reveal amounts when a saved preference cannot be read.
  }
}

bool writePortfolioPrivacyPreference(bool hidden) {
  try {
    web.window.localStorage.setItem(
      'thesisforge.portfolio.privacy.v1',
      hidden ? 'on' : 'off',
    );
    return true;
  } catch (_) {
    return false;
  }
}

String? _readCookieLanguage() {
  try {
    final raw = web.document.cookie;
    final match = RegExp(r'(?:^|;\s*)tf_lang=(zh|en)(?:;|$)', caseSensitive: false)
        .firstMatch(raw);
    return match?.group(1)?.toLowerCase();
  } catch (_) {
    return null;
  }
}

String? readAppLanguagePreference() {
  String? stored;
  try {
    stored = web.window.localStorage.getItem('thesisforge.language.v1');
  } catch (_) {}
  if (stored != null && stored.trim().isNotEmpty) return stored.trim();
  return _readCookieLanguage();
}

bool writeAppLanguagePreference(String code) {
  final normalized = code.trim().toLowerCase().startsWith('zh') ? 'zh' : 'en';
  var saved = false;
  try {
    web.window.localStorage.setItem('thesisforge.language.v1', normalized);
    saved = true;
  } catch (_) {}
  try {
    final host = web.window.location.hostname.toLowerCase();
    final domainAttr = host.endsWith('thesisforge.tech')
        ? '; Domain=.thesisforge.tech'
        : '';
    web.document.cookie =
        'tf_lang=$normalized; Path=/; Max-Age=31536000; SameSite=Lax$domainAttr';
    saved = true;
  } catch (_) {}
  try {
    web.document.documentElement?.setAttribute(
      'lang',
      normalized == 'zh' ? 'zh-CN' : 'en',
    );
  } catch (_) {}
  return saved;
}

Map<String, String> readBrowserQuery() => Uri.base.queryParameters;

String readBrowserPath() => Uri.base.path;

void replaceBrowserQuery(
  Map<String, String?> updates, {
  bool replaceCurrent = false,
}) {
  final current = Uri.base;
  final nextParams = Map<String, String>.from(current.queryParameters);
  for (final entry in updates.entries) {
    final value = entry.value?.trim() ?? '';
    if (value.isEmpty) {
      nextParams.remove(entry.key);
    } else {
      nextParams[entry.key] = value;
    }
  }

  final path = current.path.isEmpty ? '/' : current.path;
  final next = Uri(
    path: path,
    queryParameters: nextParams.isEmpty ? null : nextParams,
    fragment: current.fragment.isEmpty ? null : current.fragment,
  ).toString();

  final currentRelative =
      '$path${current.hasQuery ? '?${current.query}' : ''}${current.hasFragment ? '#${current.fragment}' : ''}';
  if (next == currentRelative) return;
  if (replaceCurrent) {
    web.window.history.replaceState(null, web.document.title, next);
  } else {
    web.window.history.pushState(null, web.document.title, next);
  }
}

void openBrowserPath(String path) {
  web.window.location.href = path;
}

void openExternalUrl(String url) {
  try {
    final opened = web.window.open(url, '_blank', 'noopener,noreferrer');
    if (opened == null) {
      web.window.location.href = url;
    }
  } catch (_) {
    web.window.location.href = url;
  }
}

bool? debugStandaloneDisplayModeOverride;

bool isStandaloneDisplayMode() {
  if (debugStandaloneDisplayModeOverride != null) {
    return debugStandaloneDisplayModeOverride!;
  }
  try {
    if (web.window.matchMedia('(display-mode: standalone)').matches) {
      return true;
    }
  } catch (_) {}
  try {
    final nav = web.window.navigator as JSObject;
    final standalone = nav.getProperty<JSAny?>('standalone'.toJS);
    if (standalone != null &&
        standalone.isA<JSBoolean>() &&
        (standalone as JSBoolean).toDart) {
      return true;
    }
  } catch (_) {}
  return false;
}

bool isAppleMobileBrowser() {
  try {
    final ua = web.window.navigator.userAgent;
    if (RegExp(r'iPhone|iPad|iPod', caseSensitive: false).hasMatch(ua)) {
      return true;
    }
    final platform = web.window.navigator.platform;
    if (platform == 'MacIntel' && web.window.navigator.maxTouchPoints > 1) {
      return true;
    }
  } catch (_) {}
  return false;
}

bool _isSupabaseAuthStorageKey(String key) {
  final lower = key.toLowerCase();
  return (lower.startsWith('sb-') &&
          (lower.contains('auth-token') || lower.contains('code-verifier'))) ||
      lower.startsWith('supabase.auth.');
}

void _purgeStorageObject(web.Storage storage) {
  try {
    final keysToRemove = <String>[];
    for (var i = 0; i < storage.length; i++) {
      final key = storage.key(i);
      if (key != null && _isSupabaseAuthStorageKey(key)) {
        keysToRemove.add(key);
      }
    }
    for (final key in keysToRemove) {
      storage.removeItem(key);
    }
  } catch (_) {}
}

void stripBrowserAuthCallbackParams() {
  try {
    final current = Uri.base;
    const callbackKeys = {
      'code',
      'error',
      'error_code',
      'error_description',
      'state',
      'provider_token',
      'provider_refresh_token',
    };
    final nextParams = Map<String, String>.from(current.queryParameters);
    var changed = false;
    for (final key in callbackKeys) {
      if (nextParams.remove(key) != null) changed = true;
    }
    var nextFragment = current.fragment;
    if (nextFragment.contains('access_token=') ||
        nextFragment.contains('refresh_token=') ||
        nextFragment.contains('error_description=')) {
      nextFragment = '';
      changed = true;
    }
    if (!changed) return;
    final path = current.path.isEmpty ? '/' : current.path;
    final next = Uri(
      path: path,
      queryParameters: nextParams.isEmpty ? null : nextParams,
      fragment: nextFragment.isEmpty ? null : nextFragment,
    ).toString();
    web.window.history.replaceState(null, web.document.title, next);
  } catch (_) {}
}

void purgeBrowserAuthPersistence() {
  _purgeStorageObject(web.window.localStorage);
  _purgeStorageObject(web.window.sessionStorage);
  stripBrowserAuthCallbackParams();
}

StreamSubscription<dynamic>? listenBrowserAuthStorageChanges(
  void Function() onChanged,
) {
  try {
    return web.EventStreamProviders.storageEvent
        .forTarget(web.window)
        .listen((web.StorageEvent event) {
          final key = event.key;
          if (key == null || _isSupabaseAuthStorageKey(key)) {
            onChanged();
          }
        });
  } catch (_) {
    return null;
  }
}
