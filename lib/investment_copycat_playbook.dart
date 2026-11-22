part of 'main.dart';

class GuruCopycatPlaybookPanel extends StatefulWidget {
  const GuruCopycatPlaybookPanel({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.onCompany,
    required this.onExploreGuru,
    this.initialSelection = const {},
    this.onSelection,
  });

  final ApiClient api;
  final Palette palette;
  final String asOf;
  final ValueChanged<String> onCompany;
  final ValueChanged<String> onExploreGuru;
  final Map<String, dynamic> initialSelection;
  final ValueChanged<Map<String, dynamic>>? onSelection;

  @override
  State<GuruCopycatPlaybookPanel> createState() =>
      _GuruCopycatPlaybookPanelState();
}

class _GuruCopycatPlaybookPanelState extends State<GuruCopycatPlaybookPanel> {
  static const Color _mint = Color(0xFF14B8A6);
  static const Color _sky = Color(0xFF38BDF8);
  static const Color _violet = Color(0xFFA78BFA);
  static const Color _amber = Color(0xFFF59E0B);
  static const Color _coral = Color(0xFFF43F5E);

  Map<String, dynamic>? data;
  Map<String, dynamic>? activeSnapshotOverride;
  _CopycatCurveSeries? _cachedCurveSeries;
  bool loading = true;
  bool snapshotLoading = false;
  String? error;

