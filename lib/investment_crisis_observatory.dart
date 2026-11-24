part of 'main.dart';

class CrisisObservatoryPanel extends StatefulWidget {
  const CrisisObservatoryPanel({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.onCompany,
    this.initialSelection = const {},
    this.onSelection,
  });

  final ApiClient api;
  final Palette palette;
  final String asOf;
  final ValueChanged<String> onCompany;
  final Map<String, dynamic> initialSelection;
  final ValueChanged<Map<String, dynamic>>? onSelection;

  @override
  State<CrisisObservatoryPanel> createState() => _CrisisObservatoryPanelState();
}

class _CrisisObservatoryPanelState extends State<CrisisObservatoryPanel> {
  // Calm institutional Dark-Obsidian semantic accents; everything else uses native Palette tokens.
  static const Color _emerald = Color(0xFF5EC49E);
  static const Color _amber = Color(0xFFE5B45B);
  static const Color _coral = Color(0xFFE47F8B);
  static const Color _sky = Color(0xFF7DB8F0);
  static const Color _lilac = Color(0xFFB8A1EA);

  static const List<String> _primaryStrategies = [
    'U1_PureOptions',
    'B1c_PureAD',
    'D2_SixLights',
    'NoPut_CallOnly',
  ];

  static const List<String> _tpModeIds = [
    'layered_itm',
    'standard_dual',
    'both_4x',
  ];

  static const List<String> _ccModeIds = [
    'cc_off',
    'cc_d12_d35',
    'cc_d12_r45',
    'cc_d12_cr55',
  ];

  static const Map<String, String> _strategyNavKeys = {
    'U1_PureOptions': 'nav_u1',
    'B1c_PureAD': 'nav_b1c',
    'D2_SixLights': 'nav_d2',
    'H2_G4_PriceGate': 'nav_h2',
    'NoPut_CallOnly': 'nav_cc',
    'BH_Pure_QQQ': 'nav_bh',
  };

  Map<String, dynamic>? data;
  final Map<String, Map<String, dynamic>> _tpModeCache = {};
  bool loading = true;
  bool switchingTpMode = false;
  String? error;

