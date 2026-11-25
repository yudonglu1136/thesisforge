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
      final sNum = (tr['slot_num'] as num?)?.round() ?? 1;
      final evType = isNk
          ? (sNum == 1 ? 'slot1_naked_put' : 'slot${sNum}_naked_put')
          : 'slot${tr['slot_num']}_collar';
      events.add({
        'event_id': '${strategyId}_tr${tr['tranche_id']}_open',
        'tranche_id': tr['tranche_id'],
        'strategy_id': strategyId,
        'date': tr['entry_date'],
        'event_type': evType,
        'slot_num': sNum,
        'tranche_type': tr['tranche_type'],
        'spot': tr['entry_spot'],
        'kp': tr['kp'],
        'kc': tr['kc'],
        if (tr['crisis_prob'] != null) 'crisis_prob': tr['crisis_prob'],
      });
      final exitReason = (tr['exit_reason'] ?? '').toString();
      final isOpenLive = tr['is_open_live'] == true;
      final isLiveRollArmed =
          exitReason == 'live_roll50_armed_next_open' ||
          exitReason == 'live_roll30_armed_next_open';
      final isLiveArmed =
          exitReason == 'live_tp_armed_next_open' || isLiveRollArmed;
      final isRoll30 = exitReason == 'roll_30d';
      final isRoll50 = exitReason == 'roll_50d' || isRoll30;
      final evExitDate = !isOpenLive ? tr['exit_date'] : tr['mtm_date'];
      if ((!isOpenLive || isLiveArmed) && evExitDate != null) {
        final isPut5x = exitReason.contains('put_5x');
        final isItmTp = exitReason.contains('itm_tp');
        final is4xTp = exitReason.contains('4x_tp');
        final isTp = exitReason.contains('tp') && !isOpenLive;
        final evTypeExit = isLiveRollArmed
            ? (exitReason.contains('30')
                  ? 'live_roll30_armed'
                  : 'live_roll50_armed')
            : (isLiveArmed
                  ? 'live_tp_armed'
                  : (isRoll30
                        ? 'roll_30d'
                        : (isRoll50
                              ? 'roll_50d'
                              : (isPut5x
                                    ? 'put5x_dte45_tp'
                                    : (isItmTp
                                          ? 'vix110_itm_tp'
                                          : (is4xTp
                                                ? 'vix110_4x_tp'
                                                : (isTp
                                                      ? 'vix110_tp'
                                                      : 'option_expiry')))))));
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
          'exit_val_usd': tr['exit_val_usd'],
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
    if (uri.path == '/api/investment/crisis-observatory/pit' ||
        uri.path == '/api/discover/crisis-observatory/pit') {
      final raw = Map<String, dynamic>.from(artifact);
      final qp = uri.queryParameters;
      final reqDate = (qp['date'] ?? raw['as_of_date'] ?? '2026-11-20').toString();
      final series = (raw['daily_series'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      var idx = series.lastIndexWhere((r) => (r['date'] ?? '').toString().compareTo(reqDate) <= 0);
      if (idx < 0) idx = 0;
      final bar = series[idx];
      final pitDate = bar['date'].toString();
      final latestDate = series.last['date'].toString();
      final prevDate = idx > 0 ? series[idx - 1]['date'].toString() : null;
      final nextDate = idx + 1 < series.length ? series[idx + 1]['date'].toString() : null;
      final m7Mask = (bar['m7_mask'] as num?)?.toInt() ?? 0;
      final lightsMask = (bar['lights_mask'] as num?)?.toInt() ?? 0;
      final modOn = <String, bool>{
        'M0': (m7Mask & 1) != 0,
        'M6': (m7Mask & 2) != 0,
        'M2': (m7Mask & 4) != 0,
        'M5': (m7Mask & 8) != 0,
        'M4': (m7Mask & 16) != 0,
        'M3': (m7Mask & 32) != 0,
      };
      final pScores = <String, int>{
        'P1': (bar['m7_p1'] as num?)?.round() ?? 0,
        'P2': (bar['m7_p2'] as num?)?.round() ?? 0,
        'P3': (bar['m7_p3'] as num?)?.round() ?? 0,
      };
      final baseDash = Map<String, dynamic>.from(
        (raw['m7_live_dashboard'] as Map?) ?? const {},
      );
      final pitPillars = ((baseDash['pillars'] as List?) ?? const []).map((pil) {
        final pm = Map<String, dynamic>.from(pil as Map);
        final pid = pm['id'].toString();
        final mods = ((pm['modules'] as List?) ?? const []).map((m) {
          final mm = Map<String, dynamic>.from(m as Map);
          final mid = mm['id'].toString();
          final trig = modOn[mid] ?? false;
          final pts = (mm['points'] as num?)?.round() ?? 0;
          return <String, dynamic>{
            ...mm,
            'triggered': trig,
            'earned_points': trig ? pts : 0,
          };
        }).toList();
        return <String, dynamic>{
          ...pm,
          'score': pScores[pid] ?? 0,
          'modules': mods,
        };
      }).toList();
      final qqq = (bar['qqq_close'] as num?)?.toDouble() ?? 0.0;
      final vxn = (bar['vxn'] as num?)?.toDouble() ?? 0.0;
      final vr = (bar['vix_ratio'] as num?)?.toDouble() ?? 0.0;
      final dd = (bar['dd_ath_pct'] as num?)?.toDouble() ?? 0.0;
      final pitDash = <String, dynamic>{
        ...baseDash,
        'as_of_date': pitDate,
        'crisis_prob': (bar['m7_prob'] as num?)?.round() ?? 0,
        'p1_score': pScores['P1'],
        'p2_score': pScores['P2'],
        'p3_score': pScores['P3'],
        'target_slots': (bar['m7_target_slots'] as num?)?.round() ?? 0,
        'active_slots': (bar['m7_active_slots'] as num?)?.round() ?? 0,
        'redline': {
          ...Map<String, dynamic>.from((baseDash['redline'] as Map?) ?? const {}),
          'vxn': vxn,
          'vix_ratio': vr,
          'blocked': vxn > 27.0 || vr >= 1.02,
        },
        'sizing_calculator': {
          ...Map<String, dynamic>.from(
            (baseDash['sizing_calculator'] as Map?) ?? const {},
          ),
          'qqq_spot': qqq,
          'vxn': vxn,
        },
        'pillars': pitPillars,
      };
      final pitLights = ((raw['six_crisis_lights'] as List?) ?? const [])
          .asMap()
          .entries
          .map((e) {
            final lm = Map<String, dynamic>.from(e.value as Map);
            final lit = ((lightsMask >> e.key) & 1) != 0;
            return <String, dynamic>{
              ...lm,
              'lit': lit,
              'pit_historical': pitDate != latestDate,
              'reading_value': lit ? 'PIT ON' : 'PIT OFF',
            };
          })
          .toList();
      final c3Pillars = pitPillars.map((pm) {
        final pid = pm['id'].toString();
        final mods = ((pm['modules'] as List?) ?? const []).map((m) {
          final mm = Map<String, dynamic>.from(m as Map);
          final mid = mm['id'].toString();
          final disabled = mid == 'M2' || mid == 'M5' || mid == 'M3';
          return <String, dynamic>{
            ...mm,
            'disabled_in_core3': disabled,
            if (disabled) 'triggered': false,
            if (disabled) 'earned_points': 0,
            if (disabled) 'points': 0,
          };
        }).toList();
        return <String, dynamic>{
          ...pm,
          'disabled_in_core3': pid == 'P2',
          'score': pid == 'P1'
              ? ((bar['c3_p1'] as num?)?.round() ?? 0)
              : (pid == 'P3' ? ((bar['c3_p3'] as num?)?.round() ?? 0) : 0),
          'modules': mods,
        };
      }).toList();
      final pitC3Dash = <String, dynamic>{
        ...pitDash,
        'strategy_id': 'Core3_Adaptive',
        'crisis_prob': (bar['c3_prob'] as num?)?.round() ?? 0,
        'p1_score': (bar['c3_p1'] as num?)?.round() ?? 0,
        'p2_score': 0,
        'p3_score': (bar['c3_p3'] as num?)?.round() ?? 0,
        'target_slots': (bar['c3_target_slots'] as num?)?.round() ?? 0,
        'active_slots': (bar['c3_active_slots'] as num?)?.round() ?? 0,
        'pillars': c3Pillars,
      };
      final reqStrat = qp['strategy'] ??
          (qp['profile'] == 'core3_adaptive' ? 'Core3_Adaptive' : 'M7G_Graded');
      return {
        'pit_mode': true,
        'pit_date': pitDate,
        'latest_as_of_date': latestDate,
        'is_historical_pit': pitDate != latestDate,
        'prev_date': prevDate,
        'next_date': nextDate,
        'as_of_date': pitDate,
        'pit_bar': bar,
        'live_market_snapshot': {
          ...Map<String, dynamic>.from(
            (raw['live_market_snapshot'] as Map?) ?? const {},
          ),
          'as_of_date': pitDate,
          'qqq_close': qqq,
          'dd_from_ath_pct': dd,
          'vxn': vxn,
          'vix': bar['vix'],
          'vix3m': bar['vix3m'],
          'vix_vix3m_ratio': vr,
          'raw_crisis_score': bar['crisis_lights'],
        },
        'm7_live_dashboard': reqStrat == 'Core3_Adaptive' ? pitC3Dash : pitDash,
        'm7_live_dashboards_by_strategy': {
          'M7G_Graded': pitDash,
          'Core3_Adaptive': pitC3Dash,
          'M7_Ensemble': pitDash,
        },
        'six_crisis_lights': pitLights,
        'ad_line_signal': {
          ...Map<String, dynamic>.from(
            (raw['ad_line_signal'] as Map?) ?? const {},
          ),
          'ad_line': bar['ad_line'],
          'ad_sma50': bar['ad_sma50'],
          'below_50ma':
              ((bar['ad_line'] as num?)?.toDouble() ?? 0) <
              ((bar['ad_sma50'] as num?)?.toDouble() ?? 0),
          'last_top_divergence_date': '',
        },
      };
    }
    if (uri.path == '/api/investment/crisis-observatory' ||
        uri.path == '/api/discover/crisis-observatory') {
      final raw = Map<String, dynamic>.from(artifact);
      final qp = uri.queryParameters;
      final rawProfile = (qp['profile'] ?? qp['co_profile'] ?? '').toString();
      final strat = qp['strategy'] ??
          (rawProfile == 'core3_adaptive' ? 'Core3_Adaptive' : 'M7G_Graded');
      final profile = strat == 'Core3_Adaptive'
          ? 'core3_adaptive'
          : 'full_m7_adaptive';
      final putOtm = qp['putOtm'] ?? raw['default_put_otm'] ?? 'otm15';
      final m7TpMode = qp['m7TpMode'] ?? raw['default_m7_tp_mode'] ?? 'standard';
      final rawRoll =
          (qp['rollMode'] ?? raw['default_roll_mode'] ?? 'adaptive_120_90')
              .toString();
      final rollMode = (strat == 'Core3_Adaptive' && rawRoll == '90d_hold')
          ? 'adaptive_120_90'
          : rawRoll;
      final m0Enabled = (qp['m0Enabled'] ?? 'true') != 'false';
      final tpMode = qp['tpMode'] ?? raw['default_tp_mode'] ?? 'layered_itm';
      final ccMode = qp['ccMode'] ?? raw['default_cc_mode'] ?? 'cc_off';
      final spMode = qp['spMode'] ?? raw['default_sp_mode'] ?? 'sp_off';
      final defaultWc =
          (raw['default_wc_mode'] ?? 'wc_reclaim_30d_d35').toString();
      final wcMode = (qp['wcMode'] ?? defaultWc).toString();

      final m0Tag = m0Enabled ? 'm0on' : 'm0off';
      final m7BaseKey = '${putOtm}__${m7TpMode}__${rollMode}__$m0Tag';
      final m7Bundles = raw['m7_bundles'] as Map<String, dynamic>?;
      final m7Base = m7Bundles != null
          ? m7Bundles[m7BaseKey] as Map<String, dynamic>?
          : null;

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
      final projectedSeries = List<Map<String, dynamic>>.generate(
        baseSeries.length,
        (i) {
          final row = Map<String, dynamic>.from(baseSeries[i] as Map);
          if (m7Base != null) {
            final navM7g = m7Base['nav_m7g'] as List?;
            final navC3 = m7Base['nav_c3'] as List?;
            final navM7 = m7Base['nav_m7'] as List?;
            if (navM7g != null && i < navM7g.length) row['nav_m7g'] = navM7g[i];
            if (navC3 != null && i < navC3.length) row['nav_c3'] = navC3[i];
            if (navM7 != null && i < navM7.length) row['nav_m7'] = navM7[i];
          }
          if (bundle != null) {
            row['nav_u1'] = (bundle['nav_u1'] as List)[i];
            row['nav_b1c'] = (bundle['nav_b1c'] as List)[i];
            row['nav_d2'] = (bundle['nav_d2'] as List)[i];
            row['nav_h2'] = (bundle['nav_h2'] as List)[i];
            row['nav_cc'] = (bundle['nav_cc'] as List)[i];
          }
          return row;
        },
      );

      final baseWindows = (raw['crisis_windows'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final baseWinById = {for (final w in baseWindows) w['id'].toString(): w};
      final hydratedWindows =
          (bundle != null && bundle['crisis_windows'] is List
                  ? (bundle['crisis_windows'] as List).map((wItem) {
                      final wMap = Map<String, dynamic>.from(wItem as Map);
                      final base =
                          baseWinById[wMap['id']?.toString() ?? ''] ?? const {};
                      return {...base, ...wMap};
                    }).toList()
                  : baseWindows)
              .map((wMap) {
                final id = wMap['id']?.toString() ?? '';
                final byStrat = Map<String, dynamic>.from(
                  (wMap['strategy_stats'] as Map?) ?? const {},
                );
                if (m7Base != null && m7Base['window_stats'] is Map) {
                  final ws = m7Base['window_stats'] as Map;
                  for (final m7Sid in [
                    'M7G_Graded',
                    'Core3_Adaptive',
                    'M7_Ensemble',
                  ]) {
                    final sidWs = ws[m7Sid];
                    if (sidWs is Map && sidWs[id] is Map) {
                      byStrat[m7Sid] = Map<String, dynamic>.from(
                        sidWs[id] as Map,
                      );
                    }
                  }
                }
                return {...wMap, 'strategy_stats': byStrat};
              })
              .toList();

      final legacyTradeLedgers = bundle != null
          ? _unpackLedgerMap(bundle['trade_ledgers_by_strategy'])
          : _unpackLedgerMap(raw['trade_ledgers_by_strategy']);
      final m7TradeLedgers = m7Base != null
          ? _unpackLedgerMap(m7Base['ledgers'])
          : const <String, List<Map<String, dynamic>>>{};
      final tradeLedgers = {
        ...legacyTradeLedgers,
        ...m7TradeLedgers,
      };
      final ccLedgers = bundle != null
          ? _unpackLedgerMap(bundle['cc_ledgers_by_strategy'])
          : _unpackLedgerMap(raw['cc_ledgers_by_strategy']);
      final spLedgers = bundle != null
          ? _unpackLedgerMap(bundle['sp_ledgers_by_strategy'])
          : _unpackLedgerMap(raw['sp_ledgers_by_strategy']);

      final eventsByStrat = <String, dynamic>{};
      for (final e in tradeLedgers.entries) {
        if ((e.key == 'M7G_Graded' ||
                e.key == 'Core3_Adaptive' ||
                e.key == 'M7_Ensemble') &&
            m7Base != null &&
            m7Base['events'] is Map &&
            (m7Base['events'] as Map)[e.key] is List) {
          eventsByStrat[e.key] = (m7Base['events'] as Map)[e.key];
        } else if (bundle != null &&
            bundle['events_by_strategy'] is Map &&
            (bundle['events_by_strategy'] as Map)[e.key] is List) {
          eventsByStrat[e.key] = (bundle['events_by_strategy'] as Map)[e.key];
        } else {
          eventsByStrat[e.key] = _synthesizeEvents(e.key, e.value);
        }
      }
      final ledgerStrat = strat == 'BH_Pure_QQQ' ? 'M7G_Graded' : strat;

      Map<String, dynamic>? resolveBundle(
        String tp,
        String cc,
        String sp,
        String wc,
      ) {
        if (modeBundles == null) return null;
        final key = sp == 'sp_off'
            ? '${tp}__$cc'
            : (wc == defaultWc
                  ? '${tp}__${cc}__$sp'
                  : '${tp}__${cc}__${sp}__$wc');
        final b =
            modeBundles[key] ??
            modeBundles['${tp}__${cc}__${sp}__$wc'] ??
            modeBundles['${tp}__${cc}__$sp'];
        return b is Map<String, dynamic> ? b : null;
      }

      Map<String, Map<String, dynamic>> summaryById(Map<String, dynamic>? b) {
        final rawList =
            (b?['strategies_summary'] ?? raw['strategies_summary'])
                as List<dynamic>;
        final baseMap = {
          for (final item in rawList)
            (item as Map)['id'].toString(): Map<String, dynamic>.from(item),
        };
        if (m7Base != null && m7Base['summaries'] is Map) {
          final m7Sums = m7Base['summaries'] as Map;
          for (final sid in ['M7G_Graded', 'Core3_Adaptive', 'M7_Ensemble']) {
            if (m7Sums[sid] is Map) {
              baseMap[sid] = Map<String, dynamic>.from(m7Sums[sid] as Map);
            }
          }
        }
        return baseMap;
      }

      final m1 = summaryById(resolveBundle(tpMode, 'cc_off', 'sp_off', defaultWc));
      final m2 = summaryById(resolveBundle(tpMode, ccMode, 'sp_off', defaultWc));
      final m3Solo = summaryById(resolveBundle(tpMode, 'cc_off', spMode, wcMode));
      final mCur = summaryById(bundle);
      final sBh = mCur['BH_Pure_QQQ'] ?? const <String, dynamic>{};
      final bhNav = (sBh['end_nav'] as num?)?.toDouble() ?? 0.0;
      final bhSh = (sBh['final_shares'] as num?)?.toDouble() ?? 0.0;
      final bhCagr = (sBh['cagr_pct'] as num?)?.toDouble() ?? 0.0;
      final bhMdd = (sBh['max_dd_pct'] as num?)?.toDouble() ?? 0.0;
      final bhCal = (sBh['calmar'] as num?)?.toDouble() ?? 0.0;

      final engineAttrByStrat = <String, dynamic>{};
      for (final sid in [
        'M7G_Graded',
        'Core3_Adaptive',
        'M7_Ensemble',
        'U1_PureOptions',
        'B1c_PureAD',
        'D2_SixLights',
        'H2_G4_PriceGate',
        'NoPut_CallOnly',
        'BH_Pure_QQQ',
      ]) {
        final isM7Strat =
            sid == 'M7G_Graded' ||
            sid == 'Core3_Adaptive' ||
            sid == 'M7_Ensemble';
        final hasE1 = sid != 'NoPut_CallOnly' && sid != 'BH_Pure_QQQ';
        final hasE2 = ccMode != 'cc_off' && sid != 'BH_Pure_QQQ';
        final hasE3 = spMode != 'sp_off' && sid != 'BH_Pure_QQQ';
        final s1 = hasE1 ? (m1[sid] ?? sBh) : sBh;
        final s2 = hasE2 ? (m2[sid] ?? s1) : s1;
        final s3 = hasE3 ? (mCur[sid] ?? s2) : s2;
        final s2Solo = hasE2 ? (m2['NoPut_CallOnly'] ?? sBh) : sBh;
        final s3Solo = hasE3 ? (m3Solo['NoPut_CallOnly'] ?? sBh) : sBh;
        double nVal(Map<String, dynamic> m, String k) =>
            (m[k] as num?)?.toDouble() ?? 0.0;
        final effBhNav = isM7Strat && s3['bh_parity_end_nav'] is num
            ? nVal(s3, 'bh_parity_end_nav')
            : bhNav;
        final effBhSh = isM7Strat && s3['bh_final_shares'] is num
            ? nVal(s3, 'bh_final_shares')
            : bhSh;
        final totNav = nVal(s3, 'end_nav');
        final totAlpha = totNav - effBhNav;
        final d1Usd = hasE1 ? nVal(s1, 'end_nav') - effBhNav : 0.0;
        final d2Usd = hasE2 ? nVal(s2, 'end_nav') - nVal(s1, 'end_nav') : 0.0;
        final d3Usd = hasE3 ? totNav - nVal(s2, 'end_nav') : 0.0;
        final d1Sh = hasE1 ? nVal(s1, 'final_shares') - effBhSh : 0.0;
        final d2Sh = hasE2
            ? nVal(s2, 'final_shares') - nVal(s1, 'final_shares')
            : 0.0;
        final d3Sh = hasE3
            ? nVal(s3, 'final_shares') - nVal(s2, 'final_shares')
            : 0.0;
        double shPct(double d) =>
            totAlpha.abs() > 1e-6 ? (d / totAlpha) * 100.0 : 0.0;
        double exPct(double sh) => effBhSh > 0 ? (sh / effBhSh) * 100.0 : 0.0;
        final curS = mCur[sid] ?? s3;
        final e1Meta = m1[sid] ?? curS;
        engineAttrByStrat[sid] = {
          'strategy_id': sid,
          'base_end_nav': effBhNav,
          'base_shares': effBhSh,
          'base_cagr_pct': bhCagr,
          'base_max_dd_pct': bhMdd,
          'base_calmar': bhCal,
          'total_end_nav': totNav,
          'total_alpha_usd': totAlpha,
          'total_extra_shares': nVal(s3, 'final_shares') - effBhSh,
          'total_extra_shares_pct': exPct(nVal(s3, 'final_shares') - effBhSh),
          'active_engines_count':
              (hasE1 ? 1 : 0) + (hasE2 ? 1 : 0) + (hasE3 ? 1 : 0),
          'correlations': {
            'e1_e2': hasE1 && hasE2 ? 0.216 : null,
            'e1_e3': hasE1 && hasE3 ? -0.098 : null,
            'e2_e3': hasE2 && hasE3 ? -0.099 : null,
          },
          'engine1': {
            'active': hasE1,
            'delta_usd': d1Usd,
            'standalone_alpha_usd': d1Usd,
            'share_of_alpha_pct': hasE1 ? shPct(d1Usd) : 0.0,
            'delta_shares': d1Sh,
            'delta_extra_pct': exPct(d1Sh),
            'delta_cagr_pp': hasE1 ? nVal(s1, 'cagr_pct') - bhCagr : 0.0,
            'delta_mdd_pp': hasE1 ? nVal(s1, 'max_dd_pct') - bhMdd : 0.0,
            'delta_calmar': hasE1 ? nVal(s1, 'calmar') - bhCal : 0.0,
            'tranches_total': nVal(e1Meta, 'tranches_total'),
            'tp_count': nVal(e1Meta, 'tp_count'),
            'naked_prem_spent_usd': nVal(e1Meta, 'naked_prem_spent_usd'),
            'gross_put_monetized_usd': nVal(e1Meta, 'gross_put_monetized_usd'),
            'pct_days_hedged': nVal(e1Meta, 'pct_days_hedged'),
          },
          'engine2': {
            'active': hasE2,
            'delta_usd': d2Usd,
            'standalone_alpha_usd':
                hasE2 ? nVal(s2Solo, 'end_nav') - bhNav : 0.0,
            'share_of_alpha_pct': hasE2 ? shPct(d2Usd) : 0.0,
            'delta_shares': d2Sh,
            'delta_extra_pct': exPct(d2Sh),
            'delta_cagr_pp':
                hasE2 ? nVal(s2, 'cagr_pct') - nVal(s1, 'cagr_pct') : 0.0,
            'delta_mdd_pp':
                hasE2 ? nVal(s2, 'max_dd_pct') - nVal(s1, 'max_dd_pct') : 0.0,
            'delta_calmar':
                hasE2 ? nVal(s2, 'calmar') - nVal(s1, 'calmar') : 0.0,
            'trades_count': nVal(curS, 'cc_trades_count'),
            'active_years': nVal(curS, 'cc_active_years'),
            'stop_count': nVal(curS, 'cc_stop_count'),
            'roll_count': nVal(curS, 'cc_roll_count'),
            'assigned_count': nVal(curS, 'cc_assigned_count'),
            'gross_prem_usd': nVal(curS, 'cc_gross_prem_usd'),
            'gross_loss_usd': nVal(curS, 'cc_gross_loss_usd'),
            'funded_puts_usd': nVal(curS, 'cc_funded_puts_usd'),
          },
          'engine3': {
            'active': hasE3,
            'delta_usd': d3Usd,
            'standalone_alpha_usd':
                hasE3 ? nVal(s3Solo, 'end_nav') - bhNav : 0.0,
            'share_of_alpha_pct': hasE3 ? shPct(d3Usd) : 0.0,
            'delta_shares': d3Sh,
            'delta_extra_pct': exPct(d3Sh),
            'delta_cagr_pp':
                hasE3 ? nVal(s3, 'cagr_pct') - nVal(s2, 'cagr_pct') : 0.0,
            'delta_mdd_pp':
                hasE3 ? nVal(s3, 'max_dd_pct') - nVal(s2, 'max_dd_pct') : 0.0,
            'delta_calmar':
                hasE3 ? nVal(s3, 'calmar') - nVal(s2, 'calmar') : 0.0,
            'sp_trades_count': nVal(curS, 'sp_trades_count'),
            'sp_win_rate_pct': nVal(curS, 'sp_win_rate_pct'),
            'sp_assignments_count': nVal(curS, 'sp_assignments_count'),
            'wc_trades_count': nVal(curS, 'wc_trades_count'),
            'wc_called_away_count': nVal(curS, 'wc_called_away_count'),
            'gross_prem_usd':
                nVal(curS, 'sp_gross_prem_usd') +
                nVal(curS, 'wc_gross_prem_usd'),
            'margin_interest_usd': nVal(curS, 'margin_interest_usd'),
            'days_levered_stock': nVal(curS, 'days_levered_stock'),
            'max_wheel_cycle_days': nVal(curS, 'max_wheel_cycle_days'),
            'max_gross_stock_lev': nVal(curS, 'max_gross_stock_lev'),
          },
        };
      }

      final legacySummaries =
          ((bundle?['strategies_summary'] ?? raw['strategies_summary']) as List)
              .where((s) {
                final id = (s as Map)['id']?.toString() ?? '';
                return id != 'M7G_Graded' &&
                    id != 'Core3_Adaptive' &&
                    id != 'M7_Ensemble';
              })
              .toList();
      final m7Sums = m7Base?['summaries'] as Map?;
      final mergedSummaries = <dynamic>[
        if (m7Sums?['M7G_Graded'] != null) m7Sums!['M7G_Graded'],
        if (m7Sums?['Core3_Adaptive'] != null) m7Sums!['Core3_Adaptive'],
        if (m7Sums?['M7_Ensemble'] != null) m7Sums!['M7_Ensemble'],
        ...legacySummaries,
      ];

      final m7LiveDashByStrat =
          (m7Base?['m7_live_dashboards'] as Map<String, dynamic>?) ??
          (raw['m7_live_dashboards_by_strategy'] as Map<String, dynamic>?) ??
          const <String, dynamic>{};
      final activeM7Dash = strat == 'Core3_Adaptive'
          ? (m7LiveDashByStrat['Core3_Adaptive'] ?? raw['m7_live_dashboard'])
          : (strat == 'M7_Ensemble'
                ? (m7LiveDashByStrat['M7_Ensemble'] ?? raw['m7_live_dashboard'])
                : (m7LiveDashByStrat['M7G_Graded'] ?? raw['m7_live_dashboard']));

      final out = Map<String, dynamic>.from(raw)
        ..remove('tp_modes')
        ..remove('mode_bundles')
        ..remove('m7_bundles');
      return {
        ...out,
        if (bundle != null) ...{
          'live_signal_state': bundle['live_signal_state'],
          'live_signal_states_by_strategy':
              bundle['live_signal_states_by_strategy'],
          'live_sp_state': bundle['live_sp_state'],
          'live_sp_states_by_strategy': bundle['live_sp_states_by_strategy'],
        },
        'm7_live_dashboard': activeM7Dash,
        'm7_live_dashboards_by_strategy': m7LiveDashByStrat,
        'strategies_summary': mergedSummaries,
        'events_by_strategy': eventsByStrat,
        'trade_ledgers_by_strategy': tradeLedgers,
        'cc_ledgers_by_strategy': ccLedgers,
        'sp_ledgers_by_strategy': spLedgers,
        'sp_ledger': spLedgers[ledgerStrat] ?? const <dynamic>[],
        'crisis_windows': hydratedWindows,
        'daily_series': projectedSeries,
        'engine_attribution_by_strategy': engineAttrByStrat,
        'profile': profile,
        'put_otm': putOtm,
        'm7_tp_mode': m7TpMode,
        'roll_mode': rollMode,
        'm0_enabled': m0Enabled,
        'tp_mode': tpMode,
        'cc_mode': ccMode,
        'sp_mode': spMode,
        'wc_mode': spMode == 'sp_off' ? defaultWc : wcMode,
        'snapshotId': 'fixture-crisis-v5-real-opra',
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
    'Discover renders M7-Graded Three-Pillar Crisis Observatory + 120D->50D Roll selector + interactive QQQ sizing + full 3-Engine compatibility',
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
      expect(find.textContaining('FactOS'), findsNothing);

      // 1. Top 2-Card Strategy Switcher + MIT Real OPRA Provenance Strip + Default Full M7 Shield (Adaptive 120->50 / CTA 90->30)
      expect(
        find.byKey(const ValueKey('crisis-profile-switcher')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-profile-full_m7_adaptive')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-profile-core3_adaptive')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-data-provenance-strip')),
        findsOneWidget,
      );
      expect(
        find.textContaining('MIT Real QQQ OPRA Chain (9.88M Quotes, 0 Fallbacks)'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-observatory-command-center')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-m7-prob-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-m7-slots-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-m7-redline-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-m7-tp-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-m7-sizing-calculator')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-observatory-three-pillars')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('crisis-m7-pillar-P1')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-m7-pillar-P2')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-m7-pillar-P3')), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-m0-toggle')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('crisis-real-data-provenance-pill')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Real OPRA Chain 95.7%'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-legacy-upgrade-banner')),
        findsNothing,
      );

      // Penny-exact Real-OPRA Full M7 Shield Adaptive default metrics ($1,466,143 · +$178,258 · 2,409.6 sh · +13.8% · -28.3% MDD · Calmar 0.645)
      expect(find.text('\$1,466,143'), findsOneWidget);
      expect(find.text('+\$178,258'), findsWidgets);
      expect(find.text('2,409.6 sh'), findsOneWidget);
      expect(find.textContaining('+13.8%'), findsWidgets);
      expect(find.text('-28.3%'), findsOneWidget);
      expect(find.textContaining('Calmar 0.645'), findsWidgets);
      expect(find.text('50D/30D Roll Salvage'), findsOneWidget);
      expect(find.text('BSM* Calib.'), findsWidgets);

      // Interactive QQQ Shares calculator updates per-slot budget live
      final sharesField = find.byKey(const ValueKey('crisis-qqq-shares-input'));
      await tester.ensureVisible(sharesField);
      await tester.enterText(sharesField, '5000');
      await tester.pumpAndSettle();
      expect(find.textContaining('ctr (120D K=\$'), findsOneWidget);

      // Standalone Six Crisis Lights panel & toggle are retired (covered by Three-Pillar Matrix)
      expect(
        find.byKey(const ValueKey('crisis-classic-lights-toggle')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('crisis-observatory-six-lights')),
        findsNothing,
      );

      // 2. Switch to Option 2: Core-3 Minimal · Low Freq · High PF (co_profile=core3_adaptive)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-profile-core3_adaptive')),
      );
      expect(find.text('\$1,497,023'), findsOneWidget);
      expect(find.text('+\$209,138'), findsWidgets);
      expect(find.text('2,460.4 sh'), findsOneWidget);
      expect(find.textContaining('+16.2%'), findsWidgets);
      expect(find.text('-28.6%'), findsOneWidget);
      expect(find.textContaining('Calmar 0.646'), findsWidgets);
      // Safety guardrail: 90D Hold is NEVER exposed on Core-3 Minimal
      expect(
        find.byKey(const ValueKey('crisis-core3-roll-locked-badge')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-roll-pill-90d_hold')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('crisis-e1-roll-90d_hold')),
        findsNothing,
      );
      // M2, M5, and M3 sensor cards are visually dimmed & badged Off in Core-3
      expect(
        find.byKey(const ValueKey('crisis-mod-core3-off-M2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-mod-core3-off-M5')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-mod-core3-off-M3')),
        findsOneWidget,
      );
      expect(find.text('Off in Core-3'), findsWidgets);

      // Switch back to Option 1: Full M7 Shield · Recommended
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-profile-full_m7_adaptive')),
      );
      expect(find.text('\$1,466,143'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('crisis-mod-core3-off-M2')),
        findsNothing,
      );

      // Switch Tenor/Roll to 90D Hold on Full M7 Shield (90d_hold -> $1,343,816 · -28.1% MDD · Calmar 0.620)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-roll-pill-90d_hold')),
      );
      expect(find.text('\$1,343,816'), findsOneWidget);
      expect(find.text('-28.1%'), findsOneWidget);

      // Switch Strike to -20% OTM while on 90d_hold ($1,274,910 · -1.0%)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-otm-pill-otm20')),
      );
      expect(find.text('\$1,274,910'), findsOneWidget);
      expect(find.textContaining('-1.0%'), findsWidgets);

      // Switch to 120D -> 50D Roll while on -20% OTM ($1,420,675 · +10.3%)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-roll-pill-120d_roll50')),
      );
      expect(find.text('\$1,420,675'), findsOneWidget);
      expect(find.textContaining('+10.3%'), findsWidgets);

      // Switch back to Adaptive 120/90 + -15% OTM and test ITM_TP ($1,335,192 · -28.3% MDD · Calmar 0.612)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-roll-pill-adaptive_120_90')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-otm-pill-otm15')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-m7-tp-pill-itm_tp')),
      );
      expect(find.text('\$1,335,192'), findsOneWidget);
      expect(find.text('-28.3%'), findsOneWidget);
      expect(find.textContaining('Calmar 0.612'), findsWidgets);

      // Restore standard TP and verify M7_Ensemble ($1,437,261) + M0 switch
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-m7-tp-pill-standard')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-M7_Ensemble')),
      );
      expect(find.text('\$1,437,261'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-m0-toggle')),
      );
      expect(find.text('M0: OFF (Pure 5-Mod)'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-m0-toggle')),
      );

      // 3. Switch to Legacy U1_PureOptions and verify upgrade banner + 100% compatibility with all 3 Orthogonal Engines
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-strategy-pill-U1_PureOptions')),
      );
      expect(
        find.byKey(const ValueKey('crisis-legacy-upgrade-banner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-switch-to-m7g-btn')),
        findsOneWidget,
      );
      expect(find.text('\$1,322,402'), findsOneWidget);
      expect(find.text('+\$34,098'), findsWidgets);
      expect(find.text('2,173.4 sh'), findsOneWidget);
      expect(find.byKey(const ValueKey('crisis-tp-mode-bar')), findsOneWidget);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-cc-mode-pill-cc_d12_d35')),
      );
      expect(find.text('\$1,287,946'), findsOneWidget);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-sp-mode-pill-sp_14d_cap10')),
      );
      expect(find.byKey(const ValueKey('crisis-wc-mode-bar')), findsOneWidget);
      expect(find.text('\$1,357,245'), findsOneWidget);
      expect(find.textContaining('Calmar 0.537'), findsWidgets);

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-wc-mode-pill-wc_30d_c5s5')),
      );
      expect(find.text('\$1,350,632'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-wc-mode-pill-wc_14d_c0s2')),
      );
      expect(find.text('\$1,336,321'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-wc-mode-pill-wc_reclaim_30d_d35')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-sp-mode-pill-sp_off')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-cc-mode-pill-cc_off')),
      );

      // Zoom into 2025 April Tariff Crash and hover 2025-04-07 1.10 Panic Harvest
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-zoom-pill-2025-04')),
      );
      expect(find.text('2025 April Tariff Crash'), findsWidgets);
      expect(find.text('OPRA Real'), findsWidgets);

      final canvasFinder = find.byKey(
        const ValueKey('crisis-observatory-canvas'),
      );
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
          matching: find.textContaining('Target 0 / Held 0'),
        ),
        findsOneWidget,
      );

      await gesture.moveTo(Offset.zero);
      await tester.pumpAndSettle();

      // One-click upgrade banner jumps straight back to Full M7 Shield Adaptive ($1,466,143)
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-switch-to-m7g-btn')),
      );
      expect(
        find.byKey(const ValueKey('crisis-legacy-upgrade-banner')),
        findsNothing,
      );
      expect(find.text('\$1,466,143'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Crisis Observatory renders calm localized Chinese 2-Profile Real-OPRA UI cleanly on both Desktop (1440x1200) and Mobile (390x844) without overflow',
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

        expect(find.text('🛡️ 全套 M7 护盾 · 默认推荐'), findsOneWidget);
        expect(find.text('⚡ 精简 3 核 · 低频高赔率'), findsOneWidget);
        expect(
          find.textContaining('2015-01-02 至 2025-12-15：MIT 真实 QQQ OPRA 期权盘口'),
          findsOneWidget,
        );
        expect(
          find.text('三支柱概率分层监控矩阵（M7-Graded · 六大子模块）'),
          findsOneWidget,
        );
        expect(find.textContaining('单槽等金额预算：'), findsOneWidget);
        expect(find.text('自适应 120/90（推荐）'), findsOneWidget);
        expect(find.text('统一 120→50'), findsOneWidget);
        expect(find.text('90D 持有'), findsOneWidget);
        expect(find.text('-15% OTM（真实 OPRA 冠军）'), findsOneWidget);
        expect(find.text('-20% OTM（深虚值对照）'), findsOneWidget);
        expect(find.textContaining('真实盘口覆盖 95.7%'), findsOneWidget);
        expect(find.text('50D/30D 残值滚仓'), findsOneWidget);
        expect(find.text('历史保护策略 vs 死拿 QQQ'), findsOneWidget);
        expect(find.textContaining('+13.8%'), findsWidgets);
        expect(find.text('BSM* 校准'), findsWidgets);
        expect(find.textContaining('短债'), findsNothing);

        // Switch to Chinese Core-3 Minimal and back on Desktop & Mobile (390x844) with zero overflow
        await tapVisible(
          tester,
          find.byKey(const ValueKey('crisis-profile-core3_adaptive')),
        );
        expect(find.text('\$1,497,023'), findsOneWidget);
        expect(find.text('精简模式已关闭'), findsWidgets);
        expect(
          find.text('已锁定最优自适应滚仓 120→50 / CTA 90→30（禁用 90D 持有）'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('crisis-profile-full_m7_adaptive')),
        );
        expect(find.text('\$1,466,143'), findsOneWidget);
      }

      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );

  testWidgets(
    'Crisis Observatory enforces Core-3 90D Hold safety guardrail on deep-link init and emits co_profile + rollMode cleanly in onSelection',
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
                    'profile': 'core3_adaptive',
                    'rollMode': '90d_hold',
                    'putOtm': 'otm15',
                    'm7TpMode': 'standard',
                    'm0Enabled': true,
                  },
                  onSelection: (sel) => latestSelection = sel,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Even when initialized with rollMode=90d_hold on core3_adaptive, safety guardrail locks it to adaptive_120_90 ($1,497,023)!
      expect(find.text('\$1,497,023'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('crisis-core3-roll-locked-badge')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('crisis-roll-pill-90d_hold')),
        findsNothing,
      );

      // Switch to Full M7 Shield and toggle 90D Hold to verify full state emission
      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-profile-full_m7_adaptive')),
      );
      expect(latestSelection['profile'], 'full_m7_adaptive');
      expect(latestSelection['strategy'], 'M7G_Graded');
      expect(latestSelection['rollMode'], 'adaptive_120_90');

      await tapVisible(
        tester,
        find.byKey(const ValueKey('crisis-roll-pill-90d_hold')),
      );
      expect(find.text('\$1,343,816'), findsOneWidget);
      expect(latestSelection['strategy'], 'M7G_Graded');
      expect(latestSelection['putOtm'], 'otm15');
      expect(latestSelection['rollMode'], '90d_hold');
      expect(latestSelection['m7TpMode'], 'standard');
      expect(latestSelection['m0Enabled'], 'true');
    },
  );

  testWidgets(
    'Clicking any historical point on the curve replays PIT Three-Pillar state, displays date & QQQ price banner above, steps Prev/Next day, and returns cleanly to Live',
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

        // Zoom into 2020 COVID Crash window and tap the curve around 2020-01-28 (M2+M5 P2=40%)
        await tapVisible(
          tester,
          find.byKey(const ValueKey('crisis-zoom-pill-2020-03')),
        );
        final canvasFinder = find.byKey(
          const ValueKey('crisis-observatory-canvas'),
        );
        await tester.ensureVisible(canvasFinder);
        await tester.pumpAndSettle();
        final rect = tester.getRect(canvasFinder);
        // Tap 25% into the 2020 COVID window to pin a historical date
        final tapPoint = Offset(
          rect.left + 52.0 + (rect.width - 64.0) * 0.25,
          rect.top + 120.0,
        );
        await tester.tapAt(tapPoint);
        await tester.pumpAndSettle();

        // Verify /pit API was called and BOTH top PIT replay banners + chart strip are shown with date & QQQ price
        expect(
          api.calls.any(
            (c) => c.contains('/api/investment/crisis-observatory/pit'),
          ),
          isTrue,
        );
        final pillarsBanner = find.byKey(
          const ValueKey('crisis-pit-pillars-banner'),
        );
        expect(pillarsBanner, findsOneWidget);
        expect(
          find.byKey(const ValueKey('crisis-pit-cmd-banner')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('crisis-pit-chart-strip')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: pillarsBanner,
            matching: find.text('PIT 历史状态回放'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: pillarsBanner,
            matching: find.textContaining('2020-'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: pillarsBanner,
            matching: find.textContaining('QQQ \$'),
          ),
          findsOneWidget,
        );

        // Step one trading day forward and back without overflow
        await tapVisible(
          tester,
          find.byKey(const ValueKey('crisis-pit-pillars-next-btn')),
        );
        expect(pillarsBanner, findsOneWidget);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('crisis-pit-pillars-prev-btn')),
        );
        expect(pillarsBanner, findsOneWidget);

        // Return cleanly to Live state
        await tapVisible(
          tester,
          find.byKey(const ValueKey('crisis-pit-pillars-return-live-btn')),
        );
        expect(pillarsBanner, findsNothing);
        expect(
          find.byKey(const ValueKey('crisis-pit-chart-strip')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }

      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );
}