  String schemeId = 'qqq80_exqqq_monopoly';
  String weightMode = 'conviction';
  String blotterTab = 'scheme';
  String blotterFilter = 'all';
  String guruBucket = 'all';
  String guruSort = 'grade';
  String? inspectedGuruId = 'TCIFUN';
  String? selectedQuarterDate;
  bool showDrawdown = false;
  bool logScale = true;
  int hoverIndex = -1;
  int loadSerial = 0;
  int snapSerial = 0;

  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);

  String loc(dynamic v) {
    if (v is Map) {
      return polishStrategyProseZh(
        w(text(v['en']), text(v['zh'])),
        context.language,
      );
    }
    return polishStrategyProseZh(text(v), context.language);
  }

  @override
  void initState() {
    super.initState();
    final initScheme = text(widget.initialSelection['scheme']);
    if (const {
      'qqq80_exqqq_monopoly',
      'barbell_70_30',
      'monopoly_compounders',
      'pre2014_legends',
      'new_adds_catalyst',
    }.contains(initScheme)) {
      schemeId = initScheme;
    }
    if (widget.initialSelection['weightMode'] == 'equal') {
      weightMode = 'equal';
    }
    final initBlotter = text(widget.initialSelection['blotter']);
    if (const {'scheme', 'blueprint16', 'exits', 'q1dump'}.contains(initBlotter)) {
      blotterTab = initBlotter;
    }
    final initQuarter = text(widget.initialSelection['quarter']);
    if (initQuarter.isNotEmpty) {
      selectedQuarterDate = initQuarter;
    }
    unawaited(_loadDashboard());
  }

  @override
  void didUpdateWidget(covariant GuruCopycatPlaybookPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOf != widget.asOf || oldWidget.api != widget.api) {
      unawaited(_loadDashboard());
    }
  }

  void _emitSelection() {
    widget.onSelection?.call({
      'scheme': schemeId,
      'weightMode': weightMode,
      'blotter': blotterTab,
      if (selectedQuarterDate != null && selectedQuarterDate!.isNotEmpty)
        'quarter': selectedQuarterDate,
    });
  }

  Future<void> _loadDashboard({String? quarterOverride}) async {
    final serial = ++loadSerial;
    final cutoff = widget.asOf;
    final qParam = quarterOverride ?? selectedQuarterDate;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final qp = <String, String>{
        'asOf': cutoff,
        'scheme': schemeId,
        'weightMode': weightMode,
        if (qParam != null && qParam.isNotEmpty) 'quarter': qParam,
      };
      final uri = Uri(
        path: '/api/investment/guru-copycat-playbook',
        queryParameters: qp,
      );
      final res = await widget.api.getJson(uri.toString());
      if (!mounted || serial != loadSerial) return;
      final activeSnap = asMap(res['activeSnapshot']);
      final roster = asList(res['guruRoster']);
      setState(() {
        data = res;
        _cachedCurveSeries = _parseCurveSeries(res);
        activeSnapshotOverride = null;
        selectedQuarterDate = text(
          activeSnap['quarterDate'],
          text(res['selectedQuarterDate']),
        );
        if (inspectedGuruId == null && roster.isNotEmpty) {
          inspectedGuruId = text(roster.first['investorId']);
        }
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

  Future<void> _selectQuarterSnapshot(String quarterDate) async {
    if (quarterDate.isEmpty || quarterDate == selectedQuarterDate) return;
    final serial = ++snapSerial;
    setState(() {
      selectedQuarterDate = quarterDate;
      snapshotLoading = true;
    });
    _emitSelection();
    try {
      final uri = Uri(
        path: '/api/investment/guru-copycat-playbook/snapshot',
        queryParameters: {
          'asOf': widget.asOf,
          'scheme': schemeId,
          'weightMode': weightMode,
          'quarter': quarterDate,
        },
      );
      final res = await widget.api.getJson(uri.toString());
      if (!mounted || serial != snapSerial) return;
      setState(() {
        activeSnapshotOverride = asMap(res['snapshot']);
        snapshotLoading = false;
      });
    } catch (_) {
      if (!mounted || serial != snapSerial) return;
      setState(() => snapshotLoading = false);
      unawaited(_loadDashboard(quarterOverride: quarterDate));
    }
  }

  void _selectScheme(String nextScheme) {
    if (nextScheme == schemeId) return;
    setState(() {
      schemeId = nextScheme;
      activeSnapshotOverride = null;
      hoverIndex = -1;
    });
    _emitSelection();
    unawaited(_loadDashboard(quarterOverride: selectedQuarterDate));
  }

  void _toggleWeightMode(String nextMode) {
    if (nextMode == weightMode) return;
    setState(() {
      weightMode = nextMode;
      hoverIndex = -1;
    });
    _emitSelection();
    unawaited(_loadDashboard(quarterOverride: selectedQuarterDate));
  }

  Map<String, dynamic> get _activeScheme {
    final schemes = asList(data?['schemes']);
    return schemes.firstWhere(
      (s) => text(s['id']) == schemeId,
      orElse: () => schemes.isNotEmpty ? schemes.first : const {},
    );
  }

  Map<String, dynamic> get _activeSnapshot {
    if (activeSnapshotOverride != null && activeSnapshotOverride!.isNotEmpty) {
      return activeSnapshotOverride!;
    }
    return asMap(data?['activeSnapshot']);
  }

  static List<double> _computeDrawdownPct(List<double> navs) {
    if (navs.isEmpty) return const [];
    final out = List<double>.filled(navs.length, 0.0);
    var peak = navs.first > 0 ? navs.first : 100.0;
    for (var i = 0; i < navs.length; i++) {
      final v = navs[i];
      if (v > peak) peak = v;
      out[i] = peak > 0 ? ((v / peak) - 1.0) * 100.0 : 0.0;
    }
    return out;
  }

  _CopycatCurveSeries _parseCurveSeries(Map<String, dynamic>? res) {
    final dc = asMap(res?['dailyCurve']);
    final rawDates = dc['dates'];
    final rawScheme = dc['schemeNav'];
    final rawSpy = dc['spyNav'];
    final rawQqq = dc['qqqNav'];
    if (rawDates is List &&
        rawScheme is List &&
        rawSpy is List &&
        rawQqq is List) {
      final n = math.min(
        math.min(rawDates.length, rawScheme.length),
        math.min(rawSpy.length, rawQqq.length),
      );
      if (n >= 2) {
        final dates = List<String>.generate(n, (i) => text(rawDates[i]));
        final sNav = List<double>.generate(
          n,
          (i) => (nullableNumber(rawScheme[i]) ?? 100.0).toDouble(),
        );
        final spyNav = List<double>.generate(
          n,
          (i) => (nullableNumber(rawSpy[i]) ?? 100.0).toDouble(),
        );
        final qqqNav = List<double>.generate(
          n,
          (i) => (nullableNumber(rawQqq[i]) ?? 100.0).toDouble(),
        );
        return _CopycatCurveSeries(
          dates: dates,
          schemeNav: sNav,
          spyNav: spyNav,
          qqqNav: qqqNav,
          schemeDd: _computeDrawdownPct(sNav),
          spyDd: _computeDrawdownPct(spyNav),
          qqqDd: _computeDrawdownPct(qqqNav),
          isDaily: true,
        );
      }
    }

    // Graceful fallback to quarterly curve if dailyCurve is unavailable
    final schemes = asList(res?['schemes']);
    final active = schemes.firstWhere(
      (s) => text(s['id']) == schemeId,
      orElse: () => schemes.isNotEmpty ? schemes.first : const {},
    );
    final qCurve = asList(asMap(active['metrics'])['curve']);
    final spyQ = asList(asMap(asMap(res?['benchmarks'])['SPY'])['curve']);
    final qqqQ = asList(asMap(asMap(res?['benchmarks'])['QQQ'])['curve']);
    final n = qCurve.length;
    if (n < 2) return _CopycatCurveSeries.empty;
    final dates = List<String>.generate(n, (i) => text(qCurve[i]['quarter']));
    final sNav = List<double>.generate(
      n,
      (i) => (nullableNumber(qCurve[i]['nav100k']) ?? 100.0).toDouble(),
    );
    final spyNav = List<double>.generate(
      n,
      (i) => i < spyQ.length
          ? (nullableNumber(spyQ[i]['nav100k']) ?? 100.0).toDouble()
          : 100.0,
    );
    final qqqNav = List<double>.generate(
      n,
      (i) => i < qqqQ.length
          ? (nullableNumber(qqqQ[i]['nav100k']) ?? 100.0).toDouble()
          : 100.0,
    );
    final sDd = List<double>.generate(
      n,
      (i) => (nullableNumber(qCurve[i]['drawdownPct']) ?? 0.0).toDouble(),
    );
    final spyDd = List<double>.generate(
      n,
      (i) => i < spyQ.length
          ? (nullableNumber(spyQ[i]['drawdownPct']) ?? 0.0).toDouble()
          : 0.0,
    );
    final qqqDd = List<double>.generate(
      n,
      (i) => i < qqqQ.length
          ? (nullableNumber(qqqQ[i]['drawdownPct']) ?? 0.0).toDouble()
          : 0.0,
    );
    return _CopycatCurveSeries(
      dates: dates,
      schemeNav: sNav,
      spyNav: spyNav,
      qqqNav: qqqNav,
      schemeDd: sDd,
      spyDd: spyDd,
      qqqDd: qqqDd,
      isDaily: false,
    );
  }

  String _fmtPct(dynamic v, {bool signed = false, int digits = 2}) {
    final n = nullableNumber(v);
    if (n == null) return '—';
    final prefix = signed && n > 0 ? '+' : '';
    return '$prefix${n.toStringAsFixed(digits)}%';
  }

  String _fmtPrice(dynamic v) {
    final n = nullableNumber(v);
    if (n == null || n <= 0) return '—';
    return '\$${n.toStringAsFixed(n >= 100 ? 1 : 2)}';
  }

  String _fmt100k(dynamic v) {
    final n = nullableNumber(v);
    if (n == null) return '—';
    if (n >= 1000) return '\$${(n / 1000).toStringAsFixed(2)}M';
    return '\$${n.toStringAsFixed(1)}k';
  }

  Color _signedColor(num? v) {
    if (v == null) return p.muted;
    if (v > 0) return p.positive;
    if (v < 0) return p.negative;
    return p.text;
  }

  Widget _badgePill(
    String label, {
    Color? fg,
    Color? bg,
    Color? border,
    IconData? icon,
  }) {
    final color = fg ?? p.text;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: bg ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: border ?? color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tickerChip(
    String ticker, {
    String? suffix,
    Color? accent,
    Key? chipKey,
  }) {
    final isEtf = ticker == 'SPY' || ticker == 'QQQ';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: chipKey,
        borderRadius: BorderRadius.circular(6),
        onTap: isEtf ? null : () => widget.onCompany(ticker),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
          decoration: BoxDecoration(
            color: (accent ?? p.text).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: (accent ?? p.border).withValues(alpha: accent != null ? 0.35 : 1),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StockLogo(ticker: ticker, palette: p, size: 16),
              const SizedBox(width: 5),
              Text(
                suffix == null ? ticker : '$ticker $suffix',
                style: TextStyle(
                  color: accent ?? p.text,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panelCard({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
    Color? borderColor,
  }) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor ?? p.border),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return _panelCard(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 20),
        child: Column(
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(height: 12),
            Text(
              w(
                'Loading 12-Year Strict T+45 Guru Copycat Playbook...',
                '正在加载 12 年严格 T+45 大师作业实战引擎...',
              ),
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (error != null && data == null) {
      return _panelCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(
                'Could not load the Guru Copycat Playbook right now.',
                '暂时无法加载大师作业实战面板。',
              ),
              style: TextStyle(
                color: p.text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error!,
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              key: const ValueKey('copycat-retry-btn'),
              onPressed: _loadDashboard,
              child: Text(w('Retry', '重试')),
            ),
          ],
        ),
      );
    }

    final schemes = asList(data?['schemes']);
    if (schemes.isEmpty) {
      return _panelCard(
        child: Text(
          w(
            'No 13F statutory disclosures available before this cutoff date.',
            '当前回放截止日期前暂无可用的 13F 法定披露快照。',
          ),
          style: TextStyle(color: p.muted, fontSize: 13),
        ),
      );
    }

    return Column(
      key: const ValueKey('guru-copycat-playbook-root'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (loading) const LinearProgressIndicator(minHeight: 2),
        _buildModule1HeaderAndSchemes(),
        const SizedBox(height: 14),
        _buildModule2BacktestAndAnalytics(),
        const SizedBox(height: 14),
        _buildModule3ActionableBlotter(),
        const SizedBox(height: 14),
        _buildModule4GuruRosterMatrix(),
        const SizedBox(height: 14),
        _buildModule5QuarterlySnapshotExplorer(),
      ],
    );
  }

  // ===========================================================================
  // MODULE 1: Executive Header + 5-Scheme Architecture Switcher + 8-Cell KPI Strip
  // ===========================================================================
  Widget _buildModule1HeaderAndSchemes() {
    final sched = asMap(data?['rebalanceSchedule']);
    final schemes = asList(data?['schemes']);
    final active = _activeScheme;
    final m = asMap(active['metrics']);
    final spyM = asMap(asMap(data?['benchmarks'])['SPY']);
    final qqqM = asMap(asMap(data?['benchmarks'])['QQQ']);
    final latestQ = text(data?['latestQuarter'], '2026 Q3');
    final latestFiled = text(data?['latestFiledDate'], '2026-11-16');
    final nextReb = text(sched['nextRebalanceDate'], '2027-02-16');
    final latestNavDate = text(
      asMap(data?['dailyCurve'])['endDate'],
      text(data?['latestPriceDate'], widget.asOf),
    );

    return _panelCard(
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
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: const BoxDecoration(
                          color: _mint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          w(
                            'SEC 13F STRICT T+45 EXECUTION PLAYBOOK · 2014 Q1 – $latestQ',
                            'SEC 13F 严格 T+45 滞后实盘回测与当季跟单台 · 2014 Q1 – $latestQ',
                          ),
                          style: const TextStyle(
                            color: _mint,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    w(
                      'Institutional Guru Copycat Playbook',
                      '大师作业实战指挥台',
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _badgePill(
                    w(
                      'NAV Through $latestNavDate (Daily MTM)',
                      '净值持续至 $latestNavDate (日频盯市)',
                    ),
                    fg: p.positive,
                    icon: Icons.trending_up_rounded,
                  ),
                  _badgePill(
                    w(
                      'Active 13F Window: $latestQ (Filed $latestFiled)',
                      '当前披露期: $latestQ (法定日 $latestFiled)',
                    ),
                    fg: _mint,
                    icon: Icons.verified_outlined,
                  ),
                  _badgePill(
                    w(
                      'Next Rebalance: $nextReb (4×/yr)',
                      '下次法定调仓: $nextReb (每年4次)',
                    ),
                    fg: _sky,
                    icon: Icons.event_repeat_outlined,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (_, c) {
              final cols = c.maxWidth >= 1180
                  ? 5
                  : c.maxWidth >= 760
                  ? 3
                  : c.maxWidth >= 480
                  ? 2
                  : 1;
              const gap = 10.0;
              final cardW = (c.maxWidth - (cols - 1) * gap) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final sc in schemes)
                    SizedBox(
                      width: cardW,
                      child: _buildSchemeSelectorCard(sc),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: p.panel,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: p.border),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loc(active['formula']),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        loc(active['whyItWorks']),
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                if (schemeId == 'qqq80_exqqq_monopoly' ||
                    schemeId == 'monopoly_compounders')
                  Builder(
                    builder: (_) {
                      final convM = asMap(active['convictionVariant']);
                      final eqM = asMap(active['equalWeightVariant']);
                      final convLbl = _fmtPct(convM['cagrPct'], digits: 2);
                      final eqCagrLbl = _fmtPct(eqM['cagrPct'], digits: 2);
                      final eqWinLbl = _fmtPct(eqM['winRatePct'], digits: 1);
                      final isQqq80 = schemeId == 'qqq80_exqqq_monopoly';
                      final convText = isQqq80
                          ? w(
                              'Top-5 Conviction ($convLbl · ${_fmtPct(convM['annTurnoverPct'], digits: 0)} TO)',
                              'Top-5 信念加权 ($convLbl · ${_fmtPct(convM['annTurnoverPct'], digits: 0)}换手)',
                            )
                          : w('Conviction Wt ($convLbl)', '信念加权 ($convLbl)');
                      final eqText = isQqq80
                          ? w(
                              'Top-8 Equal ($eqCagrLbl · ${_fmtPct(eqM['annTurnoverPct'], digits: 0)} TO)',
                              'Top-8 等权 ($eqCagrLbl · ${_fmtPct(eqM['annTurnoverPct'], digits: 0)}低换手)',
                            )
                          : w(
                              'Equal Wt ($eqWinLbl Win)',
                              '等权高胜率 ($eqWinLbl)',
                            );
                      return Container(
                        key: const ValueKey('copycat-weight-toggle'),
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: p.card,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: p.border),
                        ),
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            _weightModePill('conviction', convText),
                            _weightModePill('equal', eqText),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (_, c) {
              final cols = c.maxWidth >= 1180
                  ? 8
                  : c.maxWidth >= 680
                  ? 4
                  : 2;
              const gap = 8.0;
              final tileW = (c.maxWidth - (cols - 1) * gap) / cols;
              final isQqqFlagship = schemeId == 'qqq80_exqqq_monopoly';
              final hasQqqAlpha = nullableNumber(m['alphaVsQqqPct']) != null;
              final hasRoll3yQqq = nullableNumber(m['roll3yWinQqqPct']) != null;
              final kpis = [
                (
                  w('Strict T+45 CAGR', '严格 T+45 年化'),
                  _fmtPct(m['cagrPct']),
                  w(
                    'SPY ${_fmtPct(spyM['cagrPct'])} · QQQ ${_fmtPct(qqqM['cagrPct'])}',
                    '标普 ${_fmtPct(spyM['cagrPct'])} · 纳指 ${_fmtPct(qqqM['cagrPct'])}',
                  ),
                  _mint,
                ),
                isQqqFlagship && hasQqqAlpha
                    ? (
                        w('Net Alpha vs QQQ', '较 QQQ 净超额'),
                        _fmtPct(m['alphaVsQqqPct'], signed: true),
                        w(
                          '${_fmtPct(m['alphaPct'], signed: true)} vs SPY · 10bps',
                          '较标普 ${_fmtPct(m['alphaPct'], signed: true)} · 扣10bps',
                        ),
                        _signedColor(nullableNumber(m['alphaVsQqqPct'])),
                      )
                    : (
                        w('Net Alpha vs SPY', '净超额 Alpha'),
                        _fmtPct(m['alphaPct'], signed: true),
                        w('Net of 10 bps cost', '已扣 10 bps 摩擦'),
                        _signedColor(nullableNumber(m['alphaPct'])),
                      ),
                (
                  w('Sharpe · IR', '夏普比 · 信息比'),
                  '${nullableNumber(m['sharpe'])?.toStringAsFixed(2) ?? '—'} · ${nullableNumber(m['ir'])?.toStringAsFixed(2) ?? '—'}',
                  w(
                    'QQQ Sharpe ${nullableNumber(qqqM['sharpe'])?.toStringAsFixed(2) ?? '1.06'}',
                    '纳指夏普 ${nullableNumber(qqqM['sharpe'])?.toStringAsFixed(2) ?? '1.06'}',
                  ),
                  _sky,
                ),
                (
                  w('Max Drawdown', '最大回撤 MDD'),
                  _fmtPct(m['maxDrawdownPct']),
                  w(
                    'SPY ${_fmtPct(spyM['maxDrawdownPct'], digits: 1)} · QQQ ${_fmtPct(qqqM['maxDrawdownPct'], digits: 1)}',
                    '标普 ${_fmtPct(spyM['maxDrawdownPct'], digits: 1)} · 纳指 ${_fmtPct(qqqM['maxDrawdownPct'], digits: 1)}',
                  ),
                  _amber,
                ),
                isQqqFlagship && hasRoll3yQqq
                    ? (
                        w('3Y Beat-QQQ Win Rate', '滚动3年跑赢QQQ'),
                        _fmtPct(m['roll3yWinQqqPct'], digits: 1),
                        w(
                          'Qtr vs SPY ${_fmtPct(m['winRatePct'], digits: 1)}',
                          '单季胜标普 ${_fmtPct(m['winRatePct'], digits: 1)}',
                        ),
                        p.positive,
                      )
                    : (
                        w('Quarterly Win Rate', '季度跑赢胜率'),
                        _fmtPct(m['winRatePct'], digits: 1),
                        w(
                          '${m['winQuarters'] ?? '—'}/${m['quarters'] ?? 50} realized Qs',
                          '${m['winQuarters'] ?? '—'}/${m['quarters'] ?? 50} 季跑赢标普',
                        ),
                        p.positive,
                      ),
                (
                  w('Annual Turnover', '年化换手率'),
                  _fmtPct(m['annTurnoverPct'], digits: 0),
                  w(
                    'Avg ${nullableNumber(m['avgHoldings'])?.toStringAsFixed(0) ?? '6'} positions',
                    '平均持仓 ${nullableNumber(m['avgHoldings'])?.toStringAsFixed(0) ?? '6'} 只',
                  ),
                  (nullableNumber(m['annTurnoverPct']) ?? 0) > 250
                      ? _amber
                      : p.text,
                ),
                (
                  w('Dual-Regime Alpha', '双周期超额检验'),
                  '${_fmtPct(m['alpha1419Pct'], signed: true, digits: 1)} / ${_fmtPct(m['alpha2026Pct'], signed: true, digits: 1)}',
                  w('2014–19 / 2020–26 vs SPY', '14–19上半场 / 20–26下半场'),
                  m['bothHalvesBeat'] == true ? p.positive : _sky,
                ),
                (
                  w('\$100k Terminal NAV', '十万美元终值'),
                  _fmt100k(m['final100k']),
                  isQqqFlagship
                      ? w(
                          'QQQ ${_fmt100k(qqqM['final100k'])} · SPY ${_fmt100k(spyM['final100k'])}',
                          '纳指 ${_fmt100k(qqqM['final100k'])} · 标普 ${_fmt100k(spyM['final100k'])}',
                        )
                      : w(
                          'vs ${_fmt100k(spyM['final100k'])} SPY',
                          '对比标普 ${_fmt100k(spyM['final100k'])}',
                        ),
                  _mint,
                ),
              ];
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final k in kpis)
                    Container(
                      width: tileW,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: p.panel,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: p.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            k.$1,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              k.$2,
                              style: TextStyle(
                                color: k.$4,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            k.$3,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: p.muted, fontSize: 10.5),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _weightModePill(String modeKey, String label) {
    final selected = weightMode == modeKey;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('copycat-weight-$modeKey'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => _toggleWeightMode(modeKey),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? _mint.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? _mint : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? _mint : p.muted,
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSchemeSelectorCard(Map<String, dynamic> sc) {
    final id = text(sc['id']);
    final selected = id == schemeId;
    final m = asMap(sc['metrics']);
    final isHighTo = id == 'new_adds_catalyst';
    final isQqqFlagship = id == 'qqq80_exqqq_monopoly';
    final hasQqqAlpha = nullableNumber(m['alphaVsQqqPct']) != null;
    final badgeColor = sc['recommended'] == true
        ? _mint
        : isHighTo
        ? _amber
        : _sky;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('copycat-scheme-$id'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => _selectScheme(id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: selected ? _mint.withValues(alpha: 0.10) : p.panel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? _mint : p.border,
              width: selected ? 1.5 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _badgePill(
                      loc(sc['badge']),
                      fg: badgeColor,
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.check_circle, size: 15, color: _mint),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                loc(sc['name']),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    _fmtPct(m['cagrPct']),
                    style: TextStyle(
                      color: selected ? _mint : p.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      isQqqFlagship && hasQqqAlpha
                          ? '${_fmtPct(m['alphaVsQqqPct'], signed: true, digits: 2)} vs QQQ'
                          : '${_fmtPct(m['alphaPct'], signed: true, digits: 1)} vs SPY',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.positive,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                isQqqFlagship
                    ? w(
                        '${_fmtPct(m['alphaPct'], signed: true, digits: 1)} vs SPY · Sharpe ${nullableNumber(m['sharpe'])?.toStringAsFixed(2) ?? '—'} · TO ${_fmtPct(m['annTurnoverPct'], digits: 0)}',
                        '较标普 ${_fmtPct(m['alphaPct'], signed: true, digits: 1)} · 夏普 ${nullableNumber(m['sharpe'])?.toStringAsFixed(2) ?? '—'} · 换手 ${_fmtPct(m['annTurnoverPct'], digits: 0)}',
                      )
                    : w(
                        'Win ${_fmtPct(m['winRatePct'], digits: 1)} · Sharpe ${nullableNumber(m['sharpe'])?.toStringAsFixed(2) ?? '—'} · MDD ${_fmtPct(m['maxDrawdownPct'], digits: 1)}',
                        '胜率 ${_fmtPct(m['winRatePct'], digits: 1)} · 夏普 ${nullableNumber(m['sharpe'])?.toStringAsFixed(2) ?? '—'} · 回撤 ${_fmtPct(m['maxDrawdownPct'], digits: 1)}',
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.muted, fontSize: 10.8),
              ),
              const SizedBox(height: 3),
              Text(
                loc(sc['taxBadge']),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isHighTo ? _amber : p.muted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // MODULE 2: Interactive 12-Year Strict T+45 Daily Equity Curve + Position Count + Anti-Patterns
  // ===========================================================================
  Widget _buildModule2BacktestAndAnalytics() {
    final active = _activeScheme;
    final m = asMap(active['metrics']);
    final curveSeries = _cachedCurveSeries ?? _parseCurveSeries(data);
    final annuals = asList(m['annualReturns']);
    final posRows = asList(data?['positionCountSensitivity']);
    final traps = asList(data?['antiPatterns']);

    return LayoutBuilder(
      builder: (_, c) {
        final wide = c.maxWidth >= 1120;
        final chartPane = _panelCard(
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
                          '12-Year Strict T+45 Daily NAV & Drawdown',
                          '12年严格 T+45 披露滞后十万美元日频净值与回撤对比',
                        ),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        curveSeries.isDaily
                            ? w(
                                'Daily mark-to-market NAV (${curveSeries.length} sessions · ${curveSeries.startLabel} – ${curveSeries.endLabel}), strictly rebalanced 4×/yr on T+45 net of 10 bps cost.',
                                '日频盯市净值（${curveSeries.length} 个交易日 · ${curveSeries.startLabel} – ${curveSeries.endLabel}），严格于季末 45 天法定日调仓并扣单边 10 bps 摩擦，零前视偏差。',
                              )
                            : w(
                                'Every trade executes 45+ calendar days after quarter-end (Feb 16 / May 16 / Aug 16 / Nov 16), net of 10 bps turnover cost.',
                                '全部调仓严格在季末 45 天后法定披露窗口成交，已扣除单边 10 bps 交易摩擦，零前视偏差。',
                              ),
                        style: TextStyle(color: p.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _chartToggleBtn(
                        key: const ValueKey('copycat-chart-nav'),
                        active: !showDrawdown,
                        label: w('\$100k NAV', '\$100k 净值'),
                        onTap: () => setState(() => showDrawdown = false),
                      ),
                      _chartToggleBtn(
                        key: const ValueKey('copycat-chart-dd'),
                        active: showDrawdown,
                        label: w('Drawdown %', '水下回撤 %'),
                        onTap: () => setState(() => showDrawdown = true),
                      ),
                      if (!showDrawdown)
                        _chartToggleBtn(
                          key: const ValueKey('copycat-chart-log'),
                          active: logScale,
                          label: w('Log Scale', '对数坐标'),
                          onTap: () => setState(() => logScale = !logScale),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _buildHoverReadoutBar(curveSeries, active),
              const SizedBox(height: 8),
              SizedBox(
                height: 250,
                child: _buildInteractiveCurveCanvas(curveSeries),
              ),
              const SizedBox(height: 12),
              Text(
                w(
                  'Calendar-Year Realized & Live YTD Returns vs SPY (2014–2026 YTD)',
                  '历年严格 T+45 实盘与 2026 年至今 (YTD) 收益分布',
                ),
                style: TextStyle(
                  color: p.muted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final yr in annuals)
                    Container(
                      width: 78,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: p.panel,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: yr['beatSpy'] == true
                              ? p.positive.withValues(alpha: 0.35)
                              : p.border,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            text(yr['year']),
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _fmtPct(yr['retPct'], signed: true, digits: 1),
                            style: TextStyle(
                              color: p.text,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            'α ${_fmtPct(yr['excessSpyPct'], signed: true, digits: 1)}',
                            style: TextStyle(
                              color: _signedColor(
                                nullableNumber(yr['excessSpyPct']),
                              ),
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        );

        final rightPane = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _panelCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          w(
                            'Position Count Sweet-Spot Audit',
                            '抄作业持仓只数敏感度实测',
                          ),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      _badgePill(
                        w('Sweet Spot: 8–12', '黄金甜点: 8–12只'),
                        fg: _mint,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    w(
                      'Zero-hindsight Pre-2014 Famous Pool under strict T+45 lag: >20 stocks dilutes conviction back toward index beta.',
                      '基于零后视镜大师池严格 T+45 实测：超过 20 只会迅速稀释重仓信念沦为平庸指数，8–12 只兼具高超额与可控回撤。',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 11.5, height: 1.35),
                  ),
                  const SizedBox(height: 10),
                  for (final row in posRows) ...[
                    _buildPositionSensitivityRow(row),
                    const SizedBox(height: 6),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _panelCard(
              borderColor: _coral.withValues(alpha: 0.35),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: _coral,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          w(
                            '3 Empirical Copycat Traps (Proven Losers)',
                            '三大血泪反面教材（12年实证必败陷阱）',
                          ),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < traps.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: _coral.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: _coral.withValues(alpha: 0.24),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  loc(traps[i]['title']),
                                  style: TextStyle(
                                    color: p.text,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${_fmtPct(traps[i]['cagrPct'])} (${_fmtPct(traps[i]['alphaPct'], signed: true)})',
                                style: const TextStyle(
                                  color: _coral,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            loc(traps[i]['lesson']),
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 11,
                              height: 1.38,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );

        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              chartPane,
              const SizedBox(height: 12),
              rightPane,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 62, child: chartPane),
            const SizedBox(width: 14),
            Expanded(flex: 38, child: rightPane),
          ],
        );
      },
    );
  }

  Widget _chartToggleBtn({
    required Key key,
    required bool active,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
          decoration: BoxDecoration(
            color: active ? _mint.withValues(alpha: 0.16) : p.panel,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: active ? _mint : p.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? _mint : p.muted,
              fontSize: 11.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHoverReadoutBar(
    _CopycatCurveSeries series,
    Map<String, dynamic> active,
  ) {
    if (series.isEmpty) return const SizedBox.shrink();
    final idx = (hoverIndex >= 0 && hoverIndex < series.length)
        ? hoverIndex
        : series.length - 1;
    final dateLabel = series.dates[idx];
    final sNav = series.schemeNav[idx];
    final spyNav = series.spyNav[idx];
    final qqqNav = series.qqqNav[idx];
    final sDd = series.schemeDd[idx];
    final spyDd = series.spyDd[idx];
    final qqqDd = series.qqqDd[idx];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.border),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            dateLabel,
            style: TextStyle(
              color: p.text,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          _legendMetricDot(
            _mint,
            loc(active['shortName']),
            showDrawdown
                ? _fmtPct(sDd)
                : '${_fmt100k(sNav)} (${_fmtPct(sNav - 100.0, signed: true, digits: 1)})',
          ),
          _legendMetricDot(
            _sky,
            'SPY',
            showDrawdown
                ? _fmtPct(spyDd)
                : '${_fmt100k(spyNav)} (${_fmtPct(spyNav - 100.0, signed: true, digits: 1)})',
          ),
          _legendMetricDot(
            _violet,
            'QQQ',
            showDrawdown
                ? _fmtPct(qqqDd)
                : '${_fmt100k(qqqNav)} (${_fmtPct(qqqNav - 100.0, signed: true, digits: 1)})',
          ),
        ],
      ),
    );
  }

  Widget _legendMetricDot(Color color, String name, String val) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$name: ',
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
                TextSpan(
                  text: val,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildInteractiveCurveCanvas(_CopycatCurveSeries series) {
    if (series.length < 2) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (_, c) {
        void updateHover(Offset localPos) {
          const padLeft = 52.0;
          const padRight = 12.0;
          final plotW = math.max(1.0, c.maxWidth - padLeft - padRight);
          final frac = ((localPos.dx - padLeft) / plotW).clamp(0.0, 1.0);
          final nextIdx = (frac * (series.length - 1)).round();
          if (nextIdx != hoverIndex) {
            setState(() => hoverIndex = nextIdx);
          }
        }

        return MouseRegion(
          onHover: (e) => updateHover(e.localPosition),
          onExit: (_) => setState(() => hoverIndex = -1),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => updateHover(d.localPosition),
            onHorizontalDragUpdate: (d) => updateHover(d.localPosition),
            child: CustomPaint(
              size: Size(c.maxWidth, 250),
              painter: _CopycatEquityCurvePainter(
                series: series,
                showDrawdown: showDrawdown,
                logScale: logScale,
                hoverIndex: hoverIndex,
                textColor: p.muted,
                gridColor: p.border,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPositionSensitivityRow(Map<String, dynamic> row) {
    final sweet = row['sweetSpot'] == true;
    final cagr = nullableNumber(row['cagrPct']) ?? 0.0;
    final barFrac = (cagr / 24.0).clamp(0.08, 1.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: sweet ? _mint.withValues(alpha: 0.09) : p.panel,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: sweet ? _mint.withValues(alpha: 0.45) : p.border,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 54,
                child: Text(
                  text(row['label']),
                  style: TextStyle(
                    color: sweet ? _mint : p.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: barFrac.toDouble(),
                    minHeight: 7,
                    backgroundColor: p.border.withValues(alpha: 0.45),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      sweet ? _mint : _sky.withValues(alpha: 0.75),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _fmtPct(cagr),
                style: TextStyle(
                  color: sweet ? _mint : p.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: 8,
              runSpacing: 2,
              alignment: WrapAlignment.spaceBetween,
              children: [
                Text(
                  'α ${_fmtPct(row['alphaPct'], signed: true)} · Sharpe ${nullableNumber(row['sharpe'])?.toStringAsFixed(2) ?? '—'}',
                  style: TextStyle(color: p.muted, fontSize: 10.5),
                ),
                Text(
                  'MDD ${_fmtPct(row['maxDrawdownPct'], digits: 1)} · ${_fmt100k(row['final100k'])}',
                  style: TextStyle(color: p.muted, fontSize: 10.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // MODULE 3: Current Quarter Actionable Blotter + 16-Stock Blueprint + Exits + Q1 HF Dump Radar
  // ===========================================================================
  Widget _buildModule3ActionableBlotter() {
    final latestSnap = asMap(data?['latestBlotterSnapshot']);
    final schemeHoldings = asList(latestSnap['holdings']);
    final blueprint = asList(data?['masterBlueprint16']);
    final exits = asList(data?['guruExitsAndSlashes']);
    final q1Dumps = asList(data?['q1HfDumpRadar']);
    final latestQ = text(data?['latestQuarter'], '2026 Q3');

    final tabs = [
      (
        'scheme',
        w(
          'Active Scheme Blotter (${schemeHoldings.length})',
          '当前方案实操单 (${schemeHoldings.length})',
        ),
        _mint,
      ),
      (
        'blueprint16',
        w(
          '16-Stock Master Blueprint (${blueprint.length})',
          '16股全天候总表 (${blueprint.length})',
        ),
        _sky,
      ),
      (
        'exits',
        w(
          'Q3 Exits & >50% Slashes (${exits.length})',
          '当季清仓与大砍单 (${exits.length})',
        ),
        _amber,
      ),
      (
        'q1dump',
        w(
          'Q1 HF Dump Minefield (${q1Dumps.length})',
          'Q1 聪明钱狂抛排雷榜 (${q1Dumps.length})',
        ),
        _coral,
      ),
    ];

    return _panelCard(
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
                    w(
                      '$latestQ Actionable Buy / Hold / Sell Execution Blotter & Q1 Minefield Radar',
                      '$latestQ 当季买入 / 锁仓 / 清仓实操清单与 Q1 聪明钱排雷雷达',
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    w(
                      'Click any stock ticker to open full ThesisForge Company Valuation & Fundamentals Research.',
                      '点击任意股票代码即可一键直达 ThesisForge 深度估值、财报与机构持仓研究台。',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                ],
              ),
              if (blotterTab == 'scheme')
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _filterChipBtn(
                      'all',
                      w('All Positions', '全部仓位'),
                    ),
                    _filterChipBtn(
                      'adds',
                      w('New & Big Adds', '新进与加仓'),
                    ),
                    _filterChipBtn(
                      'discount',
                      w('Cheaper Than Guru', '低于大师成本'),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in tabs)
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: ValueKey('copycat-blotter-tab-${t.$1}'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      setState(() => blotterTab = t.$1);
                      _emitSelection();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: blotterTab == t.$1
                            ? t.$3.withValues(alpha: 0.15)
                            : p.panel,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: blotterTab == t.$1 ? t.$3 : p.border,
                        ),
                      ),
                      child: Text(
                        t.$2,
                        style: TextStyle(
                          color: blotterTab == t.$1 ? t.$3 : p.muted,
                          fontSize: 12,
                          fontWeight: blotterTab == t.$1
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (blotterTab == 'scheme') _buildSchemeBlotterTable(schemeHoldings),
          if (blotterTab == 'blueprint16') _buildMasterBlueprintView(blueprint),
          if (blotterTab == 'exits') _buildGuruExitsView(exits),
          if (blotterTab == 'q1dump') _buildQ1DumpRadarView(q1Dumps),
        ],
      ),
    );
  }

  Widget _filterChipBtn(String key, String label) {
    final active = blotterFilter == key;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('copycat-blotter-filter-$key'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => setState(() => blotterFilter = key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: active ? _mint.withValues(alpha: 0.16) : p.panel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: active ? _mint : p.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? _mint : p.muted,
              fontSize: 11,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSchemeBlotterTable(List<Map<String, dynamic>> rows) {
    final filtered = rows.where((r) {
      if (blotterFilter == 'adds') {
        final act = text(r['leadAction']).toUpperCase();
        return act.startsWith('NEW') ||
            act.startsWith('ADD') ||
            r['status'] == 'NEW';
      }
      if (blotterFilter == 'discount') {
        final disc = nullableNumber(r['vsGuruCostPct']);
        return disc != null && disc < 0;
      }
      return true;
    }).toList();

    if (filtered.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text(
          w(
            'No positions match this filter in the current quarter.',
            '当前筛选条件下暂无匹配持仓。',
          ),
          style: TextStyle(color: p.muted, fontSize: 12.5),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < filtered.length; i++) ...[
          if (i > 0) Divider(height: 1, color: p.border),
          _buildHoldingExecutionRow(filtered[i]),
        ],
      ],
    );
  }

  Widget _buildHoldingExecutionRow(
    Map<String, dynamic> row, {
    String? tierText,
    Map<String, dynamic>? thesisMap,
  }) {
    final tk = text(row['ticker']);
    final wt = nullableNumber(row['targetWeightPct']) ??
        nullableNumber(row['weightPct']) ??
        0.0;
    final act = text(row['leadAction'], text(row['status']));
    final backing = (row['backingGurus'] as List?)
            ?.map((x) => text(x))
            .where((s) => s.isNotEmpty)
            .toList() ??
        const <String>[];
    final vsCost = nullableNumber(row['vsGuruCostPct']);
    final dd52 = nullableNumber(row['dd52wPct']);
    final isQ1Warn = row['q1DumpWarning'] == true;
    final verdict = asMap(row['verdict']);

    final actUpper = act.toUpperCase();
    final actColor = actUpper.startsWith('NEW') || actUpper.startsWith('ADD')
        ? p.positive
        : actUpper.startsWith('TRIM')
        ? _amber
        : actUpper.contains('ETF')
        ? _sky
        : p.muted;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: LayoutBuilder(
        builder: (_, c) {
          final compact = c.maxWidth < 760;
          final leftIdentity = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _tickerChip(
                tk,
                chipKey: ValueKey('copycat-blotter-ticker-$tk'),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            text(row['companyName'], tk),
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
                        _badgePill(act, fg: actColor),
                        if (isQ1Warn) ...[
                          const SizedBox(width: 6),
                          _badgePill(
                            w('Q1 HF Dump Trap!', 'Q1 聪明钱抛售预警!'),
                            fg: _coral,
                            icon: Icons.warning_amber_rounded,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      tierText != null
                          ? '$tierText · ${backing.join(' · ')}'
                          : backing.join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 11),
                    ),
                    if (thesisMap != null && thesisMap.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        loc(thesisMap),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _sky.withValues(alpha: 0.9),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );

          final metricsCluster = Wrap(
            spacing: 14,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _miniColMetric(
                w('Target Wt', '目标权重'),
                '${wt.toStringAsFixed(1)}%',
                _mint,
              ),
              _miniColMetric(
                w('Guru Q3 Cost', '大师Q3均价'),
                _fmtPrice(row['estGuruCost']),
                p.text,
              ),
              _miniColMetric(
                w('Latest Price', '最新现价'),
                _fmtPrice(row['latestPrice']),
                p.text,
              ),
              _miniColMetric(
                w('vs Guru Cost', '较大师成本'),
                _fmtPct(vsCost, signed: true, digits: 1),
                vsCost == null
                    ? p.muted
                    : (vsCost <= 0 ? p.positive : _amber),
              ),
              _miniColMetric(
                w('52W DD', '52周回撤'),
                _fmtPct(dd52, digits: 1),
                p.muted,
              ),
              if (verdict.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: _badgePill(
                    loc(verdict),
                    fg: isQ1Warn
                        ? _coral
                        : (vsCost != null && vsCost <= -5
                              ? p.positive
                              : _mint),
                  ),
                ),
            ],
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                leftIdentity,
                const SizedBox(height: 8),
                metricsCluster,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(flex: 46, child: leftIdentity),
              const SizedBox(width: 12),
              Expanded(
                flex: 54,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: metricsCluster,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _miniColMetric(String label, String val, Color valColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(color: p.muted, fontSize: 10),
        ),
        const SizedBox(height: 2),
        Text(
          val,
          style: TextStyle(
            color: valColor,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _buildMasterBlueprintView(List<Map<String, dynamic>> blueprint) {
    if (blueprint.isEmpty) {
      return Text(
        w(
          'Master Blueprint is available on the latest 2026 Q3 filing window.',
          '16股全天候总表在最新 2026 Q3 披露窗口下可用。',
        ),
        style: TextStyle(color: p.muted, fontSize: 12.5),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _sky.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _sky.withValues(alpha: 0.28)),
          ),
          child: Text(
            w(
              '16-Stock All-Weather Copycat Blueprint: 42% Non-Tech Monopoly Ballast (7 × 6%) + 42% Tech Super-Consensus (6 × 7%) + 16% Fresh Catalyst Satellites (STX 6%, AMAT 5%, FOXA 5%). Zero overlap with Q1 HF-dumped landmines.',
              '16股全天候抄作业组合蓝图：42% 非科技垄断压舱石 (7×6%) + 42% 科技巨头超级共识 (6×7%) + 16% 当季猛加进攻卫星 (STX 6% / AMAT 5% / FOXA 5%)，100% 规避 Q1 对冲基金狂抛雷区。',
            ),
            style: TextStyle(color: p.text, fontSize: 12, height: 1.4),
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < blueprint.length; i++) ...[
          if (i > 0) Divider(height: 1, color: p.border),
          _buildHoldingExecutionRow(
            blueprint[i],
            tierText: loc(blueprint[i]['tierLabel']),
            thesisMap: asMap(blueprint[i]['thesis']),
          ),
        ],
      ],
    );
  }

  Widget _buildGuruExitsView(List<Map<String, dynamic>> exits) {
    if (exits.isEmpty) {
      return Text(
        w(
          'No major exits recorded for this cutoff.',
          '当前截止期暂无核心重仓清仓与大砍记录。',
        ),
        style: TextStyle(color: p.muted, fontSize: 12.5),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _amber.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _amber.withValues(alpha: 0.30)),
          ),
          child: Text(
            w(
              'Strict Sell Discipline: Whenever a tracked guru fully exits (EXIT -100%) or slashes >50% of shares on a ≥1.8% core holding, exit unconditionally on the T+45 rebalance date — never bag-hold an orphaned copycat position.',
              '铁血卖出纪律：只要跟踪大师将原占比 ≥1.8% 的核心持仓 100% 清仓或单季砍仓超 50%，必须在 T+45 法定日无条件同步清仓/跟砍，绝不替已撤退的大师站岗。',
            ),
            style: TextStyle(color: p.text, fontSize: 12, height: 1.4),
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < exits.length; i++) ...[
          if (i > 0) Divider(height: 1, color: p.border),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _tickerChip(
                      text(exits[i]['ticker']),
                      accent: exits[i]['isFullExit'] == true ? _coral : _amber,
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 380),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  '${loc(exits[i]['guruName'])} · ${text(exits[i]['companyName'])}',
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
                              _badgePill(
                                text(exits[i]['action']),
                                fg: exits[i]['isFullExit'] == true
                                    ? _coral
                                    : _amber,
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            loc(exits[i]['sellRule']),
                            style: TextStyle(color: p.muted, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  children: [
                    _miniColMetric(
                      w('Prior -> Cur Wt', '前季→当季权重'),
                      '${_fmtPct(exits[i]['prevWeightPct'], digits: 1)} → ${_fmtPct(exits[i]['curWeightPct'], digits: 1)}',
                      p.text,
                    ),
                    _miniColMetric(
                      w('Share Cut', '股数削减'),
                      _fmtPct(exits[i]['shareCutPct'], digits: 0),
                      _coral,
                    ),
                    _miniColMetric(
                      w('Latest vs Q3', '现价较Q3均价'),
                      '${_fmtPrice(exits[i]['latestPrice'])} (${_fmtPct(exits[i]['vsQ3CostPct'], signed: true, digits: 1)})',
                      _signedColor(nullableNumber(exits[i]['vsQ3CostPct'])),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildQ1DumpRadarView(List<Map<String, dynamic>> dumps) {
    if (dumps.isEmpty) {
      return Text(
        w(
          'Q1 HF Dump Radar is available on the latest 2026 Q3 filing window.',
          'Q1 聪明钱排雷榜在最新 2026 Q3 披露窗口下可用。',
        ),
        style: TextStyle(color: p.muted, fontSize: 12.5),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _coral.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _coral.withValues(alpha: 0.35)),
          ),
          child: Text(
            w(
              'FREE ALPHA SHIELD — Q1 Active-HF Heavy Dumping List (≥\$15B Cap): Across 49 quarters, the bottom quintile of Active-HF net selling returned only 7.30%/yr (-6.84% vs SPY). Even if a single guru initiates a position (e.g., GQG in NBIS), veto it when 2,092 Active HFs are stampeding for the exit!',
              '免费排雷护盾 — 主动对冲基金狂抛 Q1 雷区榜（市值 ≥\$150亿）：12年实证显示主动HF净抛售最猛的 Q1 组年化仅 7.30%（跑输标普 -6.84%/年）！哪怕个别大师逆势买入（如 GQG 新进 NBIS），只要撞上全市场主动HF集体撤退，一律一票否决！',
            ),
            style: TextStyle(color: p.text, fontSize: 12, height: 1.4),
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < dumps.length; i++) ...[
          if (i > 0) Divider(height: 1, color: p.border),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text(
                        '#${dumps[i]['rank']}',
                        style: const TextStyle(
                          color: _coral,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    _tickerChip(
                      text(dumps[i]['ticker']),
                      accent: _coral,
                      chipKey: ValueKey(
                        'copycat-q1dump-${text(dumps[i]['ticker'])}',
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 410),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${text(dumps[i]['companyName'])} · 13F \$${nullableNumber(dumps[i]['tot13fB'])?.toStringAsFixed(1) ?? '—'}B',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: p.text,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            loc(dumps[i]['warningTag']),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: (dumps[i]['guruOverlap'] as List?)
                                          ?.isNotEmpty ==
                                      true
                                  ? _amber
                                  : _coral,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 14,
                  runSpacing: 6,
                  children: [
                    _miniColMetric(
                      w('HF Net Flow', '主动HF净抛占比'),
                      _fmtPct(dumps[i]['hfFlowPct'], signed: true),
                      _coral,
                    ),
                    _miniColMetric(
                      w('HF Net \$', 'HF净卖出额'),
                      '\$${((nullableNumber(dumps[i]['hfNetM']) ?? 0) / 1000).toStringAsFixed(2)}B',
                      _coral,
                    ),
                    _miniColMetric(
                      w('HF Count Δ', '持仓HF家数变化'),
                      '${dumps[i]['nHf']} (${(nullableNumber(dumps[i]['dNHf']) ?? 0) >= 0 ? '+' : ''}${dumps[i]['dNHf']})',
                      p.text,
                    ),
                    _miniColMetric(
                      w('Post-Q3 Move', 'Q3后涨跌验证'),
                      '${_fmtPrice(dumps[i]['latestPrice'])} (${_fmtPct(dumps[i]['postQ3ReturnPct'], signed: true, digits: 1)})',
                      _signedColor(nullableNumber(dumps[i]['postQ3ReturnPct'])),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ===========================================================================
  // MODULE 4: 16 Tracked Gurus Panorama Matrix & Top-12 Holdings Inspector
  // ===========================================================================
  Widget _buildModule4GuruRosterMatrix() {
    final allGurus = asList(data?['guruRoster']);
    final filtered = allGurus.where((g) {
      if (guruBucket == 'all') return true;
      return text(g['bucket']) == guruBucket;
    }).toList();

    int gradeScore(String g) => switch (g) {
      'A+' => 4,
      'A' => 3,
      'B' => 2,
      _ => 1,
    };

    filtered.sort((a, b) {
      if (guruSort == 't45Alpha') {
        return (nullableNumber(b['t45AlphaPct']) ?? -99)
            .compareTo(nullableNumber(a['t45AlphaPct']) ?? -99);
      }
      if (guruSort == 'retention') {
        return (nullableNumber(b['alphaRetentionPct']) ?? 0)
            .compareTo(nullableNumber(a['alphaRetentionPct']) ?? 0);
      }
      if (guruSort == 'cagr') {
        return (nullableNumber(b['t45CagrPct']) ?? -99)
            .compareTo(nullableNumber(a['t45CagrPct']) ?? -99);
      }
      if (guruSort == 'conc') {
        return (nullableNumber(b['top10ConcPct']) ?? 0)
            .compareTo(nullableNumber(a['top10ConcPct']) ?? 0);
      }
      final gd = gradeScore(text(b['copyabilityGrade']))
          .compareTo(gradeScore(text(a['copyabilityGrade'])));
      if (gd != 0) return gd;
      return (nullableNumber(b['t45AlphaPct']) ?? -99)
          .compareTo(nullableNumber(a['t45AlphaPct']) ?? -99);
    });

    final inspected = allGurus.firstWhere(
      (g) => text(g['investorId']) == inspectedGuruId,
      orElse: () => filtered.isNotEmpty ? filtered.first : const {},
    );

    return _panelCard(
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
                    w(
                      '16 Tracked Gurus Panorama Matrix & T+45 Alpha Retention Audit',
                      '16位跟踪大师全景矩阵与 T+45 超额留存率审计',
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    w(
                      'Select any guru row to inspect all Top-12 holdings, QoQ weight changes, and Q3 cost basis vs current price.',
                      '点击任意大师行展开其最新 Top-12 核心重仓、环比加减仓幅度及 Q3 建仓成本对比；支持一键跳转完整大师档案。',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _guruBucketPill('all', w('All (16)', '全部 (16)')),
                  _guruBucketPill(
                    'L1_COMPOUND',
                    w('Monopoly Compounder', '垄断复利'),
                  ),
                  _guruBucketPill(
                    'L2_CATALYST',
                    w('Activist & Macro', '激进与宏观'),
                  ),
                  _guruBucketPill(
                    'L3_DEEPVAL',
                    w('Deep Value', '极集中深价值'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w('Sort by:', '排序维度:'),
                style: TextStyle(color: p.muted, fontSize: 11),
              ),
              _guruSortPill('grade', w('Copyability Grade', '可抄作业评级')),
              _guruSortPill('t45Alpha', w('Strict T+45 Alpha', 'T+45 净超额')),
              _guruSortPill('retention', w('T+45 Retention %', 'T+45 留存率')),
              _guruSortPill('cagr', w('T+45 CAGR', 'T+45 年化')),
              _guruSortPill('conc', w('Top-10 Concentration', '前十集中度')),
            ],
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < filtered.length; i++) ...[
            if (i > 0) Divider(height: 1, color: p.border),
            _buildGuruMatrixRow(filtered[i]),
          ],
          if (inspected.isNotEmpty &&
              asList(inspected['top12Holdings']).isNotEmpty) ...[
            const SizedBox(height: 14),
            _buildInspectedGuruDrawer(inspected),
          ],
        ],
      ),
    );
  }

  Widget _guruBucketPill(String bucket, String label) {
    final active = guruBucket == bucket;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('copycat-guru-bucket-$bucket'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => setState(() => guruBucket = bucket),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: active ? _mint.withValues(alpha: 0.16) : p.panel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: active ? _mint : p.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? _mint : p.muted,
              fontSize: 11,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _guruSortPill(String sortKey, String label) {
    final active = guruSort == sortKey;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('copycat-guru-sort-$sortKey'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => setState(() => guruSort = sortKey),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: active ? _sky.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: active ? _sky : p.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? _sky : p.muted,
              fontSize: 10.8,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGuruMatrixRow(Map<String, dynamic> g) {
    final gid = text(g['investorId']);
    final isSelected = gid == inspectedGuruId;
    final grade = text(g['copyabilityGrade']);
    final gradeColor = switch (grade) {
      'A+' => _mint,
      'A' => p.positive,
      'B' => _sky,
      _ => _amber,
    };
    final topSummary = asList(g['topHoldingsSummary']);
    final dossierId = text(g['thesisForgeGuruId']);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('copycat-guru-$gid'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => inspectedGuruId = gid),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? _mint.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: LayoutBuilder(
            builder: (_, c) {
              final compact = c.maxWidth < 860;
              final identity = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 34,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: gradeColor.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: gradeColor.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Text(
                      grade == 'Caution' ? 'C' : grade,
                      style: TextStyle(
                        color: gradeColor,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                loc(g['name']),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.text,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            if (dossierId.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.open_in_new_rounded,
                                size: 13,
                                color: _sky.withValues(alpha: 0.85),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${loc(g['style'])} · \$${nullableNumber(g['aumB'])?.toStringAsFixed(1) ?? '—'}B · ${g['stockCount']} ${w('stocks', '只')} · Top10 ${_fmtPct(g['top10ConcPct'], digits: 1)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              );

              final stats = Wrap(
                spacing: 12,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _miniColMetric(
                    w('T+45 CAGR', 'T+45年化'),
                    _fmtPct(g['t45CagrPct'], digits: 1),
                    p.text,
                  ),
                  _miniColMetric(
                    w('T+45 Alpha', 'T+45超额'),
                    _fmtPct(g['t45AlphaPct'], signed: true, digits: 2),
                    _signedColor(nullableNumber(g['t45AlphaPct'])),
                  ),
                  _miniColMetric(
                    w('Lag Retention', '超额留存率'),
                    _fmtPct(g['alphaRetentionPct'], digits: 0),
                    (nullableNumber(g['alphaRetentionPct']) ?? 0) >= 75
                        ? _mint
                        : _amber,
                  ),
                  _miniColMetric(
                    w('IR · MDD', 'IR · 回撤'),
                    '${nullableNumber(g['ir'])?.toStringAsFixed(2) ?? '—'} · ${_fmtPct(g['maxDrawdownPct'], digits: 0)}',
                    p.muted,
                  ),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final h in topSummary.take(4))
                        _tickerChip(
                          text(h['ticker']),
                          suffix:
                              '${nullableNumber(h['weightPct'])?.toStringAsFixed(0) ?? ''}%',
                        ),
                    ],
                  ),
                ],
              );

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    identity,
                    const SizedBox(height: 8),
                    stats,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(flex: 36, child: identity),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 64,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: stats,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildInspectedGuruDrawer(Map<String, dynamic> g) {
    final gid = text(g['investorId']);
    final dossierId = text(g['thesisForgeGuruId']);
    final top12 = asList(g['top12Holdings']);

    return Container(
      key: ValueKey('copycat-guru-drawer-$gid'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _mint.withValues(alpha: 0.40)),
      ),
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
                    '${loc(g['name'])} — ${text(g['latestQuarter'])} Top-${top12.length} ${w('Core Holdings & Cost Basis', '核心持仓与建仓成本透视')}',
                    style: TextStyle(
                      color: p.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    w(
                      'QE CAGR ${_fmtPct(g['qeCagrPct'])} -> Strict T+45 CAGR ${_fmtPct(g['t45CagrPct'])} (${_fmtPct(g['alphaRetentionPct'], digits: 0)} alpha retained) · Biggest Q3 Move: ${text(g['biggestMove'])}',
                      '季末无滞后年化 ${_fmtPct(g['qeCagrPct'])} → 严格 T+45 年化 ${_fmtPct(g['t45CagrPct'])}（超额留存率 ${_fmtPct(g['alphaRetentionPct'], digits: 0)}）· 当季最大动作: ${text(g['biggestMove'])}',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                ],
              ),
              if (dossierId.isNotEmpty)
                FilledButton.tonalIcon(
                  key: ValueKey('copycat-open-dossier-$gid'),
                  onPressed: () => widget.onExploreGuru(dossierId),
                  icon: const Icon(Icons.account_balance_outlined, size: 15),
                  label: Text(
                    w('Open Full Guru Dossier', '打开大师深度档案'),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final h in top12)
                Container(
                  width: 245,
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: p.card,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: h['q1DumpWarning'] == true
                          ? _coral.withValues(alpha: 0.55)
                          : p.border,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '#${h['rank']}',
                            style: TextStyle(
                              color: p.muted,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 5),
                          _tickerChip(text(h['ticker'])),
                          const Spacer(),
                          Text(
                            _fmtPct(h['weightPct'], digits: 1),
                            style: TextStyle(
                              color: p.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _badgePill(
                            text(h['action']),
                            fg: text(h['action']).startsWith('NEW') ||
                                    text(h['action']).startsWith('ADD')
                                ? p.positive
                                : text(h['action']).startsWith('TRIM')
                                ? _amber
                                : p.muted,
                          ),
                          Text(
                            'Δwt ${_fmtPct(h['deltaWeightPct'], signed: true, digits: 1)}',
                            style: TextStyle(
                              color: _signedColor(
                                nullableNumber(h['deltaWeightPct']),
                              ),
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        w(
                          'Cost ${_fmtPrice(h['estGuruCost'])} · Now ${_fmtPrice(h['latestPrice'])} (${_fmtPct(h['vsGuruCostPct'], signed: true, digits: 1)})',
                          '成本 ${_fmtPrice(h['estGuruCost'])} · 现价 ${_fmtPrice(h['latestPrice'])} (${_fmtPct(h['vsGuruCostPct'], signed: true, digits: 1)})',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: (nullableNumber(h['vsGuruCostPct']) ?? 0) <= 0
                              ? p.positive
                              : p.muted,
                          fontSize: 10.8,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // MODULE 5: 51-Quarter Historical Rebalance Snapshot Timeline (2014 Q1 – 2026 Q3)
  // ===========================================================================
  Widget _buildModule5QuarterlySnapshotExplorer() {
    final timeline = asList(data?['snapshotTimeline']);
    final snap = _activeSnapshot;
    if (timeline.isEmpty || snap.isEmpty) return const SizedBox.shrink();

    final curQd = text(snap['quarterDate']);
    final curIdx = timeline.indexWhere((s) => text(s['quarterDate']) == curQd);
    final entered = (snap['enteredTickers'] as List?)
            ?.map((x) => text(x))
            .where((s) => s.isNotEmpty)
            .toList() ??
        const <String>[];
    final exited = (snap['exitedTickers'] as List?)
            ?.map((x) => text(x))
            .where((s) => s.isNotEmpty)
            .toList() ??
        const <String>[];
    final holdings = asList(snap['holdings']);
    final isLive = snap['isLive'] == true;
    final beatSpy = snap['beatSpy'];

    return _panelCard(
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
                    w(
                      '${timeline.length}-Quarter Rebalance History Snapshot Explorer (2014 Q1 – ${text(timeline.last['quarter'])})',
                      '${timeline.length}季历史调仓快照回放矩阵 (Snapshot · 2014 Q1 – ${text(timeline.last['quarter'])})',
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    w(
                      'Click any quarter tile below to inspect exact T+45 entry/exit dates, new buys, full exits, and per-stock realized return attribution.',
                      '点击下方任意季度色块（绿=当季跑赢标普 / 红=跑输 / 青=当季实盘运行中），查看当季新进买入、调出卖出与单票实盘收益归因。',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const ValueKey('copycat-snap-prev'),
                    tooltip: w('Previous Quarter', '上一季度'),
                    onPressed: curIdx > 0
                        ? () => _selectQuarterSnapshot(
                              text(timeline[curIdx - 1]['quarterDate']),
                            )
                        : null,
                    icon: const Icon(Icons.chevron_left, size: 20),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: p.panel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: p.border),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        key: const ValueKey('copycat-snap-select'),
                        value: timeline.any(
                          (s) => text(s['quarterDate']) == curQd,
                        )
                            ? curQd
                            : text(timeline.last['quarterDate']),
                        dropdownColor: p.card,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                        items: [
                          for (final s in timeline.reversed)
                            DropdownMenuItem<String>(
                              value: text(s['quarterDate']),
                              child: Text(
                                '${text(s['quarter'])} ${s['isLive'] == true ? w('(Live)', '(实盘)') : _fmtPct(s['portRetPct'], signed: true, digits: 1)}',
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) _selectQuarterSnapshot(v);
                        },
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('copycat-snap-next'),
                    tooltip: w('Next Quarter', '下一季度'),
                    onPressed: curIdx >= 0 && curIdx < timeline.length - 1
                        ? () => _selectQuarterSnapshot(
                              text(timeline[curIdx + 1]['quarterDate']),
                            )
                        : null,
                    icon: const Icon(Icons.chevron_right, size: 20),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final s in timeline) _buildQuarterHeatmapTile(s, curQd),
            ],
          ),
          const SizedBox(height: 12),
          if (snapshotLoading) const LinearProgressIndicator(minHeight: 2),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: p.panel,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${text(snap['quarter'])} Snapshot',
                          style: TextStyle(
                            color: p.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        _badgePill(
                          w(
                            'Window: ${text(snap['entryDate'])} -> ${text(snap['exitDate'])}',
                            '持仓区间: ${text(snap['entryDate'])} → ${text(snap['exitDate'])}',
                          ),
                          fg: _sky,
                        ),
                        if (isLive)
                          _badgePill(
                            w('LIVE ACTIVE PORTFOLIO', '当季实盘运行中'),
                            fg: _mint,
                          )
                        else
                          _badgePill(
                            beatSpy == true
                                ? w(
                                    'BEAT SPY (${_fmtPct(snap['excessSpyPct'], signed: true)})',
                                    '跑赢标普 (${_fmtPct(snap['excessSpyPct'], signed: true)})',
                                  )
                                : w(
                                    'LAGGED SPY (${_fmtPct(snap['excessSpyPct'], signed: true)})',
                                    '落后标普 (${_fmtPct(snap['excessSpyPct'], signed: true)})',
                                  ),
                            fg: beatSpy == true ? p.positive : _coral,
                          ),
                      ],
                    ),
                    if (!isLive)
                      Wrap(
                        spacing: 14,
                        runSpacing: 6,
                        children: [
                          _miniColMetric(
                            w('Portfolio T+45', '组合实盘收益'),
                            _fmtPct(snap['portRetPct'], signed: true),
                            _signedColor(nullableNumber(snap['portRetPct'])),
                          ),
                          _miniColMetric(
                            w('SPY T+45', '标普同期'),
                            _fmtPct(snap['spyRetPct'], signed: true),
                            p.text,
                          ),
                          _miniColMetric(
                            w('QQQ T+45', '纳指同期'),
                            _fmtPct(snap['qqqRetPct'], signed: true),
                            p.text,
                          ),
                          _miniColMetric(
                            w('1-Way Turnover', '单季换手'),
                            _fmtPct(snap['turnoverPct'], digits: 1),
                            p.muted,
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (entered.isNotEmpty)
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            w(
                              'Entered (+${entered.length}):',
                              '当季新进买入 (+${entered.length}):',
                            ),
                            style: TextStyle(
                              color: p.positive,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          for (final tk in entered)
                            _tickerChip(tk, accent: p.positive),
                        ],
                      ),
                    if (exited.isNotEmpty)
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            w(
                              'Exited (-${exited.length}):',
                              '当季调出清仓 (-${exited.length}):',
                            ),
                            style: const TextStyle(
                              color: _coral,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          for (final tk in exited)
                            _tickerChip(tk, accent: _coral),
                        ],
                      ),
                    Text(
                      w(
                        'Core Held: ${snap['heldCount'] ?? 0} stocks',
                        '核心续持: ${snap['heldCount'] ?? 0} 只',
                      ),
                      style: TextStyle(color: p.muted, fontSize: 11.5),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                for (var i = 0; i < holdings.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: p.border),
                  _buildSnapshotHoldingRow(holdings[i], isLive),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuarterHeatmapTile(Map<String, dynamic> s, String curQd) {
    final qd = text(s['quarterDate']);
    final qShort = text(s['quarter']).replaceFirst('20', "'");
    final selected = qd == curQd;
    final isLive = s['isLive'] == true;
    final beat = s['beatSpy'] == true;
    final tileColor = isLive ? _mint : (beat ? p.positive : _coral);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('copycat-snap-tile-$qd'),
        borderRadius: BorderRadius.circular(5),
        onTap: () => _selectQuarterSnapshot(qd),
        child: Container(
          width: 52,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: tileColor.withValues(alpha: selected ? 0.30 : 0.11),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: selected ? tileColor : tileColor.withValues(alpha: 0.30),
              width: selected ? 1.6 : 1.0,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                qShort,
                style: TextStyle(
                  color: selected ? p.text : p.muted,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                isLive
                    ? w('LIVE', '实盘')
                    : _fmtPct(s['excessSpyPct'], signed: true, digits: 0),
                style: TextStyle(
                  color: tileColor,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSnapshotHoldingRow(Map<String, dynamic> h, bool isLive) {
    final tk = text(h['ticker']);
    final status = text(h['status']);
    final backing = (h['backingGurus'] as List?)
            ?.map((x) => text(x))
            .where((s) => s.isNotEmpty)
            .toList() ??
        const <String>[];
    final ret = nullableNumber(h['realizedRetPct']);
    final bps = nullableNumber(h['contribBps']);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _tickerChip(tk),
              const SizedBox(width: 8),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              text(h['companyName'], tk),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: p.text,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          _badgePill(
                            status,
                            fg: status == 'NEW'
                                ? p.positive
                                : status == 'CORE'
                                ? _sky
                                : p.muted,
                          ),
                        ],
                      ),
                      if (backing.isNotEmpty)
                        Text(
                          backing.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 10.8),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _miniColMetric(
                w('Weight', '持仓权重'),
                _fmtPct(h['weightPct'], digits: 1),
                p.text,
              ),
              _miniColMetric(
                w('T+45 Entry', 'T+45买入价'),
                _fmtPrice(h['entryPrice']),
                p.muted,
              ),
              if (isLive)
                _miniColMetric(
                  w('Latest Price', '最新现价'),
                  _fmtPrice(h['latestPrice']),
                  _mint,
                )
              else ...[
                _miniColMetric(
                  w('Next T+45 Exit', '下季T+45价'),
                  _fmtPrice(h['exitPrice']),
                  p.muted,
                ),
                _miniColMetric(
                  w('Quarter Return', '单季涨跌'),
                  _fmtPct(ret, signed: true, digits: 1),
                  _signedColor(ret),
                ),
                _miniColMetric(
                  w('Contribution', '组合贡献'),
                  bps == null
                      ? '—'
                      : '${bps >= 0 ? '+' : ''}${bps.toStringAsFixed(0)} bps',
                  _signedColor(bps),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _CopycatCurveSeries {
  const _CopycatCurveSeries({
    required this.dates,
    required this.schemeNav,
    required this.spyNav,
    required this.qqqNav,
    required this.schemeDd,
    required this.spyDd,
    required this.qqqDd,
    required this.isDaily,
  });

  static const empty = _CopycatCurveSeries(
    dates: [],
    schemeNav: [],
    spyNav: [],
    qqqNav: [],
    schemeDd: [],
    spyDd: [],
    qqqDd: [],
    isDaily: false,
  );

  final List<String> dates;
  final List<double> schemeNav;
  final List<double> spyNav;
  final List<double> qqqNav;
  final List<double> schemeDd;
  final List<double> spyDd;
  final List<double> qqqDd;
  final bool isDaily;

  int get length => dates.length;
  bool get isEmpty => dates.isEmpty;
  String get startLabel => dates.isNotEmpty ? dates.first : '';
  String get endLabel => dates.isNotEmpty ? dates.last : '';
}

class _CopycatEquityCurvePainter extends CustomPainter {
  _CopycatEquityCurvePainter({
    required this.series,
    required this.showDrawdown,
    required this.logScale,
    required this.hoverIndex,
    required this.textColor,
    required this.gridColor,
  });

  final _CopycatCurveSeries series;
  final bool showDrawdown;
  final bool logScale;
  final int hoverIndex;
  final Color textColor;
  final Color gridColor;

  double _mapNav(double nav) {
    final safe = math.max(10.0, nav);
    return logScale ? math.log(safe) : safe;
  }

  double _valAt(List<double> navs, List<double> dds, int idx) {
    if (showDrawdown) return dds[idx];
    return _mapNav(navs[idx]);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = series.length;
    if (n < 2) return;
    const padLeft = 52.0;
    const padRight = 12.0;
    const padTop = 10.0;
    const padBottom = 24.0;
    final plotW = math.max(1.0, size.width - padLeft - padRight);
    final plotH = math.max(1.0, size.height - padTop - padBottom);

    var minY = showDrawdown ? 0.0 : (logScale ? math.log(100.0) : 100.0);
    var maxY = minY;
    for (var i = 0; i < n; i++) {
      final sv = _valAt(series.schemeNav, series.schemeDd, i);
      final bv = _valAt(series.spyNav, series.spyDd, i);
      final qv = _valAt(series.qqqNav, series.qqqDd, i);
      if (sv < minY) minY = sv;
      if (bv < minY) minY = bv;
      if (qv < minY) minY = qv;
      if (sv > maxY) maxY = sv;
      if (bv > maxY) maxY = bv;
      if (qv > maxY) maxY = qv;
    }
    if ((maxY - minY).abs() < 1e-6) maxY = minY + 1.0;
    final padY = (maxY - minY) * 0.06;
    if (!showDrawdown) {
      minY -= padY;
      maxY += padY;
    } else {
      minY -= padY;
      maxY = 0.0;
    }

    double xAt(int i) => padLeft + (i / (n - 1)) * plotW;
    double yAt(double v) =>
        padTop + (1.0 - ((v - minY) / (maxY - minY)).clamp(0.0, 1.0)) * plotH;

    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.55)
      ..strokeWidth = 0.8;

    for (var g = 0; g <= 4; g++) {
      final frac = g / 4.0;
      final y = padTop + frac * plotH;
      canvas.drawLine(Offset(padLeft, y), Offset(padLeft + plotW, y), gridPaint);
      final rawVal = maxY - frac * (maxY - minY);
      final label = showDrawdown
          ? '${rawVal.toStringAsFixed(0)}%'
          : () {
              final nav = logScale ? math.exp(rawVal) : rawVal;
              return nav >= 1000
                  ? '\$${(nav / 1000).toStringAsFixed(1)}M'
                  : '\$${nav.toStringAsFixed(0)}k';
            }();
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: textColor, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: padLeft - 6);
      tp.paint(canvas, Offset(padLeft - tp.width - 6, y - tp.height / 2));
    }

    // X-axis labels: clean calendar years for daily NAV, quarter anchors for fallback
    final tickEntries = <(int, String)>[];
    if (series.isDaily && series.dates.first.length >= 4) {
      final yearStarts = <(int, String)>[];
      String? lastYr;
      for (var i = 0; i < n; i++) {
        final yr = series.dates[i].substring(0, 4);
        if (yr != lastYr) {
          yearStarts.add((i, yr));
          lastYr = yr;
        }
      }
      final step = yearStarts.length > 8 ? 2 : 1;
      for (var k = 0; k < yearStarts.length; k += step) {
        tickEntries.add(yearStarts[k]);
      }
      if (yearStarts.isNotEmpty &&
          (tickEntries.isEmpty || tickEntries.last.$2 != yearStarts.last.$2)) {
        final lastStart = yearStarts.last;
        if (tickEntries.isEmpty ||
            (xAt(lastStart.$1) - xAt(tickEntries.last.$1)) > 42) {
          tickEntries.add(lastStart);
        }
      }
    } else {
      final q1 = (n * 0.25).floor();
      final q2 = (n * 0.50).floor();
      final q3 = (n * 0.75).floor();
      for (final idx in {0, q1, q2, q3, n - 1}) {
        if (idx >= 0 && idx < n) {
          tickEntries.add((idx, series.dates[idx]));
        }
      }
    }

    for (final tick in tickEntries) {
      final x = xAt(tick.$1);
      final tp = TextPainter(
        text: TextSpan(
          text: tick.$2,
          style: TextStyle(color: textColor, fontSize: 9.8),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = (x - tp.width / 2).clamp(padLeft, size.width - tp.width);
      tp.paint(canvas, Offset(dx, padTop + plotH + 6));
    }

    void drawSeries(
      List<double> navs,
      List<double> dds,
      Color color,
      double width, {
      bool fill = false,
    }) {
      final path = Path();
      for (var i = 0; i < n; i++) {
        final px = xAt(i);
        final py = yAt(_valAt(navs, dds, i));
        if (i == 0) {
          path.moveTo(px, py);
        } else {
          path.lineTo(px, py);
        }
      }
      if (fill) {
        final baseY = showDrawdown ? yAt(0.0) : (padTop + plotH);
        final fillPath = Path.from(path)
          ..lineTo(xAt(n - 1), baseY)
          ..lineTo(xAt(0), baseY)
          ..close();
        canvas.drawPath(
          fillPath,
          Paint()
            ..shader = ui.Gradient.linear(
              Offset(0, padTop),
              Offset(0, padTop + plotH),
              showDrawdown
                  ? [color.withValues(alpha: 0.04), color.withValues(alpha: 0.24)]
                  : [color.withValues(alpha: 0.20), color.withValues(alpha: 0.0)],
            ),
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }

    final qqqW = series.isDaily ? 1.25 : 1.5;
    final spyW = series.isDaily ? 1.40 : 1.7;
    final schemeW = series.isDaily ? 1.85 : 2.5;

    drawSeries(series.qqqNav, series.qqqDd, const Color(0xFFA78BFA), qqqW);
    drawSeries(series.spyNav, series.spyDd, const Color(0xFF38BDF8), spyW);
    drawSeries(
      series.schemeNav,
      series.schemeDd,
      const Color(0xFF14B8A6),
      schemeW,
      fill: true,
    );

    if (hoverIndex >= 0 && hoverIndex < n) {
      final hx = xAt(hoverIndex);
      canvas.drawLine(
        Offset(hx, padTop),
        Offset(hx, padTop + plotH),
        Paint()
          ..color = textColor.withValues(alpha: 0.45)
          ..strokeWidth = 1.0,
      );
      final qy = yAt(_valAt(series.qqqNav, series.qqqDd, hoverIndex));
      final by = yAt(_valAt(series.spyNav, series.spyDd, hoverIndex));
      final sy = yAt(_valAt(series.schemeNav, series.schemeDd, hoverIndex));
      canvas.drawCircle(
        Offset(hx, qy),
        3.0,
        Paint()..color = const Color(0xFFA78BFA),
      );
      canvas.drawCircle(
        Offset(hx, by),
        3.2,
        Paint()..color = const Color(0xFF38BDF8),
      );
      canvas.drawCircle(
        Offset(hx, sy),
        4.2,
        Paint()..color = const Color(0xFF14B8A6),
      );
      canvas.drawCircle(
        Offset(hx, sy),
        5.8,
        Paint()
          ..color = const Color(0xFF14B8A6).withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CopycatEquityCurvePainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.showDrawdown != showDrawdown ||
      oldDelegate.logScale != logScale ||
      oldDelegate.hoverIndex != hoverIndex;
}