  String selectedStrategyId = 'U1_PureOptions';
  String selectedTpMode = 'layered_itm';
  String selectedCcMode = 'cc_off';
  String selectedWindowId = 'ALL';
  String activeForensicWindowId = '2026-08_11_LIVE';
  bool useLogScale = true;
  bool showRulesDisclosure = false;
  bool showSignalSubTrack = false;
  bool showFullLedger = false;
  bool showCcLedger = false;
  final Set<int> expandedTrancheIds = <int>{};
  int hoverIndex = -1;
  int loadSerial = 0;

  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);

  String _normalizeStrategyId(String raw) {
    if (raw == 'U4_DualEngine' || raw.isEmpty || raw == 'BH_Pure_QQQ') {
      return 'U1_PureOptions';
    }
    return _strategyNavKeys.containsKey(raw) ? raw : 'U1_PureOptions';
  }

  String _normalizeTpMode(String raw) {
    return _tpModeIds.contains(raw) ? raw : 'layered_itm';
  }

  String _normalizeCcMode(String raw) {
    final mapped = switch (raw) {
      'cc_high_vol' || 'cc_hv_8' || 'cc_hv_9' || 'cc_d12_3x' => 'cc_d12_d35',
      'cc_always' || 'cc_always_8' || 'cc_otm8_3x' => 'cc_d12_r45',
      _ => raw,
    };
    return _ccModeIds.contains(mapped) ? mapped : 'cc_off';
  }

  @override
  void initState() {
    super.initState();
    selectedStrategyId = _normalizeStrategyId(
      text(widget.initialSelection['strategy']),
    );
    selectedTpMode = _normalizeTpMode(
      text(widget.initialSelection['tpMode']),
    );
    selectedCcMode = _normalizeCcMode(
      text(widget.initialSelection['ccMode']),
    );
    final initWin = text(widget.initialSelection['window']);
    if (initWin.isNotEmpty) {
      selectedWindowId = initWin;
      if (initWin != 'ALL' && initWin != '1Y' && initWin != '3Y') {
        activeForensicWindowId = initWin;
      }
    }
    unawaited(_loadObservatory());
  }

  @override
  void didUpdateWidget(covariant CrisisObservatoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOf != widget.asOf || oldWidget.api != widget.api) {
      _tpModeCache.clear();
      unawaited(_loadObservatory());
    }
  }

  void _emitSelection() {
    widget.onSelection?.call({
      'strategy': selectedStrategyId,
      'window': selectedWindowId,
      'tpMode': selectedTpMode,
      'ccMode': selectedCcMode,
    });
  }

  void _selectModes({String? tpMode, String? ccMode}) {
    final nextTp = tpMode != null ? _normalizeTpMode(tpMode) : selectedTpMode;
    final nextCc = ccMode != null ? _normalizeCcMode(ccMode) : selectedCcMode;
    if (nextTp == selectedTpMode && nextCc == selectedCcMode && data != null) {
      return;
    }
    final cacheKey = '${widget.asOf}::$nextTp::$nextCc';
    final cached = _tpModeCache[cacheKey];
    if (cached != null) {
      setState(() {
        selectedTpMode = nextTp;
        selectedCcMode = nextCc;
        data = cached;
        hoverIndex = -1;
        switchingTpMode = false;
      });
      _emitSelection();
      return;
    }
    setState(() {
      selectedTpMode = nextTp;
      selectedCcMode = nextCc;
      switchingTpMode = data != null;
      hoverIndex = -1;
    });
    _emitSelection();
    unawaited(_loadObservatory(isModeSwitch: data != null));
  }

  void _selectTpMode(String modeId) => _selectModes(tpMode: modeId);

  void _selectCcMode(String modeId) => _selectModes(ccMode: modeId);

  Future<void> _loadObservatory({bool isModeSwitch = false}) async {
    final serial = ++loadSerial;
    final targetTp = selectedTpMode;
    final targetCc = selectedCcMode;
    setState(() {
      if (!isModeSwitch) {
        loading = true;
      } else {
        switchingTpMode = true;
      }
      error = null;
    });
    try {
      final uri = Uri(
        path: '/api/investment/crisis-observatory',
        queryParameters: {
          'asOf': widget.asOf,
          'strategy': selectedStrategyId,
          'tpMode': targetTp,
          'ccMode': targetCc,
        },
      );
      final res = await widget.api.getJson(uri.toString());
      if (!mounted || serial != loadSerial) return;
      _tpModeCache['${widget.asOf}::$targetTp::$targetCc'] = res;
      final windows = asList(res['crisis_windows']);
      var nextForensic = activeForensicWindowId;
      if (windows.isNotEmpty &&
          !windows.any((item) => text(item['id']) == nextForensic)) {
        nextForensic = text(windows.last['id']);
      }
      var nextWindow = selectedWindowId;
      if (nextWindow != 'ALL' &&
          nextWindow != '1Y' &&
          nextWindow != '3Y' &&
          !windows.any((item) => text(item['id']) == nextWindow)) {
        nextWindow = 'ALL';
      }
      setState(() {
        data = res;
        activeForensicWindowId = nextForensic;
        selectedWindowId = nextWindow;
        hoverIndex = -1;
        loading = false;
        switchingTpMode = false;
      });
    } catch (e) {
      if (!mounted || serial != loadSerial) return;
      setState(() {
        error = e.toString();
        loading = false;
        switchingTpMode = false;
      });
    }
  }

  double _numVal(dynamic v, [double fallback = 0]) {
    if (v is num && v.isFinite) return v.toDouble();
    if (v is String) {
      final parsed = double.tryParse(v);
      if (parsed != null && parsed.isFinite) return parsed;
    }
    return fallback;
  }

  String _fmtUsd(double v, {bool signed = false}) {
    final sign = v < 0 ? '-' : (signed && v > 0 ? '+' : '');
    final fixed = v.abs().round().toString();
    final buf = StringBuffer();
    for (var i = 0; i < fixed.length; i++) {
      if (i > 0 && (fixed.length - i) % 3 == 0) buf.write(',');
      buf.write(fixed[i]);
    }
    return '$sign\$$buf';
  }

  String _fmtPct(double v, {int digits = 1, bool signed = true}) {
    final sign = v > 0 && signed ? '+' : '';
    return '$sign${v.toStringAsFixed(digits)}%';
  }

  String _fmtShares(double v, {int digits = 1, bool signed = false}) {
    final sign = v < 0 ? '-' : (signed && v > 0 ? '+' : '');
    final parts = v.abs().toStringAsFixed(digits).split('.');
    final intPart = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return digits > 0 ? '$sign$buf.${parts[1]}' : '$sign$buf';
  }

  String _humanStrategyLabel(String id) {
    return switch (id) {
      'U1_PureOptions' => w('U1 Dual-Slot Put+Collar (Rec.)', 'U1 双槽买 Put+领口（推荐）'),
      'B1c_PureAD' => w('B1c AD Breadth Put', 'B1c 宽度背离买 Put'),
      'D2_SixLights' => w('D2 6-Light Collar', 'D2 六灯领口（零保费）'),
      'NoPut_CallOnly' => w('No Put (Call Only)', '不买 Put（仅卖 Call）'),
      'H2_G4_PriceGate' => w('Price & Vol Gate', '价格低波门控'),
      'BH_Pure_QQQ' => w('Buy & Hold QQQ', '死拿 QQQ'),
      _ => w('Protected Strategy', '保护策略'),
    };
  }

  String _activeComboBadgeText() {
    final putPart = _humanStrategyLabel(selectedStrategyId);
    final callPart = _humanCcModeLabel(selectedCcMode);
    if (selectedStrategyId == 'NoPut_CallOnly') {
      return selectedCcMode == 'cc_off'
          ? w(
              'Active Combo: Buy & Hold QQQ (No Put · No Call)',
              '当前组合：不买 Put · 不卖 Call（等效死拿 QQQ）',
            )
          : w(
              'Active Combo: No Crisis Put · Overlay $callPart',
              '当前组合：不买危机 Put · 纯叠加「$callPart」',
            );
    }
    final tpPart = _humanTpModeLabel(selectedTpMode);
    return selectedCcMode == 'cc_off'
        ? w(
            'Active Combo: $putPart ($tpPart) · No Normal-Time Call',
            '当前组合：$putPart（$tpPart）· 不叠加平时卖 Call',
          )
        : w(
            'Active Combo: $putPart ($tpPart) + $callPart',
            '当前组合：$putPart（$tpPart） + 叠加「$callPart」',
          );
  }

  List<Map<String, dynamic>> _buildCcChartEvents(
    List<Map<String, dynamic>> ccLedger,
    String visibleStart,
    String visibleEnd,
  ) {
    if (ccLedger.isEmpty || visibleStart.isEmpty || visibleEnd.isEmpty) {
      return const [];
    }
    final rollLegByDateAndGen = <String, Map<String, dynamic>>{};
    for (final cc in ccLedger) {
      final rg = _numVal(cc['roll_gen']).round();
      if (rg > 0) {
        rollLegByDateAndGen['${text(cc['entry_date'])}#$rg'] = cc;
      }
    }
    final out = <Map<String, dynamic>>[];
    for (final cc in ccLedger) {
      final entryDate = text(cc['entry_date']);
      final exitDate = text(cc['exit_date']);
      final rollGen = _numVal(cc['roll_gen']).round();
      final exitReason = text(cc['exit_reason']);
      final entrySpot = _numVal(cc['entry_spot']);
      final kc = _numVal(cc['kc']);
      final otmPct = entrySpot > 0 ? (kc / entrySpot - 1.0) * 100.0 : 0.0;

      if (rollGen == 0 &&
          entryDate.compareTo(visibleStart) >= 0 &&
          entryDate.compareTo(visibleEnd) <= 0) {
        out.add({
          'date': entryDate,
          'event_type': 'cc_open',
          'spot': entrySpot,
          'kc': kc,
          'otm_pct': otmPct,
          'prem_usd': _numVal(cc['prem_usd']),
          'entry_vxn': _numVal(cc['entry_vxn']),
        });
      }

      if (exitDate.isNotEmpty &&
          exitDate.compareTo(visibleStart) >= 0 &&
          exitDate.compareTo(visibleEnd) <= 0) {
        if (exitReason == 'delta_roll_up' || exitReason == 'delta_credit_roll') {
          final succ = rollLegByDateAndGen['$exitDate#${rollGen + 1}'];
          out.add({
            'date': exitDate,
            'event_type': exitReason == 'delta_credit_roll'
                ? 'cc_credit_roll'
                : 'cc_roll_up',
            'spot': _numVal(cc['exit_spot']),
            'old_kc': kc,
            'new_kc': succ != null ? _numVal(succ['kc']) : null,
            'loss_usd': _numVal(cc['loss_usd']),
            'new_prem_usd': succ != null ? _numVal(succ['prem_usd']) : 0.0,
            'net_pnl_usd': _numVal(cc['net_pnl_usd']),
          });
        } else if (exitReason == 'delta_stop') {
          out.add({
            'date': exitDate,
            'event_type': 'cc_delta_stop',
            'spot': _numVal(cc['exit_spot']),
            'kc': kc,
            'prem_usd': _numVal(cc['prem_usd']),
            'loss_usd': _numVal(cc['loss_usd']),
            'net_pnl_usd': _numVal(cc['net_pnl_usd']),
          });
        }
      }
    }
    return out;
  }

  String _humanTpModeLabel(String modeId) {
    return switch (modeId) {
      'layered_itm' => w('Layered ITM (Rec.)', '分层实值（推荐）'),
      'standard_dual' => w('Standard 1.10', '标准 1.10'),
      'both_4x' => w('Deep 4x Both', '两槽 4x 深度'),
      _ => w('Layered ITM', '分层实值'),
    };
  }

  String _humanTpModeHint(String modeId) {
    return switch (modeId) {
      'layered_itm' => w(
        'Collar exits at VIX/3M >= 1.10 to unlock Call cap · Naked Put ignores shallow spikes until ITM (QQQ <= K_P) · +5x slow-bear lock (DTE <= 45)',
        '次仓领口见 VIX/3M ≥ 1.10 即平解封卖 Call · 首仓裸 Put 浅跌无视倒挂，必须跌破行权价 (QQQ ≤ K_P) 进实值才平 · 叠加后半程 5x 慢熊锁利',
      ),
      'standard_dual' => w(
        'Both slots exit immediately on VIX/3M >= 1.10 panic inversion · +5x slow-bear lock (DTE <= 45)',
        '双槽统一：见 VIX/3M ≥ 1.10 恐慌倒挂即次日开盘止盈抄底 · 叠加后半程（DTE ≤ 45）Put ≥ 5x 慢熊锁利',
      ),
      'both_4x' => w(
        'Both slots require VIX/3M >= 1.10 AND Put >= 4x entry cost (filters shallow spikes) · +5x slow-bear lock (DTE <= 45)',
        '双槽统一：必须 VIX/3M ≥ 1.10 且 Put ≥ 4 倍成本才认恐慌止盈（过滤浅跌假倒挂） · 叠加后半程 5x 慢熊锁利',
      ),
      _ => '',
    };
  }

  String _humanCcModeLabel(String modeId) {
    return switch (modeId) {
      'cc_off' => w('Off', '关闭'),
      'cc_d12_d35' => w(
        '12Δ · Delta 0.35 Stop (Rec. · 0 Breach)',
        '全天候 12Δ · Delta 0.35 止损（推荐 · 0穿最稳）',
      ),
      'cc_d12_r45' => w(
        '12Δ · Delta 0.45 Roll (30D Up)',
        '全天候 12Δ · Delta 0.45 展期 Roll（30D 上移）',
      ),
      'cc_d12_cr55' => w(
        '12Δ · Delta 0.55 Credit Roll (45D)',
        '全天候 12Δ · Delta 0.55 零成本 Roll（45D）',
      ),
      _ => w('Off', '关闭'),
    };
  }

  String _humanCcModeHint(String modeId, Map<String, dynamic> stratSummary) {
    final ccN = _numVal(stratSummary['cc_trades_count']).round();
    final ccAsgn = _numVal(stratSummary['cc_assigned_count']).round();
    final ccStop = _numVal(stratSummary['cc_stop_count']).round();
    final ccRoll = _numVal(stratSummary['cc_roll_count']).round();
    final ccYrs = _numVal(stratSummary['cc_active_years']).round();
    final ccPrem = _numVal(stratSummary['cc_gross_prem_usd']);
    final ccLoss = _numVal(stratSummary['cc_gross_loss_usd']);
    final ccPutFund = _numVal(stratSummary['cc_funded_puts_usd']);
    return switch (modeId) {
      'cc_off' => w(
        'Normal-time covered calls OFF · 100% uncapped upside during bull trends',
        '平时不卖 Call · 牛市主升浪 100% 零封顶损耗',
      ),
      'cc_d12_d35' => w(
        '25D 12-Delta (min +5% OTM) whenever ATH <= 3% + Delta >= 0.35 stop buyback -> $ccN trades across $ccYrs yrs ($ccStop stops, $ccAsgn breached), collected ${_fmtUsd(ccPrem, signed: true)} (funded ${_fmtUsd(ccPutFund)} Put cost, stop/close ${_fmtUsd(-ccLoss)})',
        '距前高 ≤ 3% 全天候卖 25D 12Δ（保底 +5% OTM）Call，Delta ≥ 0.35 即止损平仓：覆盖 $ccYrs 年共 $ccN 笔（止损 $ccStop 次 · 穿价 $ccAsgn 次），收租 ${_fmtUsd(ccPrem, signed: true)}（免费抵 Put 保费 ${_fmtUsd(ccPutFund)} · 止损/平仓 ${_fmtUsd(-ccLoss)}）',
      ),
      'cc_d12_r45' => w(
        '25D 12-Delta whenever ATH <= 3% + Delta >= 0.45 roll out 30D to fresh higher 12-Delta strike -> $ccN trades across $ccYrs yrs ($ccRoll rolls, $ccAsgn breached), collected ${_fmtUsd(ccPrem, signed: true)} (funded ${_fmtUsd(ccPutFund)} Put cost, close ${_fmtUsd(-ccLoss)})',
        '距前高 ≤ 3% 全天候卖 25D 12Δ Call，Delta ≥ 0.45 同步展期 30 天上移至新 12Δ 高行权价：覆盖 $ccYrs 年共 $ccN 笔（展期上移 $ccRoll 次 · 穿价 $ccAsgn 次），收租 ${_fmtUsd(ccPrem, signed: true)}（免费抵 Put 保费 ${_fmtUsd(ccPutFund)} · 平旧仓 ${_fmtUsd(-ccLoss)}）',
      ),
      'cc_d12_cr55' => w(
        '25D 12-Delta whenever ATH <= 3% + Delta >= 0.55 zero-cost credit roll 45D (or close if no OTM credit) -> $ccN trades across $ccYrs yrs ($ccRoll rolls, $ccAsgn breached), collected ${_fmtUsd(ccPrem, signed: true)} (funded ${_fmtUsd(ccPutFund)} Put cost, close ${_fmtUsd(-ccLoss)})',
        '距前高 ≤ 3% 全天候卖 25D 12Δ Call，Delta ≥ 0.55 尝试向后 45 天做零成本上移 Roll（无虚值零成本可展则平仓）：覆盖 $ccYrs 年共 $ccN 笔（零成本展期 $ccRoll 次 · 穿价 $ccAsgn 次），收租 ${_fmtUsd(ccPrem, signed: true)}（免费抵 Put 保费 ${_fmtUsd(ccPutFund)} · 平旧仓 ${_fmtUsd(-ccLoss)}）',
      ),
      _ => '',
    };
  }

  String _ccExitReasonTag(String reason) {
    return switch (reason) {
      'delta_stop' => w('Δ0.35 Stop', 'Δ0.35止损'),
      'delta_roll_up' => w('Δ0.45 Roll Up', 'Δ0.45展期上移'),
      'delta_credit_roll' => w('Δ0.55 Credit Roll', 'Δ0.55零成本Roll'),
      'stop_3x_cap' => w('3x Stop', '3×止损'),
      'assigned_breach' => w('Breached', '穿价'),
      'closed_for_collar' => w('For Collar', '让位领口'),
      'panic_close_uncap' => w('Panic Uncap', '恐慌解封'),
      _ => w('Expired \$0', '到期归零'),
    };
  }

  List<Map<String, dynamic>> _currentCcLedgerForStrategy(
    Map<String, dynamic> doc,
  ) {
    final byStrat = asMap(doc['cc_ledgers_by_strategy']);
    return asList(byStrat[selectedStrategyId]);
  }

  String _humanWindowChipLabel(Map<String, dynamic> win) {
    final id = text(win['id']);
    return switch (id) {
      '2015-08' => w('2015 Aug', '2015 汇改'),
      '2018-Q4' => w('2018 Q4', '2018 缩表'),
      '2020-03' => w('2020 COVID', '2020 熔断'),
      '2022' => w('2022 Bear', '2022 慢熊'),
      '2024-08' => w('2024 Yen', '2024 日元'),
      '2025-04' => w('2025 Tariff', '2025 关税'),
      '2026-08_11_LIVE' => w('2026 LIVE', '2026 LIVE'),
      _ => w(text(win['pill_en']), text(win['pill_zh'])),
    };
  }

  String _humanWindowTitle(Map<String, dynamic> win) {
    final id = text(win['id']);
    return switch (id) {
      '2015-08' => w(
        '2015 Flash Crash & Devaluation Shock',
        '2015 年 8 月汇改闪崩',
      ),
      '2018-Q4' => w(
        '2018 Q4 Fed Tightening Selloff',
        '2018 四季度联储缩表急跌',
      ),
      '2020-03' => w(
        '2020 COVID-19 Liquidity Crash',
        '2020 年 3 月疫情流动性熔断',
      ),
      '2022' => w(
        '2022 Rate-Hike Grinding Bear Market',
        '2022 加息周期慢熊阴跌',
      ),
      '2024-08' => w(
        '2024 August Yen Carry Unwind',
        '2024 年 8 月日元套息平仓闪崩',
      ),
      '2025-04' => w(
        '2025 April Tariff Crash',
        '2025 年 4 月关税冲击大跌',
      ),
      '2026-08_11_LIVE' => w(
        '2026 Autumn Correction (Live)',
        '2026 秋季回调实战（进行中）',
      ),
      _ => w(text(win['title_en']), text(win['title_zh'])),
    };
  }

  List<Map<String, dynamic>> _currentEventsForStrategy(
    Map<String, dynamic> doc,
  ) {
    final byStrat = asMap(doc['events_by_strategy']);
    final list = asList(byStrat[selectedStrategyId]);
    if (list.isNotEmpty) return list;
    return asList(doc['events']);
  }

  List<Map<String, dynamic>> _currentLedgerForStrategy(
    Map<String, dynamic> doc,
  ) {
    final byStrat = asMap(doc['trade_ledgers_by_strategy']);
    final list = asList(byStrat[selectedStrategyId]);
    if (list.isNotEmpty) return list;
    return asList(doc['trade_ledger']);
  }

  Map<String, dynamic>? _findWindow(Map<String, dynamic> doc, String id) {
    for (final wItem in asList(doc['crisis_windows'])) {
      if (text(wItem['id']) == id) return wItem;
    }
    return null;
  }

  Map<String, dynamic> _findStrategySummary(
    Map<String, dynamic> doc,
    String id,
  ) {
    for (final s in asList(doc['strategies_summary'])) {
      if (text(s['id']) == id) return s;
    }
    return const {};
  }

  BoxDecoration _calmSurfaceDecoration() => BoxDecoration(
    color: p.card,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: p.border, width: 1),
  );

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return Container(
        key: const ValueKey('crisis-observatory-loading'),
        padding: const EdgeInsets.all(28),
        decoration: _calmSurfaceDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(minHeight: 2, color: _emerald),
            const SizedBox(height: 14),
            Text(
              w('Loading Crisis Observatory...', '正在加载危机观测数据...'),
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (error != null && data == null) {
      return Container(
        key: const ValueKey('crisis-observatory-error'),
        padding: const EdgeInsets.all(24),
        decoration: _calmSurfaceDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(
                'Crisis Observatory data is temporarily unavailable.',
                '危机观测数据暂时无法加载。',
              ),
              style: TextStyle(
                color: p.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const ValueKey('crisis-observatory-retry'),
              onPressed: () => unawaited(_loadObservatory()),
              child: Text(w('Retry', '重试')),
            ),
          ],
        ),
      );
    }

    final doc = data ?? const <String, dynamic>{};
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        final desktop = constraints.maxWidth >= 960;
        final gap = compact ? 18.0 : 24.0;
        return Column(
          key: const ValueKey('crisis-observatory-root'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildVerdictBlock(doc, compact: compact, desktop: desktop),
            SizedBox(height: gap),
            _buildSixSignalsBlock(
              doc,
              maxWidth: constraints.maxWidth,
              compact: compact,
            ),
            SizedBox(height: gap),
            _buildHeroChartBlock(doc, compact: compact, desktop: desktop),
            SizedBox(height: gap),
            _buildCrisisStoryAndTimelineBlock(
              doc,
              compact: compact,
              desktop: desktop,
            ),
          ],
        );
      },
    );
  }

  // ===========================================================================
  // BLOCK 1: Clean Verdict Header (今日信号结论)
  // ===========================================================================
  Widget _buildVerdictBlock(
    Map<String, dynamic> doc, {
    required bool compact,
    required bool desktop,
  }) {
    final snap = asMap(doc['live_market_snapshot']);
    final sigByStrat = asMap(doc['live_signal_states_by_strategy']);
    final stratSig = asMap(sigByStrat[selectedStrategyId]);
    final sig = stratSig.isNotEmpty
        ? stratSig
        : asMap(doc['live_signal_state']);
    final stratSummary = _findStrategySummary(doc, selectedStrategyId);
    final asOfDate = text(doc['as_of_date']).isEmpty
        ? widget.asOf
        : text(doc['as_of_date']);

    final qqqClose = _numVal(snap['qqq_close']);
    final ddAth = _numVal(snap['dd_from_ath_pct']);
    final vixRatio = _numVal(snap['vix_vix3m_ratio']);
    final rawLights = _numVal(snap['raw_crisis_score']).round();

    final regimeCode = text(sig['regime_code']);
    final slot1 = asMap(sig['slot1_naked_put']);
    final slot2 = asMap(sig['slot2_collar']);
    final s1OpenMap = asMap(slot1['open_position']);
    final s2OpenMap = asMap(slot2['open_position']);
    final s1Act = asMap(slot1['latest_action']);
    final s2Act = asMap(slot2['latest_action']);
    final gates = asList(sig['gate_checklist']);

    final s1Open = s1OpenMap.isNotEmpty;
    final s1PendingTp = s1Open && s1OpenMap['pending_tp'] == true;
    final s2Open = s2OpenMap.isNotEmpty;
    final s2PendingTp = s2Open && s2OpenMap['pending_tp'] == true;

    final Color statusColor = regimeCode == 'VIX110_TP_TRIGGERED'
        ? _emerald
        : (rawLights >= 5
              ? _coral
              : (rawLights >= 3 || regimeCode.contains('ACTIVE')
                    ? _amber
                    : _emerald));

    final String verdictHeadline = switch (regimeCode) {
      'VIX110_TP_TRIGGERED' => w(
        'Deep-ITM Panic Harvest Armed · Monetize Put Next Open ($rawLights/6 Lights)',
        '深跌实值恐慌触发 · 期权次日开盘止盈换股（$rawLights/6 亮灯）',
      ),
      'DUAL_SLOT_FULL_SHIELD' => w(
        'Full Hedge Active · Naked Put + Collar On',
        '双槽满盾保护中 · 首仓裸 Put + 次仓领口',
      ),
      'SLOT1_NAKED_PUT_ACTIVE' => w(
        'Early Warning · First-Half Naked Put Active',
        '高位预警 · 首仓 50% 裸 Put 保护中',
      ),
      'LOW_SPOT_FREEZE_NO_NEW_COLLAR' => w(
        '100% Hold QQQ · Call Caps Paused in Pullback ($rawLights/6 Lights)',
        '100% 持有 QQQ · 低位暂停新卖 Call（$rawLights/6 亮灯）',
      ),
      _ => w(
        'Calm Trend · 100% Hold QQQ ($rawLights/6 Lights)',
        '顺风区间 · 100% 持有 QQQ（$rawLights/6 亮灯）',
      ),
    };

    final totalLastHarvest =
        _numVal(s1Act['u1_net_pnl_usd']) + _numVal(s2Act['u1_net_pnl_usd']);
    final totalLastShares =
        _numVal(s1Act['u1_shares_added']) + _numVal(s2Act['u1_shares_added']);
    final lastExitDate = text(s2Act['exit_date']).length >= 10
        ? text(s2Act['exit_date']).substring(5)
        : (text(s1Act['exit_date']).length >= 10
              ? text(s1Act['exit_date']).substring(5)
              : '');

    final String humanSummary;
    if (regimeCode == 'VIX110_TP_TRIGGERED') {
      final armedMap = s1PendingTp ? s1OpenMap : s2OpenMap;
      final armedPnl = _numVal(armedMap['mtm_pnl_usd']);
      final armedSh = _numVal(armedMap['est_shares_added']);
      final armedKp = _numVal(armedMap['kp']);
      final armedSpot = _numVal(armedMap['mtm_spot'], qqqClose);
      final s2Pnl = _numVal(s2Act['u1_net_pnl_usd']);
      final s2Date = text(s2Act['exit_date']).length >= 10
          ? text(s2Act['exit_date']).substring(5)
          : '';
      humanSummary = w(
        '${s2Pnl > 0 && s2Date.isNotEmpty ? 'Collar already banked ${_fmtUsd(s2Pnl, signed: true)} on $s2Date and freed the Call cap; ' : ''}active Put (K=\$${armedKp.toStringAsFixed(0)}) ignored the shallow inversion and is now deep ITM at \$${armedSpot.toStringAsFixed(0)} — armed to monetize ${_fmtUsd(armedPnl, signed: true)} (+${armedSh.toStringAsFixed(1)} QQQ sh) at next Open.',
        '${s2Pnl > 0 && s2Date.isNotEmpty ? '$s2Date 次仓领口已先行落袋 ${_fmtUsd(s2Pnl, signed: true)} 并解除卖 Call 封顶；' : ''}持仓保护（行权 \$${armedKp.toStringAsFixed(0)}）无视前期浅倒挂，今日深跌实值至 \$${armedSpot.toStringAsFixed(0)} 触发止盈（浮盈 ${_fmtUsd(armedPnl, signed: true)} / +${armedSh.toStringAsFixed(1)} 股待次日开盘换股）。',
      );
    } else if (regimeCode == 'LOW_SPOT_FREEZE_NO_NEW_COLLAR') {
      humanSummary = w(
        '${lastExitDate.isNotEmpty && totalLastHarvest > 0 ? 'Harvested ${_fmtUsd(totalLastHarvest, signed: true)} (+${totalLastShares.toStringAsFixed(1)} extra QQQ shares) on $lastExitDate panic spike; ' : ''}new Call caps stay paused below -5% drawdown while holding 100% QQQ for full rebound upside.',
        '${lastExitDate.isNotEmpty && totalLastHarvest > 0 ? '$lastExitDate 已在恐慌倒挂中止盈落袋 ${_fmtUsd(totalLastHarvest, signed: true)}（低位增持 +${totalLastShares.toStringAsFixed(1)} 股 QQQ）；' : ''}当前跌离高点超 5% 暂停新卖 Call，100% 满仓 QQQ 完整保留反弹空间。',
      );
    } else if (regimeCode == 'DUAL_SLOT_FULL_SHIELD' ||
        regimeCode == 'SLOT1_NAKED_PUT_ACTIVE') {
      humanSummary = w(
        'Protective puts are in place near market highs; hold 100% QQQ until ${_humanTpModeLabel(selectedTpMode)} take-profit triggers to monetize into extra shares.',
        '高位看跌保护已就位；底仓 100% 持有 QQQ，按当前「${_humanTpModeLabel(selectedTpMode)}」规则等待止盈触发并抄底增持正股。',
      );
    } else {
      humanSummary = w(
        'Hold 100% QQQ with zero option drag until top breadth divergence or 4+ crisis lights appear near highs.',
        '保持 100% QQQ 现货复利、零期权损耗，静待高位出现市场宽度背离或 4 盏以上危机灯再买保护。',
      );
    }

    // 3 plain-human pure-options status columns (Core QQQ + Slot 1 + Slot 2)
    final bhSummary = _findStrategySummary(doc, 'BH_Pure_QQQ');
    final totalShares = _numVal(stratSummary['final_shares'], 2719.32);
    final bhShares = _numVal(
      stratSummary['bh_final_shares'],
      _numVal(bhSummary['final_shares'], 2117.34),
    );
    final extraShares = _numVal(
      stratSummary['extra_shares_vs_bh'],
      totalShares - bhShares,
    );
    final extraSharesPct = _numVal(
      stratSummary['extra_shares_pct'],
      bhShares > 0 ? (extraShares / bhShares) * 100.0 : 0.0,
    );
    final coreValue = w(
      '100% QQQ · ${_fmtShares(totalShares)} sh',
      '100% 满仓 QQQ · ${_fmtShares(totalShares)} 股',
    );
    final coreSub = w(
      'vs ${_fmtShares(bhShares)} sh BH · ${_fmtShares(extraShares, signed: true)} sh (${_fmtPct(extraSharesPct)})',
      '基准 ${_fmtShares(bhShares)} 股 · 累计多买 ${_fmtShares(extraShares, signed: true)} 股（${_fmtPct(extraSharesPct)}）',
    );

    final s1Value = s1PendingTp
        ? w(
            'TP Armed ${_fmtUsd(_numVal(s1OpenMap['mtm_pnl_usd']), signed: true)} · Next Open',
            '实值止盈已触发 ${_fmtUsd(_numVal(s1OpenMap['mtm_pnl_usd']), signed: true)}',
          )
        : (s1Open
              ? w('Active Hedge', '保护运行中')
              : (_numVal(s1Act['u1_net_pnl_usd']) > 0
                    ? w(
                        'Harvested ${_fmtUsd(_numVal(s1Act['u1_net_pnl_usd']), signed: true)} · Standby',
                        '已止盈 ${_fmtUsd(_numVal(s1Act['u1_net_pnl_usd']), signed: true)} · 待命',
                      )
                    : w('Standby', '待命')));
    final s1Sub = s1Open
        ? w(
            '${text(s1OpenMap['entry_date']).length >= 10 ? text(s1OpenMap['entry_date']).substring(5) : ''} @\$${_numVal(s1OpenMap['entry_spot']).toStringAsFixed(0)} (K=\$${_numVal(s1OpenMap['kp']).toStringAsFixed(0)}) · ${_numVal(s1OpenMap['rem_dte']).round()}D left · +${_numVal(s1OpenMap['est_shares_added']).toStringAsFixed(1)} sh',
            '${text(s1OpenMap['entry_date']).length >= 10 ? text(s1OpenMap['entry_date']).substring(5) : ''} @\$${_numVal(s1OpenMap['entry_spot']).toStringAsFixed(0)} 开（行权 \$${_numVal(s1OpenMap['kp']).toStringAsFixed(0)}）· 剩 ${_numVal(s1OpenMap['rem_dte']).round()} 天 · +${_numVal(s1OpenMap['est_shares_added']).toStringAsFixed(1)} 股',
          )
        : (text(s1Act['entry_date']).length >= 10 &&
                  text(s1Act['exit_date']).length >= 10
              ? w(
                  '${text(s1Act['entry_date']).substring(5)} @\$${_numVal(s1Act['entry_spot']).toStringAsFixed(0)} -> ${text(s1Act['exit_date']).substring(5)} @\$${_numVal(s1Act['exit_spot']).toStringAsFixed(0)} (+${_numVal(s1Act['u1_shares_added']).toStringAsFixed(1)} sh)',
                  '${text(s1Act['entry_date']).substring(5)} @\$${_numVal(s1Act['entry_spot']).toStringAsFixed(0)} 开 → ${text(s1Act['exit_date']).substring(5)} @\$${_numVal(s1Act['exit_spot']).toStringAsFixed(0)} 平（+${_numVal(s1Act['u1_shares_added']).toStringAsFixed(1)} 股）',
                )
              : w('50% size · No upside Call cap', '50% 仓位 · 不卖 Call 保留冲顶'));

    final s2Frozen = text(slot2['status']).contains('FROZEN');
    final s2Value = s2PendingTp
        ? w(
            'TP Armed ${_fmtUsd(_numVal(s2OpenMap['mtm_pnl_usd']), signed: true)} · Next Open',
            '止盈已触发 ${_fmtUsd(_numVal(s2OpenMap['mtm_pnl_usd']), signed: true)}',
          )
        : (s2Open
              ? w('Active Collar', '领口保护中')
              : (s2Frozen
                    ? (_numVal(s2Act['u1_net_pnl_usd']) > 0
                          ? w(
                              'Harvested ${_fmtUsd(_numVal(s2Act['u1_net_pnl_usd']), signed: true)} · Paused',
                              '已止盈 ${_fmtUsd(_numVal(s2Act['u1_net_pnl_usd']), signed: true)} · 低位暂停',
                            )
                          : w('Paused Below -5%', '低位暂停卖 Call'))
                    : w('Standby (30D Step)', '待命（满 30 天开启）')));
    final s2Sub = s2Open
        ? w(
            '${text(s2OpenMap['entry_date']).length >= 10 ? text(s2OpenMap['entry_date']).substring(5) : ''} @\$${_numVal(s2OpenMap['entry_spot']).toStringAsFixed(0)} (K=\$${_numVal(s2OpenMap['kp']).toStringAsFixed(0)}) · ${_numVal(s2OpenMap['rem_dte']).round()}D left',
            '${text(s2OpenMap['entry_date']).length >= 10 ? text(s2OpenMap['entry_date']).substring(5) : ''} @\$${_numVal(s2OpenMap['entry_spot']).toStringAsFixed(0)} 开（行权 \$${_numVal(s2OpenMap['kp']).toStringAsFixed(0)}）· 剩 ${_numVal(s2OpenMap['rem_dte']).round()} 天',
          )
        : (text(s2Act['entry_date']).length >= 10 &&
                  text(s2Act['exit_date']).length >= 10
              ? w(
                  '${text(s2Act['entry_date']).substring(5)} @\$${_numVal(s2Act['entry_spot']).toStringAsFixed(0)} -> ${text(s2Act['exit_date']).substring(5)} @\$${_numVal(s2Act['exit_spot']).toStringAsFixed(0)} (+${_numVal(s2Act['u1_shares_added']).toStringAsFixed(1)} sh)',
                  '${text(s2Act['entry_date']).substring(5)} @\$${_numVal(s2Act['entry_spot']).toStringAsFixed(0)} 开 → ${text(s2Act['exit_date']).substring(5)} @\$${_numVal(s2Act['exit_spot']).toStringAsFixed(0)} 平（+${_numVal(s2Act['u1_shares_added']).toStringAsFixed(1)} 股）',
                )
              : w('Zero-cost Put + Call collar', '零成本领口保护'));

    return Container(
      key: const ValueKey('crisis-observatory-command-center'),
      padding: EdgeInsets.all(compact ? 16 : 22),
      decoration: _calmSurfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      verdictHeadline,
                      style: TextStyle(
                        color: p.text,
                        fontSize: compact ? 17 : 19,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  InkWell(
                    key: const ValueKey('crisis-observatory-qqq-chip'),
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => widget.onCompany('QQQ'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Text(
                        'QQQ \$${qqqClose.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: p.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    w(
                      '· ${_fmtPct(ddAth)} off high · VIX/3M ${vixRatio.toStringAsFixed(2)} · $asOfDate',
                      '· 距高点 ${_fmtPct(ddAth)} · VIX/3M ${vixRatio.toStringAsFixed(2)} · $asOfDate',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 12.5),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            humanSummary,
            style: TextStyle(
              color: p.muted,
              fontSize: compact ? 13 : 13.5,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 18),
          Container(height: 1, color: p.border),
          const SizedBox(height: 16),
          if (desktop)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildMinimalSlotColumn(
                      keyId: 'core',
                      label: w('Core Equity Position', '现货底仓'),
                      value: coreValue,
                      sub: coreSub,
                      accent: p.text,
                    ),
                  ),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 18),
                    color: p.border,
                  ),
                  Expanded(
                    child: _buildMinimalSlotColumn(
                      keyId: 'slot1',
                      label: w('First-Half Naked Put (50%)', '首仓裸 Put（50%）'),
                      value: s1Value,
                      sub: s1Sub,
                      accent: s1PendingTp ? _emerald : (s1Open ? _amber : _emerald),
                    ),
                  ),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 18),
                    color: p.border,
                  ),
                  Expanded(
                    child: _buildMinimalSlotColumn(
                      keyId: 'slot2',
                      label: w('Second-Half Collar (50%)', '次仓领口（50%）'),
                      value: s2Value,
                      sub: s2Sub,
                      accent: s2PendingTp
                          ? _emerald
                          : (s2Open ? _amber : (s2Frozen ? p.text : _emerald)),
                    ),
                  ),
                ],
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildMinimalSlotColumn(
                  keyId: 'core',
                  label: w('Core Equity Position', '现货底仓'),
                  value: coreValue,
                  sub: coreSub,
                  accent: p.text,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Container(height: 1, color: p.border),
                ),
                _buildMinimalSlotColumn(
                  keyId: 'slot1',
                  label: w('First-Half Naked Put (50%)', '首仓裸 Put（50%）'),
                  value: s1Value,
                  sub: s1Sub,
                  accent: s1PendingTp ? _emerald : (s1Open ? _amber : _emerald),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Container(height: 1, color: p.border),
                ),
                _buildMinimalSlotColumn(
                  keyId: 'slot2',
                  label: w('Second-Half Collar (50%)', '次仓领口（50%）'),
                  value: s2Value,
                  sub: s2Sub,
                  accent: s2PendingTp
                      ? _emerald
                      : (s2Open ? _amber : (s2Frozen ? p.text : _emerald)),
                ),
              ],
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              InkWell(
                key: const ValueKey('crisis-rules-toggle'),
                borderRadius: BorderRadius.circular(6),
                onTap: () =>
                    setState(() => showRulesDisclosure = !showRulesDisclosure),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        showRulesDisclosure
                            ? w('Hide Trigger Rules', '收起触发条件')
                            : w('View Trigger Rules', '查看触发条件'),
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        showRulesDisclosure
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 16,
                        color: p.muted,
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                w(
                  'Take-Profit: ${_humanTpModeLabel(selectedTpMode)}${selectedCcMode != 'cc_off' ? ' · CC: ${_humanCcModeLabel(selectedCcMode)}' : ''}',
                  '止盈：${_humanTpModeLabel(selectedTpMode)}${selectedCcMode != 'cc_off' ? ' · 卖 Call：${_humanCcModeLabel(selectedCcMode)}' : ''}',
                ),
                style: TextStyle(
                  color: p.muted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          if (showRulesDisclosure) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 18,
                    runSpacing: 8,
                    children: [
                      for (final g in gates) _buildCalmGateItem(g),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    w(
                      'Execution rules: 1) Hold 100% QQQ forever. 2) Within 5% of ATH with calm volatility (VXN <= 22) and either AD < 50DMA or >= 4 lights -> buy 50% 90-day -10% Put (no Call cap). 3) After 30 days if still active -> add 50% zero-cost Collar. 4) Selectable Take-Profit (${_humanTpModeLabel(selectedTpMode)}): ${_humanTpModeHint(selectedTpMode)}. 5) Never open new Collars below -5% drawdown.',
                      '实战规则：① 底仓 100% 持有 QQQ 永不卖股；② 距高点 5% 内、波动率 VXN ≤ 22，且涨跌线跌破 50 日线或亮起 ≥ 4 盏灯 → 次日开盘买 50% 仓位 90 天 -10% 裸 Put（不卖封顶）；③ 满 30 天仍预警 → 补齐 50% 零成本领口；④ 可选止盈模式（${_humanTpModeLabel(selectedTpMode)}）：${_humanTpModeHint(selectedTpMode)}；⑤ 跌离高点超 5% 严禁新卖 Call。',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMinimalSlotColumn({
    required String keyId,
    required String label,
    required String value,
    required String sub,
    required Color accent,
  }) {
    return Column(
      key: ValueKey('crisis-slot-card-$keyId'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: p.muted,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          value,
          style: TextStyle(
            color: accent,
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          sub,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 11.5),
        ),
      ],
    );
  }

  Widget _buildCalmGateItem(Map<String, dynamic> gate) {
    final passed = gate['passed'] == true;
    final label = w(text(gate['label_en']), text(gate['label_zh']));
    final reading = text(gate['reading']);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: passed ? _emerald : p.muted.withValues(alpha: 0.45),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$label: $reading',
          style: TextStyle(
            color: passed ? p.text : p.muted,
            fontSize: 12,
            fontWeight: passed ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // BLOCK 2: Minimalist 6 Crisis Signals Strip (六大危机信号状态)
  // ===========================================================================
  Widget _buildSixSignalsBlock(
    Map<String, dynamic> doc, {
    required double maxWidth,
    required bool compact,
  }) {
    final lights = asList(doc['six_crisis_lights']);
    final ad = asMap(doc['ad_line_signal']);
    final litCount = lights.where((item) => item['lit'] == true).length;
    final adBelow = ad['below_50ma'] == true;
    final adTopDiv = ad['top_divergence_active'] == true;

    final int cols = maxWidth >= 900 ? 3 : (maxWidth >= 560 ? 2 : 1);
    final rowsCount =
        cols == 0 ? 0 : ((lights.length + cols - 1) / cols).floor();

    return Container(
      key: const ValueKey('crisis-observatory-six-lights'),
      padding: EdgeInsets.all(compact ? 16 : 22),
      decoration: _calmSurfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  w('Six Macro Crisis Signals', '六大危机信号状态'),
                  style: TextStyle(
                    color: p.text,
                    fontSize: compact ? 15.5 : 16.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                w('$litCount / 6 Active', '$litCount / 6 亮灯'),
                style: TextStyle(
                  color: litCount >= 4
                      ? _coral
                      : (litCount >= 2 ? _amber : _emerald),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(height: 1, color: p.border),
          for (var r = 0; r < rowsCount; r++) ...[
            if (r > 0) Container(height: 1, color: p.border),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var c = 0; c < cols; c++) ...[
                    if (c > 0) Container(width: 1, color: p.border),
                    Expanded(
                      child: (r * cols + c < lights.length)
                          ? _buildCleanLightCell(
                              lights[r * cols + c],
                              compact: compact,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ],
          Container(height: 1, color: p.border),
          const SizedBox(height: 12),
          Row(
            key: const ValueKey('crisis-observatory-ad-banner'),
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: adTopDiv ? _amber : (adBelow ? _coral : _emerald),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  adBelow
                      ? w(
                          'US Stock Advance-Decline Line (AD Line): Below 50DMA (${_numVal(ad['ad_line']).toStringAsFixed(0)} vs ${_numVal(ad['ad_sma50']).toStringAsFixed(0)}${text(ad['last_top_divergence_date']).isNotEmpty ? ' · Top divergence ${text(ad['last_top_divergence_date'])}' : ''})',
                          '全美股票涨跌线（AD Line）：低于 50 日均线（${_numVal(ad['ad_line']).toStringAsFixed(0)} vs ${_numVal(ad['ad_sma50']).toStringAsFixed(0)}${text(ad['last_top_divergence_date']).isNotEmpty ? ' · 顶背离预警 ${text(ad['last_top_divergence_date'])}' : ''}）',
                        )
                      : w(
                          'US Stock Advance-Decline Line (AD Line): Above 50DMA (Healthy Breadth)',
                          '全美股票涨跌线（AD Line）：站上 50 日均线（宽度健康）',
                        ),
                  style: TextStyle(color: p.muted, fontSize: 12.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  (String, String, String) _cleanLightDisplay(Map<String, dynamic> light) {
    final keyStr = text(light['key']);
    final rawReading = text(light['reading_value']);
    var primary = rawReading;
    final parenIdx = rawReading.indexOf('(');
    if (parenIdx > 0) {
      primary = rawReading.substring(0, parenIdx).trim();
    }
    primary = primary
        .replaceFirst('2Y ', '')
        .replaceFirst('10Y-2Y ', '')
        .replaceFirst(' >200D', '');

    return switch (keyStr) {
      'sig1_fed' => (
        w('Front-End Rates', '短端利率'),
        primary,
        w('2Y Treasury vs 12M low & 63DMA', '2年期美债较年内低点显著抬升'),
      ),
      'sig2_credit' => (
        w('Credit Spread', '信用利差'),
        primary,
        w('Corporate Baa-10Y spread widening', '企业信用利差走阔破季线'),
      ),
      'sig3_breadth' => (
        w('Market Breadth', '市场宽度'),
        primary,
        w('Share of stocks above 200DMA', '站上年线个股占比显著回落'),
      ),
      'sig4_copper' => (
        w('Industrial Copper', '工业铜价'),
        primary,
        w('COMEX copper vs 12M high & 63DMA', '铜价较年内高点回撤破季线'),
      ),
      'sig5_defensive' => (
        w('Defensive Rotation', '防御抱团'),
        primary,
        w('Utilities/Staples/Health vs Cyclicals', '防御板块相对周期板块走强'),
      ),
      'sig6_macro' => (
        w('Yield Curve', '收益率曲线'),
        primary,
        w('10Y-2Y curve flattening / NFCI', '期限利差压平与金融条件收紧'),
      ),
      _ => (
        w(text(light['short_en']), text(light['short_zh'])),
        primary,
        w(text(light['threshold_en']), text(light['threshold_zh'])),
      ),
    };
  }

  Widget _buildCleanLightCell(
    Map<String, dynamic> light, {
    required bool compact,
  }) {
    final lit = light['lit'] == true;
    final keyStr = text(light['key']);
    final info = _cleanLightDisplay(light);

    return Padding(
      key: ValueKey('crisis-light-card-$keyStr'),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 4 : 14,
        vertical: 14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: lit ? _coral : Colors.transparent,
                  shape: BoxShape.circle,
                  border: lit
                      ? null
                      : Border.all(
                          color: p.muted.withValues(alpha: 0.5),
                          width: 1.4,
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  info.$1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                info.$2,
                style: TextStyle(
                  color: lit ? _coral : p.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text(
              info.$3,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.muted, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // BLOCK 3: Hero Interactive Chart + Crisis Zoom-In (历史保护策略 vs 死拿 QQQ)
  // ===========================================================================
  Widget _buildHeroChartBlock(
    Map<String, dynamic> doc, {
    required bool compact,
    required bool desktop,
  }) {
    final allDaily = asList(doc['daily_series']);
    final windows = asList(doc['crisis_windows']);
    final activeWin = (selectedWindowId == 'ALL' ||
            selectedWindowId == '1Y' ||
            selectedWindowId == '3Y')
        ? null
        : _findWindow(doc, selectedWindowId);

    final List<Map<String, dynamic>> visibleDaily;
    if (activeWin != null) {
      visibleDaily = allDaily.where((row) {
        final dt = text(row['date']);
        return dt.compareTo(text(activeWin['start_date'])) >= 0 &&
            dt.compareTo(text(activeWin['end_date'])) <= 0;
      }).toList();
    } else if (selectedWindowId == '1Y' && allDaily.length > 252) {
      visibleDaily = allDaily.sublist(allDaily.length - 252);
    } else if (selectedWindowId == '3Y' && allDaily.length > 756) {
      visibleDaily = allDaily.sublist(allDaily.length - 756);
    } else {
      visibleDaily = allDaily;
    }

    final rebasedMode = selectedWindowId != 'ALL';
    final stratSummary = _findStrategySummary(doc, selectedStrategyId);
    final bhSummary = _findStrategySummary(doc, 'BH_Pure_QQQ');
    final navKey = _strategyNavKeys[selectedStrategyId] ?? 'nav_u1';

    final allEvents = _currentEventsForStrategy(doc);
    final ccLedgerForStrat = _currentCcLedgerForStrategy(doc);
    final visibleStart = visibleDaily.isNotEmpty
        ? text(visibleDaily.first['date'])
        : '';
    final visibleEnd = visibleDaily.isNotEmpty
        ? text(visibleDaily.last['date'])
        : '';
    final visibleEvents = visibleDaily.isEmpty
        ? const <Map<String, dynamic>>[]
        : allEvents.where((ev) {
            final dt = text(ev['date']);
            return dt.compareTo(visibleStart) >= 0 &&
                dt.compareTo(visibleEnd) <= 0;
          }).toList();
    final ccChartEvents = selectedCcMode == 'cc_off'
        ? const <Map<String, dynamic>>[]
        : _buildCcChartEvents(ccLedgerForStrat, visibleStart, visibleEnd);
    final combinedVisibleEvents = <Map<String, dynamic>>[
      ...visibleEvents,
      ...ccChartEvents,
    ];
    final hasPutLayer = selectedStrategyId != 'NoPut_CallOnly';
    final hasCallLayer = selectedCcMode != 'cc_off';
    final hasRollLayer =
        selectedCcMode == 'cc_d12_r45' || selectedCcMode == 'cc_d12_cr55';
    final hasStopLayer = selectedCcMode == 'cc_d12_d35';

    final isHoverActive = hoverIndex >= 0 && hoverIndex < visibleDaily.length;
    final hoveredRow = isHoverActive
        ? visibleDaily[hoverIndex]
        : (visibleDaily.isNotEmpty
              ? visibleDaily.last
              : const <String, dynamic>{});

    final startStratNav = visibleDaily.isNotEmpty
        ? _numVal(visibleDaily.first[navKey], 200000)
        : 200000.0;
    final startBhNav = visibleDaily.isNotEmpty
        ? _numVal(visibleDaily.first['nav_bh'], 200000)
        : 200000.0;

    final hovStratNav = _numVal(hoveredRow[navKey]);
    final hovBhNav = _numVal(hoveredRow['nav_bh']);
    final hovStratRet = startStratNav > 0
        ? (hovStratNav / startStratNav - 1) * 100
        : 0.0;
    final hovBhRet = startBhNav > 0 ? (hovBhNav / startBhNav - 1) * 100 : 0.0;

    final strategyTabs = [
      ..._primaryStrategies,
      if (!_primaryStrategies.contains(selectedStrategyId)) selectedStrategyId,
    ];

    final String subtitleText;
    if (activeWin != null) {
      subtitleText = w(
        'Zoomed In: ${_humanWindowTitle(activeWin)} (Rebased to 100)',
        '危机放大：${_humanWindowTitle(activeWin)}（起点归 100）',
      );
    } else if (selectedWindowId == '1Y') {
      subtitleText = w(
        'Trailing 1 Year ($visibleStart to $visibleEnd, Rebased to 100)',
        '近 1 年走势（$visibleStart 至 $visibleEnd · 起点归 100）',
      );
    } else if (selectedWindowId == '3Y') {
      subtitleText = w(
        'Trailing 3 Years ($visibleStart to $visibleEnd, Rebased to 100)',
        '近 3 年走势（$visibleStart 至 $visibleEnd · 起点归 100）',
      );
    } else {
      subtitleText = w(
        '\$200,000 initial capital (2015–2026, dividends reinvested)',
        '\$200,000 起投（2015–2026 股息再投 · 含真实期权滑点）',
      );
    }

    return Container(
      key: const ValueKey('crisis-observatory-chart-section'),
      padding: EdgeInsets.all(compact ? 16 : 22),
      decoration: _calmSurfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w(
                      'Protected Strategy vs Buy & Hold QQQ',
                      '历史保护策略 vs 死拿 QQQ',
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: compact ? 16 : 17.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitleText,
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
                ],
              ),
              Wrap(
                spacing: compact ? 16 : 24,
                runSpacing: 8,
                children: [
                  _heroStatMetric(
                    label: w('Ending Value', '策略终值'),
                    value: _fmtUsd(_numVal(stratSummary['end_nav'])),
                    sub: w(
                      'vs QQQ ${_fmtUsd(_numVal(bhSummary['end_nav']))}',
                      '死拿 ${_fmtUsd(_numVal(bhSummary['end_nav']))}',
                    ),
                    color: p.text,
                  ),
                  _heroStatMetric(
                    label: w('Net Alpha', '累计超额'),
                    value: _fmtUsd(
                      _numVal(stratSummary['net_alpha_usd']),
                      signed: true,
                    ),
                    sub: w(
                      'CAGR ${_numVal(stratSummary['cagr_pct']).toStringAsFixed(1)}%',
                      '年化 ${_numVal(stratSummary['cagr_pct']).toStringAsFixed(1)}%',
                    ),
                    color: _emerald,
                  ),
                  Builder(
                    builder: (_) {
                      final totSh = _numVal(stratSummary['final_shares']);
                      final bhSh = _numVal(
                        stratSummary['bh_final_shares'],
                        _numVal(bhSummary['final_shares'], 2117.34),
                      );
                      final exSh = _numVal(
                        stratSummary['extra_shares_vs_bh'],
                        totSh - bhSh,
                      );
                      final exPct = _numVal(
                        stratSummary['extra_shares_pct'],
                        bhSh > 0 ? (exSh / bhSh) * 100.0 : 0.0,
                      );
                      return _heroStatMetric(
                        label: w('Total Shares · Extra %', '总股数 · 多买比例'),
                        value: w(
                          '${_fmtShares(totSh)} sh',
                          '${_fmtShares(totSh)} 股',
                        ),
                        sub: w(
                          '${_fmtShares(exSh, signed: true)} sh (${_fmtPct(exPct)})',
                          '多买 ${_fmtShares(exSh, signed: true)} 股（${_fmtPct(exPct)}）',
                        ),
                        color: exPct >= 0 ? _emerald : p.text,
                      );
                    },
                  ),
                  _heroStatMetric(
                    label: w('Max Drawdown', '最大回撤'),
                    value:
                        '${_numVal(stratSummary['max_dd_pct']).toStringAsFixed(1)}%',
                    sub: w(
                      'vs ${_numVal(bhSummary['max_dd_pct']).toStringAsFixed(1)}%',
                      '死拿 ${_numVal(bhSummary['max_dd_pct']).toStringAsFixed(1)}%',
                    ),
                    color: p.text,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (switchingTpMode)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: LinearProgressIndicator(minHeight: 2, color: _emerald),
            ),
          Wrap(
            key: const ValueKey('crisis-put-strategy-bar'),
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    w('Crisis Put Strategy:', '危机 Put 策略：'),
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  for (final sid in strategyTabs) _buildCalmStrategyTab(sid),
                ],
              ),
              if (!rebasedMode)
                InkWell(
                  key: const ValueKey('crisis-scale-toggle'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => setState(() => useLogScale = !useLogScale),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      useLogScale
                          ? w('Scale: Log', '坐标：对数')
                          : w('Scale: Linear', '坐标：线性'),
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                )
              else
                InkWell(
                  key: const ValueKey('crisis-zoom-reset-btn'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () {
                    setState(() {
                      selectedWindowId = 'ALL';
                      hoverIndex = -1;
                    });
                    _emitSelection();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      w('Reset to All 12Y', '返回全部 12 年'),
                      style: const TextStyle(
                        color: _emerald,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (hasPutLayer) ...[
            const SizedBox(height: 10),
            Wrap(
              key: const ValueKey('crisis-tp-mode-bar'),
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  w('Put Take-Profit:', 'Put 止盈规则：'),
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                for (final mid in _tpModeIds) _buildCalmTpModeTab(mid),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _humanTpModeHint(selectedTpMode),
              key: const ValueKey('crisis-tp-mode-hint'),
              style: TextStyle(color: p.muted, fontSize: 11.5, height: 1.4),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            key: const ValueKey('crisis-cc-mode-bar'),
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w('Overlay Short Call:', '叠加平时卖 Call：'),
                style: TextStyle(
                  color: p.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              for (final cid in _ccModeIds) _buildCalmCcModeTab(cid),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _humanCcModeHint(selectedCcMode, stratSummary),
            key: const ValueKey('crisis-cc-mode-hint'),
            style: TextStyle(color: p.muted, fontSize: 11.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('crisis-active-combo-badge'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: p.text.withValues(alpha: 0.035),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: p.border),
            ),
            child: Text(
              _activeComboBadgeText(),
              style: TextStyle(
                color: p.text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildCleanZoomChip(
                  id: 'ALL',
                  label: w('All 12Y', '全部 12 年'),
                  isLive: false,
                ),
                const SizedBox(width: 6),
                _buildCleanZoomChip(
                  id: '1Y',
                  label: w('1Y', '近 1 年'),
                  isLive: false,
                ),
                const SizedBox(width: 6),
                _buildCleanZoomChip(
                  id: '3Y',
                  label: w('3Y', '近 3 年'),
                  isLive: false,
                ),
                for (final win in windows) ...[
                  const SizedBox(width: 6),
                  _buildCleanZoomChip(
                    id: text(win['id']),
                    label: _humanWindowChipLabel(win),
                    isLive: win['is_live'] == true,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                key: const ValueKey('crisis-chart-legend'),
                spacing: 14,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _cleanLegendItem(
                    color: _emerald,
                    dashed: false,
                    label: _humanStrategyLabel(selectedStrategyId),
                  ),
                  _cleanLegendItem(
                    color: p.muted,
                    dashed: true,
                    label: w('Buy & Hold QQQ', '死拿 QQQ'),
                  ),
                  if (hasPutLayer) ...[
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.putOpen,
                      label: w('Buy Put / Collar', '买 Put / 领口'),
                    ),
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.putTp,
                      label: w('Put TP Harvest', 'Put 止盈换股'),
                    ),
                  ],
                  if (hasCallLayer)
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.ccOpen,
                      label: w('Sell Call (▲ Up)', '卖 Call 开仓'),
                    ),
                  if (hasRollLayer)
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.ccRoll,
                      label: w('Call Roll Up', 'Call 展期 Roll'),
                    ),
                  if (hasStopLayer)
                    _cleanVectorMarkerLegend(
                      kind: _CrisisMarkerKind.ccStop,
                      label: w('Call Δ0.35 Stop', 'Call Δ0.35 止损'),
                    ),
                ],
              ),
              if (hoveredRow.isNotEmpty)
                Text(
                  !rebasedMode
                      ? '${text(hoveredRow['date'])} · ${_fmtUsd(hovStratNav)} vs ${_fmtUsd(hovBhNav)} · VIX/3M ${_numVal(hoveredRow['vix_ratio']).toStringAsFixed(2)}'
                      : '${text(hoveredRow['date'])} · ${_fmtPct(hovStratRet)} vs QQQ ${_fmtPct(hovBhRet)} · QQQ \$${_numVal(hoveredRow['qqq_close']).toStringAsFixed(1)}',
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, chartConstraints) {
              final chartWidth = chartConstraints.maxWidth;
              final mainHeight = compact ? 290.0 : 350.0;
              final totalHeight = showSignalSubTrack
                  ? mainHeight + 84.0
                  : mainHeight;
              final hoverEvents = isHoverActive
                  ? _eventsNearHoverIndex(
                      visibleDaily: visibleDaily,
                      visibleEvents: combinedVisibleEvents,
                      hoverIdx: hoverIndex,
                      chartWidth: chartWidth,
                    )
                  : const <Map<String, dynamic>>[];

              return MouseRegion(
                onHover: (ev) => _updateHoverFromDx(
                  ev.localPosition.dx,
                  chartWidth,
                  visibleDaily.length,
                ),
                onExit: (_) => setState(() => hoverIndex = -1),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _updateHoverFromDx(
                    d.localPosition.dx,
                    chartWidth,
                    visibleDaily.length,
                  ),
                  onPanDown: (d) => _updateHoverFromDx(
                    d.localPosition.dx,
                    chartWidth,
                    visibleDaily.length,
                  ),
                  onPanUpdate: (d) => _updateHoverFromDx(
                    d.localPosition.dx,
                    chartWidth,
                    visibleDaily.length,
                  ),
                  child: SizedBox(
                    key: const ValueKey('crisis-observatory-canvas'),
                    width: chartWidth,
                    height: totalHeight,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            size: Size(chartWidth, totalHeight),
                            painter: _CrisisObservatoryChartPainter(
                              rows: visibleDaily,
                              events: combinedVisibleEvents,
                              navKey: navKey,
                              rebasedMode: rebasedMode,
                              useLogScale: !rebasedMode && useLogScale,
                              showSubTrack: showSignalSubTrack,
                              hoverIndex: hoverIndex,
                              borderColor: p.border,
                              mutedColor: p.muted,
                              textColor: p.text,
                            ),
                          ),
                        ),
                        if (isHoverActive && hoveredRow.isNotEmpty)
                          _buildCleanHoverTooltip(
                            row: hoveredRow,
                            hoverEvents: hoverEvents,
                            navKey: navKey,
                            startStratNav: startStratNav,
                            startBhNav: startBhNav,
                            rebasedMode: rebasedMode,
                            hoverIdx: hoverIndex,
                            totalVisible: visibleDaily.length,
                            chartWidth: chartWidth,
                            compact: compact,
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              key: const ValueKey('crisis-subtrack-toggle'),
              borderRadius: BorderRadius.circular(6),
              onTap: () =>
                  setState(() => showSignalSubTrack = !showSignalSubTrack),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(
                  showSignalSubTrack
                      ? w(
                          'Hide Crisis Lights & VIX Sub-Track',
                          '收起危机灯与恐慌副图',
                        )
                      : w(
                          'Show Crisis Lights & VIX Sub-Track',
                          '展开危机灯与恐慌副图',
                        ),
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _eventsNearHoverIndex({
    required List<Map<String, dynamic>> visibleDaily,
    required List<Map<String, dynamic>> visibleEvents,
    required int hoverIdx,
    required double chartWidth,
  }) {
    if (visibleDaily.isEmpty ||
        visibleEvents.isEmpty ||
        hoverIdx < 0 ||
        hoverIdx >= visibleDaily.length) {
      return const [];
    }
    final hoverDate = text(visibleDaily[hoverIdx]['date']);
    final exact = visibleEvents
        .where((ev) => text(ev['date']) == hoverDate)
        .toList();
    if (exact.isNotEmpty) return exact;

    final n = visibleDaily.length;
    if (n <= 1) return const [];
    const padL = 52.0;
    const padR = 12.0;
    final plotW = math.max(1.0, chartWidth - padL - padR);
    final hoverX = padL + (hoverIdx / (n - 1)) * plotW;

    final idxByDate = <String, int>{
      for (var i = 0; i < n; i++) text(visibleDaily[i]['date']): i,
    };
    String? bestDate;
    var bestDist = 9.0;
    for (final ev in visibleEvents) {
      final evDate = text(ev['date']);
      final evIdx = idxByDate[evDate];
      if (evIdx == null) continue;
      final evX = padL + (evIdx / (n - 1)) * plotW;
      final dist = (evX - hoverX).abs();
      if (dist < bestDist) {
        bestDist = dist;
        bestDate = evDate;
      }
    }
    if (bestDate == null) return const [];
    return visibleEvents.where((ev) => text(ev['date']) == bestDate).toList();
  }

  Widget _buildCleanHoverTooltip({
    required Map<String, dynamic> row,
    required List<Map<String, dynamic>> hoverEvents,
    required String navKey,
    required double startStratNav,
    required double startBhNav,
    required bool rebasedMode,
    required int hoverIdx,
    required int totalVisible,
    required double chartWidth,
    required bool compact,
  }) {
    const padL = 52.0;
    const padR = 12.0;
    final plotW = math.max(1.0, chartWidth - padL - padR);
    final cursorX = totalVisible > 1
        ? padL + (hoverIdx / (totalVisible - 1)) * plotW
        : padL;
    final cardWidth = math.min(compact ? 230.0 : 270.0, chartWidth - 16.0);
    final placeLeft = cursorX > chartWidth * 0.56;
    final rawLeft = placeLeft ? cursorX - cardWidth - 12.0 : cursorX + 12.0;
    final clampedLeft = rawLeft.clamp(4.0, math.max(4.0, chartWidth - cardWidth - 4.0));

    final stratNav = _numVal(row[navKey]);
    final bhNav = _numVal(row['nav_bh']);
    final stratRet = startStratNav > 0 ? (stratNav / startStratNav - 1) * 100 : 0.0;
    final bhRet = startBhNav > 0 ? (bhNav / startBhNav - 1) * 100 : 0.0;
    final lights = _numVal(row['crisis_lights']).round();
    final vixRatio = _numVal(row['vix_ratio']);
    final qqqClose = _numVal(row['qqq_close']);

    double netPnlSum = 0;
    double sharesSum = 0;
    bool hasVixTp = false;
    bool hasItmTp = false;
    bool has4xTp = false;
    bool hasPut5xTp = false;
    bool hasLiveArmed = false;
    bool hasOpen = false;
    Map<String, dynamic>? firstOpenEv;
    Map<String, dynamic>? firstCcOpenEv;
    Map<String, dynamic>? firstCcRollEv;
    Map<String, dynamic>? firstCcStopEv;
    for (final ev in hoverEvents) {
      final et = text(ev['event_type']);
      if (et == 'vix110_tp' ||
          et == 'vix110_itm_tp' ||
          et == 'vix110_4x_tp' ||
          et == 'put5x_dte45_tp' ||
          et == 'live_tp_armed') {
        if (et == 'put5x_dte45_tp') {
          hasPut5xTp = true;
        } else if (et == 'live_tp_armed') {
          hasLiveArmed = true;
        } else if (et == 'vix110_itm_tp') {
          hasItmTp = true;
        } else if (et == 'vix110_4x_tp') {
          has4xTp = true;
        } else {
          hasVixTp = true;
        }
        netPnlSum += _numVal(ev['net_pnl_usd']);
        sharesSum += _numVal(ev['shares_added']);
      } else if (et.startsWith('slot')) {
        hasOpen = true;
        firstOpenEv ??= ev;
      } else if (et == 'cc_open') {
        firstCcOpenEv ??= ev;
      } else if (et == 'cc_roll_up' || et == 'cc_credit_roll') {
        firstCcRollEv ??= ev;
      } else if (et == 'cc_delta_stop') {
        firstCcStopEv ??= ev;
      }
    }
    final hasTp =
        hasVixTp || hasItmTp || has4xTp || hasPut5xTp || hasLiveArmed;
    final hasAnyMarkerEvent =
        hasTp ||
        hasOpen ||
        firstCcOpenEv != null ||
        firstCcRollEv != null ||
        firstCcStopEv != null;

    return Positioned(
      left: clampedLeft.toDouble(),
      top: 10,
      width: cardWidth,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('crisis-chart-hover-tooltip'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: p.card.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 2,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    text(row['date']),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'QQQ \$${qqqClose.toStringAsFixed(1)} · VIX/3M ${vixRatio.toStringAsFixed(2)}',
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                rebasedMode
                    ? '${_humanStrategyLabel(selectedStrategyId)} ${_fmtPct(stratRet)} vs QQQ ${_fmtPct(bhRet)}'
                    : '${_fmtUsd(stratNav)} vs QQQ ${_fmtUsd(bhNav)}',
                style: TextStyle(
                  color: _emerald,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              if (qqqClose > 0) ...[
                Builder(
                  builder: (_) {
                    final eqSh = stratNav / qqqClose;
                    final bhEqSh = bhNav / qqqClose;
                    final exPct = bhEqSh > 0 ? (eqSh / bhEqSh - 1) * 100 : 0.0;
                    return Text(
                      w(
                        'Equiv. ${_fmtShares(eqSh)} sh (${_fmtPct(exPct)} vs BH)',
                        '等效持仓 ${_fmtShares(eqSh)} 股（较死拿 ${_fmtPct(exPct)}）',
                      ),
                      style: TextStyle(color: p.muted, fontSize: 11),
                    );
                  },
                ),
                const SizedBox(height: 2),
              ],
              Text(
                w(
                  'Crisis Lights: $lights / 6 active',
                  '当日危机灯：$lights / 6 亮起',
                ),
                style: TextStyle(color: p.muted, fontSize: 11),
              ),
              if (hasAnyMarkerEvent) ...[
                const SizedBox(height: 6),
                Container(height: 1, color: p.border),
                const SizedBox(height: 6),
                if (hasTp || hasOpen)
                  Text(
                    hasLiveArmed
                        ? w(
                            '◆ Deep-ITM Panic Armed (Next Open) · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                            '◆ 实值恐慌止盈触发（次日开盘） · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                          )
                        : (hasPut5xTp
                              ? w(
                                  '◆ 5x Slow-Bear Harvest (DTE<=45) · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                                  '◆ 5x 慢熊止盈（DTE≤45） · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                                )
                              : (hasItmTp
                                    ? w(
                                        '◆ Deep-ITM Panic Harvest · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                                        '◆ 实值恐慌止盈 · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                                      )
                                    : (has4xTp
                                          ? w(
                                              '◆ 4x Deep Panic Harvest · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                                              '◆ 4x 深度恐慌止盈 · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                                            )
                                          : (hasVixTp
                                                ? w(
                                                    '◆ 1.10 Panic Harvest · ${_fmtUsd(netPnlSum, signed: true)} (+${sharesSum.toStringAsFixed(1)} sh)',
                                                    '◆ 1.10 恐慌止盈 · ${_fmtUsd(netPnlSum, signed: true)}（+${sharesSum.toStringAsFixed(1)} 股）',
                                                  )
                                                : w(
                                                    '▼ Buy ${text(firstOpenEv?['tranche_type']) == 'naked_put' ? 'Naked Put' : 'Collar'} @\$${_numVal(firstOpenEv?['spot']).toStringAsFixed(1)} (K=\$${_numVal(firstOpenEv?['kp']).toStringAsFixed(1)})',
                                                    '▼ 买${text(firstOpenEv?['tranche_type']) == 'naked_put' ? '首仓裸 Put' : '次仓领口'} @\$${_numVal(firstOpenEv?['spot']).toStringAsFixed(1)}（行权 \$${_numVal(firstOpenEv?['kp']).toStringAsFixed(1)}）',
                                                  ))))),
                    style: TextStyle(
                      color: hasTp ? _emerald : _amber,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (firstCcOpenEv != null) ...[
                  if (hasTp || hasOpen) const SizedBox(height: 4),
                  Text(
                    w(
                      '▲ Sell 25D 12Δ Call · K=\$${_numVal(firstCcOpenEv['kc']).toStringAsFixed(0)} (+${_numVal(firstCcOpenEv['otm_pct']).toStringAsFixed(1)}%) · Prem ${_fmtUsd(_numVal(firstCcOpenEv['prem_usd']), signed: true)}',
                      '▲ 卖 25D 12Δ Call · 行权 \$${_numVal(firstCcOpenEv['kc']).toStringAsFixed(0)}（+${_numVal(firstCcOpenEv['otm_pct']).toStringAsFixed(1)}%）· 收租 ${_fmtUsd(_numVal(firstCcOpenEv['prem_usd']), signed: true)}',
                    ),
                    style: const TextStyle(
                      color: _sky,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (firstCcRollEv != null) ...[
                  if (hasTp || hasOpen || firstCcOpenEv != null)
                    const SizedBox(height: 4),
                  Builder(
                    builder: (_) {
                      final isCredit =
                          text(firstCcRollEv!['event_type']) ==
                          'cc_credit_roll';
                      final oldK = _numVal(firstCcRollEv['old_kc']);
                      final newK = firstCcRollEv['new_kc'] is num
                          ? (firstCcRollEv['new_kc'] as num).toDouble()
                          : null;
                      final net = _numVal(firstCcRollEv['net_pnl_usd']);
                      final moveTxt = newK != null
                          ? w(
                              '\$${oldK.toStringAsFixed(0)} -> \$${newK.toStringAsFixed(0)}',
                              '\$${oldK.toStringAsFixed(0)} → \$${newK.toStringAsFixed(0)}',
                            )
                          : w(
                              'Closed K=\$${oldK.toStringAsFixed(0)}',
                              '平旧 \$${oldK.toStringAsFixed(0)}（无虚值可展）',
                            );
                      return Text(
                        isCredit
                            ? w(
                                '↻ Δ0.55 Credit Roll 45D · $moveTxt (${_fmtUsd(net, signed: true)})',
                                '↻ Δ0.55 零成本 Roll 45D · $moveTxt（旧腿 ${_fmtUsd(net, signed: true)}）',
                              )
                            : w(
                                '↻ Δ0.45 Roll Up 30D · $moveTxt (${_fmtUsd(net, signed: true)})',
                                '↻ Δ0.45 展期 Roll 30D · $moveTxt（旧腿 ${_fmtUsd(net, signed: true)}）',
                              ),
                        style: const TextStyle(
                          color: _lilac,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    },
                  ),
                ],
                if (firstCcStopEv != null) ...[
                  if (hasTp ||
                      hasOpen ||
                      firstCcOpenEv != null ||
                      firstCcRollEv != null)
                    const SizedBox(height: 4),
                  Text(
                    w(
                      '✕ Δ0.35 Call Stop Buyback · K=\$${_numVal(firstCcStopEv['kc']).toStringAsFixed(0)} (${_fmtUsd(_numVal(firstCcStopEv['net_pnl_usd']), signed: true)})',
                      '✕ Δ0.35 卖 Call 止损平仓 · 原行权 \$${_numVal(firstCcStopEv['kc']).toStringAsFixed(0)}（净盈亏 ${_fmtUsd(_numVal(firstCcStopEv['net_pnl_usd']), signed: true)}）',
                    ),
                    style: const TextStyle(
                      color: _coral,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _heroStatMetric({
    required String label,
    required String value,
    required String sub,
    required Color color,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: p.muted, fontSize: 11)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 16.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(sub, style: TextStyle(color: p.muted, fontSize: 11)),
      ],
    );
  }

  Widget _buildCalmCcModeTab(String modeId) {
    final active = selectedCcMode == modeId;
    return InkWell(
      key: ValueKey('crisis-cc-mode-pill-$modeId'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => _selectCcMode(modeId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
        decoration: BoxDecoration(
          color: active
              ? _emerald.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? _emerald.withValues(alpha: 0.65) : p.border,
          ),
        ),
        child: Text(
          _humanCcModeLabel(modeId),
          style: TextStyle(
            color: active ? p.text : p.muted,
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCalmTpModeTab(String modeId) {
    final active = selectedTpMode == modeId;
    return InkWell(
      key: ValueKey('crisis-tp-mode-pill-$modeId'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => _selectTpMode(modeId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
        decoration: BoxDecoration(
          color: active
              ? _emerald.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? _emerald.withValues(alpha: 0.65) : p.border,
          ),
        ),
        child: Text(
          _humanTpModeLabel(modeId),
          style: TextStyle(
            color: active ? p.text : p.muted,
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCalmStrategyTab(String sid) {
    final active = selectedStrategyId == sid;
    return InkWell(
      key: ValueKey('crisis-strategy-pill-$sid'),
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        if (selectedStrategyId == sid) return;
        setState(() {
          selectedStrategyId = sid;
        });
        if (sid == 'NoPut_CallOnly' && selectedCcMode == 'cc_off') {
          _selectCcMode('cc_d12_d35');
          return;
        }
        _emitSelection();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: active ? p.text.withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? p.text.withValues(alpha: 0.28) : p.border,
          ),
        ),
        child: Text(
          _humanStrategyLabel(sid),
          style: TextStyle(
            color: active ? p.text : p.muted,
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildCleanZoomChip({
    required String id,
    required String label,
    required bool isLive,
  }) {
    final active = selectedWindowId == id;
    return InkWell(
      key: ValueKey('crisis-zoom-pill-$id'),
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        setState(() {
          selectedWindowId = id;
          if (id != 'ALL' && id != '1Y' && id != '3Y') {
            activeForensicWindowId = id;
            showFullLedger = false;
          }
          hoverIndex = -1;
        });
        _emitSelection();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5.5),
        decoration: BoxDecoration(
          color: active
              ? _emerald.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? _emerald.withValues(alpha: 0.65) : p.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLive) ...[
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: _coral,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                color: active ? p.text : p.muted,
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cleanLegendItem({
    required Color color,
    required bool dashed,
    required String label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dashed)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 5, height: 2, color: color),
              const SizedBox(width: 2),
              Container(width: 5, height: 2, color: color),
            ],
          )
        else
          Container(width: 12, height: 2.5, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: p.muted, fontSize: 12)),
      ],
    );
  }

  Widget _cleanVectorMarkerLegend({
    required _CrisisMarkerKind kind,
    required String label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CustomPaint(painter: _CrisisMarkerGlyphPainter(kind: kind)),
        ),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: p.muted, fontSize: 12)),
      ],
    );
  }

  void _updateHoverFromDx(double dx, double width, int count) {
    if (count <= 1 || width <= 64) return;
    const padL = 52.0;
    const padR = 12.0;
    final plotW = math.max(1.0, width - padL - padR);
    final rel = ((dx - padL) / plotW).clamp(0.0, 1.0);
    final idx = (rel * (count - 1)).round().clamp(0, count - 1);
    if (idx != hoverIndex) {
      setState(() => hoverIndex = idx);
    }
  }

  // ===========================================================================
  // BLOCK 4: Zoomed-In Crisis Story & Clean Action Timeline (危机复盘与具体操作)
  // ===========================================================================
  Widget _buildCrisisStoryAndTimelineBlock(
    Map<String, dynamic> doc, {
    required bool compact,
    required bool desktop,
  }) {
    final windows = asList(doc['crisis_windows']);
    final forensicWin =
        _findWindow(doc, activeForensicWindowId) ??
        (windows.isNotEmpty ? windows.last : const <String, dynamic>{});
    final winId = text(forensicWin['id']);
    final winStratStats = asMap(
      asMap(forensicWin['strategy_stats'])[selectedStrategyId],
    );

    final fullLedger = _currentLedgerForStrategy(doc);
    final winStart = text(forensicWin['start_date']);
    final winEnd = text(forensicWin['end_date']);

    final filteredTranches = showFullLedger
        ? fullLedger.reversed.toList()
        : fullLedger.where((tr) {
            final ent = text(tr['entry_date']);
            final ex = text(tr['exit_date']);
            final inStart = ent.compareTo(winEnd) <= 0;
            final inEnd = ex.isEmpty || ex.compareTo(winStart) >= 0;
            return inStart && inEnd;
          }).toList();

    final qqqMdd = _numVal(forensicWin['qqq_mdd']);
    final stratMdd = _numVal(
      winStratStats['mdd_pct'],
      _numVal(forensicWin['u1_mdd']),
    );
    final excessPct = _numVal(
      winStratStats['excess_ret_pct'],
      _numVal(forensicWin['excess_ret_u1']),
    );
    final harvestedUsd = _numVal(
      winStratStats['harvested_tp_usd'],
      _numVal(forensicWin['harvested_usd']),
    );
    final sharesAdded = _numVal(
      winStratStats['shares_added_tp'],
      _numVal(forensicWin['shares_added']),
    );

    return Container(
      key: const ValueKey('crisis-observatory-forensic-section'),
      padding: EdgeInsets.all(compact ? 16 : 22),
      decoration: _calmSurfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    showFullLedger
                        ? w(
                            'All 12-Year Historical Operations (2015–2026)',
                            '全部 12 年历史实战记录（2015–2026）',
                          )
                        : _humanWindowTitle(forensicWin),
                    style: TextStyle(
                      color: p.text,
                      fontSize: compact ? 16 : 17.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!showFullLedger) ...[
                    const SizedBox(height: 2),
                    Text(
                      '$winStart → $winEnd',
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                  ],
                ],
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final win in windows) ...[
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: InkWell(
                          key: ValueKey(
                            'crisis-forensic-pill-${text(win['id'])}',
                          ),
                          borderRadius: BorderRadius.circular(999),
                          onTap: () {
                            final id = text(win['id']);
                            setState(() {
                              activeForensicWindowId = id;
                              selectedWindowId = id;
                              showFullLedger = false;
                              hoverIndex = -1;
                            });
                            _emitSelection();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4.5,
                            ),
                            decoration: BoxDecoration(
                              color: !showFullLedger && winId == text(win['id'])
                                  ? p.text.withValues(alpha: 0.09)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color:
                                    !showFullLedger && winId == text(win['id'])
                                    ? p.text.withValues(alpha: 0.28)
                                    : p.border,
                              ),
                            ),
                            child: Text(
                              _humanWindowChipLabel(win),
                              style: TextStyle(
                                color:
                                    !showFullLedger && winId == text(win['id'])
                                    ? p.text
                                    : p.muted,
                                fontSize: 11.5,
                                fontWeight:
                                    !showFullLedger && winId == text(win['id'])
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (!showFullLedger) ...[
            const SizedBox(height: 12),
            Text(
              w(
                text(forensicWin['narrative_en']),
                text(forensicWin['narrative_zh']),
              ),
              style: TextStyle(
                color: p.muted,
                fontSize: compact ? 12.5 : 13,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: compact ? 20 : 36,
              runSpacing: 12,
              children: [
                _heroStatMetric(
                  label: w('Drawdown vs QQQ', '区间回撤对比'),
                  value:
                      '${stratMdd.toStringAsFixed(1)}% vs ${qqqMdd.toStringAsFixed(1)}%',
                  sub: w(
                    'Protection ${_fmtPct(excessPct)}',
                    '区间超额 ${_fmtPct(excessPct)}',
                  ),
                  color: excessPct >= 0 ? _emerald : p.text,
                ),
                _heroStatMetric(
                  label: w('Option Profit Harvested', '期权止盈落袋'),
                  value: _fmtUsd(harvestedUsd, signed: harvestedUsd > 0),
                  sub: w('Monetized via dual-track TP', '双轨止盈变现现金'),
                  color: harvestedUsd > 0 ? _emerald : p.text,
                ),
                _heroStatMetric(
                  label: w('QQQ Shares Added', '低位增持 QQQ'),
                  value: '+${sharesAdded.toStringAsFixed(1)} ${w('sh', '股')}',
                  sub: w(
                    'Peak VIX/3M ${_numVal(forensicWin['peak_vix_ratio']).toStringAsFixed(2)}',
                    '峰值恐慌比 ${_numVal(forensicWin['peak_vix_ratio']).toStringAsFixed(2)}',
                  ),
                  color: sharesAdded > 0 ? _emerald : p.text,
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          Container(height: 1, color: p.border),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                showFullLedger
                    ? w(
                        'Chronological Operations (${fullLedger.length})',
                        '逐笔操作明细（共 ${fullLedger.length} 笔）',
                      )
                    : w('Operations in This Crisis', '当期具体操作时间线'),
                style: TextStyle(
                  color: p.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              InkWell(
                key: const ValueKey('crisis-ledger-scope-toggle'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => showFullLedger = !showFullLedger),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Text(
                    showFullLedger
                        ? w('Show Selected Crisis Only', '仅看当前危机')
                        : w(
                            'View All 12Y (${fullLedger.length})',
                            '查看全部 12 年（${fullLedger.length} 笔）',
                          ),
                    style: const TextStyle(
                      color: _emerald,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (filteredTranches.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                w(
                  'No option hedges triggered during this window; 100% QQQ held unhedged.',
                  '该窗口内未触发期权保护，全程 100% 持有 QQQ 现货。',
                ),
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            )
          else
            for (final tr in filteredTranches)
              _buildCleanTimelineTrancheRow(tr, compact: compact),
          if (selectedCcMode != 'cc_off') ...[
            Builder(
              builder: (_) {
                final ccList = _currentCcLedgerForStrategy(doc);
                if (ccList.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 14),
                    Container(height: 1, color: p.border),
                    const SizedBox(height: 10),
                    InkWell(
                      key: const ValueKey('crisis-cc-ledger-toggle'),
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => setState(() => showCcLedger = !showCcLedger),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              w(
                                'Normal-Time 25D 12Δ Covered Call Cash Ledger (${ccList.length} trades)',
                                '平时卖 25D 12Δ Call 攒现金明细（共 ${ccList.length} 笔）',
                              ),
                              style: TextStyle(
                                color: p.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Icon(
                              showCcLedger
                                  ? Icons.keyboard_arrow_up
                                  : Icons.keyboard_arrow_down,
                              size: 16,
                              color: p.muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (showCcLedger) ...[
                      const SizedBox(height: 8),
                      for (final cc in ccList.reversed)
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(color: p.border, width: 1),
                            ),
                          ),
                          child: Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                w(
                                  '${text(cc['entry_date'])} -> ${text(cc['exit_date'])} · Sold K=\$${_numVal(cc['kc']).toStringAsFixed(0)} Call (VXN ${_numVal(cc['entry_vxn']).toStringAsFixed(1)}, Exit \$${_numVal(cc['exit_spot']).toStringAsFixed(0)})',
                                  '${text(cc['entry_date'])} → ${text(cc['exit_date'])} · 卖 \$${_numVal(cc['kc']).toStringAsFixed(0)} Call（VXN ${_numVal(cc['entry_vxn']).toStringAsFixed(1)} · 收盘 \$${_numVal(cc['exit_spot']).toStringAsFixed(0)}）',
                                ),
                                style: TextStyle(color: p.muted, fontSize: 12),
                              ),
                              Text(
                                w(
                                  'Prem ${_fmtUsd(_numVal(cc['prem_usd']), signed: true)} · Net ${_fmtUsd(_numVal(cc['net_pnl_usd']), signed: true)} · ${_ccExitReasonTag(text(cc['exit_reason']))}',
                                  '收租 ${_fmtUsd(_numVal(cc['prem_usd']), signed: true)} · 净盈亏 ${_fmtUsd(_numVal(cc['net_pnl_usd']), signed: true)} · ${_ccExitReasonTag(text(cc['exit_reason']))}',
                                ),
                                style: TextStyle(
                                  color: _numVal(cc['net_pnl_usd']) >= 0
                                      ? _emerald
                                      : _coral,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCleanTimelineTrancheRow(
    Map<String, dynamic> tr, {
    required bool compact,
  }) {
    final trancheId = _numVal(tr['tranche_id']).round();
    final expanded = expandedTrancheIds.contains(trancheId);
    final isNaked = text(tr['tranche_type']) == 'naked_put';
    final isOpenLive = tr['is_open_live'] == true;
    final exitReason = text(tr['exit_reason']);
    final isLiveArmed = exitReason == 'live_tp_armed_next_open';
    final isOpenCutoff = tr['exit_date'] == null && !isOpenLive;
    final isPut5xTp = exitReason.contains('put_5x');
    final isItmTp = exitReason.contains('itm_tp');
    final is4xTp = exitReason.contains('4x_tp');
    final isTp = exitReason.contains('tp') && !isOpenLive;
    final netPnl = _numVal(tr['net_pnl_usd']);
    final shAdded = _numVal(tr['shares_added']);
    final kp = _numVal(tr['kp']);
    final kc = tr['kc'] == null ? null : _numVal(tr['kc']);

    final tagLabel = isNaked
        ? w('First-Half Put', '首仓裸 Put')
        : w('Zero-Cost Collar', '次仓领口');
    final tagColor = isNaked ? _amber : p.muted;

    final entrySpot = _numVal(tr['entry_spot']).toStringAsFixed(1);
    final exitSpot = _numVal(tr['exit_spot']).toStringAsFixed(1);
    final rawExitDate = isOpenLive
        ? text(tr['mtm_date'])
        : text(tr['exit_date']);
    final exitShort = isOpenCutoff || rawExitDate.length < 10
        ? ''
        : rawExitDate.substring(5);
    final tpLabelEn = isLiveArmed
        ? 'Deep-ITM TP Armed (Next Open)'
        : (isOpenLive
              ? 'Open Live MTM'
              : (isPut5xTp
                    ? '5x Slow-Bear Harvest'
                    : (isItmTp
                          ? 'Deep-ITM Panic Harvest'
                          : (is4xTp
                                ? '4x Deep Panic Harvest'
                                : (isTp ? '1.10 Panic Harvest' : 'Expired')))));
    final tpLabelZh = isLiveArmed
        ? '实值恐慌触发 · 待次日开盘止盈'
        : (isOpenLive
              ? '实盘持仓浮盈'
              : (isPut5xTp
                    ? '5x 慢熊止盈'
                    : (isItmTp
                          ? '实值恐慌止盈'
                          : (is4xTp
                                ? '4x 深度恐慌止盈'
                                : (isTp ? '恐慌止盈' : '到期结算')))));

    final String actionSentence;
    if (isNaked) {
      actionSentence = isOpenCutoff
          ? w(
              'QQQ \$$entrySpot -> Bought 90D \$${kp.toStringAsFixed(1)} Put (no upside cap) · Open',
              'QQQ \$$entrySpot 买入 90 天 \$${kp.toStringAsFixed(1)} 看跌保护（不卖封顶）· 持仓中',
            )
          : w(
              'QQQ \$$entrySpot -> Bought \$${kp.toStringAsFixed(1)} Put (no cap) · $tpLabelEn $exitShort @\$$exitSpot',
              'QQQ \$$entrySpot 买入 \$${kp.toStringAsFixed(1)} 看跌保护（不卖封顶） → $exitShort @\$$exitSpot $tpLabelZh',
            );
    } else {
      actionSentence = isOpenCutoff
          ? w(
              'QQQ \$$entrySpot -> Zero-cost Collar (\$${kp.toStringAsFixed(0)} Put / \$${(kc ?? 0).toStringAsFixed(0)} Call) · Open',
              'QQQ \$$entrySpot 开启零成本领口（保护 \$${kp.toStringAsFixed(0)} / 封顶 \$${(kc ?? 0).toStringAsFixed(0)}）· 持仓中',
            )
          : w(
              'QQQ \$$entrySpot -> Collar (\$${kp.toStringAsFixed(0)} Put / \$${(kc ?? 0).toStringAsFixed(0)} Call) · ${isTp || isOpenLive ? '$tpLabelEn $exitShort @\$$exitSpot' : 'Settled $exitShort @\$$exitSpot'}',
              'QQQ \$$entrySpot 零成本领口（保护 \$${kp.toStringAsFixed(0)} / 封顶 \$${(kc ?? 0).toStringAsFixed(0)}） → $exitShort @\$$exitSpot $tpLabelZh',
            );
    }

    final pnlText = isOpenCutoff
        ? w('Open', '持仓中')
        : '${_fmtUsd(netPnl, signed: true)}${shAdded.abs() >= 0.1 ? ' · ${shAdded >= 0 ? '+' : ''}${shAdded.toStringAsFixed(1)} ${w('sh', '股')}' : ''}';
    final pnlColor = isOpenCutoff
        ? _amber
        : (netPnl > 0 ? _emerald : p.muted);

    return InkWell(
      key: ValueKey('crisis-tranche-row-$trancheId'),
      onTap: isOpenCutoff
          ? null
          : () => setState(() {
              if (expanded) {
                expandedTrancheIds.remove(trancheId);
              } else {
                expandedTrancheIds.add(trancheId);
              }
            }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.border, width: 1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (compact) ...[
              Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        text(tr['entry_date']),
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _smallTimelineTag(tagLabel, tagColor),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        pnlText,
                        style: TextStyle(
                          color: pnlColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (!isOpenCutoff) ...[
                        const SizedBox(width: 4),
                        Icon(
                          expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 16,
                          color: p.muted,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                actionSentence,
                style: TextStyle(color: p.text, fontSize: 13, height: 1.4),
              ),
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 88,
                    child: Text(
                      text(tr['entry_date']),
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  _smallTimelineTag(tagLabel, tagColor),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      actionSentence,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.text, fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    pnlText,
                    style: TextStyle(
                      color: pnlColor,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!isOpenCutoff) ...[
                    const SizedBox(width: 4),
                    Icon(
                      expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: p.muted,
                    ),
                  ],
                ],
              ),
            if (expanded && !isOpenCutoff) ...[
              const SizedBox(height: 9),
              Wrap(
                spacing: 18,
                runSpacing: 6,
                children: [
                  Text(
                    '${w('Trigger', '触发信号')}: ${w(text(tr['trigger_en']), text(tr['trigger_zh']))}',
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                  Text(
                    'Delta ${_fmtUsd(_numVal(tr['delta_usd']), signed: true)}',
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                  Text(
                    'Gamma ${_fmtUsd(_numVal(tr['gamma_usd']), signed: true)}',
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                  Text(
                    'Vega ${_fmtUsd(_numVal(tr['vega_usd']), signed: true)}',
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                  Text(
                    '${w('Time & Slippage', '时间损耗与滑点')} ${_fmtUsd(_numVal(tr['theta_slip_usd']), signed: true)}',
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _smallTimelineTag(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// =============================================================================
// Minimalist Apple-Stocks / Linear Style Equity Curve Painter
// =============================================================================
class _CrisisObservatoryChartPainter extends CustomPainter {
  _CrisisObservatoryChartPainter({
    required this.rows,
    required this.events,
    required this.navKey,
    required this.rebasedMode,
    required this.useLogScale,
    required this.showSubTrack,
    required this.hoverIndex,
    required this.borderColor,
    required this.mutedColor,
    required this.textColor,
  });

  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> events;
  final String navKey;
  final bool rebasedMode;
  final bool useLogScale;
  final bool showSubTrack;
  final int hoverIndex;
  final Color borderColor;
  final Color mutedColor;
  final Color textColor;

  static const Color _emerald = Color(0xFF5EC49E);
  static const Color _amber = Color(0xFFE5B45B);
  static const Color _coral = Color(0xFFE47F8B);

  double _val(dynamic v, [double fb = 0]) {
    if (v is num && v.isFinite) return v.toDouble();
    return fb;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.length < 2) return;

    const padL = 52.0;
    const padR = 12.0;
    const padT = 10.0;
    const padB = 24.0;
    final plotW = math.max(1.0, size.width - padL - padR);
    final totalH = math.max(1.0, size.height - padT - padB);

    final subH = showSubTrack ? 68.0 : 0.0;
    final gap = showSubTrack ? 14.0 : 0.0;
    final mainH = math.max(80.0, totalH - subH - gap);

    final mainTop = padT;
    final mainBot = mainTop + mainH;
    final subTop = mainBot + gap;
    final subBot = subTop + subH;

    final n = rows.length;
    double xAt(int i) => padL + (i / (n - 1)) * plotW;

    final baseStrat = math.max(1e-6, _val(rows.first[navKey], 200000));
    final baseBh = math.max(1e-6, _val(rows.first['nav_bh'], 200000));

    final stratVals = <double>[];
    final bhVals = <double>[];
    for (final r in rows) {
      final sv = _val(r[navKey], baseStrat);
      final bv = _val(r['nav_bh'], baseBh);
      if (rebasedMode) {
        stratVals.add((sv / baseStrat) * 100.0);
        bhVals.add((bv / baseBh) * 100.0);
      } else {
        stratVals.add(useLogScale ? math.log(math.max(1.0, sv)) : sv);
        bhVals.add(useLogScale ? math.log(math.max(1.0, bv)) : bv);
      }
    }

    var yMin = math.min(stratVals.reduce(math.min), bhVals.reduce(math.min));
    var yMax = math.max(stratVals.reduce(math.max), bhVals.reduce(math.max));
    if ((yMax - yMin).abs() < 1e-6) {
      yMax += 1.0;
      yMin -= 1.0;
    }
    final padY = (yMax - yMin) * 0.08;
    yMin -= padY;
    yMax += padY;

    double yMain(double v) =>
        mainBot - ((v - yMin) / (yMax - yMin)).clamp(0.0, 1.0) * mainH;

    // 1. Ultra-subtle translucent crisis tint when >= 5 lights ON
    final crisisTint = Paint()..color = _coral.withValues(alpha: 0.045);
    final stepW = math.max(1.0, plotW / (n - 1));
    for (var i = 0; i < n; i++) {
      if (_val(rows[i]['crisis_lights']) >= 5) {
        canvas.drawRect(
          Rect.fromLTWH(xAt(i) - stepW * 0.5, mainTop, stepW, mainH),
          crisisTint,
        );
      }
    }

    // 2. Clean 3 horizontal gridlines
    final gridPaint = Paint()
      ..color = borderColor.withValues(alpha: 0.7)
      ..strokeWidth = 0.8;
    for (var g = 0; g <= 3; g++) {
      final frac = g / 3.0;
      final gy = mainBot - frac * mainH;
      canvas.drawLine(Offset(padL, gy), Offset(padL + plotW, gy), gridPaint);
      final rawVal = yMin + frac * (yMax - yMin);
      final String lbl;
      if (rebasedMode) {
        lbl = rawVal.toStringAsFixed(0);
      } else {
        final usd = useLogScale ? math.exp(rawVal) : rawVal;
        lbl = usd >= 1000000
            ? '\$${(usd / 1000000).toStringAsFixed(1)}M'
            : '\$${(usd / 1000).toStringAsFixed(0)}K';
      }
      _drawLabel(canvas, lbl, Offset(2, gy - 6), mutedColor, 10.0);
    }

    // 3. Dashed Buy & Hold QQQ curve + Solid Emerald Strategy curve with soft area fill
    final bhPath = Path();
    final stratPath = Path();
    final fillPath = Path();
    for (var i = 0; i < n; i++) {
      final x = xAt(i);
      final yb = yMain(bhVals[i]);
      final ys = yMain(stratVals[i]);
      if (i == 0) {
        bhPath.moveTo(x, yb);
        stratPath.moveTo(x, ys);
        fillPath.moveTo(x, mainBot);
        fillPath.lineTo(x, ys);
      } else {
        bhPath.lineTo(x, yb);
        stratPath.lineTo(x, ys);
        fillPath.lineTo(x, ys);
      }
    }
    fillPath
      ..lineTo(xAt(n - 1), mainBot)
      ..close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, mainTop),
          Offset(0, mainBot),
          [
            _emerald.withValues(alpha: 0.13),
            _emerald.withValues(alpha: 0.0),
          ],
        ),
    );

    _drawDashedPath(
      canvas,
      bhPath,
      Paint()
        ..color = mutedColor.withValues(alpha: 0.72)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.45,
    );

    canvas.drawPath(
      stratPath,
      Paint()
        ..color = _emerald
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );

    // 4. Distinct vector markers:
    //    - ▼ Amber downward triangle = Buy Put / Collar
    //    - ◆ Emerald diamond         = Crisis Put TP Harvest
    //    - ▲ Sky Blue UPWARD equilateral triangle = Sell Call Open
    //    - ↻ Lilac circular-arrow Roll logo       = Call Roll Up / Credit Roll
    //    - ✕ Coral stop-badge                     = Call Δ0.35 Stop Buyback
    final idxByDate = <String, int>{
      for (var i = 0; i < n; i++) text(rows[i]['date']): i,
    };
    final baseR = rebasedMode ? 5.2 : 4.0;
    // Draw Sell Call ▲ slightly above the curve first, then Put/TP, then Roll/Stop on top so critical actions never get buried.
    for (final ev in events) {
      final et = text(ev['event_type']);
      if (et != 'cc_open') continue;
      final idx = idxByDate[text(ev['date'])];
      if (idx == null) continue;
      final x = xAt(idx);
      final y = (yMain(stratVals[idx]) - (rebasedMode ? 7.5 : 5.5)).clamp(
        mainTop + 5.0,
        mainBot - 5.0,
      );
      _paintCrisisMarkerGlyph(
        canvas,
        Offset(x, y),
        rebasedMode ? 4.8 : 3.6,
        _CrisisMarkerKind.ccOpen,
      );
    }
    for (final ev in events) {
      final et = text(ev['event_type']);
      final idx = idxByDate[text(ev['date'])];
      if (idx == null) continue;
      final x = xAt(idx);
      final y = yMain(stratVals[idx]);
      if (et == 'slot1_naked_put' ||
          et == 'slot2_collar' ||
          et == 'slot1_collar' ||
          et == 'slot3_collar') {
        _paintCrisisMarkerGlyph(
          canvas,
          Offset(x, (y + (rebasedMode ? 4.5 : 3.0)).clamp(mainTop + 5.0, mainBot - 5.0)),
          baseR,
          _CrisisMarkerKind.putOpen,
        );
      } else if (et == 'vix110_tp' ||
          et == 'vix110_itm_tp' ||
          et == 'vix110_4x_tp' ||
          et == 'put5x_dte45_tp' ||
          et == 'live_tp_armed') {
        _paintCrisisMarkerGlyph(
          canvas,
          Offset(x, y),
          rebasedMode ? 5.4 : 4.2,
          _CrisisMarkerKind.putTp,
          rimColor: et == 'live_tp_armed'
              ? Colors.white
              : (et == 'put5x_dte45_tp' ? _amber : null),
        );
      }
    }
    for (final ev in events) {
      final et = text(ev['event_type']);
      if (et != 'cc_roll_up' &&
          et != 'cc_credit_roll' &&
          et != 'cc_delta_stop') {
        continue;
      }
      final idx = idxByDate[text(ev['date'])];
      if (idx == null) continue;
      final x = xAt(idx);
      final y = (yMain(stratVals[idx]) - (rebasedMode ? 9.0 : 6.5)).clamp(
        mainTop + 7.0,
        mainBot - 7.0,
      );
      _paintCrisisMarkerGlyph(
        canvas,
        Offset(x, y),
        rebasedMode ? 6.2 : 5.0,
        et == 'cc_delta_stop'
            ? _CrisisMarkerKind.ccStop
            : _CrisisMarkerKind.ccRoll,
      );
    }

    // 5. Optional compact sub-track (Crisis Lights + VIX/3M 1.10 threshold)
    if (showSubTrack) {
      canvas.drawLine(
        Offset(padL, subTop),
        Offset(padL + plotW, subTop),
        gridPaint,
      );
      canvas.drawLine(
        Offset(padL, subBot),
        Offset(padL + plotW, subBot),
        gridPaint,
      );
      _drawLabel(canvas, '1.10', Offset(6, subTop + 8), _amber, 9.5);

      const vMin = 0.75;
      const vMax = 1.35;
      double yVix(double vr) =>
          subBot - ((vr - vMin) / (vMax - vMin)).clamp(0.0, 1.0) * subH;

      final y110 = yVix(1.10);
      _drawDashedPath(
        canvas,
        Path()
          ..moveTo(padL, y110)
          ..lineTo(padL + plotW, y110),
        Paint()
          ..color = _amber.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9,
      );

      final vixPath = Path();
      for (var i = 0; i < n; i++) {
        final x = xAt(i);
        final vr = _val(rows[i]['vix_ratio'], 0.90);
        final y = yVix(vr);
        if (i == 0) {
          vixPath.moveTo(x, y);
        } else {
          vixPath.lineTo(x, y);
        }
      }
      canvas.drawPath(
        vixPath,
        Paint()
          ..color = _amber.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25,
      );
    }

    // 6. Clean X-axis date ticks (zero overlap)
    final axisBaseY = showSubTrack ? subBot : mainBot;
    final tickIndices = [
      0,
      ((n - 1) * 0.25).round(),
      ((n - 1) * 0.50).round(),
      ((n - 1) * 0.75).round(),
      n - 1,
    ];
    double lastRight = -999;
    for (final ti in tickIndices) {
      final dt = text(rows[ti]['date']);
      final lbl = rebasedMode ? dt.substring(2) : dt.substring(0, 7);
      final x = xAt(ti);
      final estW = lbl.length * 5.8;
      final drawX = (x - estW * 0.5)
          .clamp(padL, math.max(padL, padL + plotW - estW))
          .toDouble();
      if (drawX - lastRight < 14) continue;
      _drawLabel(canvas, lbl, Offset(drawX, axisBaseY + 6), mutedColor, 10.0);
      lastRight = drawX + estW;
    }

    // 7. Calm hover crosshair + active dots
    if (hoverIndex >= 0 && hoverIndex < n) {
      final hx = xAt(hoverIndex);
      canvas.drawLine(
        Offset(hx, mainTop),
        Offset(hx, axisBaseY),
        Paint()
          ..color = textColor.withValues(alpha: 0.28)
          ..strokeWidth = 1.0,
      );
      final hsY = yMain(stratVals[hoverIndex]);
      final hbY = yMain(bhVals[hoverIndex]);
      canvas.drawCircle(Offset(hx, hbY), 3.2, Paint()..color = mutedColor);
      canvas.drawCircle(Offset(hx, hsY), 4.2, Paint()..color = _emerald);
    }
  }

  void _drawDashedPath(
    Canvas canvas,
    Path source,
    Paint paint, {
    double dash = 4.5,
    double gap = 3.5,
  }) {
    for (final metric in source.computeMetrics()) {
      double distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance += dash + gap;
      }
    }
  }

  void _drawLabel(
    Canvas canvas,
    String value,
    Offset offset,
    Color color,
    double fontSize,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _CrisisObservatoryChartPainter oldDelegate) {
    return oldDelegate.rows != rows ||
        oldDelegate.events != events ||
        oldDelegate.navKey != navKey ||
        oldDelegate.rebasedMode != rebasedMode ||
        oldDelegate.useLogScale != useLogScale ||
        oldDelegate.showSubTrack != showSubTrack ||
        oldDelegate.hoverIndex != hoverIndex ||
        oldDelegate.borderColor != borderColor;
  }
}

enum _CrisisMarkerKind { putOpen, putTp, ccOpen, ccRoll, ccStop }

void _paintCrisisMarkerGlyph(
  Canvas canvas,
  Offset c,
  double r,
  _CrisisMarkerKind kind, {
  Color? rimColor,
}) {
  const obsidian = Color(0xFF0A0E14);
  const emerald = Color(0xFF5EC49E);
  const amber = Color(0xFFE5B45B);
  const coral = Color(0xFFE47F8B);
  const sky = Color(0xFF7DB8F0);
  const lilac = Color(0xFFB8A1EA);

  switch (kind) {
    case _CrisisMarkerKind.ccOpen:
      // Equilateral triangle pointing UP (正三角形向上 = 卖 Call)
      final h = r * 1.12;
      final halfW = r * 0.98;
      final tri = Path()
        ..moveTo(c.dx, c.dy - h)
        ..lineTo(c.dx - halfW, c.dy + h * 0.68)
        ..lineTo(c.dx + halfW, c.dy + h * 0.68)
        ..close();
      canvas.drawPath(tri, Paint()..color = sky);
      canvas.drawPath(
        tri,
        Paint()
          ..color = obsidian.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9,
      );
      break;

    case _CrisisMarkerKind.putOpen:
      // Equilateral triangle pointing DOWN (倒三角形向下 = 买 Put 防下跌)
      final h = r * 1.08;
      final halfW = r * 0.94;
      final tri = Path()
        ..moveTo(c.dx, c.dy + h)
        ..lineTo(c.dx - halfW, c.dy - h * 0.66)
        ..lineTo(c.dx + halfW, c.dy - h * 0.66)
        ..close();
      canvas.drawPath(tri, Paint()..color = amber);
      canvas.drawPath(
        tri,
        Paint()
          ..color = obsidian.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9,
      );
      break;

    case _CrisisMarkerKind.putTp:
      // Diamond (◆ 危机 Put 止盈换股)
      final dia = Path()
        ..moveTo(c.dx, c.dy - r)
        ..lineTo(c.dx + r, c.dy)
        ..lineTo(c.dx, c.dy + r)
        ..lineTo(c.dx - r, c.dy)
        ..close();
      canvas.drawPath(dia, Paint()..color = emerald);
      canvas.drawPath(
        dia,
        Paint()
          ..color = rimColor ?? obsidian.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = rimColor != null ? 1.3 : 0.9,
      );
      break;

    case _CrisisMarkerKind.ccRoll:
      // Distinct Roll Logo: dark halo badge + bright Lilac 270° circular arc + crisp arrowhead (↻)
      canvas.drawCircle(c, r, Paint()..color = obsidian.withValues(alpha: 0.94));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..color = lilac.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9,
      );
      final arcR = r * 0.62;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: arcR),
        -math.pi * 0.2,
        math.pi * 1.48,
        false,
        Paint()
          ..color = lilac
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.25, r * 0.24)
          ..strokeCap = StrokeCap.round,
      );
      // Arrowhead at the top-right end of the clockwise roll arc
      final tipAngle = -math.pi * 0.2;
      final tip = Offset(
        c.dx + arcR * math.cos(tipAngle),
        c.dy + arcR * math.sin(tipAngle),
      );
      final ah = math.max(2.1, r * 0.42);
      final arrow = Path()
        ..moveTo(tip.dx + ah * 0.35, tip.dy + ah * 0.15)
        ..lineTo(tip.dx - ah * 0.72, tip.dy - ah * 0.65)
        ..lineTo(tip.dx + ah * 0.42, tip.dy - ah * 0.82)
        ..close();
      canvas.drawPath(arrow, Paint()..color = lilac);
      break;

    case _CrisisMarkerKind.ccStop:
      // Distinct Stop Badge: dark halo badge + Coral ring + crisp ✕
      canvas.drawCircle(c, r * 0.92, Paint()..color = obsidian.withValues(alpha: 0.94));
      canvas.drawCircle(
        c,
        r * 0.92,
        Paint()
          ..color = coral
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.15,
      );
      final cr = r * 0.44;
      final xPaint = Paint()
        ..color = coral
        ..strokeWidth = math.max(1.2, r * 0.24)
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(c.dx - cr, c.dy - cr), Offset(c.dx + cr, c.dy + cr), xPaint);
      canvas.drawLine(Offset(c.dx + cr, c.dy - cr), Offset(c.dx - cr, c.dy + cr), xPaint);
      break;
  }
}

class _CrisisMarkerGlyphPainter extends CustomPainter {
  const _CrisisMarkerGlyphPainter({required this.kind});

  final _CrisisMarkerKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) * 0.42;
    _paintCrisisMarkerGlyph(canvas, c, r, kind);
  }

  @override
  bool shouldRepaint(covariant _CrisisMarkerGlyphPainter oldDelegate) =>
      oldDelegate.kind != kind;
}
