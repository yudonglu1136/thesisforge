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
  static const Color _obsidian = Color(0xFF080B0F);
  static const Color _surface = Color(0xFF0E141B);
  static const Color _surfaceRaised = Color(0xFF131B24);
  static const Color _hairline = Color(0xFF25313B);
  static const Color _mint = Color(0xFF80C6A8);
  static const Color _sky = Color(0xFF7DB8F0);
  static const Color _amber = Color(0xFFF2BC60);
  static const Color _lilac = Color(0xFFB8A1EA);
  static const Color _coral = Color(0xFFEC8C98);
  static const Color _slate = Color(0xFF9CABB9);

  static const List<String> _selectableStrategies = [
    'U1_PureOptions',
    'B1c_PureAD',
    'D2_SixLights',
    'H2_G4_PriceGate',
  ];

  static const Map<String, String> _strategyNavKeys = {
    'U1_PureOptions': 'nav_u1',
    'B1c_PureAD': 'nav_b1c',
    'D2_SixLights': 'nav_d2',
    'H2_G4_PriceGate': 'nav_h2',
    'BH_Pure_QQQ': 'nav_bh',
  };

  static const int _minZoomSpan = 15;

  Map<String, dynamic>? data;
  bool loading = true;
  String? error;

  String selectedStrategyId = 'U1_PureOptions';
  String selectedWindowId = 'ALL';
  String activePeriodPreset = 'ALL';
  String activeForensicWindowId = '2026-08_11_LIVE';
  int rangeStartIdx = 0;
  int rangeEndIdx = -1;
  bool useRebasedZoom = true;
  bool useLogScale = true;
  bool showFullLedger = false;
  bool showMethodology = false;
  int hoverIndex = -1;
  int loadSerial = 0;

  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);

  @override
  void initState() {
    super.initState();
    final rawInitStrat = text(widget.initialSelection['strategy']);
    final initStrat =
        rawInitStrat == 'U4_DualEngine' ? 'U1_PureOptions' : rawInitStrat;
    if (_selectableStrategies.contains(initStrat)) {
      selectedStrategyId = initStrat;
    }
    final initWin = text(widget.initialSelection['window']);
    if (initWin.isNotEmpty) {
      selectedWindowId = initWin;
      if (initWin != 'ALL' && initWin != 'CUSTOM') {
        activeForensicWindowId = initWin;
        activePeriodPreset = 'CRISIS';
      }
    }
    unawaited(_loadObservatory());
  }

  @override
  void didUpdateWidget(covariant CrisisObservatoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOf != widget.asOf || oldWidget.api != widget.api) {
      unawaited(_loadObservatory());
    }
  }

  void _emitSelection() {
    widget.onSelection?.call({
      'strategy': selectedStrategyId,
      'window': selectedWindowId,
    });
  }

  (int, int) _windowBoundsInSeries(
    List<Map<String, dynamic>> allDaily,
    Map<String, dynamic>? win,
  ) {
    if (allDaily.isEmpty) return (0, 0);
    final last = allDaily.length - 1;
    if (win == null) return (0, last);
    final startStr = text(win['start_date']);
    final endStr = text(win['end_date']);
    var s = 0;
    while (s < last && text(allDaily[s]['date']).compareTo(startStr) < 0) {
      s++;
    }
    var e = last;
    while (e > s && text(allDaily[e]['date']).compareTo(endStr) > 0) {
      e--;
    }
    if (e - s < _minZoomSpan && allDaily.length > _minZoomSpan) {
      e = math.min(last, s + _minZoomSpan);
      s = math.max(0, e - _minZoomSpan);
    }
    return (s, e);
  }

  (int, int) _resolvedRange(int totalLen) {
    if (totalLen <= 1) return (0, 0);
    final last = totalLen - 1;
    final rawEnd = (rangeEndIdx < 0 || rangeEndIdx > last) ? last : rangeEndIdx;
    final rawStart = rangeStartIdx.clamp(0, rawEnd);
    if (rawEnd - rawStart < _minZoomSpan && totalLen > _minZoomSpan) {
      final adjustedEnd = math.min(last, rawStart + _minZoomSpan);
      final adjustedStart = math.max(0, adjustedEnd - _minZoomSpan);
      return (adjustedStart, adjustedEnd);
    }
    return (rawStart, rawEnd);
  }

  void _applyWindowSelection(
    List<Map<String, dynamic>> allDaily,
    Map<String, dynamic> doc,
    String winId,
  ) {
    if (allDaily.isEmpty) return;
    final last = allDaily.length - 1;
    if (winId == 'ALL') {
      setState(() {
        selectedWindowId = 'ALL';
        activePeriodPreset = 'ALL';
        rangeStartIdx = 0;
        rangeEndIdx = last;
        hoverIndex = -1;
      });
    } else {
      final win = _findWindow(doc, winId);
      final bounds = _windowBoundsInSeries(allDaily, win);
      setState(() {
        selectedWindowId = winId;
        activeForensicWindowId = winId;
        activePeriodPreset = 'CRISIS';
        rangeStartIdx = bounds.$1;
        rangeEndIdx = bounds.$2;
        useRebasedZoom = true;
        hoverIndex = -1;
      });
    }
    _emitSelection();
  }

  void _applyPeriodPreset(List<Map<String, dynamic>> allDaily, String preset) {
    if (allDaily.isEmpty) return;
    final last = allDaily.length - 1;
    final int spanDays = switch (preset) {
      '6M' => 126,
      '1Y' => 252,
      '3Y' => 756,
      '5Y' => 1260,
      _ => allDaily.length,
    };
    final nextStart = preset == 'ALL' ? 0 : math.max(0, allDaily.length - spanDays);
    setState(() {
      rangeStartIdx = nextStart;
      rangeEndIdx = last;
      activePeriodPreset = preset;
      selectedWindowId = preset == 'ALL' ? 'ALL' : 'CUSTOM';
      hoverIndex = -1;
    });
    _emitSelection();
  }

  void _zoomByFactor(List<Map<String, dynamic>> allDaily, double factor) {
    if (allDaily.length <= _minZoomSpan + 1) return;
    final last = allDaily.length - 1;
    final (curStart, curEnd) = _resolvedRange(allDaily.length);
    final curSpan = math.max(_minZoomSpan, curEnd - curStart);
    final targetSpan = (curSpan * factor).round().clamp(_minZoomSpan, last);
    final center = (curStart + curEnd) / 2.0;
    var nextStart = (center - targetSpan / 2.0).round();
    var nextEnd = nextStart + targetSpan;
    if (nextStart < 0) {
      nextStart = 0;
      nextEnd = math.min(last, targetSpan);
    }
    if (nextEnd > last) {
      nextEnd = last;
      nextStart = math.max(0, last - targetSpan);
    }
    final isFull = nextStart == 0 && nextEnd == last;
    setState(() {
      rangeStartIdx = nextStart;
      rangeEndIdx = nextEnd;
      selectedWindowId = isFull ? 'ALL' : 'CUSTOM';
      activePeriodPreset = isFull ? 'ALL' : 'CUSTOM';
      hoverIndex = -1;
    });
    _emitSelection();
  }

  void _panRange(List<Map<String, dynamic>> allDaily, double fraction) {
    if (allDaily.length <= _minZoomSpan + 1) return;
    final last = allDaily.length - 1;
    final (curStart, curEnd) = _resolvedRange(allDaily.length);
    final curSpan = curEnd - curStart;
    if (curSpan >= last) return;
    final rawShift = (curSpan * fraction).round();
    final shift = rawShift == 0 ? (fraction < 0 ? -5 : 5) : rawShift;
    var nextStart = (curStart + shift).clamp(0, last - curSpan);
    var nextEnd = nextStart + curSpan;
    if (nextStart == curStart && nextEnd == curEnd) return;
    setState(() {
      rangeStartIdx = nextStart;
      rangeEndIdx = nextEnd;
      selectedWindowId = 'CUSTOM';
      activePeriodPreset = 'CUSTOM';
      hoverIndex = -1;
    });
    _emitSelection();
  }

  Future<void> _loadObservatory() async {
    final serial = ++loadSerial;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final uri = Uri(
        path: '/api/investment/crisis-observatory',
        queryParameters: {
          'asOf': widget.asOf,
          'strategy': selectedStrategyId,
        },
      );
      final res = await widget.api.getJson(uri.toString());
      if (!mounted || serial != loadSerial) return;
      final windows = asList(res['crisis_windows']);
      final allDaily = asList(res['daily_series']);
      var nextForensic = activeForensicWindowId;
      if (windows.isNotEmpty &&
          !windows.any((item) => text(item['id']) == nextForensic)) {
        nextForensic = text(windows.last['id']);
      }
      var nextWindow = selectedWindowId;
      if (nextWindow != 'ALL' &&
          nextWindow != 'CUSTOM' &&
          !windows.any((item) => text(item['id']) == nextWindow)) {
        nextWindow = 'ALL';
      }
      final initWinObj = (nextWindow != 'ALL' && nextWindow != 'CUSTOM')
          ? windows.cast<Map<String, dynamic>?>().firstWhere(
              (item) => text(item?['id']) == nextWindow,
              orElse: () => null,
            )
          : null;
      final bounds = _windowBoundsInSeries(allDaily, initWinObj);
      setState(() {
        data = res;
        activeForensicWindowId = nextForensic;
        selectedWindowId = nextWindow;
        activePeriodPreset = nextWindow == 'ALL' ? 'ALL' : 'CRISIS';
        rangeStartIdx = bounds.$1;
        rangeEndIdx = bounds.$2;
        hoverIndex = -1;
        loading = false;
      });
    } catch (e) {
      if (!mounted || serial != loadSerial) return;
      setState(() {
        error = e.toString();
        loading = false;
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

  String _fmtUsd(double v, {bool signed = false, bool compact = false}) {
    final sign = v < 0 ? '-' : (signed && v > 0 ? '+' : '');
    final absV = v.abs();
    if (compact) {
      if (absV >= 1000000) {
        return '$sign\$${(absV / 1000000).toStringAsFixed(3)}M';
      }
      if (absV >= 1000) {
        return '$sign\$${(absV / 1000).toStringAsFixed(1)}K';
      }
    }
    final fixed = absV.round().toString();
    final buf = StringBuffer();
    for (var i = 0; i < fixed.length; i++) {
      if (i > 0 && (fixed.length - i) % 3 == 0) buf.write(',');
      buf.write(fixed[i]);
    }
    return '$sign\$$buf';
  }

  String _fmtPct(double v, {int digits = 2, bool signed = true}) {
    final sign = v > 0 && signed ? '+' : '';
    return '$sign${v.toStringAsFixed(digits)}%';
  }

  List<Map<String, dynamic>> _currentEventsForStrategy(Map<String, dynamic> doc) {
    final byStrat = asMap(doc['events_by_strategy']);
    final list = asList(byStrat[selectedStrategyId]);
    if (list.isNotEmpty) return list;
    return asList(doc['events']);
  }

  List<Map<String, dynamic>> _currentLedgerForStrategy(Map<String, dynamic> doc) {
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

  Map<String, dynamic> _findStrategySummary(Map<String, dynamic> doc, String id) {
    for (final s in asList(doc['strategies_summary'])) {
      if (text(s['id']) == id) return s;
    }
    return const {};
  }

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return Container(
        key: const ValueKey('crisis-observatory-loading'),
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(minHeight: 2, color: _mint),
            const SizedBox(height: 14),
            Text(
              w(
                'Loading QQQ Crisis Observatory (6 Druckenmiller Signals, AD Divergence & Option Convexity)...',
                '正在加载 QQQ 危机观测台（六大宏观危机灯 × 市场宽度顶背离 × 裸 Put / Collar 凸性台账）...',
              ),
              style: const TextStyle(color: _slate, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (error != null && data == null) {
      return Container(
        key: const ValueKey('crisis-observatory-error'),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _coral.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(
                'Crisis Observatory data is temporarily unavailable.',
                '危机观测模块数据暂时无法加载。',
              ),
              style: TextStyle(
                color: p.text,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('crisis-observatory-retry'),
              onPressed: () => unawaited(_loadObservatory()),
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(w('Retry Crisis Observatory', '重新加载危机观测')),
            ),
          ],
        ),
      );
    }

    final doc = data ?? const <String, dynamic>{};
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        final desktop = constraints.maxWidth >= 980;
        return Column(
          key: const ValueKey('crisis-observatory-root'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeaderBanner(doc, compact: compact),
            const SizedBox(height: 14),
            _buildHeroSignalCommandCenter(doc, compact: compact, desktop: desktop),
            const SizedBox(height: 14),
            _buildSixSignalsAndBreadthSection(
              doc,
              maxWidth: constraints.maxWidth,
              compact: compact,
            ),
            const SizedBox(height: 14),
            _buildEquityCurveAndZoomSection(
              doc,
              compact: compact,
              desktop: desktop,
            ),
            const SizedBox(height: 14),
            _buildForensicDrawerAndLedgerSection(
              doc,
              compact: compact,
              desktop: desktop,
            ),
            const SizedBox(height: 12),
            _buildMethodologyAccordion(compact: compact),
          ],
        );
      },
    );
  }

  Widget _buildHeaderBanner(Map<String, dynamic> doc, {required bool compact}) {
    final snap = asMap(doc['live_market_snapshot']);
    final asOfDate = text(doc['as_of_date']).isEmpty
        ? widget.asOf
        : text(doc['as_of_date']);
    final qqqClose = _numVal(snap['qqq_close']);
    final ddAth = _numVal(snap['dd_from_ath_pct']);
    final ma200 = _numVal(snap['qqq_ma200']);
    final vix = _numVal(snap['vix']);
    final vixRatio = _numVal(snap['vix_vix3m_ratio']);
    final vxn = _numVal(snap['vxn']);
    final rawLights = _numVal(snap['raw_crisis_score']).round();

    return Container(
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: _obsidian,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: _mint.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: _mint.withValues(alpha: 0.45)),
                ),
                child: Text(
                  w('CRISIS OBSERVATORY · ZERO-LOOKAHEAD', '危机观测 · 零前视实盘引擎'),
                  style: const TextStyle(
                    color: _mint,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              InkWell(
                key: const ValueKey('crisis-observatory-qqq-chip'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => widget.onCompany('QQQ'),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: _sky.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _sky.withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    'QQQ \$${qqqClose.toStringAsFixed(2)} (${_fmtPct(ddAth)})',
                    style: const TextStyle(
                      color: _sky,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              _metricChip(
                w('As Of $asOfDate', '数据截至 $asOfDate'),
                _slate,
              ),
              _metricChip(
                w('Lights $rawLights/6', '危机灯 $rawLights/6'),
                rawLights >= 4 ? _coral : _mint,
              ),
              _metricChip(
                'VIX ${vix.toStringAsFixed(2)} · VIX/3M ${vixRatio.toStringAsFixed(3)}',
                vixRatio >= 1.10 ? _amber : _slate,
              ),
              _metricChip(
                'VXN ${vxn.toStringAsFixed(2)} · 200DMA \$${ma200.toStringAsFixed(2)}',
                _slate,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            w(
              'Druckenmiller 6 Crisis Lights × AD Top-Divergence × Pure-Options Naked Put + Collar Shield',
              '德鲁肯米勒六大危机信号 × 全美腾落线顶背离 × 首仓裸 Put + 次仓零成本 Collar 纯期权护城河',
            ),
            style: TextStyle(
              color: p.text,
              fontSize: compact ? 17.5 : 20.5,
              fontWeight: FontWeight.w800,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            w(
              '100% QQQ core forever (zero cash/bond timing): Slot 1 buys a 50% 90-DTE -10% Naked Put near highs (retaining 100% upside); Slot 2 adds a 50% Zero-Cost Collar >=30 days later; VIX/VIX3M >= 1.10 harvests put convexity into extra QQQ shares; new Collars are hard-frozen below ATH -5%.',
              '底仓 100% 满仓 QQQ 永不卖股：高位出现宽度顶背离或 >=4 灯且 VXN<=22 时，首仓买 50% 裸 -10% Put（不卖 Call 保留 100% 冲顶收益）；满 30 日补齐次仓 50% 零成本 Collar；VIX/VIX3M >= 1.10 恐慌倒挂全额止盈抄底增持 QQQ 股数；跌离前高超 5% 严禁低位新开 Collar。',
            ),
            style: TextStyle(
              color: _slate,
              fontSize: compact ? 12 : 13,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricChip(String label, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _surfaceRaised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildHeroSignalCommandCenter(
    Map<String, dynamic> doc, {
    required bool compact,
    required bool desktop,
  }) {
    final sig = asMap(doc['live_signal_state']);
    final regimeCode = text(sig['regime_code']);
    final title = w(
      text(sig['regime_title_en']),
      text(sig['regime_title_zh']),
    );
    final subtitle = w(
      text(sig['regime_subtitle_en']),
      text(sig['regime_subtitle_zh']),
    );
    final activeSlots = _numVal(sig['active_option_slots']).round();

    final Color bannerAccent = switch (regimeCode) {
      'VIX110_TP_TRIGGERED' => _mint,
      'DUAL_SLOT_FULL_SHIELD' || 'SLOT1_NAKED_PUT_ACTIVE' => _sky,
      'SLOT1_NAKED_PUT_ARMED' => _lilac,
      'LOW_SPOT_FREEZE_NO_NEW_COLLAR' => _coral,
      _ => _mint,
    };

    final slot1 = asMap(sig['slot1_naked_put']);
    final slot2 = asMap(sig['slot2_collar']);
    final gates = asList(sig['gate_checklist']);

    final slotCards = [
      _buildTacticalSlotCard(
        keyId: 'slot1',
        title: w(text(slot1['title_en']), text(slot1['title_zh'])),
        badge: w(text(slot1['status_label_en']), text(slot1['status_label_zh'])),
        statusCode: text(slot1['status']),
        accent: _sky,
        ruleText: w(text(slot1['rule_en']), text(slot1['rule_zh'])),
        actionLabel: w('Latest Verified Execution', '最近一笔实盘执行'),
        actionText: w(
          text(asMap(slot1['latest_action'])['summary_en']),
          text(asMap(slot1['latest_action'])['summary_zh']),
        ),
      ),
      _buildTacticalSlotCard(
        keyId: 'slot2',
        title: w(text(slot2['title_en']), text(slot2['title_zh'])),
        badge: w(text(slot2['status_label_en']), text(slot2['status_label_zh'])),
        statusCode: text(slot2['status']),
        accent: _lilac,
        ruleText: w(text(slot2['rule_en']), text(slot2['rule_zh'])),
        actionLabel: w('Latest Verified Execution', '最近一笔实盘执行'),
        actionText: w(
          text(asMap(slot2['latest_action'])['summary_en']),
          text(asMap(slot2['latest_action'])['summary_zh']),
        ),
      ),
    ];

    return Container(
      key: const ValueKey('crisis-observatory-command-center'),
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: bannerAccent.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 5, right: 10),
                decoration: BoxDecoration(
                  color: bannerAccent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: bannerAccent.withValues(alpha: 0.65),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w(
                        'LIVE TACTICAL SIGNAL COMMAND CENTER · PURE OPTIONS',
                        '实时战术信号指令舱 · 首仓裸 Put / 次仓 Collar 纯期权双槽',
                      ),
                      style: TextStyle(
                        color: bannerAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      title,
                      style: TextStyle(
                        color: p.text,
                        fontSize: compact ? 15 : 17,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(color: _slate, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 12),
                Container(
                  key: const ValueKey('crisis-core-allocation-badge'),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _obsidian,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _mint.withValues(alpha: 0.45)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        w('U1 Pure-Options Core', 'U1 纯期权核心底仓'),
                        style: const TextStyle(color: _slate, fontSize: 10.5),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        w(
                          '100% QQQ · $activeSlots/2 Option Slots',
                          '100% 满仓 QQQ · $activeSlots/2 持盾槽位',
                        ),
                        style: TextStyle(
                          color: activeSlots > 0 ? _sky : _mint,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          if (desktop)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: slotCards[0]),
                  const SizedBox(width: 10),
                  Expanded(child: slotCards[1]),
                ],
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                slotCards[0],
                const SizedBox(height: 10),
                slotCards[1],
              ],
            ),
          if (gates.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final g in gates) _buildGatePill(g),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTacticalSlotCard({
    required String keyId,
    required String title,
    required String badge,
    required String statusCode,
    required Color accent,
    required String ruleText,
    required String actionLabel,
    required String actionText,
  }) {
    final isFrozen = statusCode.contains('FROZEN');
    final isActive = statusCode.startsWith('ACTIVE') || statusCode.contains('ARMED');
    final badgeColor = isFrozen ? _coral : (isActive ? accent : _mint);

    return Container(
      key: ValueKey('crisis-slot-card-$keyId'),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: _obsidian,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive
              ? badgeColor.withValues(alpha: 0.55)
              : _hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: badgeColor.withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    badge,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            ruleText,
            style: const TextStyle(color: _slate, fontSize: 11.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: _surfaceRaised,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: _hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  actionLabel,
                  style: TextStyle(
                    color: accent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  actionText,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGatePill(Map<String, dynamic> gate) {
    final passed = gate['passed'] == true;
    final keyStr = text(gate['key']);
    final isTp = keyStr == 'vix_ratio_ge_110_tp' || keyStr == 'vix_tp_110';
    final color = passed ? (isTp ? _amber : _mint) : _slate;
    final label = w(text(gate['label_en']), text(gate['label_zh']));
    final readingVal = text(gate['current_value']).isNotEmpty
        ? text(gate['current_value'])
        : text(gate['reading']);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: passed ? color.withValues(alpha: 0.12) : _obsidian,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: passed ? color.withValues(alpha: 0.5) : _hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            passed ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              readingVal.isEmpty ? label : '$label: $readingVal',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: passed ? p.text : _slate,
                fontSize: 11.5,
                fontWeight: passed ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSixSignalsAndBreadthSection(
    Map<String, dynamic> doc, {
    required double maxWidth,
    required bool compact,
  }) {
    final lights = asList(doc['six_crisis_lights']);
    final ad = asMap(doc['ad_line_signal']);
    final snap = asMap(doc['live_market_snapshot']);
    final litCount = lights.where((item) => item['lit'] == true).length;
    final smooth5d = _numVal(
      snap['smooth_crisis_score_5d'],
      _numVal(snap['smooth_5d_score']),
    );

    final int cols = maxWidth >= 980 ? 3 : (maxWidth >= 620 ? 2 : 1);
    final double spacing = 10;
    final double innerWidth = maxWidth - (compact ? 28 : 36);
    final double cardWidth = cols == 1
        ? innerWidth
        : (innerWidth - spacing * (cols - 1)) / cols;

    final adBelow = ad['below_50ma'] == true;
    final adTopDiv = ad['top_divergence_active'] == true;
    final adAccent = adTopDiv ? _amber : (adBelow ? _coral : _mint);

    return Container(
      key: const ValueKey('crisis-observatory-six-lights'),
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w(
                      'SIX DRUCKENMILLER MACRO CRISIS SIGNALS + AD BREADTH MONITOR',
                      '德鲁肯米勒六大危机信号灯状态 × 全美股票腾落线顶背离监测',
                    ),
                    style: const TextStyle(
                      color: _mint,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    w(
                      'Cross-Asset Early-Warning Matrix (Rates · Credit · Breadth · Copper · Defensives · Curve/NFCI)',
                      '跨资产六维先行危机矩阵（前端利率 · 信用利差 · 市场宽度 · 铜博士 · 防御/周期 · 曲线与金融条件）',
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: compact ? 14.5 : 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: (litCount >= 4 ? _coral : _mint).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(
                        color: (litCount >= 4 ? _coral : _mint).withValues(alpha: 0.5),
                      ),
                    ),
                    child: Text(
                      w(
                        '$litCount / 6 LIGHTS ON',
                        '$litCount / 6 危机灯亮起',
                      ),
                      style: TextStyle(
                        color: litCount >= 4 ? _coral : _mint,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _obsidian,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: _hairline),
                    ),
                    child: Text(
                      w(
                        '5D Avg: ${smooth5d.toStringAsFixed(2)}',
                        '5日均灯: ${smooth5d.toStringAsFixed(2)}',
                      ),
                      style: const TextStyle(
                        color: _amber,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final light in lights)
                SizedBox(
                  width: cardWidth,
                  child: _buildSingleCrisisLightCard(light),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            key: const ValueKey('crisis-observatory-ad-banner'),
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: _obsidian,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: adAccent.withValues(alpha: 0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: adAccent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: adAccent.withValues(alpha: 0.45)),
                      ),
                      child: Text(
                        w(text(ad['status_en']), text(ad['status_zh'])),
                        style: TextStyle(
                          color: adAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      w(
                        'AD ${_numVal(ad['ad_line']).toStringAsFixed(0)} vs 50DMA ${_numVal(ad['ad_sma50']).toStringAsFixed(0)} (${_numVal(ad['spread_vs_50ma']) >= 0 ? '+' : ''}${_numVal(ad['spread_vs_50ma']).toStringAsFixed(0)})',
                        '腾落线 AD ${_numVal(ad['ad_line']).toStringAsFixed(0)} vs 50DMA ${_numVal(ad['ad_sma50']).toStringAsFixed(0)}（差值 ${_numVal(ad['spread_vs_50ma']) >= 0 ? '+' : ''}${_numVal(ad['spread_vs_50ma']).toStringAsFixed(0)}）',
                      ),
                      style: TextStyle(
                        color: p.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (text(ad['last_top_divergence_date']).isNotEmpty)
                      Text(
                        w(
                          'Last Pre-Crash ATH<=5% Divergence: ${text(ad['last_top_divergence_date'])}',
                          '最近一次高位顶背离信号日: ${text(ad['last_top_divergence_date'])}',
                        ),
                        style: const TextStyle(color: _sky, fontSize: 11.5, fontWeight: FontWeight.w600),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  w(text(ad['note_en']), text(ad['note_zh'])),
                  style: const TextStyle(color: _slate, fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSingleCrisisLightCard(Map<String, dynamic> light) {
    final lit = light['lit'] == true;
    final keyStr = text(light['key']);
    final idx = _numVal(light['index']).round();
    final accent = lit ? _coral : _slate;

    return Container(
      key: ValueKey('crisis-light-card-$keyStr'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _obsidian,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: lit ? _coral.withValues(alpha: 0.45) : _hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: lit ? _coral : _hairline,
                  shape: BoxShape.circle,
                  boxShadow: lit
                      ? [
                          BoxShadow(
                            color: _coral.withValues(alpha: 0.65),
                            blurRadius: 6,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  '#$idx · ${w(text(light['name_en']), text(light['name_zh']))}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: lit ? _coral.withValues(alpha: 0.16) : _surfaceRaised,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: lit ? _coral.withValues(alpha: 0.5) : _hairline,
                  ),
                ),
                child: Text(
                  lit ? w('ON', '亮灯') : w('OFF', '熄灭'),
                  style: TextStyle(
                    color: accent,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  text(light['reading_value']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: lit ? _amber : p.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text(light['secondary_value']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _slate,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            w(text(light['threshold_en']), text(light['threshold_zh'])),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _slate, fontSize: 11, height: 1.35),
          ),
        ],
      ),
    );
  }

  Widget _buildEquityCurveAndZoomSection(
    Map<String, dynamic> doc, {
    required bool compact,
    required bool desktop,
  }) {
    final allDaily = asList(doc['daily_series']);
    final windows = asList(doc['crisis_windows']);
    final (effStart, effEnd) = _resolvedRange(allDaily.length);
    final isZoomed =
        allDaily.length > 1 && (effStart > 0 || effEnd < allDaily.length - 1);
    final activeWin =
        (selectedWindowId != 'ALL' && selectedWindowId != 'CUSTOM')
            ? _findWindow(doc, selectedWindowId)
            : null;

    final List<Map<String, dynamic>> visibleDaily = allDaily.isEmpty
        ? const []
        : allDaily.sublist(effStart, effEnd + 1);

    final visStartDate =
        visibleDaily.isNotEmpty ? text(visibleDaily.first['date']) : '';
    final visEndDate =
        visibleDaily.isNotEmpty ? text(visibleDaily.last['date']) : '';

    final stratSummary = _findStrategySummary(doc, selectedStrategyId);
    final bhSummary = _findStrategySummary(doc, 'BH_Pure_QQQ');
    final navKey = _strategyNavKeys[selectedStrategyId] ?? 'nav_u1';

    final allEvents = _currentEventsForStrategy(doc);
    final visibleEvents = visibleDaily.isEmpty
        ? const <Map<String, dynamic>>[]
        : allEvents.where((ev) {
            final dt = text(ev['date']);
            return dt.compareTo(visStartDate) >= 0 &&
                dt.compareTo(visEndDate) <= 0;
          }).toList();

    final hoveredRow =
        (hoverIndex >= 0 && hoverIndex < visibleDaily.length)
        ? visibleDaily[hoverIndex]
        : (visibleDaily.isNotEmpty ? visibleDaily.last : const <String, dynamic>{});

    final startStratNav = visibleDaily.isNotEmpty
        ? _numVal(visibleDaily.first[navKey], 200000)
        : 200000.0;
    final startBhNav = visibleDaily.isNotEmpty
        ? _numVal(visibleDaily.first['nav_bh'], 200000)
        : 200000.0;
    final endStratNav = visibleDaily.isNotEmpty
        ? _numVal(visibleDaily.last[navKey], startStratNav)
        : startStratNav;
    final endBhNav = visibleDaily.isNotEmpty
        ? _numVal(visibleDaily.last['nav_bh'], startBhNav)
        : startBhNav;

    final hovStratNav = _numVal(hoveredRow[navKey]);
    final hovBhNav = _numVal(hoveredRow['nav_bh']);
    final hovStratRebased = startStratNav > 0 ? (hovStratNav / startStratNav) * 100 : 100.0;
    final hovBhRebased = startBhNav > 0 ? (hovBhNav / startBhNav) * 100 : 100.0;
    final rebasedActive = isZoomed && useRebasedZoom;

    double winStratRetPct = 0;
    double winBhRetPct = 0;
    double winStratMddPct = 0;
    double winBhMddPct = 0;
    if (visibleDaily.length >= 2) {
      winStratRetPct =
          startStratNav > 0 ? (endStratNav / startStratNav - 1.0) * 100.0 : 0.0;
      winBhRetPct =
          startBhNav > 0 ? (endBhNav / startBhNav - 1.0) * 100.0 : 0.0;
      var pkS = startStratNav;
      var pkB = startBhNav;
      for (final row in visibleDaily) {
        final sv = _numVal(row[navKey], pkS);
        final bv = _numVal(row['nav_bh'], pkB);
        if (sv > pkS) pkS = sv;
        if (bv > pkB) pkB = bv;
        final ddS = pkS > 0 ? (sv / pkS - 1.0) * 100.0 : 0.0;
        final ddB = pkB > 0 ? (bv / pkB - 1.0) * 100.0 : 0.0;
        if (ddS < winStratMddPct) winStratMddPct = ddS;
        if (ddB < winBhMddPct) winBhMddPct = ddB;
      }
    }
    final winExcessPct = winStratRetPct - winBhRetPct;
    final tpEventsInWin = visibleEvents
        .where((e) {
          final et = text(e['event_type']);
          return et == 'vix110_tp' || et == 'tp_exit';
        })
        .length;
    final openEventsInWin = visibleEvents
        .where((e) {
          final et = text(e['event_type']);
          return et == 'slot1_naked_put' ||
              et.endsWith('_collar') ||
              et == 'open_naked_put' ||
              et == 'open_collar';
        })
        .length;

    final canZoomIn = (effEnd - effStart) > _minZoomSpan;
    final canZoomOut = isZoomed;
    final canPanLeft = isZoomed && effStart > 0;
    final canPanRight = isZoomed && effEnd < allDaily.length - 1;

    final String headerTitle = activeWin != null
        ? (rebasedActive
            ? w(
                'Zoomed In: ${text(activeWin['title_en'])} (Rebased to 100.0 at Window Start)',
                '危机放大视图：${text(activeWin['title_zh'])}（窗口起点归一化 = 100.0）',
              )
            : w(
                'Zoomed In: ${text(activeWin['title_en'])} ($visStartDate -> $visEndDate)',
                '危机放大视图：${text(activeWin['title_zh'])}（$visStartDate -> $visEndDate）',
              ))
        : (isZoomed
            ? (rebasedActive
                ? w(
                    'Custom Range: $visStartDate -> $visEndDate (${visibleDaily.length}D · Rebased to 100.0)',
                    '自定义观测时段：$visStartDate -> $visEndDate（${visibleDaily.length} 个交易日 · 起点归一化 = 100.0）',
                  )
                : w(
                    'Custom Range: $visStartDate -> $visEndDate (${visibleDaily.length}D · Absolute NAV \$)',
                    '自定义观测时段：$visStartDate -> $visEndDate（${visibleDaily.length} 个交易日 · 美元净值）',
                  ))
            : w(
                'Full-Cycle Compounding (2015-01-02 to ${text(doc['as_of_date'])}) · Drag Slider or Click Any Crisis to Zoom In',
                '2015-2026 完整周期净值对比 · 支持拖动下方时间滑块、快捷时段按钮或危机胶囊任意缩放',
              ));

    return Container(
      key: const ValueKey('crisis-observatory-chart-section'),
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w(
                      'HISTORICAL EQUITY CURVE & INTERACTIVE TIME-RANGE ZOOM INSPECTOR (\$200K DRIP START)',
                      '历史纯期权保护 vs 纯持有 QQQ 净值曲线与交互式时段放大镜（\$200,000 起投股息再投）',
                    ),
                    style: const TextStyle(
                      color: _mint,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    headerTitle,
                    style: TextStyle(
                      color: p.text,
                      fontSize: compact ? 14.5 : 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (isZoomed) ...[
                    _scaleToggleBtn(
                      key: const ValueKey('crisis-rebased-toggle-btn'),
                      label: rebasedActive
                          ? w('Rebased 100', '归一化 = 100')
                          : w('USD NAV (\$)', '美元净值 (\$)'),
                      active: true,
                      onTap: () =>
                          setState(() => useRebasedZoom = !useRebasedZoom),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('crisis-zoom-reset-btn'),
                      onPressed: () =>
                          _applyWindowSelection(allDaily, doc, 'ALL'),
                      icon: const Icon(
                        Icons.zoom_out_map,
                        size: 14,
                        color: _mint,
                      ),
                      label: Text(
                        w('Reset Full Range', '重置全景'),
                        style: const TextStyle(color: _mint, fontSize: 12),
                      ),
                    ),
                  ],
                  if (!rebasedActive) ...[
                    _scaleToggleBtn(
                      key: const ValueKey('crisis-scale-log-btn'),
                      label: w('Log Scale', '对数坐标'),
                      active: useLogScale,
                      onTap: () => setState(() => useLogScale = true),
                    ),
                    _scaleToggleBtn(
                      key: const ValueKey('crisis-scale-linear-btn'),
                      label: w('Linear', '线性坐标'),
                      active: !useLogScale,
                      onTap: () => setState(() => useLogScale = false),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Strategy selector pills
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final sid in _selectableStrategies)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _buildStrategyPill(doc, sid),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Full-cycle KPI comparison strip
          _buildStrategyKpiStrip(
            stratSummary,
            bhSummary,
            compact: compact,
            desktop: desktop,
          ),
          const SizedBox(height: 12),
          // Interactive Time-Range Presets + Precision Zoom/Pan Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _obsidian,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _hairline),
            ),
            child: Wrap(
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
                      w('Range:', '快捷时段:'),
                      style: const TextStyle(
                        color: _slate,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    for (final preset in const [
                      ('6M', '6M', '近6月'),
                      ('1Y', '1Y', '近1年'),
                      ('3Y', '3Y', '近3年'),
                      ('5Y', '5Y', '近5年'),
                      ('ALL', 'ALL', '全周期'),
                    ])
                      _scaleToggleBtn(
                        key: ValueKey('crisis-period-pill-${preset.$1}'),
                        label: w(preset.$2, preset.$3),
                        active: activePeriodPreset == preset.$1,
                        onTap: () => _applyPeriodPreset(allDaily, preset.$1),
                      ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _zoomIconBtn(
                      key: const ValueKey('crisis-pan-left-btn'),
                      icon: Icons.chevron_left,
                      label: w('Pan', '左移'),
                      enabled: canPanLeft,
                      onTap: () => _panRange(allDaily, -0.25),
                    ),
                    _zoomIconBtn(
                      key: const ValueKey('crisis-zoom-in-btn'),
                      icon: Icons.zoom_in,
                      label: w('Zoom In', '放大'),
                      enabled: canZoomIn,
                      onTap: () => _zoomByFactor(allDaily, 0.55),
                    ),
                    _zoomIconBtn(
                      key: const ValueKey('crisis-zoom-out-btn'),
                      icon: Icons.zoom_out,
                      label: w('Zoom Out', '缩小'),
                      enabled: canZoomOut,
                      onTap: () => _zoomByFactor(allDaily, 1.75),
                    ),
                    _zoomIconBtn(
                      key: const ValueKey('crisis-pan-right-btn'),
                      icon: Icons.chevron_right,
                      label: w('Pan', '右移'),
                      enabled: canPanRight,
                      onTap: () => _panRange(allDaily, 0.25),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Crisis Zoom-In Pills
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _buildWindowZoomPill(
                id: 'ALL',
                label: w('All 2015-2026', '全周期 2015-2026'),
                isLive: false,
                onTap: () => _applyWindowSelection(allDaily, doc, 'ALL'),
              ),
              for (final win in windows)
                _buildWindowZoomPill(
                  id: text(win['id']),
                  label: w(text(win['pill_en']), text(win['pill_zh'])),
                  isLive: win['is_live'] == true,
                  onTap: () =>
                      _applyWindowSelection(allDaily, doc, text(win['id'])),
                ),
            ],
          ),
          if (isZoomed && visibleDaily.length >= 2) ...[
            const SizedBox(height: 10),
            Container(
              key: const ValueKey('crisis-zoom-window-stats'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: _obsidian,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _mint.withValues(alpha: 0.35)),
              ),
              child: Wrap(
                spacing: 14,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    w(
                      'Window: $visStartDate -> $visEndDate (${visibleDaily.length}D)',
                      '当前区间：$visStartDate -> $visEndDate（${visibleDaily.length} 交易日）',
                    ),
                    style: const TextStyle(
                      color: _sky,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '${w('Strategy', '策略收益')} ${_fmtPct(winStratRetPct)} vs QQQ ${_fmtPct(winBhRetPct)} (${w('Excess', '超额')} ${_fmtPct(winExcessPct)})',
                    style: TextStyle(
                      color: winExcessPct >= 0 ? _mint : _coral,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    '${w('Window MDD', '区间最大回撤')}: ${_fmtPct(winStratMddPct, signed: false)} vs QQQ ${_fmtPct(winBhMddPct, signed: false)}',
                    style: const TextStyle(
                      color: _amber,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    w(
                      'Events: $openEventsInWin Opens · $tpEventsInWin Panic TPs',
                      '区间期权信号：$openEventsInWin 次建仓 · $tpEventsInWin 次 1.10 止盈',
                    ),
                    style: const TextStyle(
                      color: _slate,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          // Legend + Live Hover Readout Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: _obsidian,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _hairline),
            ),
            child: Wrap(
              spacing: 14,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _legendItem(
                  _mint,
                  w(
                    text(stratSummary['short_en']).isEmpty
                        ? selectedStrategyId
                        : text(stratSummary['short_en']),
                    text(stratSummary['short_zh']).isEmpty
                        ? selectedStrategyId
                        : text(stratSummary['short_zh']),
                  ),
                ),
                _legendItem(_sky, w('Pure QQQ Hold (DRIP)', '纯持有 QQQ (股息再投)')),
                _legendItem(_amber, w('▲ Slot 1 Naked Put', '▲ 首仓裸 Put')),
                _legendItem(_lilac, w('● Slot 2 Collar', '● 次仓 Collar')),
                _legendItem(_mint, w('◆ 1.10 Panic TP', '◆ 1.10 恐慌止盈')),
                if (hoveredRow.isNotEmpty)
                  Text(
                    rebasedActive
                        ? '${text(hoveredRow['date'])} · ${w('Idx', '归一化')} ${hovStratRebased.toStringAsFixed(1)} vs QQQ ${hovBhRebased.toStringAsFixed(1)} · QQQ \$${_numVal(hoveredRow['qqq_close']).toStringAsFixed(2)} · ${w('Lights', '灯')} ${_numVal(hoveredRow['crisis_lights']).round()}/6 · VIX/3M ${_numVal(hoveredRow['vix_ratio']).toStringAsFixed(2)}'
                        : '${text(hoveredRow['date'])} · ${_fmtUsd(hovStratNav)} vs QQQ ${_fmtUsd(hovBhNav)} · ${w('Lights', '危机灯')} ${_numVal(hoveredRow['crisis_lights']).round()}/6 · VIX/3M ${_numVal(hoveredRow['vix_ratio']).toStringAsFixed(2)}',
                    style: TextStyle(
                      color: p.text,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Interactive Multi-Track CustomPainter Canvas + Floating Hover Tooltip
          LayoutBuilder(
            builder: (context, chartConstraints) {
              final chartWidth = chartConstraints.maxWidth;
              final chartHeight = compact ? 350.0 : 420.0;
              final isHoverActive =
                  hoverIndex >= 0 && hoverIndex < visibleDaily.length;
              final activeHoverRow = isHoverActive
                  ? visibleDaily[hoverIndex]
                  : const <String, dynamic>{};
              final hoverEvents = isHoverActive
                  ? _eventsNearHoverIndex(
                      visibleDaily: visibleDaily,
                      visibleEvents: visibleEvents,
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
                  child: Container(
                    key: const ValueKey('crisis-observatory-canvas'),
                    height: chartHeight,
                    decoration: BoxDecoration(
                      color: _obsidian,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _hairline),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              size: Size(chartWidth, chartHeight),
                              painter: _CrisisObservatoryChartPainter(
                                rows: visibleDaily,
                                events: visibleEvents,
                                navKey: navKey,
                                rebasedMode: rebasedActive,
                                useLogScale: !rebasedActive && useLogScale,
                                hoverIndex: hoverIndex,
                              ),
                            ),
                          ),
                          if (isHoverActive && activeHoverRow.isNotEmpty)
                            _buildChartHoverTooltip(
                              row: activeHoverRow,
                              hoverEvents: hoverEvents,
                              stratSummary: stratSummary,
                              navKey: navKey,
                              startStratNav: startStratNav,
                              startBhNav: startBhNav,
                              isZoomed: isZoomed,
                              rebasedActive: rebasedActive,
                              hoverIdx: hoverIndex,
                              totalVisible: visibleDaily.length,
                              chartWidth: chartWidth,
                              chartHeight: chartHeight,
                              compact: compact,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          if (allDaily.length > _minZoomSpan + 1) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _obsidian,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        visStartDate,
                        style: const TextStyle(
                          color: _mint,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          w(
                            'Drag handles to adjust time range (${visibleDaily.length}/${allDaily.length} trading days)',
                            '拖动两端滑块自由缩放/平移观测时段（${visibleDaily.length}/${allDaily.length} 交易日）',
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _slate,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      Text(
                        visEndDate,
                        style: const TextStyle(
                          color: _mint,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      activeTrackColor: _mint,
                      inactiveTrackColor: _hairline,
                      thumbColor: _mint,
                      overlayColor: _mint.withValues(alpha: 0.18),
                      rangeThumbShape: const RoundRangeSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      valueIndicatorColor: _surfaceRaised,
                      valueIndicatorTextStyle: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    child: RangeSlider(
                      key: const ValueKey('crisis-zoom-range-slider'),
                      min: 0,
                      max: (allDaily.length - 1).toDouble(),
                      values: RangeValues(
                        effStart.toDouble(),
                        effEnd.toDouble(),
                      ),
                      labels: RangeLabels(visStartDate, visEndDate),
                      onChanged: (rv) {
                        var nextS = rv.start.round().clamp(0, allDaily.length - 1);
                        var nextE = rv.end.round().clamp(0, allDaily.length - 1);
                        if (nextE - nextS < _minZoomSpan) {
                          if ((nextS - effStart).abs() > (nextE - effEnd).abs()) {
                            nextS = math.max(0, nextE - _minZoomSpan);
                          } else {
                            nextE = math.min(
                              allDaily.length - 1,
                              nextS + _minZoomSpan,
                            );
                          }
                        }
                        if (nextS == effStart && nextE == effEnd) return;
                        final isFull =
                            nextS == 0 && nextE == allDaily.length - 1;
                        setState(() {
                          rangeStartIdx = nextS;
                          rangeEndIdx = nextE;
                          selectedWindowId = isFull ? 'ALL' : 'CUSTOM';
                          activePeriodPreset = isFull ? 'ALL' : 'CUSTOM';
                          hoverIndex = -1;
                        });
                      },
                      onChangeEnd: (_) => _emitSelection(),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _updateHoverFromDx(double dx, double width, int count) {
    if (count <= 1 || width <= 64) return;
    const padL = 54.0;
    const padR = 14.0;
    final plotW = math.max(1.0, width - padL - padR);
    final rel = ((dx - padL) / plotW).clamp(0.0, 1.0);
    final idx = (rel * (count - 1)).round().clamp(0, count - 1);
    if (idx != hoverIndex) {
      setState(() => hoverIndex = idx);
    }
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

    // On dense multi-year ranges, snap to the nearest marker within 9px of crosshair
    final n = visibleDaily.length;
    if (n <= 1) return const [];
    const padL = 54.0;
    const padR = 14.0;
    final plotW = math.max(1.0, chartWidth - padL - padR);
    final hoverX = padL + (hoverIdx / (n - 1)) * plotW;

    final idxByDate = <String, int>{
      for (var i = 0; i < n; i++) text(visibleDaily[i]['date']): i,
    };
    String? bestDate;
    var bestDist = 9.5;
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

  Widget _buildChartHoverTooltip({
    required Map<String, dynamic> row,
    required List<Map<String, dynamic>> hoverEvents,
    required Map<String, dynamic> stratSummary,
    required String navKey,
    required double startStratNav,
    required double startBhNav,
    required bool isZoomed,
    required bool rebasedActive,
    required int hoverIdx,
    required int totalVisible,
    required double chartWidth,
    required double chartHeight,
    required bool compact,
  }) {
    const padL = 54.0;
    const padR = 14.0;
    final plotW = math.max(1.0, chartWidth - padL - padR);
    final hx = totalVisible > 1
        ? padL + (hoverIdx / (totalVisible - 1)) * plotW
        : padL;
    final tooltipW = compact ? math.min(272.0, chartWidth - 18.0) : 336.0;
    final placeRight = hx + 14.0 + tooltipW <= chartWidth - 8.0;
    final double leftPos = placeRight
        ? hx + 14.0
        : (hx - tooltipW - 14.0).clamp(
            8.0,
            math.max(8.0, chartWidth - tooltipW - 8.0),
          );

    final dt = text(row['date']);
    final qqqClose = _numVal(row['qqq_close']);
    final ddAth = _numVal(row['dd_ath_pct']);
    final stratNav = _numVal(row[navKey]);
    final bhNav = _numVal(row['nav_bh']);
    final stratWinRet =
        startStratNav > 0 ? (stratNav / startStratNav - 1.0) * 100.0 : 0.0;
    final bhWinRet =
        startBhNav > 0 ? (bhNav / startBhNav - 1.0) * 100.0 : 0.0;
    final winExcess = stratWinRet - bhWinRet;
    final stratRebased =
        startStratNav > 0 ? (stratNav / startStratNav) * 100.0 : 100.0;
    final bhRebased = startBhNav > 0 ? (bhNav / startBhNav) * 100.0 : 100.0;
    final dollarAlpha = stratNav - bhNav;

    final lightsCount = _numVal(row['crisis_lights']).round();
    final lightsMask = _numVal(row['lights_mask']).round();
    final vix = _numVal(row['vix']);
    final vix3m = _numVal(row['vix3m']);
    final vixRatio = _numVal(row['vix_ratio']);
    final vxn = _numVal(row['vxn']);
    final adVs50 = _numVal(row['ad_vs_50ma']);
    final activeSlots = _numVal(row['active_slots']).round();

    final stratLabel = w(
      text(stratSummary['short_en']).isEmpty
          ? selectedStrategyId
          : text(stratSummary['short_en']),
      text(stratSummary['short_zh']).isEmpty
          ? selectedStrategyId
          : text(stratSummary['short_zh']),
    );

    final lightNames = <(int, String, String)>[
      (1, 'Rates', '利率'),
      (2, 'Credit', '信用'),
      (4, 'Breadth', '宽度'),
      (8, 'Copper', '铜价'),
      (16, 'Def/Cyc', '防御'),
      (32, 'Curve', '曲线'),
    ];
    final litLabels = [
      for (final item in lightNames)
        if ((lightsMask & item.$1) != 0) w(item.$2, item.$3),
    ];

    Color borderColor = _hairline;
    if (hoverEvents.isNotEmpty) {
      final firstType = text(hoverEvents.first['event_type']);
      if (firstType == 'vix110_tp' || firstType == 'tp_exit') {
        borderColor = _mint.withValues(alpha: 0.75);
      } else if (firstType == 'slot1_naked_put' ||
          firstType == 'open_naked_put') {
        borderColor = _amber.withValues(alpha: 0.75);
      } else if (firstType.endsWith('_collar') || firstType == 'open_collar') {
        borderColor = _lilac.withValues(alpha: 0.75);
      }
    }

    return Positioned(
      left: leftPos,
      top: 10,
      width: tooltipW,
      child: IgnorePointer(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: math.max(120, chartHeight - 24)),
          child: Container(
            key: const ValueKey('crisis-chart-hover-tooltip'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xF20B1118),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: borderColor, width: 1.1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header: Date + QQQ Spot & ATH DD
                  Row(
                    children: [
                      Text(
                        dt,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: _surfaceRaised,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: _hairline),
                            ),
                            child: Text(
                              'QQQ \$${qqqClose.toStringAsFixed(2)} (${_fmtPct(ddAth, digits: 1)})',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: ddAth <= -5.0 ? _coral : _sky,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Strategy vs QQQ NAV & Return
                  _tooltipMetricRow(
                    dotColor: _mint,
                    label: stratLabel,
                    value: rebasedActive
                        ? '${stratRebased.toStringAsFixed(1)} (${_fmtPct(stratWinRet, digits: 1)}) · ${_fmtUsd(stratNav, compact: true)}'
                        : '${_fmtUsd(stratNav)} (${_fmtPct(stratWinRet, digits: 1)})',
                    valueColor: _mint,
                  ),
                  const SizedBox(height: 3),
                  _tooltipMetricRow(
                    dotColor: _sky,
                    label: w('Pure QQQ', '纯持 QQQ'),
                    value: rebasedActive
                        ? '${bhRebased.toStringAsFixed(1)} (${_fmtPct(bhWinRet, digits: 1)}) · ${_fmtUsd(bhNav, compact: true)}'
                        : '${_fmtUsd(bhNav)} (${_fmtPct(bhWinRet, digits: 1)})',
                    valueColor: _sky,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        isZoomed
                            ? w('Window Excess', '区间超额')
                            : w('Cumulative Alpha', '累计净超额'),
                        style: const TextStyle(color: _slate, fontSize: 10.5),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isZoomed
                              ? '${_fmtPct(winExcess)} (${_fmtUsd(dollarAlpha, signed: true, compact: true)})'
                              : '${_fmtUsd(dollarAlpha, signed: true)} (${_fmtPct(winExcess)})',
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: (isZoomed ? winExcess : dollarAlpha) >= 0
                                ? _mint
                                : _coral,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 11, color: _hairline),
                  // Crisis Lights + Lit Tags + VIX/VIX3M + AD Breadth
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: (lightsCount >= 4 ? _coral : _mint)
                              .withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          w('Lights $lightsCount/6', '危机灯 $lightsCount/6'),
                          style: TextStyle(
                            color: lightsCount >= 4 ? _coral : _mint,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          litLabels.isEmpty
                              ? w('All 6 Clear', '六灯全灭')
                              : litLabels.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _slate,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 3,
                    children: [
                      Text(
                        'VIX ${vix.toStringAsFixed(1)} / 3M ${vix3m.toStringAsFixed(1)}',
                        style: const TextStyle(color: _slate, fontSize: 10.5),
                      ),
                      Text(
                        'VIX/3M ${vixRatio.toStringAsFixed(3)}${vixRatio >= 1.10 ? ' TP!' : ''}',
                        style: TextStyle(
                          color: vixRatio >= 1.10 ? _amber : p.text,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'VXN ${vxn.toStringAsFixed(1)}',
                        style: const TextStyle(color: _slate, fontSize: 10.5),
                      ),
                      Text(
                        'AD ${adVs50 >= 0 ? '+' : ''}${adVs50.round()}',
                        style: TextStyle(
                          color: adVs50 < 0 ? _coral : _mint,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (selectedStrategyId == 'U1_PureOptions')
                        Text(
                          w('Slots $activeSlots/2', '槽位 $activeSlots/2'),
                          style: TextStyle(
                            color: activeSlots > 0 ? _sky : _slate,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                  // Option Event Callouts (if hovering on or near any marker!)
                  if (hoverEvents.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    for (var i = 0; i < math.min(2, hoverEvents.length); i++) ...[
                      if (i > 0) const SizedBox(height: 5),
                      _buildTooltipEventCard(
                        hoverEvents[i],
                        hoveredDate: dt,
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tooltipMetricRow({
    required Color dotColor,
    required String label,
    required String value,
    required Color valueColor,
  }) {
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          flex: 4,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _slate, fontSize: 10.5),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 6,
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTooltipEventCard(
    Map<String, dynamic> ev, {
    required String hoveredDate,
  }) {
    final et = text(ev['event_type']);
    final evDate = text(ev['date']);
    final isTp = et == 'vix110_tp' || et == 'tp_exit';
    final isNakedOpen = et == 'slot1_naked_put' || et == 'open_naked_put';
    final isCollarOpen = et.endsWith('_collar') || et == 'open_collar';

    final Color accent = isTp
        ? _mint
        : (isNakedOpen ? _amber : (isCollarOpen ? _lilac : _slate));
    final String badgeText = isTp
        ? w('◆ 1.10 PANIC TP', '◆ 1.10 恐慌止盈抄底')
        : (isNakedOpen
            ? w('▲ SLOT 1 NAKED PUT', '▲ 首仓 50% 裸 Put 建仓')
            : (isCollarOpen
                ? w('● ZERO-COST COLLAR', '● 零成本 Collar 建仓')
                : w('90-DTE EXPIRY', '90-DTE 到期结算')));

    final spot = _numVal(ev['spot']);
    final kp = _numVal(ev['kp']);
    final kc = ev['kc'] == null ? null : _numVal(ev['kc']);
    final capPct = ev['call_cap_pct'] == null ? null : _numVal(ev['call_cap_pct']);
    final strikeLine = kc == null
        ? 'K_P=\$${kp.toStringAsFixed(2)} (${w('No Call Cap', '无卖Call封顶')})'
        : 'K_P=\$${kp.toStringAsFixed(2)} / K_C=\$${kc.toStringAsFixed(2)}${capPct != null ? ' (+${capPct.toStringAsFixed(1)}%)' : ''}';
    final triggerTxt = w(text(ev['trigger_en']), text(ev['trigger_zh']));
    final netPnl = ev['net_pnl_usd'] == null ? null : _numVal(ev['net_pnl_usd']);
    final shAdded = ev['shares_added'] == null ? null : _numVal(ev['shares_added']);

    return Container(
      key: ValueKey('crisis-hover-event-${text(ev['event_id'])}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: accent.withValues(alpha: 0.48)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  evDate != hoveredDate ? '$badgeText · $evDate' : badgeText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (netPnl != null && (isTp || et == 'option_expiry')) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    '${_fmtUsd(netPnl, signed: true)} (${shAdded != null && shAdded >= 0 ? '+' : ''}${shAdded?.toStringAsFixed(1) ?? '0.0'} sh)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: netPnl >= 0 ? _mint : _coral,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '@\$${spot.toStringAsFixed(2)} · $strikeLine',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: p.text,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (triggerTxt.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              triggerTxt,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _slate, fontSize: 10),
            ),
          ],
          if (isTp && ev['gamma_usd'] != null && ev['vega_usd'] != null) ...[
            const SizedBox(height: 2),
            Text(
              'Delta ${_fmtUsd(_numVal(ev['delta_usd']), signed: true, compact: true)} · Gamma ${_fmtUsd(_numVal(ev['gamma_usd']), signed: true, compact: true)} · Vega ${_fmtUsd(_numVal(ev['vega_usd']), signed: true, compact: true)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _amber,
                fontSize: 9.8,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _scaleToggleBtn({
    Key? key,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? _mint.withValues(alpha: 0.16) : _obsidian,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? _mint : _hairline),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? _mint : _slate,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _zoomIconBtn({
    Key? key,
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final fg = enabled ? p.text : _slate.withValues(alpha: 0.38);
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(6),
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: enabled ? _surfaceRaised : _obsidian,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: enabled ? _hairline : _hairline.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: enabled ? _sky : fg),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStrategyPill(Map<String, dynamic> doc, String sid) {
    final s = _findStrategySummary(doc, sid);
    final active = selectedStrategyId == sid;
    final label = w(
      text(s['short_en']).isEmpty ? sid : text(s['short_en']),
      text(s['short_zh']).isEmpty ? sid : text(s['short_zh']),
    );
    final alpha = _numVal(s['net_alpha_usd']);

    return InkWell(
      key: ValueKey('crisis-strategy-pill-$sid'),
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        if (selectedStrategyId == sid) return;
        setState(() {
          selectedStrategyId = sid;
        });
        _emitSelection();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: active ? _mint.withValues(alpha: 0.16) : _obsidian,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? _mint : _hairline,
            width: active ? 1.4 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: active ? p.text : _slate,
                fontSize: 12,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _fmtUsd(alpha, signed: true, compact: true),
              style: TextStyle(
                color: active ? _mint : _sky,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStrategyKpiStrip(
    Map<String, dynamic> strat,
    Map<String, dynamic> bh, {
    required bool compact,
    required bool desktop,
  }) {
    final tiles = [
      (
        w('Strategy End NAV', '保护策略期末净值'),
        _fmtUsd(_numVal(strat['end_nav'])),
        '${w('vs QQQ', '对比纯持')} ${_fmtUsd(_numVal(bh['end_nav']), compact: true)}',
        _mint,
      ),
      (
        w('Net Dollar Alpha', '累计净超额收益'),
        _fmtUsd(_numVal(strat['net_alpha_usd']), signed: true),
        '+${(_numVal(strat['final_shares']) - _numVal(bh['final_shares'])).toStringAsFixed(1)} QQQ sh',
        _mint,
      ),
      (
        w('CAGR (2015-2026)', '年化复合收益 CAGR'),
        _fmtPct(_numVal(strat['cagr_pct']), signed: false),
        'QQQ ${_fmtPct(_numVal(bh['cagr_pct']), signed: false)}',
        _sky,
      ),
      (
        w('Max Drawdown', '历史最大回撤 MDD'),
        _fmtPct(_numVal(strat['max_dd_pct']), signed: false),
        'QQQ ${_fmtPct(_numVal(bh['max_dd_pct']), signed: false)}',
        _amber,
      ),
      (
        w('Sharpe / Calmar', '夏普 / 卡玛比率'),
        '${_numVal(strat['sharpe']).toStringAsFixed(3)} / ${_numVal(strat['calmar']).toStringAsFixed(3)}',
        'QQQ ${_numVal(bh['sharpe']).toStringAsFixed(3)} / ${_numVal(bh['calmar']).toStringAsFixed(3)}',
        _lilac,
      ),
    ];

    if (desktop) {
      return Row(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: _kpiTile(tiles[i])),
          ],
        ],
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final t in tiles)
          SizedBox(
            width: compact ? 155 : 190,
            child: _kpiTile(t),
          ),
      ],
    );
  }

  Widget _kpiTile((String, String, String, Color) item) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _obsidian,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.$1,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _slate, fontSize: 10.5),
          ),
          const SizedBox(height: 3),
          Text(
            item.$2,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: item.$4,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            item.$3,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _slate, fontSize: 10.5),
          ),
        ],
      ),
    );
  }

  Widget _buildWindowZoomPill({
    required String id,
    required String label,
    required bool isLive,
    required VoidCallback onTap,
  }) {
    final active = selectedWindowId == id;
    final accent = isLive ? _coral : _sky;
    return InkWell(
      key: ValueKey('crisis-zoom-pill-$id'),
      borderRadius: BorderRadius.circular(7),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? accent.withValues(alpha: 0.18)
              : (isLive ? _coral.withValues(alpha: 0.08) : _obsidian),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: active
                ? accent
                : (isLive ? _coral.withValues(alpha: 0.45) : _hairline),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              id == 'ALL' ? Icons.public : Icons.zoom_in,
              size: 13,
              color: active ? accent : _slate,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: active ? p.text : (isLive ? _coral : _slate),
                fontSize: 11.5,
                fontWeight: active || isLive ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(
            color: _slate,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildForensicDrawerAndLedgerSection(
    Map<String, dynamic> doc, {
    required bool compact,
    required bool desktop,
  }) {
    final allDaily = asList(doc['daily_series']);
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
    final peakVixRatio = _numVal(forensicWin['peak_vix_ratio']);

    return Container(
      key: const ValueKey('crisis-observatory-forensic-section'),
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w(
                      'CRISIS FORENSIC REPLAY & STEP-BY-STEP OPTION TRADE LEDGER',
                      '历史危机切片复盘 × 逐笔裸 Put / Collar 期权操作明细台账',
                    ),
                    style: const TextStyle(
                      color: _mint,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    w(
                      text(forensicWin['title_en']),
                      text(forensicWin['title_zh']),
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: compact ? 14.5 : 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final win in windows)
                    InkWell(
                      key: ValueKey('crisis-forensic-pill-${text(win['id'])}'),
                      borderRadius: BorderRadius.circular(6),
                      onTap: () {
                        final id = text(win['id']);
                        showFullLedger = false;
                        _applyWindowSelection(allDaily, doc, id);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: winId == text(win['id'])
                              ? _sky.withValues(alpha: 0.18)
                              : _obsidian,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: winId == text(win['id']) ? _sky : _hairline,
                          ),
                        ),
                        child: Text(
                          w(text(win['pill_en']), text(win['pill_zh'])),
                          style: TextStyle(
                            color: winId == text(win['id']) ? p.text : _slate,
                            fontSize: 11,
                            fontWeight: winId == text(win['id'])
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Forensic narrative box
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: _obsidian,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _sky.withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w(
                    'Window: $winStart -> $winEnd (Crash Core: ${text(forensicWin['crash_start_date'])} -> ${text(forensicWin['crash_end_date'])})',
                    '观测窗口：$winStart -> $winEnd（主跌核心段：${text(forensicWin['crash_start_date'])} -> ${text(forensicWin['crash_end_date'])}）',
                  ),
                  style: const TextStyle(
                    color: _sky,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  w(
                    text(forensicWin['narrative_en']),
                    text(forensicWin['narrative_zh']),
                  ),
                  style: TextStyle(
                    color: p.text,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _forensicMiniStat(
                      w('QQQ Window MDD', 'QQQ 窗口最大回撤'),
                      _fmtPct(qqqMdd, signed: false),
                      _coral,
                    ),
                    _forensicMiniStat(
                      w('Strategy MDD', '保护策略最大回撤'),
                      _fmtPct(stratMdd, signed: false),
                      _mint,
                    ),
                    _forensicMiniStat(
                      w('Window Excess', '危机窗口超额保护'),
                      _fmtPct(excessPct),
                      excessPct >= 0 ? _mint : _coral,
                    ),
                    _forensicMiniStat(
                      w('Put Cash Harvested', '期权止盈变现现金'),
                      _fmtUsd(harvestedUsd, signed: harvestedUsd > 0),
                      _amber,
                    ),
                    _forensicMiniStat(
                      w('QQQ Shares Added', '低位净增持 QQQ 股数'),
                      '+${sharesAdded.toStringAsFixed(2)} sh',
                      _sky,
                    ),
                    _forensicMiniStat(
                      w('Peak VIX/VIX3M', '峰值恐慌倒挂比'),
                      peakVixRatio.toStringAsFixed(3),
                      peakVixRatio >= 1.10 ? _amber : _slate,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Option Action Ledger Header + Toggle
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                showFullLedger
                    ? w(
                        'Full Historical Pure-Options Action Ledger (${fullLedger.length} Option Tranches)',
                        '2015-2026 全部历史纯期权实战台账（共 ${fullLedger.length} 笔期权操作）',
                      )
                    : w(
                        'Exact Option Operations Inside ${text(forensicWin['pill_en'])} (${filteredTranches.length} Option Tranches)',
                        '${text(forensicWin['pill_zh'])} 期间具体期权操作（${filteredTranches.length} 笔期权交易）',
                      ),
                style: TextStyle(
                  color: p.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              InkWell(
                key: const ValueKey('crisis-ledger-scope-toggle'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => showFullLedger = !showFullLedger),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _obsidian,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: _mint.withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    showFullLedger
                        ? w('Show Selected Crisis Only', '仅看当前选中危机操作')
                        : w(
                            'Show All ${fullLedger.length} Historical Trades',
                            '展开 2015-2026 全部 ${fullLedger.length} 笔台账',
                          ),
                    style: const TextStyle(
                      color: _mint,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (filteredTranches.isEmpty)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _obsidian,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _hairline),
              ),
              child: Text(
                w(
                  'Zero option tranches fired in this window under the selected strategy gate (100% QQQ held unhedged with zero call-cap drag).',
                  '当前所选策略门控在该窗口内未触发建仓（100% 现货持有 QQQ，零期权保费损耗与零卖 Call 封顶拖累）。',
                ),
                style: const TextStyle(color: _slate, fontSize: 12),
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final tr in filteredTranches) ...[
                  _buildTrancheLedgerCard(tr, compact: compact),
                  const SizedBox(height: 8),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _forensicMiniStat(String label, String val, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: _surfaceRaised,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: _slate, fontSize: 10.5)),
          const SizedBox(height: 2),
          Text(
            val,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrancheLedgerCard(
    Map<String, dynamic> tr, {
    required bool compact,
  }) {
    final isNaked = text(tr['tranche_type']) == 'naked_put';
    final isOpenCutoff = tr['exit_date'] == null;
    final isTp = text(tr['exit_reason']).contains('tp');
    final netPnl = _numVal(tr['net_pnl_usd']);
    final shAdded = _numVal(tr['shares_added']);
    final slotAccent = isNaked ? _amber : _lilac;
    final pnlColor = isOpenCutoff
        ? _sky
        : (netPnl > 0 ? _mint : (netPnl < 0 ? _coral : _slate));

    final kp = _numVal(tr['kp']);
    final kc = tr['kc'] == null ? null : _numVal(tr['kc']);
    final strikesLabel = isNaked || kc == null
        ? 'Put K=\$${kp.toStringAsFixed(2)} (${w('No Call Cap', '无卖Call封顶')})'
        : 'Put K=\$${kp.toStringAsFixed(2)} / Call K=\$${kc.toStringAsFixed(2)} (+${_numVal(tr['call_cap_pct']).toStringAsFixed(1)}%)';

    return Container(
      key: ValueKey('crisis-tranche-row-${tr['tranche_id']}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _obsidian,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: isTp ? _mint.withValues(alpha: 0.45) : _hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Wrap(
                spacing: 7,
                runSpacing: 5,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: slotAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: slotAccent.withValues(alpha: 0.45)),
                    ),
                    child: Text(
                      isNaked
                          ? w('Slot 1 · 50% Naked -10% Put', '首仓 50% 裸 -10% Put')
                          : w('Slot 2 · 50% Zero-Cost Collar', '次仓 50% 零成本 Collar'),
                      style: TextStyle(
                        color: slotAccent,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    isOpenCutoff
                        ? '${text(tr['entry_date'])} -> ${w('OPEN', '持仓中')}'
                        : '${text(tr['entry_date'])} -> ${text(tr['exit_date'])} (${_numVal(tr['actual_days_held']).round()}D)',
                    style: TextStyle(
                      color: p.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: _surfaceRaised,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      w(text(tr['trigger_en']), text(tr['trigger_zh'])),
                      style: const TextStyle(
                        color: _sky,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
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
                  if (!isOpenCutoff)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: isTp
                            ? _mint.withValues(alpha: 0.16)
                            : _surfaceRaised,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isTp
                            ? w('VIX/3M >= 1.10 TP', '1.10 恐慌倒挂止盈')
                            : w('90-DTE Expiry', '90日到期结算'),
                        style: TextStyle(
                          color: isTp ? _mint : _slate,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  Text(
                    isOpenCutoff
                        ? w('Active Open Shield', '保护伞运行中')
                        : '${_fmtUsd(netPnl, signed: true)} (${shAdded >= 0 ? '+' : ''}${shAdded.toStringAsFixed(2)} sh)',
                    style: TextStyle(
                      color: pnlColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              Text(
                isOpenCutoff
                    ? 'QQQ @\$${_numVal(tr['entry_spot']).toStringAsFixed(2)} · VXN ${_numVal(tr['entry_vxn']).toStringAsFixed(1)}'
                    : 'QQQ \$${_numVal(tr['entry_spot']).toStringAsFixed(2)} -> \$${_numVal(tr['exit_spot']).toStringAsFixed(2)} (${_fmtPct(_numVal(tr['underlying_ret_pct']))}) · VXN ${_numVal(tr['entry_vxn']).toStringAsFixed(1)} -> ${_numVal(tr['exit_vxn']).toStringAsFixed(1)}',
                style: const TextStyle(color: _slate, fontSize: 11.5),
              ),
              Text(
                strikesLabel,
                style: TextStyle(
                  color: p.text,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (!isOpenCutoff) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                Text(
                  w('4-Factor Convexity:', '四因子凸性归因:'),
                  style: const TextStyle(
                    color: _slate,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Delta ${_fmtUsd(_numVal(tr['delta_usd']), signed: true)}',
                  style: const TextStyle(color: _sky, fontSize: 11),
                ),
                Text(
                  'Gamma ${_fmtUsd(_numVal(tr['gamma_usd']), signed: true)}',
                  style: const TextStyle(color: _mint, fontSize: 11),
                ),
                Text(
                  'Vega ${_fmtUsd(_numVal(tr['vega_usd']), signed: true)}',
                  style: const TextStyle(color: _amber, fontSize: 11),
                ),
                Text(
                  'Theta+Slip ${_fmtUsd(_numVal(tr['theta_slip_usd']), signed: true)}',
                  style: const TextStyle(color: _coral, fontSize: 11),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMethodologyAccordion({required bool compact}) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 18,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: const ValueKey('crisis-methodology-toggle'),
            onTap: () => setState(() => showMethodology = !showMethodology),
            child: Row(
              children: [
                const Icon(Icons.verified_outlined, size: 16, color: _mint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    w(
                      'Zero-Lookahead Execution & OPRA Skew Pricing Audit Contract',
                      '零前视执行规范与 OPRA 真实期权偏度定价审计契约',
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  showMethodology ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: _slate,
                ),
              ],
            ),
          ),
          if (showMethodology) ...[
            const SizedBox(height: 10),
            Text(
              w(
                '1. T+1 Open Execution: Every signal (6 Crisis Lights, US Liquid Common-Stock AD Line < 50DMA, VXN <= 22, and VIX/VIX3M >= 1.10 TP) is evaluated strictly at Day-t Close and executed at Day-(t+1) Open with +/-2.5% per-leg bid-ask slippage.\n'
                '2. Empirical OPRA Skew: 90-DTE option strikes are priced via continuous-dividend Black-Scholes-Merton calibrated to QQQ OPRA cubic implied-volatility skew across moneyness.\n'
                '3. Asymmetric 2-Slot Campaign: First tranche buys a 50% -10% OTM Naked Put (funded from QQQ shares, zero short Call cap). Second tranche (>=30 calendar days later if gates remain ON) opens a 50% Zero-Cost Collar. Below ATH -5%, new or rolled Collars are hard-frozen to preserve 100% rebound upside.',
                '1. 严格 T+1 开盘成交：全部六大危机灯、全美高流动性普通股腾落线 AD < 50DMA、VXN <= 22 及 VIX/VIX3M >= 1.10 止盈信号均在 t 日收盘判定，严格于 t+1 日开盘价计入单腿 +/-2.5% 买卖价差滑点成交。\n'
                '2. OPRA 真实隐含波动率偏度：90-DTE 期权采用连续分红 BSM 模型叠加 QQQ 实证三次多项式波动率偏度曲面定价。\n'
                '3. 非对称双槽战役铁律：首仓买入 50% 仓位 -10% 虚值裸 Put（不卖 Call，100% 保留慢牛冲顶斜率）；满 30 自然日且门控仍亮灯才补齐次仓 50% 零成本 Collar；一旦 QQQ 距历史最高点回撤超过 5%，硬性冻结一切新开或展期 Collar，绝不在坑底封死反弹空间。',
              ),
              style: const TextStyle(color: _slate, fontSize: 11.5, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}

class _CrisisObservatoryChartPainter extends CustomPainter {
  _CrisisObservatoryChartPainter({
    required this.rows,
    required this.events,
    required this.navKey,
    required this.rebasedMode,
    required this.useLogScale,
    required this.hoverIndex,
  });

  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> events;
  final String navKey;
  final bool rebasedMode;
  final bool useLogScale;
  final int hoverIndex;

  static const Color _hairline = Color(0xFF25313B);
  static const Color _mint = Color(0xFF80C6A8);
  static const Color _sky = Color(0xFF7DB8F0);
  static const Color _amber = Color(0xFFF2BC60);
  static const Color _lilac = Color(0xFFB8A1EA);
  static const Color _coral = Color(0xFFEC8C98);
  static const Color _slate = Color(0xFF9CABB9);

  double _val(dynamic v, [double fb = 0]) {
    if (v is num && v.isFinite) return v.toDouble();
    return fb;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.length < 2) return;

    const padL = 54.0;
    const padR = 14.0;
    const padT = 14.0;
    const padB = 24.0;
    final plotW = math.max(1.0, size.width - padL - padR);
    final totalH = math.max(1.0, size.height - padT - padB);

    final mainH = totalH * 0.62;
    const gap1 = 10.0;
    final lightsH = totalH * 0.16;
    const gap2 = 10.0;
    final vixH = math.max(24.0, totalH - mainH - lightsH - gap1 - gap2);

    final mainTop = padT;
    final mainBot = mainTop + mainH;
    final lightsTop = mainBot + gap1;
    final lightsBot = lightsTop + lightsH;
    final vixTop = lightsBot + gap2;
    final vixBot = vixTop + vixH;

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

    var yMin = math.min(
      stratVals.reduce(math.min),
      bhVals.reduce(math.min),
    );
    var yMax = math.max(
      stratVals.reduce(math.max),
      bhVals.reduce(math.max),
    );
    if ((yMax - yMin).abs() < 1e-6) {
      yMax += 1.0;
      yMin -= 1.0;
    }
    final padY = (yMax - yMin) * 0.07;
    yMin -= padY;
    yMax += padY;

    double yMain(double v) =>
        mainBot - ((v - yMin) / (yMax - yMin)).clamp(0.0, 1.0) * mainH;

    // 1. Background regime shading (Crisis Lights >= 4 in soft coral)
    final crisisShadePaint = Paint()..color = _coral.withValues(alpha: 0.08);
    final stepW = math.max(1.0, plotW / (n - 1));
    for (var i = 0; i < n; i++) {
      final x = xAt(i);
      if (_val(rows[i]['crisis_lights']) >= 4) {
        canvas.drawRect(
          Rect.fromLTWH(x - stepW * 0.5, mainTop, stepW, mainH),
          crisisShadePaint,
        );
      }
    }

    // 2. Horizontal gridlines & Y-axis labels on Main Track
    final gridPaint = Paint()
      ..color = _hairline
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
            ? '\$${(usd / 1000000).toStringAsFixed(2)}M'
            : '\$${(usd / 1000).toStringAsFixed(0)}K';
      }
      _drawLabel(canvas, lbl, Offset(4, gy - 6), _slate, 9.5);
    }

    // 3. Pure QQQ Hold curve (Sky Blue) & Selected Strategy curve (Mint)
    final bhPath = Path();
    final stratPath = Path();
    for (var i = 0; i < n; i++) {
      final x = xAt(i);
      final yb = yMain(bhVals[i]);
      final ys = yMain(stratVals[i]);
      if (i == 0) {
        bhPath.moveTo(x, yb);
        stratPath.moveTo(x, ys);
      } else {
        bhPath.lineTo(x, yb);
        stratPath.lineTo(x, ys);
      }
    }
    canvas.drawPath(
      bhPath,
      Paint()
        ..color = _sky.withValues(alpha: 0.78)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    canvas.drawPath(
      stratPath,
      Paint()
        ..color = _mint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.3,
    );

    // 4. Trade Event Markers on Strategy Curve (Slot 1 Naked Put ▲, Collar ●, 1.10 Panic TP ◆)
    final idxByDate = <String, int>{
      for (var i = 0; i < n; i++) text(rows[i]['date']): i,
    };
    final markerOutline = Paint()
      ..color = const Color(0xFF080B0F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final ev in events) {
      final idx = idxByDate[text(ev['date'])];
      if (idx == null) continue;
      final x = xAt(idx);
      final y = yMain(stratVals[idx]);
      final et = text(ev['event_type']);
      if (et == 'slot1_naked_put' || et == 'open_naked_put') {
        final tri = Path()
          ..moveTo(x, y - 6.5)
          ..lineTo(x - 5.5, y + 4.5)
          ..lineTo(x + 5.5, y + 4.5)
          ..close();
        canvas.drawPath(tri, Paint()..color = _amber);
        canvas.drawPath(tri, markerOutline);
      } else if (et.endsWith('_collar') || et == 'open_collar') {
        canvas.drawCircle(Offset(x, y), 4.6, Paint()..color = _lilac);
        canvas.drawCircle(Offset(x, y), 4.6, markerOutline);
      } else if (et == 'vix110_tp' || et == 'tp_exit') {
        final dia = Path()
          ..moveTo(x, y - 6.8)
          ..lineTo(x + 6.0, y)
          ..lineTo(x, y + 6.8)
          ..lineTo(x - 6.0, y)
          ..close();
        canvas.drawPath(dia, Paint()..color = _mint);
        canvas.drawPath(dia, markerOutline);
      }
    }

    // 5. Middle Sub-Track: 0..6 Crisis Lights + AD < 50DMA Breadth
    canvas.drawLine(
      Offset(padL, lightsTop),
      Offset(padL + plotW, lightsTop),
      gridPaint,
    );
    canvas.drawLine(
      Offset(padL, lightsBot),
      Offset(padL + plotW, lightsBot),
      gridPaint,
    );
    _drawLabel(canvas, '6L', Offset(6, lightsTop - 2), _coral, 9.0);
    _drawLabel(canvas, '0L', Offset(6, lightsBot - 11), _slate, 9.0);

    final lightsPath = Path();
    for (var i = 0; i < n; i++) {
      final x = xAt(i);
      final sc = _val(rows[i]['crisis_lights']).clamp(0.0, 6.0);
      final y = lightsBot - (sc / 6.0) * lightsH;
      if (i == 0) {
        lightsPath.moveTo(x, y);
      } else {
        lightsPath.lineTo(x, y);
      }
      if (_val(rows[i]['ad_vs_50ma']) < 0 && (n <= 260 || i % 4 == 0)) {
        canvas.drawCircle(
          Offset(x, lightsBot - 2),
          1.2,
          Paint()..color = _sky.withValues(alpha: 0.65),
        );
      }
    }
    canvas.drawPath(
      lightsPath,
      Paint()
        ..color = _coral
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );

    // 6. Bottom Sub-Track: VIX / VIX3M Ratio with 1.10 Take-Profit Threshold
    canvas.drawLine(Offset(padL, vixTop), Offset(padL + plotW, vixTop), gridPaint);
    canvas.drawLine(Offset(padL, vixBot), Offset(padL + plotW, vixBot), gridPaint);
    const vMin = 0.75;
    const vMax = 1.35;
    double yVix(double vr) =>
        vixBot - ((vr - vMin) / (vMax - vMin)).clamp(0.0, 1.0) * vixH;

    final y110 = yVix(1.10);
    canvas.drawLine(
      Offset(padL, y110),
      Offset(padL + plotW, y110),
      Paint()
        ..color = _amber.withValues(alpha: 0.65)
        ..strokeWidth = 1.0,
    );
    _drawLabel(canvas, '1.10 TP', Offset(4, y110 - 6), _amber, 8.8);

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
        ..color = _amber
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );

    // 7. X-axis date ticks
    final tickIndices = [
      0,
      ((n - 1) * 0.25).round(),
      ((n - 1) * 0.50).round(),
      ((n - 1) * 0.75).round(),
      n - 1,
    ];
    final showFullDate = n <= 420;
    for (final ti in tickIndices) {
      final dt = text(rows[ti]['date']);
      final shortDt = dt.length >= 10
          ? dt.substring(0, showFullDate ? 10 : 7)
          : dt;
      final dx = (xAt(ti) - (showFullDate ? 28 : 20)).clamp(
        padL,
        padL + plotW - (showFullDate ? 62 : 46),
      );
      _drawLabel(canvas, shortDt, Offset(dx, vixBot + 5), _slate, 9.5);
    }

    // 8. Hover vertical crosshair across all 3 synchronized tracks
    if (hoverIndex >= 0 && hoverIndex < n) {
      final hx = xAt(hoverIndex);
      canvas.drawLine(
        Offset(hx, mainTop),
        Offset(hx, vixBot),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.42)
          ..strokeWidth = 1.0,
      );
      final ringPaint = Paint()
        ..color = const Color(0xFF080B0F)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      // Main NAV track dots
      final ys = yMain(stratVals[hoverIndex]);
      final yb = yMain(bhVals[hoverIndex]);
      canvas.drawCircle(Offset(hx, ys), 4.6, Paint()..color = _mint);
      canvas.drawCircle(Offset(hx, ys), 4.6, ringPaint);
      canvas.drawCircle(Offset(hx, yb), 4.0, Paint()..color = _sky);
      canvas.drawCircle(Offset(hx, yb), 4.0, ringPaint);

      // Crisis Lights track dot
      final scHov = _val(rows[hoverIndex]['crisis_lights']).clamp(0.0, 6.0);
      final yl = lightsBot - (scHov / 6.0) * lightsH;
      canvas.drawCircle(Offset(hx, yl), 3.6, Paint()..color = _coral);
      canvas.drawCircle(Offset(hx, yl), 3.6, ringPaint);

      // VIX / VIX3M track dot
      final vrHov = _val(rows[hoverIndex]['vix_ratio'], 0.90);
      final yv = yVix(vrHov);
      canvas.drawCircle(Offset(hx, yv), 3.6, Paint()..color = _amber);
      canvas.drawCircle(Offset(hx, yv), 3.6, ringPaint);
    }
  }

  void _drawLabel(
    Canvas canvas,
    String str,
    Offset pos,
    Color color,
    double fontSize,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: str,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(covariant _CrisisObservatoryChartPainter oldDelegate) {
    return oldDelegate.rows != rows ||
        oldDelegate.events != events ||
        oldDelegate.navKey != navKey ||
        oldDelegate.rebasedMode != rebasedMode ||
        oldDelegate.useLogScale != useLogScale ||
        oldDelegate.hoverIndex != hoverIndex;
  }
}
