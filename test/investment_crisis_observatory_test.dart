import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guru_analysis_terminal/main.dart';

class CrisisObservatoryFixtureApi extends ApiClient {
  CrisisObservatoryFixtureApi() : super(() => 'test');

  static Map<String, dynamic>? _cachedArtifact;
  static Map<String, dynamic> get artifact => _cachedArtifact ??=
      jsonDecode(
            File(
              'server/config/crisis-observatory-dashboard.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  final calls = <String>[];

  static List<Map<String, dynamic>> _unpackTable(dynamic rawVal) {
    if (rawVal is List) {
      return rawVal
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (rawVal is Map &&
        rawVal['_cols'] is List &&
        rawVal['_rows'] is List) {
      final cols = (rawVal['_cols'] as List).map((e) => e.toString()).toList();
      final rows = rawVal['_rows'] as List;
      return rows.map((row) {
        final rList = row as List;
        final obj = <String, dynamic>{};
        for (var i = 0; i < cols.length; i++) {
          obj[cols[i]] = i < rList.length ? rList[i] : null;
        }
        return obj;
      }).toList();
    }
    return const [];
  }

  static Map<String, List<Map<String, dynamic>>> _unpackLedgerMap(
    dynamic rawMap,
  ) {
    if (rawMap is! Map) return const {};
    return {
      for (final entry in rawMap.entries)
        entry.key.toString(): _unpackTable(entry.value),
    };
  }

  static List<Map<String, dynamic>> _synthesizeEvents(
    String strategyId,
    List<Map<String, dynamic>> ledger,
  ) {
    final events = <Map<String, dynamic>>[];
    for (final tr in ledger) {
      final isNk = tr['tranche_type'] == 'naked_put';
      final evType = isNk ? 'slot1_naked_put' : 'slot${tr['slot_num']}_collar';
      events.add({
        'event_id': '${strategyId}_tr${tr['tranche_id']}_open',
        'tranche_id': tr['tranche_id'],
        'strategy_id': strategyId,
        'date': tr['entry_date'],
        'event_type': evType,
        'tranche_type': tr['tranche_type'],
        'spot': tr['entry_spot'],
        'kp': tr['kp'],
        'kc': tr['kc'],
      });
      final exitReason = (tr['exit_reason'] ?? '').toString();
      final isOpenLive = tr['is_open_live'] == true;
      final isLiveArmed = exitReason == 'live_tp_armed_next_open';
      final evExitDate = !isOpenLive ? tr['exit_date'] : tr['mtm_date'];
      if ((!isOpenLive || isLiveArmed) && evExitDate != null) {
        final isPut5x = exitReason.contains('put_5x');
        final isItmTp = exitReason.contains('itm_tp');
        final is4xTp = exitReason.contains('4x_tp');
        final isTp = exitReason.contains('tp') && !isOpenLive;
        final evTypeExit = isLiveArmed
            ? 'live_tp_armed'
            : (isPut5x
                  ? 'put5x_dte45_tp'
                  : (isItmTp
                        ? 'vix110_itm_tp'
                        : (is4xTp
                              ? 'vix110_4x_tp'
                              : (isTp ? 'vix110_tp' : 'option_expiry'))));
        events.add({
          'event_id': '${strategyId}_tr${tr['tranche_id']}_exit',
          'tranche_id': tr['tranche_id'],
          'strategy_id': strategyId,
          'date': evExitDate,
          'event_type': evTypeExit,
          'tranche_type': tr['tranche_type'],
          'spot': tr['exit_spot'],
          'kp': tr['kp'],
          'kc': tr['kc'],
          'net_pnl_usd': tr['net_pnl_usd'],
          'shares_added': tr['shares_added'],
        });
      }
    }
    return events;
  }

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    calls.add(path);
    final uri = Uri.parse(path);
    if (uri.path == '/api/investment/crisis-observatory' ||
        uri.path == '/api/discover/crisis-observatory') {
      final raw = Map<String, dynamic>.from(artifact);
      final qp = uri.queryParameters;
      final strat = qp['strategy'] ?? 'U1_PureOptions';
      final tpMode = qp['tpMode'] ?? raw['default_tp_mode'] ?? 'layered_itm';
      final ccMode = qp['ccMode'] ?? raw['default_cc_mode'] ?? 'cc_off';
      final spMode = qp['spMode'] ?? raw['default_sp_mode'] ?? 'sp_off';
      final defaultWc = (raw['default_wc_mode'] ?? 'wc_30d_c5s5').toString();
      final wcMode = (qp['wcMode'] ?? defaultWc).toString();
      final modeBundles = raw['mode_bundles'] as Map<String, dynamic>?;
      final tpModes = raw['tp_modes'] as Map<String, dynamic>?;
      final bundleKey = spMode == 'sp_off'
          ? '${tpMode}__$ccMode'
          : (wcMode == defaultWc
                ? '${tpMode}__${ccMode}__$spMode'
                : '${tpMode}__${ccMode}__${spMode}__$wcMode');
      final dynamic rawBundle =
          (modeBundles != null
              ? (modeBundles[bundleKey] ??
                    modeBundles['${tpMode}__${ccMode}__${spMode}__$wcMode'] ??
                    modeBundles['${tpMode}__${ccMode}__$spMode'])
              : null) ??
          (ccMode == 'cc_off' && spMode == 'sp_off' && tpModes != null
              ? tpModes[tpMode]
              : null);
      final bundle = rawBundle as Map<String, dynamic>?;
      final baseSeries = raw['daily_series'] as List<dynamic>;
      final isDefault =
          tpMode == raw['default_tp_mode'] &&
          ccMode == raw['default_cc_mode'] &&
          spMode == (raw['default_sp_mode'] ?? 'sp_off');
      final projectedSeries = (bundle != null && !isDefault)
          ? List<Map<String, dynamic>>.generate(baseSeries.length, (i) {
              final row = Map<String, dynamic>.from(baseSeries[i] as Map);
              row['nav_u1'] = (bundle['nav_u1'] as List)[i];
              row['nav_b1c'] = (bundle['nav_b1c'] as List)[i];
              row['nav_d2'] = (bundle['nav_d2'] as List)[i];
              row['nav_h2'] = (bundle['nav_h2'] as List)[i];
              row['nav_cc'] = (bundle['nav_cc'] as List)[i];
              return row;
            })
          : baseSeries;
      final baseWindows = (raw['crisis_windows'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final baseWinById = {for (final w in baseWindows) w['id'].toString(): w};
      final hydratedWindows = bundle != null && bundle['crisis_windows'] is List
          ? (bundle['crisis_windows'] as List).map((wItem) {
              final wMap = Map<String, dynamic>.from(wItem as Map);
              final base = baseWinById[wMap['id']?.toString() ?? ''] ?? const {};
              return {...base, ...wMap};
            }).toList()
          : baseWindows;

      final tradeLedgers = bundle != null
          ? _unpackLedgerMap(bundle['trade_ledgers_by_strategy'])
          : _unpackLedgerMap(raw['trade_ledgers_by_strategy']);
      final ccLedgers = bundle != null
          ? _unpackLedgerMap(bundle['cc_ledgers_by_strategy'])
          : _unpackLedgerMap(raw['cc_ledgers_by_strategy']);
      final spLedgers = bundle != null
          ? _unpackLedgerMap(bundle['sp_ledgers_by_strategy'])
          : _unpackLedgerMap(raw['sp_ledgers_by_strategy']);
      final eventsByStrat = bundle != null && bundle['events_by_strategy'] is Map
          ? bundle['events_by_strategy']
          : {
              for (final e in tradeLedgers.entries)
                e.key: _synthesizeEvents(e.key, e.value),
            };
      final ledgerStrat = strat == 'BH_Pure_QQQ' ? 'U1_PureOptions' : strat;

      final out = Map<String, dynamic>.from(raw)
        ..remove('tp_modes')
        ..remove('mode_bundles');
      return {
        ...out,
        if (bundle != null) ...{
          'live_signal_state': bundle['live_signal_state'],
          'live_signal_states_by_strategy': bundle['live_signal_states_by_strategy'],
          'live_sp_state': bundle['live_sp_state'],
          'live_sp_states_by_strategy': bundle['live_sp_states_by_strategy'],
          'strategies_summary': bundle['strategies_summary'],
          'events_by_strategy': eventsByStrat,
          'trade_ledgers_by_strategy': tradeLedgers,
          'cc_ledgers_by_strategy': ccLedgers,
          'sp_ledgers_by_strategy': spLedgers,
          'sp_ledger': spLedgers[ledgerStrat] ?? const <dynamic>[],
          'crisis_windows': hydratedWindows,
          'daily_series': projectedSeries,
        },
        'tp_mode': tpMode,
        'cc_mode': ccMode,
        'sp_mode': spMode,
        'wc_mode': spMode == 'sp_off' ? defaultWc : wcMode,
        'snapshotId': 'fixture-crisis-v3-three-engine',
        'requestedAsOf': qp['asOf'] ?? raw['as_of_date'],
        'selected_strategy_id': strat,
        'liveExtended': false,
      };
    }
    return {
      'asOf': '2026-11-20',
      'rows': const <dynamic>[],
      'gurus': const <dynamic>[],
    };
  }
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Discover renders minimalist Crisis Observatory via ?discoverTab=crisis_observatory with plain human copy, 6 signals, interactive chart hover & expandable timeline',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = CrisisObservatoryFixtureApi();
      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: InvestmentWorkspace(
              api: api,
              palette: Palette(false),
              initialPage: 'discover',
              initialTicker: '',
              initialAsOf: '2026-11-20',
              initialQuery: const {'discoverTab': 'crisis_observatory'},
              onLanguage: (_) {},
              onLegacy: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Crisis Observatory'), findsWidgets);
      expect(
        find.byKey(const ValueKey('crisis-observatory-root')),
        findsOneWidget,
      );
      expect(
        api.calls.any(
          (c) => c.contains('/api/investment/crisis-observatory'),
        ),
        isTrue,
      );

      // Zero raw internal engineering IDs or bond-timing clutter exposed on screen
      expect(find.textContaining('U4_DualEngine'), findsNothing);
      expect(find.textContaining('U1_PureOptions'), findsNothing);
      expect(find.textContaining('B1c_PureAD'), findsNothing);
      expect(find.textContaining('MONETIZED_STANDBY'), findsNothing);
      expect(find.textContaining('T-Bill'), findsNothing);

      // 1. Clean Verdict Header + 3-column pure-options hairline strip + expandable rules
      expect(
        find.byKey(const ValueKey('crisis-observatory-command-center')),
        findsOneWidget,
      );
      expect(
        find.text('Deep-ITM Panic Harvest Armed · Monetize Put Next Open (6/6 Lights)'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('crisis-slot-card-core')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-slot-card-slot1')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-slot-card-slot2')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-sp-live-badge')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-sp-mode-bar')), findsOneWidget);
      // Wheel Call selector stays hidden when Engine 3 is OFF
      expect(find.byKey(const ValueKey('crisis-wc-mode-bar')), findsNothing);

      await tapVisible(tester, find.byKey(const ValueKey('crisis-rules-toggle')));
      expect(find.textContaining('Execution rules:'), findsOneWidget);

      // 2. Minimalist Six Crisis Signals flat grid + AD Line footer
      expect(find.text('6 / 6 Active'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('crisis-light-card-sig1_fed')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-light-card-sig4_copper')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-observatory-ad-banner')),
        findsOneWidget,
      );

      // 3. Hero Interactive Chart: exact U1 Layered ITM TP metrics + total shares & extra % + selectable TP & CC bars
      expect(find.text('\$1,654,577'), findsOneWidget);
      expect(find.text('+\$366,272'), findsOneWidget);
      expect(find.text('2,719.3 sh'), findsOneWidget);
      expect(find.textContaining('+28.4%'), findsWidgets);
      expect(find.text('-31.5%'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('crisis-tp-mode-bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-cc-mode-bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-observatory-canvas')),
        findsOneWidget,
      );

      // Switch selectable 4-way Normal-Time 25D 12Δ Covered Call modes live: Δ0.35 Stop -> Δ0.45 Roll -> Δ0.55 Credit Roll -> NoPut Call-Only -> Off
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-cc-mode-pill-cc_d12_d35')),
      );
      expect(find.text('\$1,714,947'), findsOneWidget);
      expect(find.text('2,818.6 sh'), findsOneWidget);
      expect(find.textContaining('+33.1%'), findsWidgets);
      expect(find.text('Sell Call (▲ Up)'), findsOneWidget);
      expect(find.text('Call Δ0.35 Stop'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-cc-ledger-toggle')),
      );
      expect(find.textContaining('Sold K='), findsWidgets);

      // Switch 3rd Engine (Panic Put Wheel) presets on Dual (U1 + layered_itm + cc_d12_d35):
      // Default Wheel Call is now 30D +5% Cost/Spot (wc_30d_c5s5):
      // - 14D 10% Cap + wc_30d_c5s5 ($1,819,738 · Calmar 0.685 · $1,481.18 · K >= $656.70)
      // - Compare toggle to 14D Breakeven+2% (wc_14d_c0s2 -> $1,779,823 · Calmar 0.677 · $816.85 · K >= $625.43)
      // - Switch back to wc_30d_c5s5 -> 10D VIX Falling ($1,831,563 · $1,257.35) -> 14D Unfiltered ($1,930,239 · +49.9%) -> Off
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-sp-mode-pill-sp_14d_cap10')),
      );
      expect(find.byKey(const ValueKey('crisis-wc-mode-bar')), findsOneWidget);
      expect(find.text('30D +5% Cost/Spot (Rec.)'), findsOneWidget);
      expect(find.text('14D Breakeven+2% (Legacy)'), findsOneWidget);
      expect(find.text('\$1,819,738'), findsOneWidget);
      expect(find.textContaining('Calmar 0.685'), findsWidgets);
      expect(find.textContaining('\$1,481.18'), findsWidgets);
      expect(find.textContaining('K >= \$656.70'), findsOneWidget);
      expect(find.text('Sell Panic Put'), findsOneWidget);
      expect(find.text('Wheel Assigned'), findsOneWidget);
      expect(find.text('Wheel Call Exit'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-sp-ledger-toggle')),
      );
      expect(find.text('Wheel Call'), findsWidgets);

      // Toggle Wheel Call comparison to Legacy 14D Breakeven+2% (wc_14d_c0s2) and back
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-wc-mode-pill-wc_14d_c0s2')),
      );
      expect(find.text('\$1,779,823'), findsOneWidget);
      expect(find.textContaining('Calmar 0.677'), findsWidgets);
      expect(find.textContaining('\$816.85'), findsWidgets);
      expect(find.textContaining('K >= \$625.43'), findsOneWidget);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-wc-mode-pill-wc_30d_c5s5')),
      );
      expect(find.text('\$1,819,738'), findsOneWidget);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-sp-mode-pill-sp_10d_vixf')),
      );
      expect(find.text('\$1,831,563'), findsOneWidget);
      expect(find.textContaining('\$1,257.35'), findsWidgets);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-sp-mode-pill-sp_14d_unf')),
      );
      expect(find.text('\$1,930,239'), findsOneWidget);
      expect(find.textContaining('+49.8%'), findsWidgets);

      // Verify Standalone Engine 3 on Pure QQQ (NoPut_CallOnly + cc_off + sp_14d_unf -> $1,449,832 on wc_30d_c5s5, $1,387,278 on wc_14d_c0s2)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-cc-mode-pill-cc_off')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-NoPut_CallOnly')),
      );
      expect(find.text('\$1,449,832'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-wc-mode-pill-wc_14d_c0s2')),
      );
      expect(find.text('\$1,387,278'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-wc-mode-pill-wc_30d_c5s5')),
      );

      // Restore U1 + cc_d12_d35 + sp_off so existing 2D assertions proceed unchanged
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-U1_PureOptions')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-cc-mode-pill-cc_d12_d35')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-sp-mode-pill-sp_off')),
      );
      expect(find.byKey(const ValueKey('crisis-wc-mode-bar')), findsNothing);
      expect(find.text('\$1,714,947'), findsOneWidget);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-cc-mode-pill-cc_d12_r45')),
      );
      expect(find.text('\$1,704,612'), findsOneWidget);
      expect(find.text('2,801.6 sh'), findsOneWidget);
      expect(find.textContaining('+32.3%'), findsWidgets);
      expect(find.text('Call Roll Up'), findsOneWidget);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-cc-mode-pill-cc_d12_cr55')),
      );
      expect(find.text('\$1,688,797'), findsOneWidget);
      expect(find.text('2,775.6 sh'), findsOneWidget);
      expect(find.textContaining('+31.1%'), findsWidgets);

      // Switch Put Strategy to NoPut_CallOnly (Call-only comparison) and back to U1
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-NoPut_CallOnly')),
      );
      expect(find.text('\$1,327,646'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-U1_PureOptions')),
      );

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-cc-mode-pill-cc_off')),
      );
      expect(find.text('\$1,654,577'), findsOneWidget);

      // Switch selectable Take-Profit modes live: Standard 1.10 -> Deep 4x Both -> back to Layered ITM
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-tp-mode-pill-standard_dual')),
      );
      expect(find.text('\$1,625,378'), findsOneWidget);
      expect(find.text('+\$337,073'), findsOneWidget);
      expect(
        find.text('100% Hold QQQ · Call Caps Paused in Pullback (6/6 Lights)'),
        findsOneWidget,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-tp-mode-pill-both_4x')),
      );
      expect(find.text('\$1,643,123'), findsOneWidget);
      expect(find.text('+\$354,818'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-tp-mode-pill-layered_itm')),
      );
      expect(find.text('\$1,654,577'), findsOneWidget);

      // Zoom into 2022 Slow Bear and verify Track-2 5x Slow-Bear Harvest (+$37,675 / -31.5% MDD)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-pill-2022')),
      );
      expect(find.text('2022 Rate-Hike Grinding Bear Market'), findsWidgets);
      expect(find.textContaining('5x Slow-Bear Harvest'), findsWidgets);
      expect(find.textContaining('+\$37,675'), findsWidgets);

      // Zoom into 2025 April Tariff Crash and hover 2025-04-07 1.10 Panic Harvest
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-pill-2025-04')),
      );
      expect(find.text('2025 April Tariff Crash'), findsWidgets);

      final canvasFinder = find.byKey(const ValueKey('crisis-observatory-canvas'));
      await tester.ensureVisible(canvasFinder);
      await tester.pumpAndSettle();
      final canvasRect = tester.getRect(canvasFinder);
      final hoverTarget = Offset(
        canvasRect.left + 52.0 + (canvasRect.width - 64.0) * (73.0 / 101.0),
        canvasRect.top + 120.0,
      );
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(hoverTarget);
      await tester.pumpAndSettle();

      final tooltipFinder = find.byKey(
        const ValueKey('crisis-chart-hover-tooltip'),
      );
      expect(tooltipFinder, findsOneWidget);
      expect(
        find.descendant(
          of: tooltipFinder,
          matching: find.textContaining('2025-04-07'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: tooltipFinder,
          matching: find.textContaining('◆ 1.10 Panic Harvest'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: tooltipFinder,
          matching: find.textContaining('+\$76,719'),
        ),
        findsOneWidget,
      );

      await gesture.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('crisis-chart-hover-tooltip')),
        findsNothing,
      );

      // Reset zoom to All 12Y and switch strategy tab to Breadth Divergence (B1c)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-reset-btn')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-B1c_PureAD')),
      );
      expect(find.text('\$1,587,801'), findsOneWidget);
      expect(find.text('+\$299,496'), findsOneWidget);

      // 4. Zoom into 2026 LIVE and expand a tranche row for 4-factor convexity
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-U1_PureOptions')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-pill-2026-08_11_LIVE')),
      );
      expect(
        find.byKey(const ValueKey('crisis-tranche-row-34')),
        findsOneWidget,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-tranche-row-34')),
      );
      expect(find.textContaining('Vega'), findsWidgets);

      // Toggle full 12-year chronological ledger
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-ledger-scope-toggle')),
      );
      expect(
        find.textContaining('All 12-Year Historical Operations'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Crisis Observatory renders calm localized Chinese UI cleanly on both Desktop (1440x1200) and Mobile (390x844) without overflow',
    (tester) async {
      final api = CrisisObservatoryFixtureApi();

      for (final size in [const Size(1440, 1200), const Size(390, 844)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          MaterialApp(
            home: LanguageScope(
              language: AppLanguage.zh,
              child: Scaffold(
                backgroundColor: const Color(0xFF06090F),
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(14),
                  child: CrisisObservatoryPanel(
                    api: api,
                    palette: Palette(false),
                    asOf: '2026-11-20',
                    onCompany: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('深跌实值恐慌触发 · 期权次日开盘止盈换股（6/6 亮灯）'),
          findsOneWidget,
        );
        expect(find.text('危机 Put 策略：'), findsOneWidget);
        expect(find.text('不买 Put（仅卖 Call）'), findsOneWidget);
        expect(find.text('Put 止盈规则：'), findsOneWidget);
        expect(find.text('叠加平时卖 Call：'), findsOneWidget);
        expect(find.text('恐慌卖 Put Wheel：'), findsOneWidget);
        expect(find.text('14D 10%帽（Calmar冠军 · 推荐）'), findsOneWidget);
        expect(find.text('10D VIX回落（20%帽）'), findsOneWidget);
        expect(find.text('14D 无过滤（20%帽 · 收益冠军）'), findsOneWidget);
        expect(find.text('分层实值（推荐）'), findsOneWidget);
        expect(find.text('标准 1.10'), findsOneWidget);
        expect(find.text('两槽 4x 深度'), findsOneWidget);
        expect(find.text('全天候 12Δ · Delta 0.35 止损（推荐 · 0穿最稳）'), findsOneWidget);
        expect(find.text('全天候 12Δ · Delta 0.45 展期 Roll（30D 上移）'), findsOneWidget);
        expect(find.text('全天候 12Δ · Delta 0.55 零成本 Roll（45D）'), findsOneWidget);
        expect(find.byKey(const ValueKey('crisis-active-combo-badge')), findsOneWidget);
        expect(find.text('6 / 6 亮灯'), findsOneWidget);
        expect(find.text('历史保护策略 vs 死拿 QQQ'), findsOneWidget);
        expect(find.text('100% 满仓 QQQ · 2,719.3 股'), findsOneWidget);
        expect(find.text('总股数 · 多买比例'), findsOneWidget);
        expect(find.textContaining('+28.4%'), findsWidgets);
        expect(find.textContaining('短债'), findsNothing);

        // Activate 14D 10% Cap on Chinese Desktop & Mobile (390x844), toggle 30D +5% <-> 14D Breakeven+2%, and expand Wheel Ledger to verify zero overflow
        await tapVisible(
          tester,
          find.byKey(const ValueKey('crisis-sp-mode-pill-sp_14d_cap10')),
        );
        expect(find.text('30D 双+5%（推荐）'), findsOneWidget);
        expect(find.text('14D 保本+2%（原基准）'), findsOneWidget);
        expect(find.textContaining('已接货进 Wheel'), findsOneWidget);
        expect(find.textContaining('K >= \$656.70'), findsOneWidget);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('crisis-wc-mode-pill-wc_14d_c0s2')),
        );
        expect(find.textContaining('K >= \$625.43'), findsOneWidget);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('crisis-wc-mode-pill-wc_30d_c5s5')),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('crisis-sp-ledger-toggle')),
        );
        expect(find.textContaining('恐慌卖 Put Wheel 实战明细'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('crisis-sp-mode-pill-sp_off')),
        );
      }

      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );

  testWidgets(
    'Crisis Observatory honors co_wcMode deep-link initialization and emits wcMode in onSelection when Engine 3 is active',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final api = CrisisObservatoryFixtureApi();
      Map<String, dynamic> latestSelection = const {};

      await tester.pumpWidget(
        MaterialApp(
          home: LanguageScope(
            language: AppLanguage.en,
            child: Scaffold(
              body: SingleChildScrollView(
                child: CrisisObservatoryPanel(
                  api: api,
                  palette: Palette(false),
                  asOf: '2026-11-20',
                  onCompany: (_) {},
                  initialSelection: const {
                    'strategy': 'U1_PureOptions',
                    'tpMode': 'layered_itm',
                    'ccMode': 'cc_d12_d35',
                    'spMode': 'sp_14d_cap10',
                    'wcMode': 'wc_14d_c0s2',
                  },
                  onSelection: (sel) => latestSelection = sel,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('\$1,779,823'), findsOneWidget);
      expect(find.textContaining('K >= \$625.43'), findsOneWidget);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-wc-mode-pill-wc_30d_c5s5')),
      );
      expect(find.text('\$1,819,738'), findsOneWidget);
      expect(find.textContaining('K >= \$656.70'), findsOneWidget);
      expect(latestSelection['spMode'], 'sp_14d_cap10');
      expect(latestSelection['wcMode'], 'wc_30d_c5s5');

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-sp-mode-pill-sp_off')),
      );
      expect(latestSelection['spMode'], 'sp_off');
      expect(latestSelection.containsKey('wcMode'), isFalse);
    },
  );
}
