import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class _AdminAccessApi extends ApiClient {
  _AdminAccessApi() : super(() => 'test-session');

  final paths = <String>[];
  Completer<Map<String, dynamic>>? pendingAdmin;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    paths.add(path);
    if (path == '/api/admin/portfolio-users') {
      if (pendingAdmin != null) return pendingAdmin!.future;
      return {
        'summary': {'users': 0, 'linked': 0, 'accounts': 0, 'errors': 0},
        'users': <Map<String, dynamic>>[],
      };
    }
    if (path == '/api/admin/system-health') {
      return {'status': 'success', 'jobs': <Map<String, dynamic>>[]};
    }
    return {'gurus': <Map<String, dynamic>>[]};
  }
}

Widget _terminal(
  _AdminAccessApi api, {
  String email = 'luyudong1136@gmail.com',
  String token = 'test-session',
  String userId = 'owner-id',
  String view = 'admin',
  AppLanguage language = AppLanguage.en,
}) => MaterialApp(
  home: TerminalHome(
    key: const ValueKey('same-terminal-state'),
    api: api,
    accessToken: token,
    userId: userId,
    userName: 'Test user',
    userEmail: email,
    language: language,
    routeUri: Uri.parse('http://localhost/?view=$view&lang=${language.name}'),
    onLanguage: (_) {},
    onLogout: () {},
  ),
);

void main() {
  test('admin presentation requires the exact owner and a non-dev session', () {
    expect(
      canShowAdmin(email: ' LUYUDONG1136@gmail.com ', accessToken: 'session'),
      isTrue,
    );
    for (final email in [
      '',
      'other@example.com',
      'luyudong1136+admin@gmail.com',
      'luyudong1136@gmail.com.attacker.test',
    ]) {
      expect(canShowAdmin(email: email, accessToken: 'session'), isFalse);
    }
    for (final token in ['', ' ', 'local-dev-token']) {
      expect(
        canShowAdmin(email: 'luyudong1136@gmail.com', accessToken: token),
        isFalse,
      );
    }
  });

  test('a disposed account client cannot read or retry as another user', () {
    var active = true;
    final api = ApiClient(() => 'owner-session', isSessionActive: () => active);
    expect(api.accessToken, 'owner-session');
    active = false;
    expect(() => api.accessToken, throwsStateError);
  });

  testWidgets('owner sees the existing admin console', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _AdminAccessApi();
    await tester.pumpWidget(_terminal(api));
    await tester.pumpAndSettle();
    expect(find.byType(AdminPortfolioDashboard), findsOneWidget);
    expect(find.byType(InvestmentWorkspace), findsOneWidget);
    expect(find.byType(TerminalHeader), findsNothing);
    expect(find.text('Portfolio admin console'), findsOneWidget);
    expect(api.paths, contains('/api/admin/portfolio-users'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('admin returns through the shared workspace navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _AdminAccessApi();
    await tester.pumpWidget(_terminal(api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home').first);
    await tester.pumpAndSettle();
    expect(find.byType(AdminPortfolioDashboard), findsNothing);
    expect(
      find.byType(InvestmentWorkspace),
      investmentWorkflowEnabled ? findsOneWidget : findsNothing,
    );
    expect(
      find.byType(TerminalHeader),
      investmentWorkflowEnabled ? findsNothing : findsOneWidget,
    );
    await tester.tap(find.text('Admin').first);
    await tester.pumpAndSettle();
    expect(find.byType(AdminPortfolioDashboard), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('non-owner, local preview and signed-out deep links deny admin', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final identity in [
      ('other@example.com', 'session'),
      ('luyudong1136@gmail.com', 'local-dev-token'),
      ('luyudong1136@gmail.com', ''),
    ]) {
      final api = _AdminAccessApi();
      await tester.pumpWidget(
        _terminal(api, email: identity.$1, token: identity.$2),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AdminPortfolioDashboard), findsNothing);
      expect(find.text('Admin'), findsNothing);
      expect(
        api.paths.where((path) => path.startsWith('/api/admin/')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('switching accounts discards cached admin view immediately', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _AdminAccessApi();
    await tester.pumpWidget(_terminal(api));
    await tester.pumpAndSettle();
    expect(find.byType(AdminPortfolioDashboard), findsOneWidget);
    final previousAdminCalls = api.paths
        .where((path) => path.startsWith('/api/admin/'))
        .length;
    await tester.pumpWidget(
      _terminal(api, email: 'other@example.com', userId: 'other-id'),
    );
    expect(find.byType(AdminPortfolioDashboard), findsNothing);
    expect(find.text('Admin'), findsNothing);
    await tester.pumpAndSettle();
    expect(
      api.paths.where((path) => path.startsWith('/api/admin/')).length,
      previousAdminCalls,
    );
    await tester.pumpWidget(_terminal(api));
    await tester.pumpAndSettle();
    expect(find.byType(AdminPortfolioDashboard), findsOneWidget);
    expect(
      api.paths.where((path) => path == '/api/admin/portfolio-users').length,
      2,
    );
    await tester.pumpWidget(_terminal(api, token: ''));
    expect(find.byType(AdminPortfolioDashboard), findsNothing);
    expect(find.text('Admin'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late owner response cannot restore admin after account switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _AdminAccessApi();
    api.pendingAdmin = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(_terminal(api));
    await tester.pump();
    await tester.pumpWidget(
      _terminal(api, email: 'other@example.com', userId: 'other-id'),
    );
    api.pendingAdmin!.complete({
      'summary': {'users': 1},
      'users': [
        {'userHash': 'private-owner', 'email': 'sensitive-user@example.com'},
      ],
    });
    await tester.pumpAndSettle();
    expect(find.byType(AdminPortfolioDashboard), findsNothing);
    expect(find.textContaining('sensitive-user@example.com'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [390.0, 1280.0]) {
    for (final language in AppLanguage.values) {
      testWidgets('integrated admin fits $width / $language', (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          _terminal(_AdminAccessApi(), language: language),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AdminPortfolioDashboard), findsOneWidget);
        expect(find.byType(InvestmentWorkspace), findsOneWidget);
        expect(find.byType(TerminalHeader), findsNothing);
        expect(
          find.image(const AssetImage(thesisForgeMarkAsset)),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
      testWidgets('workspace admin entry is gated at $width / $language', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, width == 390 ? 844 : 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? target;
        for (final showAdmin in [false, true]) {
          await tester.pumpWidget(
            MaterialApp(
              home: LanguageScope(
                language: language,
                child: InvestmentWorkspace(
                  api: _AdminAccessApi(),
                  palette: Palette(false),
                  initialPage: 'home',
                  initialTicker: '',
                  onLanguage: (_) {},
                  onLegacy: () {},
                  onLegacyView: (mode) => target = mode,
                  showAdmin: showAdmin,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final label = language == AppLanguage.en ? 'Admin' : '管理';
          expect(find.text(label), showAdmin ? findsOneWidget : findsNothing);
          if (showAdmin) {
            await tester.tap(find.text(label));
            await tester.pumpAndSettle();
            expect(target, 'admin');
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }
      });
    }
  }
}
