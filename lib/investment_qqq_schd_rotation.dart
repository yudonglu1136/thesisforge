part of 'main.dart';

class QqqSchdRotationDashboard extends StatefulWidget {
  const QqqSchdRotationDashboard({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.onCompany,
    this.onSummaryLoaded,
  });

  final ApiClient api;
  final Palette palette;
  final String asOf;
  final ValueChanged<String> onCompany;
  final ValueChanged<Map<String, dynamic>>? onSummaryLoaded;

  @override
  State<QqqSchdRotationDashboard> createState() =>
      _QqqSchdRotationDashboardState();
}

class _QqqSchdRotationDashboardState extends State<QqqSchdRotationDashboard> {
  static const Color _teal = Color(0xff14b8a6);
  static const Color _amber = Color(0xfff59e0b);
  static const Color _violet = Color(0xffa78bfa);
  static const Color _sky = Color(0xff38bdf8);

  Map<String, dynamic>? data;
  Map<String, dynamic>? rangeDetail;
  bool loading = true;
  bool failed = false;
  bool rangeLoading = false;
  String mode = 'm6';
  String window = 'live_2011';
  String activePreset = 'all';
  String proofTab = 'canonical';
  String sopTab = 'sop';
  String ledgerScope = 'window';
  bool logScale = true;
  bool showDrawdown = false;
  int epoch = 0;
  int rangeEpoch = 0;
  int hover = -1;
  Timer? rangeDebounce;
  RangeValues range = const RangeValues(0, 1);
  String? savedStart;
  String? savedEnd;
  final GlobalKey _liveRadarKey = GlobalKey();
  final Set<String> enabledCurves = {'m6', 'qqq', 'schd', 'static7030'};

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

  TextStyle s([double size = 13, bool bold = false, Color? color]) => TextStyle(
    fontSize: size,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? p.text,
    height: 1.42,
  );

  @override
  void initState() {
    super.initState();
    final q = readBrowserQuery();
    if (const ['m6', 'm4', 'm7'].contains(q['rotationMode'])) {
      mode = q['rotationMode']!;
      enabledCurves.add(mode);
    }
    if (const ['live_2011', 'full_2000'].contains(q['rotationWindow'])) {
      window = q['rotationWindow']!;
    }
    savedStart = q['rotationFrom'];
    savedEnd = q['rotationTo'];
    unawaited(load());
  }

  @override
  void dispose() {
    rangeDebounce?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant QqqSchdRotationDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOf != widget.asOf || oldWidget.api != widget.api) {
      unawaited(load());
    }
  }

  Color _modeColor(String id) => switch (id) {
    'm6' => _teal,
    'm4' => p.positive,
    'm7' => _sky,
    'qqq' => _violet,
    'schd' => _amber,
    _ => p.secondary,
  };

  String _curveLabel(String id) => switch (id) {
    'm6' => w('M6 Flagship (Slow-Sell / Fast-Buy)', 'M6 慢卖快买旗舰'),
    'm4' => w('M4 Left-Side All-In', 'M4 双锚左侧全仓'),
    'm7' => w('M7 50/50 Core-Satellite', 'M7 50%底仓应税版'),
    'qqq' => w('100% QQQ Buy & Hold', '100% QQQ 买入持有'),
    'schd' => w('100% SCHD Dividend', '100% SCHD 红利'),
    _ => w('70/30 Static Q-Rebal', '70/30 静态再平衡'),
  };

  String _shortCurveLabel(String id) => switch (id) {
    'm6' => w('M6', 'M6 旗舰'),
    'm4' => w('M4', 'M4 左侧'),
    'm7' => w('M7', 'M7 底仓'),
    'qqq' => 'QQQ',
    'schd' => 'SCHD',
    _ => w('70/30 Static', '70/30 静态'),
  };

  String _pct(dynamic v, [int digits = 2]) => nullableNumber(v) == null
      ? '—'
      : '${number(v) >= 0 ? '+' : ''}${(number(v) * 100).toStringAsFixed(digits)}%';

  String _pctPlain(dynamic v, [int digits = 2]) => nullableNumber(v) == null
      ? '—'
      : '${(number(v) * 100).toStringAsFixed(digits)}%';

  String _pctDirect(dynamic v, [int digits = 1]) => nullableNumber(v) == null
      ? '—'
      : '${number(v) >= 0 ? '+' : ''}${number(v).toStringAsFixed(digits)}%';

  String _mult(dynamic v) =>
      nullableNumber(v) == null ? '—' : '${number(v).toStringAsFixed(2)}x';

  String _dec(dynamic v, [int digits = 2]) =>
      nullableNumber(v) == null ? '—' : number(v).toStringAsFixed(digits);

  Widget _panel(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: p.panel,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: p.border),
    ),
    child: child,
  );

  Widget _sectionHeader(String numTag, String title, {String? subtitle, Color? accent}) {
    final c = accent ?? _modeColor(mode);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(numTag, style: s(12, true, c)),
            ),
            const SizedBox(width: 9),
            Expanded(child: Text(title, style: s(18.5, true))),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 5),
          Text(subtitle, style: s(12, false, p.muted)),
        ],
      ],
    );
  }

  Future<void> load() async {
    final req = ++epoch;
    final reqMode = mode;
    final reqWin = window;
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final res = await widget.api.getJson(
        '/api/investment/qqq-schd-rotation?asOf=${Uri.encodeQueryComponent(widget.asOf)}&mode=$reqMode&window=$reqWin',
      );
      if (!mounted || req != epoch) return;
      widget.onSummaryLoaded?.call(res);
      final curve = asList(asMap(res['backtest'])['curve']);
      final nextRange = _restoreRange(curve);
      setState(() {
        data = res;
        loading = false;
        hover = -1;
        range = nextRange;
      });
      _scheduleRangeAnalysis(curve, nextRange, immediate: true);
    } catch (_) {
      if (!mounted || req != epoch) return;
      setState(() {
        failed = true;
        loading = false;
      });
    }
  }

  RangeValues _restoreRange(List<Map<String, dynamic>> curve) {
    if (curve.length < 2 || savedStart == null || savedEnd == null) {
      activePreset = 'all';
      return const RangeValues(0, 1);
    }
    final first = curve.indexWhere(
      (r) => text(r['date']).compareTo(savedStart!) >= 0,
    );
    final last = curve.lastIndexWhere(
      (r) => text(r['date']).compareTo(savedEnd!) <= 0,
    );
    if (first < 0 || last <= first) {
      activePreset = 'all';
      return const RangeValues(0, 1);
    }
    return RangeValues(first / (curve.length - 1), last / (curve.length - 1));
  }

  void _scheduleRangeAnalysis(
    List<Map<String, dynamic>> curve,
    RangeValues rv, {
    bool immediate = false,
  }) {
    rangeDebounce?.cancel();
    if (curve.length < 2 || data == null) return;
    final first = (rv.start * (curve.length - 1)).round().clamp(0, curve.length - 2);
    final last = (rv.end * (curve.length - 1)).round().clamp(first + 1, curve.length - 1);
    if (first == 0 && last == curve.length - 1) {
      setState(() {
        rangeDetail = null;
        rangeLoading = false;
      });
      return;
    }
    final startD = text(curve[first]['date']);
    final endD = text(curve[last]['date']);
    final snapId = text(data?['snapshotId']);

    Future<void> runFetch() async {
      final rReq = ++rangeEpoch;
      setState(() => rangeLoading = true);
      try {
        final detail = await widget.api.getJson(
          '/api/investment/qqq-schd-rotation/analysis?asOf=${Uri.encodeQueryComponent(widget.asOf)}'
          '&mode=$mode&window=$window&snapshotId=${Uri.encodeQueryComponent(snapId)}'
          '&start=$startD&end=$endD',
        );
        if (!mounted || rReq != rangeEpoch) return;
        setState(() {
          rangeDetail = detail;
          rangeLoading = false;
        });
      } catch (_) {
        if (!mounted || rReq != rangeEpoch) return;
        setState(() => rangeLoading = false);
      }
    }

    if (immediate) {
      unawaited(runFetch());
    } else {
      rangeDebounce = Timer(const Duration(milliseconds: 180), () {
        unawaited(runFetch());
      });
    }
  }

  void _switchMode(String nextMode) {
    if (nextMode == mode) return;
    setState(() {
      mode = nextMode;
      enabledCurves
        ..removeWhere((k) => const {'m6', 'm4', 'm7'}.contains(k) && k != nextMode)
        ..add(nextMode);
    });
    replaceBrowserQuery({
      'strategyTab': 'portfolio',
      'portfolioStrategy': 'qqq_schd_rotation',
      'rotationMode': nextMode,
      'rotationWindow': window,
    }, replaceCurrent: true);
    unawaited(load());
  }

  void _switchWindow(String nextWindow) {
    if (nextWindow == window) return;
    setState(() {
      window = nextWindow;
      activePreset = 'all';
      savedStart = null;
      savedEnd = null;
      range = const RangeValues(0, 1);
      rangeDetail = null;
    });
    replaceBrowserQuery({
      'strategyTab': 'portfolio',
      'portfolioStrategy': 'qqq_schd_rotation',
      'rotationMode': mode,
      'rotationWindow': nextWindow,
      'rotationFrom': null,
      'rotationTo': null,
    }, replaceCurrent: true);
    unawaited(load());
  }

  void _applyPreset(String preset, List<Map<String, dynamic>> curve) {
    if (curve.length < 2) return;
    int first = 0;
    int last = curve.length - 1;
    if (preset == '5y') {
      first = math.max(0, curve.length - 1 - 1260);
    } else if (preset == '3y') {
      first = math.max(0, curve.length - 1 - 756);
    } else if (preset == 'bear2022') {
      final fIdx = curve.indexWhere((r) => text(r['date']).compareTo('2021-11-19') >= 0);
      final lIdx = curve.lastIndexWhere((r) => text(r['date']).compareTo('2022-12-28') <= 0);
      if (fIdx >= 0 && lIdx > fIdx) {
        first = fIdx;
        last = lIdx;
      }
    } else if (preset == 'tariff2025') {
      final fIdx = curve.indexWhere((r) => text(r['date']).compareTo('2024-07-10') >= 0);
      final lIdx = curve.lastIndexWhere((r) => text(r['date']).compareTo('2025-04-08') <= 0);
      if (fIdx >= 0 && lIdx > fIdx) {
        first = fIdx;
        last = lIdx;
      }
    }
    final nextRv = RangeValues(first / (curve.length - 1), last / (curve.length - 1));
    setState(() {
      activePreset = preset;
      range = nextRv;
      hover = -1;
      savedStart = first == 0 && last == curve.length - 1 ? null : text(curve[first]['date']);
      savedEnd = first == 0 && last == curve.length - 1 ? null : text(curve[last]['date']);
    });
    replaceBrowserQuery({
      'strategyTab': 'portfolio',
      'portfolioStrategy': 'qqq_schd_rotation',
      'rotationMode': mode,
      'rotationWindow': window,
      'rotationFrom': savedStart,
      'rotationTo': savedEnd,
    }, replaceCurrent: true);
    _scheduleRangeAnalysis(curve, nextRv, immediate: true);
  }

  void _changeRange(RangeValues value, List<Map<String, dynamic>> curve) {
    final first = (value.start * (curve.length - 1)).round();
    final last = (value.end * (curve.length - 1)).round();
    if (first >= last) return;
    final isFull = first == 0 && last == curve.length - 1;
    setState(() {
      activePreset = isFull ? 'all' : 'custom';
      range = value;
      hover = -1;
      savedStart = isFull ? null : text(curve[first]['date']);
      savedEnd = isFull ? null : text(curve[last]['date']);
    });
    replaceBrowserQuery({
      'strategyTab': 'portfolio',
      'portfolioStrategy': 'qqq_schd_rotation',
      'rotationMode': mode,
      'rotationWindow': window,
      'rotationFrom': savedStart,
      'rotationTo': savedEnd,
    }, replaceCurrent: true);
    _scheduleRangeAnalysis(curve, value);
  }

  Future<void> _pickBoundary(List<Map<String, dynamic>> curve, bool beginning) async {
    final reqEpoch = epoch;
    final first = (range.start * (curve.length - 1)).round();
    final last = (range.end * (curve.length - 1)).round();
    final minimum = DateTime.parse(text(curve[beginning ? 0 : first + 1]['date']));
    final maximum = DateTime.parse(text(curve[beginning ? last - 1 : curve.length - 1]['date']));
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(text(curve[beginning ? first : last]['date'])),
      firstDate: minimum,
      lastDate: maximum,
      helpText: beginning
          ? w('Select start date', '选择起始日期')
          : w('Select end date', '选择结束日期'),
      cancelText: w('Cancel', '取消'),
      confirmText: w('Apply', '应用'),
    );
    if (!mounted || picked == null || reqEpoch != epoch) return;
    final iso = picked.toIso8601String().substring(0, 10);
    final idx = beginning
        ? curve.indexWhere((r) => text(r['date']).compareTo(iso) >= 0)
        : curve.lastIndexWhere((r) => text(r['date']).compareTo(iso) <= 0);
    if (idx < 0) return;
    final newFirst = beginning ? idx : first;
    final newLast = beginning ? last : idx;
    if (newFirst >= newLast) return;
    final nextRv = RangeValues(newFirst / (curve.length - 1), newLast / (curve.length - 1));
    _changeRange(nextRv, curve);
    _scheduleRangeAnalysis(curve, nextRv, immediate: true);
  }

  Widget _buildModeAndWindowBar(List<Map<String, dynamic>> curve) {
    final modesSummary = asMap(data?['modesSummary']);
    Widget buildModeBtn(String id) {
      final m = asMap(modesSummary[id]);
      final mStat = asMap(m['metrics']);
      final selected = mode == id;
      final c = _modeColor(id);
      return Material(
        color: selected ? c.withValues(alpha: 0.13) : p.card,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          key: ValueKey('rotation-mode-$id'),
          borderRadius: BorderRadius.circular(11),
          onTap: () => _switchMode(id),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: selected ? c : p.border,
                width: selected ? 1.8 : 1.0,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          loc(m['badge']),
                          overflow: TextOverflow.ellipsis,
                          style: s(10, true, c),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      selected ? Icons.check_circle : Icons.circle_outlined,
                      size: 17,
                      color: selected ? c : p.muted,
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(loc(m['name']), style: s(14.5, true)),
                const SizedBox(height: 4),
                Text(loc(m['summary']), style: s(11.5, false, p.muted)),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 6,
                  runSpacing: 5,
                  children: [
                    _miniTag('${w('CAGR', '年化')} ${_pctPlain(mStat['cagr'])}', c, selected),
                    _miniTag(_mult(mStat['endingMultiple']), c, selected),
                    _miniTag('${w('Sharpe', '夏普')} ${_dec(mStat['sharpe'], 3)}', c, selected),
                    _miniTag('${w('MDD', '回撤')} ${_pctPlain(mStat['maxDrawdown'], 1)}', c, selected),
                    _miniTag(
                      '${mStat['switchCount'] ?? 0} ${w('switches', '次切换')}',
                      c,
                      selected,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    final first = (range.start * (curve.length - 1)).round().clamp(0, curve.length - 2);
    final last = (range.end * (curve.length - 1)).round().clamp(first + 1, curve.length - 1);
    final startStr = text(curve[first]['date']);
    final endStr = text(curve[last]['date']);

    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w(
                  'QQQ ⇄ SCHD Valuation & Panic Resonance Rotation',
                  'QQQ ⇄ SCHD 估值与恐慌共振慢卖快买轮动策略',
                ),
                key: const ValueKey('rotation-dashboard-heading'),
                style: s(20, true),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _teal.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  w(
                    'Point-in-Time Fundamentals · T+1 Execution · 5 bps/side',
                    '无前视时点财报 · T+1 收盘成交 · 双边 5 bps 冲击成本',
                  ),
                  style: s(11, true, _teal),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            w(
              'Replaces naive valuation moving averages with Dual-Anchor Valuation Guardrails + Asymmetric Slow-Sell (100% -> 70% -> 45% -> 0%) and Instant 100% Panic Sniping when drawdown <= -18% resonates with VIX >= 32 or Daily RSI <= 28.',
              '摒弃单一估值均线陷阱，采用「绝对现金流/盈利锚 + 3年估值均线锚」双护栏：泡沫超买分两档慢卖（100%→70%→45%）并在跌破 MA150 时清仓换入 SCHD 防守；一旦回撤 ≤ -18% 共振 VIX ≥ 32 或日 RSI ≤ 28，一次性全额卖出 SCHD 100% 切回 QQQ。',
            ),
            style: s(12.5, false, p.muted),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (ctx, cons) {
              if (cons.maxWidth >= 960) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: buildModeBtn('m6')),
                    const SizedBox(width: 10),
                    Expanded(child: buildModeBtn('m4')),
                    const SizedBox(width: 10),
                    Expanded(child: buildModeBtn('m7')),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  buildModeBtn('m6'),
                  const SizedBox(height: 8),
                  buildModeBtn('m4'),
                  const SizedBox(height: 8),
                  buildModeBtn('m7'),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          Divider(color: p.border, height: 1),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(w('Backtest Universe:', '回测大周期:'), style: s(12, true, p.muted)),
              ChoiceChip(
                key: const ValueKey('rotation-window-live_2011'),
                label: Text(w('Live ETF Era (2011–2026)', '实盘 ETF 周期 (2011–2026)')),
                selected: window == 'live_2011',
                onSelected: (_) => _switchWindow('live_2011'),
              ),
              ChoiceChip(
                key: const ValueKey('rotation-window-full_2000'),
                label: Text(w('Full 27Y Dot-Com Cycle (2000–2026)', '27年穿越泡沫全周期 (2000–2026)')),
                selected: window == 'full_2000',
                onSelected: (_) => _switchWindow('full_2000'),
              ),
              const SizedBox(width: 8),
              Text(w('Quick Range:', '快捷区间:'), style: s(12, true, p.muted)),
              ChoiceChip(
                key: const ValueKey('rotation-preset-all'),
                label: Text(w('Full Window', '全区间')),
                selected: activePreset == 'all',
                onSelected: (_) => _applyPreset('all', curve),
              ),
              ChoiceChip(
                key: const ValueKey('rotation-preset-5y'),
                label: Text(w('Last 5Y', '近 5 年')),
                selected: activePreset == '5y',
                onSelected: (_) => _applyPreset('5y', curve),
              ),
              ChoiceChip(
                key: const ValueKey('rotation-preset-3y'),
                label: Text(w('Last 3Y', '近 3 年')),
                selected: activePreset == '3y',
                onSelected: (_) => _applyPreset('3y', curve),
              ),
              ChoiceChip(
                key: const ValueKey('rotation-preset-bear2022'),
                label: Text(w('2022 Rate-Hike Bear', '2022 加息熊市')),
                selected: activePreset == 'bear2022',
                onSelected: (_) => _applyPreset('bear2022', curve),
              ),
              ChoiceChip(
                key: const ValueKey('rotation-preset-tariff2025'),
                label: Text(w('2024–25 Tariff Crash', '2024–25 关税闪崩')),
                selected: activePreset == 'tariff2025',
                onSelected: (_) => _applyPreset('tariff2025', curve),
              ),
              OutlinedButton.icon(
                key: const ValueKey('rotation-pick-start'),
                onPressed: () => _pickBoundary(curve, true),
                icon: const Icon(Icons.calendar_today, size: 14),
                label: Text('${w('From', '起')}: $startStr', style: s(11.5, true)),
              ),
              OutlinedButton.icon(
                key: const ValueKey('rotation-pick-end'),
                onPressed: () => _pickBoundary(curve, false),
                icon: const Icon(Icons.event, size: 14),
                label: Text('${w('To', '止')}: $endStr', style: s(11.5, true)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniTag(String label, Color accent, bool active) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: p.panel.withValues(alpha: 0.85),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(
        color: active ? accent.withValues(alpha: 0.4) : p.border,
      ),
    ),
    child: Text(label, style: s(10.8, true)),
  );

  Widget _buildPerformanceModule(List<Map<String, dynamic>> curve) {
    final first = (range.start * (curve.length - 1)).round().clamp(0, curve.length - 2);
    final last = (range.end * (curve.length - 1)).round().clamp(first + 1, curve.length - 1);
    final isSubRange = first > 0 || last < curve.length - 1;
    final subCurve = curve.sublist(first, last + 1);

    final activeMetrics = isSubRange && rangeDetail != null
        ? asMap(rangeDetail?['metrics'])
        : asMap(asMap(data?['mode'])['metrics']);
    final qqqMetrics = isSubRange && rangeDetail != null
        ? asMap(asMap(rangeDetail?['benchmarks'])['qqq'])
        : asMap(asMap(data?['benchmarks'])['qqq']);
    final schdMetrics = isSubRange && rangeDetail != null
        ? asMap(asMap(rangeDetail?['benchmarks'])['schd'])
        : asMap(asMap(data?['benchmarks'])['schd']);
    final s70Metrics = isSubRange && rangeDetail != null
        ? asMap(asMap(rangeDetail?['benchmarks'])['static7030'])
        : asMap(asMap(data?['benchmarks'])['static7030']);

    final excessCagr = nullableNumber(activeMetrics['cagr']) != null &&
            nullableNumber(qqqMetrics['cagr']) != null
        ? number(activeMetrics['cagr']) - number(qqqMetrics['cagr'])
        : null;

    final kpis = [
      (
        w('Net CAGR (5 bps/side)', '扣费年化收益 CAGR'),
        _pctPlain(activeMetrics['cagr']),
        '${w('vs QQQ', '对比 QQQ')} ${_pct(excessCagr)}/${w('yr', '年')}',
        p.positive,
      ),
      (
        w('Ending Multiple', '期末净值倍数'),
        _mult(activeMetrics['endingMultiple']),
        'QQQ ${_mult(qqqMetrics['endingMultiple'])} · SCHD ${_mult(schdMetrics['endingMultiple'])}',
        _modeColor(mode),
      ),
      (
        w('Sharpe / Sortino', '夏普比率 / 索提诺'),
        '${_dec(activeMetrics['sharpe'], 3)} / ${_dec(activeMetrics['sortino'], 2)}',
        'QQQ ${_dec(qqqMetrics['sharpe'], 3)} · 70/30 ${_dec(s70Metrics['sharpe'], 3)}',
        p.accent,
      ),
      (
        w('Max Drawdown & Ulcer', '最大回撤与溃疡指数'),
        _pctPlain(activeMetrics['maxDrawdown']),
        'Ulcer ${_dec(activeMetrics['ulcerIndex'], 2)} (QQQ ${_dec(qqqMetrics['ulcerIndex'], 2)})',
        _amber,
      ),
      (
        w('Rolling 5Y / 3Y Beat QQQ', '滚动5年 / 3年跑赢QQQ胜率'),
        nullableNumber(activeMetrics['winRate5y']) != null
            ? '${_pctPlain(activeMetrics['winRate5y'], 1)} / ${_pctPlain(activeMetrics['winRate3y'], 1)}'
            : nullableNumber(activeMetrics['winRate3y']) != null
                ? '— / ${_pctPlain(activeMetrics['winRate3y'], 1)}'
                : w('Short Window', '短周期窗口'),
        'Calmar ${_dec(activeMetrics['calmar'], 3)}',
        p.positive,
      ),
      (
        w('Avg QQQ Weight & Switches', '平均 QQQ 仓位与调仓数'),
        '${_pctPlain(activeMetrics['avgQqqWeight'], 1)} QQQ',
        '${activeMetrics['switchCount'] ?? 0} ${w('switches', '次调仓')} · ${w('Turn', '年换手')} ${_pctPlain(activeMetrics['annualTurnover'], 1)}',
        _sky,
      ),
    ];

    final inspectedIdx = hover >= 0 && hover < subCurve.length ? hover : subCurve.length - 1;
    final inspectedRow = subCurve[inspectedIdx];
    final baseRow = subCurve.first;

    double rebasedVal(Map<String, dynamic> row, String k) {
      final b = number(baseRow[k]);
      return b > 0 ? number(row[k]) / b : 1.0;
    }

    final activeWeight = number(inspectedRow['${mode}w']);
    final yearlyReturns = asList(asMap(data?['backtest'])['yearlyReturns']);
    final allocAttr = asMap(rangeDetail?['allocationAttribution']);

    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            '01',
            w(
              'Audited Performance, Multi-Curve Chart & Dynamic QQQ/SCHD Allocation Ribbon',
              '实证业绩指标、交互式多曲线净值/回撤图与动态仓位丝带',
            ),
            subtitle:
                '${text(subCurve.first['date'])} → ${text(subCurve.last['date'])} · ${subCurve.length} ${w('trading days · Risk-free rate: BIL T-Bill total return', '个交易日 · 无风险基准：BIL 短融美债真实总回报')}',
          ),
          if (rangeLoading) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(color: _modeColor(mode)),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final k in kpis)
                Container(
                  width: 196,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.card,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 36,
                        height: 3,
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: k.$4,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Text(k.$1, style: s(11, true, p.muted)),
                      const SizedBox(height: 3),
                      Text(k.$2, style: s(17.5, true)),
                      const SizedBox(height: 2),
                      Text(k.$3, style: s(11, false, p.muted)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final cid in ['m6', 'm4', 'm7', 'qqq', 'schd', 'static7030'])
                FilterChip(
                  selected: enabledCurves.contains(cid),
                  selectedColor: _modeColor(cid).withValues(alpha: 0.22),
                  checkmarkColor: _modeColor(cid),
                  label: Text(_curveLabel(cid), style: s(11.5, true)),
                  onSelected: (on) {
                    if (!on && enabledCurves.length <= 1) return;
                    setState(() {
                      if (on) {
                        enabledCurves.add(cid);
                      } else {
                        enabledCurves.remove(cid);
                      }
                    });
                  },
                ),
              const SizedBox(width: 8),
              ChoiceChip(
                key: const ValueKey('rotation-scale-log'),
                label: Text(w('Log NAV', '对数净值')),
                selected: !showDrawdown && logScale,
                onSelected: (_) => setState(() {
                  showDrawdown = false;
                  logScale = true;
                }),
              ),
              ChoiceChip(
                key: const ValueKey('rotation-scale-linear'),
                label: Text(w('Linear NAV', '线性净值')),
                selected: !showDrawdown && !logScale,
                onSelected: (_) => setState(() {
                  showDrawdown = false;
                  logScale = false;
                }),
              ),
              ChoiceChip(
                key: const ValueKey('rotation-view-dd'),
                label: Text(w('Underwater Drawdown', '水下回撤对比')),
                selected: showDrawdown,
                onSelected: (_) => setState(() => showDrawdown = true),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: p.border),
            ),
            child: Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                Text(text(inspectedRow['date']), style: s(12, true, _modeColor(mode))),
                for (final cid in ['m6', 'm4', 'm7', 'qqq', 'schd', 'static7030'])
                  if (enabledCurves.contains(cid))
                    Text(
                      showDrawdown
                          ? '${_shortCurveLabel(cid)}: ${_pctPlain(inspectedRow['${cid}Dd'], 1)}'
                          : '${_shortCurveLabel(cid)}: ${rebasedVal(inspectedRow, cid).toStringAsFixed(2)}x',
                      style: s(11.8, true, _modeColor(cid)),
                    ),
                Text(
                  '${mode.toUpperCase()} ${w('Alloc', '仓位')}: ${(activeWeight * 100).toStringAsFixed(0)}% QQQ / ${((1 - activeWeight) * 100).toStringAsFixed(0)}% SCHD',
                  style: s(11.5, true),
                ),
                Text(
                  'PE ${_dec(inspectedRow['posPe'], 1)}x · FCF ${_dec(inspectedRow['fcfYield'], 2)}% · VIX ${_dec(inspectedRow['vix'], 1)} · RSI ${_dec(inspectedRow['rsi14'], 1)}',
                  style: s(11.5, false, p.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (ctx, cons) {
              void updateHover(Offset local) {
                final plotLeft = 48.0;
                final plotW = math.max(1.0, cons.maxWidth - plotLeft - 12.0);
                final frac = ((local.dx - plotLeft) / plotW).clamp(0.0, 1.0);
                final idx = (frac * (subCurve.length - 1)).round();
                if (idx != hover) setState(() => hover = idx);
              }

              return MouseRegion(
                onHover: (e) => updateHover(e.localPosition),
                onExit: (_) => setState(() => hover = -1),
                child: GestureDetector(
                  onPanDown: (d) => updateHover(d.localPosition),
                  onPanUpdate: (d) => updateHover(d.localPosition),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 270,
                        child: CustomPaint(
                          painter: _RotationEquityChartPainter(
                            rows: subCurve,
                            enabledCurves: enabledCurves,
                            logScale: logScale,
                            showDrawdown: showDrawdown,
                            hoverIndex: hover,
                            palette: p,
                            colorFor: _modeColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const SizedBox(width: 48),
                          Expanded(
                            child: Wrap(
                              spacing: 12,
                              runSpacing: 4,
                              children: [
                                Text(
                                  w(
                                    'Synchronized Allocation Ribbon (${mode.toUpperCase()}):',
                                    '同步动态仓位条 (${mode.toUpperCase()}):',
                                  ),
                                  style: s(11, true, p.muted),
                                ),
                                _legendDot(_teal, w('100% QQQ Offense', '100% QQQ 满仓进攻')),
                                _legendDot(_amber, w('70% / 45% Staged Trim', '70%/45% 慢卖分批止盈')),
                                _legendDot(_sky, w('100% SCHD Shield (or 50/50 Core)', '100% SCHD 避险 (或50%底仓)')),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 54,
                        child: CustomPaint(
                          painter: _RotationWeightRibbonPainter(
                            rows: subCurve,
                            weightKey: '${mode}w',
                            hoverIndex: hover,
                            palette: p,
                            teal: _teal,
                            amber: _amber,
                            sky: _sky,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: _modeColor(mode),
              thumbColor: _modeColor(mode),
            ),
            child: RangeSlider(
              values: range,
              onChanged: (v) => _changeRange(v, curve),
            ),
          ),
          if (isSubRange && allocAttr.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _modeColor(mode).withValues(alpha: 0.35)),
              ),
              child: Wrap(
                spacing: 16,
                runSpacing: 6,
                children: [
                  Text(
                    w('Selected Window Attribution:', '所选自定义区间归因:'),
                    style: s(12, true, _modeColor(mode)),
                  ),
                  Text(
                    '${w('QQQ Sleeve Additive', 'QQQ进攻端贡献')}: ${_pct(allocAttr['additiveQqqContribution'])}',
                    style: s(12, true),
                  ),
                  Text(
                    '${w('SCHD Shield Additive', 'SCHD避险端贡献')}: ${_pct(allocAttr['additiveSchdContribution'])}',
                    style: s(12, true),
                  ),
                  Text(
                    '${w('Slippage Cost Drag', '调仓冲击损耗')}: -${_pctPlain(allocAttr['switchingCostDrag'])}',
                    style: s(12, false, p.muted),
                  ),
                  Text(
                    '${w('Excess vs QQQ', '区间跑赢QQQ')}: ${_pct(asMap(rangeDetail?['comparison'])['excessReturnVsQqq'])}',
                    style: s(
                      12,
                      true,
                      number(asMap(rangeDetail?['comparison'])['excessReturnVsQqq']) >= 0
                          ? p.positive
                          : p.negative,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Material(
            color: Colors.transparent,
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                w(
                  'Calendar Year Returns Comparison (${yearlyReturns.length} Years)',
                  '展开查看逐年日历收益对比表（共 ${yearlyReturns.length} 年）',
                ),
                style: s(13.5, true),
              ),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowHeight: 36,
                    dataRowMinHeight: 32,
                    dataRowMaxHeight: 36,
                    columnSpacing: 18,
                    columns: [
                      DataColumn(label: Text(w('Year', '年份'), style: s(11.5, true))),
                      DataColumn(label: Text('M6', style: s(11.5, true, _teal))),
                      DataColumn(label: Text('M4', style: s(11.5, true, p.positive))),
                      DataColumn(label: Text('M7', style: s(11.5, true, _sky))),
                      DataColumn(label: Text('100% QQQ', style: s(11.5, true, _violet))),
                      DataColumn(label: Text('100% SCHD', style: s(11.5, true, _amber))),
                      DataColumn(label: Text(w('70/30 Static', '70/30 静态'), style: s(11.5, true, p.muted))),
                    ],
                    rows: [
                      for (final yr in yearlyReturns.reversed)
                        DataRow(
                          cells: [
                            DataCell(Text(text(yr['label']), style: s(12, true))),
                            DataCell(_retCell(yr['m6'])),
                            DataCell(_retCell(yr['m4'])),
                            DataCell(_retCell(yr['m7'])),
                            DataCell(_retCell(yr['qqq'])),
                            DataCell(_retCell(yr['schd'])),
                            DataCell(_retCell(yr['static7030'])),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _retCell(dynamic v) => Text(
    _pct(v, 1),
    style: s(12, true, number(v) >= 0 ? p.positive : p.negative),
  );

  Widget _legendDot(Color c, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
      ),
      const SizedBox(width: 4),
      Text(label, style: s(11, false, p.muted)),
    ],
  );

  Widget _buildBlueprintAndShowdownModule() {
    final steps = asList(asMap(data?['mode'])['blueprint']);
    final traps = asList(data?['traps']);
    final canonLive = asList(asMap(data?['canonicalComparisonByWindow'])['live_2011']);
    final canonFull = asList(asMap(data?['canonicalComparisonByWindow'])['full_2000']);
    final fullByCode = {for (final r in canonFull) text(r['code']): r};
    final grid = asMap(data?['robustnessGrid']);
    final gridCells = asList(grid['cells']);
    final peAxis = (grid['sellPeakPeAxis'] as List? ?? const []).map(number).toList();
    final ddAxis = (grid['buyDrawdownAxis'] as List? ?? const []).map(number).toList();

    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            '02',
            w(
              '4-Step Execution Blueprint, Valuation-MA Trap Anatomy & 12-Strategy Showdown',
              '四步量化执行蓝图、纯估值均线双陷阱解剖与 12 种方案硬核比武',
            ),
            subtitle: w(
              'Why naive static PE and rolling valuation Z-scores fail — and how Dual-Anchor Guardrails + Left-Side Panic Sniping generate +2.59%/yr alpha.',
              '揭秘为何「固定低PE」与「纯估值均线」必败，以及「双锚护栏 + 慢卖快买 + VIX/RSI全卖SCHD抄底」如何每年多赚 +2.59% 纯超额。',
            ),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (ctx, cons) {
              final cols = cons.maxWidth >= 1040
                  ? 4
                  : cons.maxWidth >= 620
                      ? 2
                      : 1;
              final cardW = (cons.maxWidth - (cols - 1) * 10) / cols;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final st in steps)
                    Container(
                      width: cardW,
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: p.card,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: p.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _modeColor(mode).withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  w('STEP ${st['step']}', '第 ${st['step']} 步'),
                                  style: s(11, true, _modeColor(mode)),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  localizeStrategyMetricText(
                                    loc(st['metricBadge']),
                                    context.language,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  style: s(11, true, p.muted),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 7),
                          Text(loc(st['title']), style: s(13.5, true)),
                          const SizedBox(height: 4),
                          Text(loc(st['summary']), style: s(11.8, false, p.muted)),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (ctx, cons) {
              final trapWidgets = [
                for (final tr in traps)
                  Container(
                    padding: const EdgeInsets.all(13),
                    decoration: BoxDecoration(
                      color: (text(tr['severity']) == 'danger' ? p.negative : _amber)
                          .withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: (text(tr['severity']) == 'danger' ? p.negative : _amber)
                            .withValues(alpha: 0.4),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          loc(tr['title']),
                          style: s(
                            13.2,
                            true,
                            text(tr['severity']) == 'danger' ? p.negative : _amber,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(loc(tr['body']), style: s(11.8, false, p.text)),
                        const SizedBox(height: 6),
                        Text(loc(tr['guardrail']), style: s(11.5, true, _teal)),
                      ],
                    ),
                  ),
              ];
              if (cons.maxWidth >= 820 && trapWidgets.length == 2) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: trapWidgets[0]),
                    const SizedBox(width: 12),
                    Expanded(child: trapWidgets[1]),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < trapWidgets.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    trapWidgets[i],
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('rotation-proof-canonical'),
                label: Text(w('12-Strategy Canonical Showdown', '12 种方案硬核比武总表')),
                selected: proofTab == 'canonical',
                onSelected: (_) => setState(() => proofTab = 'canonical'),
              ),
              ChoiceChip(
                key: const ValueKey('rotation-proof-grid'),
                label: Text(
                  w(
                    '5x5 Parameter Robustness Grid (${_dec(grid['beatQqqSharpePct'], 0)}% Beat QQQ Sharpe)',
                    '5×5 参数稳健性网格（${_dec(grid['beatQqqSharpePct'], 0)}% 网格夏普跑赢 QQQ）',
                  ),
                ),
                selected: proofTab == 'grid',
                onSelected: (_) => setState(() => proofTab = 'grid'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (proofTab == 'canonical')
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 38,
                dataRowMinHeight: 40,
                dataRowMaxHeight: 54,
                columnSpacing: 14,
                columns: [
                  DataColumn(label: Text(w('Code & Strategy', '代码与策略机制'), style: s(11.5, true))),
                  DataColumn(label: Text(w('Live CAGR\n(2011–26)', '实盘年化\n(2011–26)'), style: s(11.5, true))),
                  DataColumn(label: Text(w('Live Mult', '实盘倍数'), style: s(11.5, true))),
                  DataColumn(label: Text(w('Sharpe', '夏普'), style: s(11.5, true))),
                  DataColumn(label: Text(w('MDD', '最大回撤'), style: s(11.5, true))),
                  DataColumn(label: Text(w('Ulcer', '溃疡指数'), style: s(11.5, true))),
                  DataColumn(label: Text(w('5Y Win', '5年胜率'), style: s(11.5, true))),
                  DataColumn(label: Text(w('27Y CAGR\n(2000–26)', '27年年化\n(2000–26)'), style: s(11.5, true))),
                  DataColumn(label: Text(w('27Y Mult (MDD)', '27年倍数 (回撤)'), style: s(11.5, true))),
                ],
                rows: [
                  for (final r in canonLive)
                    () {
                      final code = text(r['code']);
                      final fRow = asMap(fullByCode[code]);
                      final highlight = const {'M6', 'M4', 'M7'}.contains(code);
                      return DataRow(
                        color: highlight
                            ? WidgetStatePropertyAll(_teal.withValues(alpha: 0.09))
                            : null,
                        cells: [
                          DataCell(
                            SizedBox(
                              width: 260,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$code · ${loc(r['name'])}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: s(12, true),
                                  ),
                                  Text(
                                    loc(r['rule']),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: s(10.5, false, p.muted),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              '${_dec(r['cagrPct'], 2)}%',
                              style: s(
                                12,
                                true,
                                number(r['cagrPct']) >= 18.97 ? p.positive : p.text,
                              ),
                            ),
                          ),
                          DataCell(Text('${_dec(r['endingMultiple'], 2)}x', style: s(12, true))),
                          DataCell(
                            Text(
                              _dec(r['sharpe'], 3),
                              style: s(
                                12,
                                true,
                                number(r['sharpe']) >= 0.96 ? p.positive : p.text,
                              ),
                            ),
                          ),
                          DataCell(
                            Text('${_dec(r['maxDrawdownPct'], 2)}%', style: s(12, false, p.negative)),
                          ),
                          DataCell(Text(_dec(r['ulcerIndex'], 2), style: s(12))),
                          DataCell(Text('${_dec(r['win5yPct'], 1)}%', style: s(12, true))),
                          DataCell(Text('${_dec(fRow['cagrPct'], 2)}%', style: s(12, true))),
                          DataCell(
                            Text(
                              '${_dec(fRow['endingMultiple'], 2)}x (${_dec(fRow['maxDrawdownPct'], 1)}%)',
                              style: s(12, highlight),
                            ),
                          ),
                        ],
                      );
                    }(),
                ],
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w(
                    '25-Cell Parameter Neighborhood (${window == 'live_2011' ? 'Live 2011–2026' : 'Full 2000–2026'}): Mean CAGR ${_dec(grid['meanCagrPct'], 2)}% (Range ${_dec(grid['minCagrPct'], 2)}%..${_dec(grid['maxCagrPct'], 2)}%), Mean Sharpe ${_dec(grid['meanSharpe'], 3)}, Beat QQQ Sharpe ${_dec(grid['beatQqqSharpePct'], 0)}%, Better MDD ${_dec(grid['beatQqqMddPct'], 0)}%.',
                    '25 格参数邻域检验（${window == 'live_2011' ? '实盘 2011–2026' : '全周期 2000–2026'}）：均值年化 ${_dec(grid['meanCagrPct'], 2)}%（区间 ${_dec(grid['minCagrPct'], 2)}%–${_dec(grid['maxCagrPct'], 2)}%），均值夏普 ${_dec(grid['meanSharpe'], 3)}，夏普跑赢 QQQ 比例 ${_dec(grid['beatQqqSharpePct'], 0)}%，回撤优于 QQQ 比例 ${_dec(grid['beatQqqMddPct'], 0)}%（拒绝单点过拟合）。',
                  ),
                  style: s(12, false, p.muted),
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowHeight: 36,
                    dataRowMinHeight: 36,
                    dataRowMaxHeight: 42,
                    columnSpacing: 18,
                    columns: [
                      DataColumn(
                        label: Text(
                          w('Sell Peak PE \\ Buy DD', '泡沫卖出PE \\ 抄底回撤'),
                          style: s(11.5, true),
                        ),
                      ),
                      for (final dd in ddAxis)
                        DataColumn(label: Text(w('DD ≤ ${dd.toStringAsFixed(0)}%', '回撤 ≤ ${dd.toStringAsFixed(0)}%'), style: s(11.5, true))),
                    ],
                    rows: [
                      for (final sp in peAxis)
                        DataRow(
                          cells: [
                            DataCell(Text(w('Peak PE ≥ ${sp.toStringAsFixed(1)}x', '峰值 PE ≥ ${sp.toStringAsFixed(1)}x'), style: s(12, true))),
                            for (final dd in ddAxis)
                              () {
                                final cell = gridCells.firstWhere(
                                  (c) =>
                                      (number(c['sellPeakPe']) - sp).abs() < 0.01 &&
                                      (number(c['buyDrawdownPct']) - dd).abs() < 0.01,
                                  orElse: () => <String, dynamic>{},
                                );
                                final sh = number(cell['sharpe']);
                                final beat = window == 'live_2011' ? sh > 0.873 : sh > 0.362;
                                return DataCell(
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: (beat ? p.positive : _amber).withValues(alpha: 0.13),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: Text(
                                      '${_dec(cell['cagrPct'], 2)}% · ${w('Sh', '夏普')} ${_dec(sh, 3)}',
                                      style: s(11.5, true, beat ? p.positive : _amber),
                                    ),
                                  ),
                                );
                              }(),
                          ],
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

  Widget _buildLiveRadarAndSopModule() {
    final radar = asMap(data?['liveRadar']);
    final alloc = asMap(asMap(radar['allocations'])[mode]);
    final scissors = asMap(radar['scissorsDiagnostic']);
    final triggers = asMap(radar['nextTriggers']);
    final leftPlan = asMap(triggers['leftSidePanicBuy']);
    final rightPlan = asMap(triggers['rightSideTrendBuy']);
    final sopRows = asList(data?['sopTable']);
    final taxRows = asList(data?['taxSensitivity']);

    final qWeight = number(alloc['qqqWeight']);
    final bannerColor = qWeight >= 0.8 ? p.positive : qWeight <= 0.1 ? _amber : _sky;

    final gauges = [
      (
        w('QQQ Close & 2Y Drawdown', 'QQQ 收盘价与 2 年回撤'),
        '\$${_dec(radar['qqqClose'], 2)} (${_pctDirect(radar['dd2yPct'], 1)})',
        '${w('2Y Peak', '2年高点')} \$${_dec(radar['qqqPeak2y'], 2)} · SCHD \$${_dec(radar['schdClose'], 2)}',
      ),
      (
        w('Trend vs MA150 / MA200', '均线偏离度 MA150 / MA200'),
        '${_pctDirect(radar['ma150DistPct'], 2)} ${w('vs MA150', '对比 MA150')}',
        'MA150 \$${_dec(radar['qqqMa150'], 2)} · MA200 \$${_dec(radar['qqqMa200'], 2)} (${_pctDirect(radar['ma200DistPct'], 2)})',
      ),
      (
        w('Aggregate Pos-PE (90d Peak)', '纳指盈利股 Pos-PE (90日峰)'),
        '${_dec(radar['posPe'], 2)}x',
        '${w('90d Peak', '90日峰值')} ${_dec(radar['peak90Pe'], 1)}x · P/S ${_dec(radar['ps'], 2)}x',
      ),
      (
        w('FCF Yield Scissors Gauge', '自由现金流收益率 (剪刀差)'),
        '${_dec(radar['fcfYieldPct'], 2)}% (P/FCF ${_dec(radar['pFcf'], 1)}x)',
        w('Alert: < 2.35% expensive zone', '警戒：低于 2.35% 仍处现金流昂贵区'),
      ),
      (
        w('CBOE VIX / VXN Panic', 'CBOE VIX / VXN 恐慌指数'),
        'VIX ${_dec(radar['vix'], 1)} · VXN ${_dec(radar['vxn'], 1)}',
        w('Panic buy requires VIX >= 32', '左侧恐慌抄底需 VIX ≥ 32'),
      ),
      (
        w('Daily / Weekly RSI(14)', '日线 / 周线 RSI(14) 超卖度'),
        '${_dec(radar['rsi14'], 1)} / ${_dec(radar['wkRsi14'], 1)}',
        w('Oversold buy requires Daily RSI <= 28', '左侧超卖抄底需日线 RSI ≤ 28'),
      ),
    ];

    Widget buildPlanCard(Map<String, dynamic> plan, String targetBadge, Color accent) {
      final conds = asList(plan['conditions']);
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(loc(plan['title']), style: s(13.5, true, accent)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(targetBadge, style: s(11, true, accent)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final c in conds)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      c['met'] == true ? Icons.check_circle : Icons.radio_button_unchecked,
                      size: 16,
                      color: c['met'] == true ? p.positive : p.muted,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '${localizeStrategyMetricText(loc(c['metric']), context.language)} · ${w('Now', '当前')} ${localizeStrategyMetricText(loc(c['current']), context.language)} → ${w('Target', '目标')} ${localizeStrategyMetricText(loc(c['target']), context.language)}',
                        style: s(11.8, c['met'] == true),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            '03',
            w(
              'Live Signal Radar, Exact Next Triggers & Account Tax SOP (${text(radar['asOfDate'])})',
              '最新实盘信号雷达、下一步精确挂单预案与账户税务 SOP（截至 ${text(radar['asOfDate'])}）',
            ),
            subtitle: w(
              '3-minute Friday close checklist — objective valuation, trend, and panic gauges with zero guesswork.',
              '无需盯盘，每周五收盘（或市场暴跌 VIX 飙升当日）3 分钟客观核对指标，机械化执行。',
            ),
            accent: bannerColor,
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: bannerColor.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: bannerColor.withValues(alpha: 0.5), width: 1.4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${mode.toUpperCase()} ${w('MODEL TARGET STATE (RESEARCH)', '当前模型目标状态（研究参考）')}: ${loc(alloc['stateLabel'])}',
                      key: const ValueKey('rotation-live-position-banner'),
                      style: s(16, true, bannerColor),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => widget.onCompany('QQQ'),
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: Text(w('Inspect QQQ', '查看 QQQ'), style: s(11.5, true)),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => widget.onCompany('SCHD'),
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: Text(w('Inspect SCHD', '查看 SCHD'), style: s(11.5, true)),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(loc(alloc['actionInstruction']), style: s(12.5, false, p.text)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final g in gauges)
                Container(
                  width: 224,
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: p.card,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: p.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(g.$1, style: s(11, true, p.muted)),
                      const SizedBox(height: 3),
                      Text(g.$2, style: s(14.5, true)),
                      const SizedBox(height: 2),
                      Text(g.$3, style: s(10.8, false, p.muted)),
                    ],
                  ),
                ),
            ],
          ),
          if (scissors.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _amber.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: _amber.withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(loc(scissors['title']), style: s(12.8, true, _amber)),
                  const SizedBox(height: 4),
                  Text(loc(scissors['detail']), style: s(11.8, false, p.text)),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (ctx, cons) {
              final leftCard = buildPlanCard(
                leftPlan,
                text(leftPlan['qqqTargetBand']),
                p.positive,
              );
              final rightCard = buildPlanCard(
                rightPlan,
                text(rightPlan['qqqTargetLevel']),
                _sky,
              );
              if (cons.maxWidth >= 820) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: leftCard),
                    const SizedBox(width: 12),
                    Expanded(child: rightCard),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  leftCard,
                  const SizedBox(height: 10),
                  rightCard,
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('rotation-sop-rules'),
                label: Text(w('6-Stage Execution SOP Table', '六阶机械化落地 SOP 表')),
                selected: sopTab == 'sop',
                onSelected: (_) => setState(() => sopTab = 'sop'),
              ),
              ChoiceChip(
                key: const ValueKey('rotation-sop-tax'),
                label: Text(w('Account Tax Sensitivity (0% / 15% / 20% CGT)', '账户资本利得税敏感性对比 (选 M6 还是 M7?)')),
                selected: sopTab == 'tax',
                onSelected: (_) => setState(() => sopTab = 'tax'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (sopTab == 'sop')
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 36,
                dataRowMinHeight: 38,
                dataRowMaxHeight: 54,
                columnSpacing: 16,
                columns: [
                  DataColumn(label: Text(w('Stage', '阶段'), style: s(11.5, true))),
                  DataColumn(label: Text(w('Objective Trigger Thresholds', '客观量化触发阈值'), style: s(11.5, true))),
                  DataColumn(label: Text(w('M6 Action (Tax-Free)', 'M6 旗舰动作 (免税账户)'), style: s(11.5, true, _teal))),
                  DataColumn(label: Text(w('M7 Action (US Taxable)', 'M7 底仓动作 (美股应税)'), style: s(11.5, true, _sky))),
                ],
                rows: [
                  for (final r in sopRows)
                    DataRow(
                      cells: [
                        DataCell(Text(loc(r['phase']), style: s(12, true))),
                        DataCell(
                          SizedBox(
                            width: 390,
                            child: Text(loc(r['condition']), style: s(11.5)),
                          ),
                        ),
                        DataCell(Text(loc(r['actionM6']), style: s(12, true, _teal))),
                        DataCell(Text(loc(r['actionM7']), style: s(12, false, _sky))),
                      ],
                    ),
                ],
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 36,
                dataRowMinHeight: 36,
                dataRowMaxHeight: 44,
                columnSpacing: 18,
                columns: [
                  DataColumn(label: Text(w('Strategy', '策略方案'), style: s(11.5, true))),
                  DataColumn(label: Text(w('0% Tax CAGR\n(IRA / Roth / HK / SG)', '0% 免税年化\n(IRA/香港/新加坡/中东)'), style: s(11.5, true))),
                  DataColumn(label: Text(w('15% CGT CAGR', '15% 税率年化'), style: s(11.5, true))),
                  DataColumn(label: Text(w('20% CGT CAGR', '20% 税率年化'), style: s(11.5, true))),
                  DataColumn(label: Text(w('20% Tax Drag', '20% 税损拖累'), style: s(11.5, true))),
                  DataColumn(label: Text(w('Sharpe / MDD', '夏普 / 最大回撤'), style: s(11.5, true))),
                ],
                rows: [
                  for (final tr in taxRows)
                    DataRow(
                      color: const {'M6', 'M7'}.contains(text(tr['code']))
                          ? WidgetStatePropertyAll(_teal.withValues(alpha: 0.08))
                          : null,
                      cells: [
                        DataCell(Text(loc(tr['label']), style: s(12, true))),
                        DataCell(Text('${_dec(tr['taxFreeCagrPct'], 2)}%', style: s(12, true, p.positive))),
                        DataCell(Text('${_dec(tr['tax15CagrPct'], 2)}%', style: s(12, true))),
                        DataCell(Text('${_dec(tr['tax20CagrPct'], 2)}%', style: s(12, true))),
                        DataCell(Text('${_dec(tr['tax20DragPct'], 2)}%${w('/yr', '/年')}', style: s(12, false, p.muted))),
                        DataCell(
                          Text(
                            '${_dec(tr['sharpe'], 3)} / ${_dec(tr['maxDrawdownPct'], 2)}%',
                            style: s(12),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRegimeAttributionModule() {
    final regimes = asList(data?['regimeAttribution']);
    final exCol = '${mode}ExcessPct';

    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            '04',
            w(
              'Historical Crisis & Secular Bull Regime Attribution (2000–2026)',
              '十轮历史重大牛熊与危机行情逐段归因（2000–2026）',
            ),
            subtitle: w(
              'Defense via SCHD in valuation-compression tech bears (2000, 2022, 2024–25) + 100% QQQ offense at VIX/RSI capitulation troughs.',
              '杀估值科技熊市（2000科网、2022加息、2024–25关税前夕）靠 SCHD 护体；流动性恐慌极值（2002底、2022春、2025.04关税底）靠 100% 满仓 QQQ 吃满反转弹性。',
            ),
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 38,
              dataRowMinHeight: 42,
              dataRowMaxHeight: 58,
              columnSpacing: 15,
              columns: [
                DataColumn(label: Text(w('Regime & Window', '历史行情阶段与起止区间'), style: s(11.5, true))),
                DataColumn(label: Text('100% QQQ', style: s(11.5, true, _violet))),
                DataColumn(label: Text('100% SCHD', style: s(11.5, true, _amber))),
                DataColumn(label: Text(w('70/30 Static', '70/30 静态'), style: s(11.5, true, p.muted))),
                DataColumn(label: Text(w('M6 Flagship', 'M6 旗舰'), style: s(11.5, true, _teal))),
                DataColumn(label: Text(w('M4 Left', 'M4 纯左侧'), style: s(11.5, true, p.positive))),
                DataColumn(label: Text(w('M7 Core', 'M7 底仓'), style: s(11.5, true, _sky))),
                DataColumn(
                  label: Text(
                    '${mode.toUpperCase()} ${w('vs QQQ', '对比 QQQ')}',
                    style: s(11.5, true, _modeColor(mode)),
                  ),
                ),
              ],
              rows: [
                for (final rg in regimes)
                  () {
                    final isBear = text(rg['type']) == 'bear';
                    final ex = number(rg[exCol]);
                    return DataRow(
                      cells: [
                        DataCell(
                          SizedBox(
                            width: 280,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: (isBear ? p.negative : p.positive).withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        isBear ? w('BEAR', '熊市/冲击') : w('BULL', '主升牛市'),
                                        style: s(11, true, isBear ? p.negative : p.positive),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        loc(rg['label']),
                                        overflow: TextOverflow.ellipsis,
                                        style: s(12, true),
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  '${text(rg['start'])} → ${text(rg['end'])} · ${loc(rg['note'])}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: s(10.5, false, p.muted),
                                ),
                              ],
                            ),
                          ),
                        ),
                        DataCell(_pctNumCell(rg['qqqPct'])),
                        DataCell(_pctNumCell(rg['schdPct'])),
                        DataCell(_pctNumCell(rg['static7030Pct'])),
                        DataCell(_pctNumCell(rg['m6Pct'], bold: mode == 'm6')),
                        DataCell(_pctNumCell(rg['m4Pct'], bold: mode == 'm4')),
                        DataCell(_pctNumCell(rg['m7Pct'], bold: mode == 'm7')),
                        DataCell(
                          Text(
                            _pctDirect(rg[exCol], 1),
                            style: s(
                              12,
                              true,
                              ex > 0.05
                                  ? p.positive
                                  : ex < -0.05
                                      ? p.negative
                                      : p.muted,
                            ),
                          ),
                        ),
                      ],
                    );
                  }(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pctNumCell(dynamic v, {bool bold = false}) => Text(
    _pctDirect(v, 1),
    style: s(12, bold, number(v) >= 0 ? p.positive : p.negative),
  );

  Widget _buildSwitchLedgerModule() {
    final modeObj = asMap(data?['mode']);
    final winSwitches = asList(modeObj['switches']);
    final all27ySwitches = asList(modeObj['allSwitches27y']);
    final shown = ledgerScope == 'all27y' ? all27ySwitches : winSwitches;

    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
            '05',
            w(
              'Audited Historical Allocation Switch Ledger (${mode.toUpperCase()})',
              '历史真实调仓切换台账与逐笔信号复盘 (${mode.toUpperCase()})',
            ),
            subtitle: w(
              'Every T+1 allocation change with exact QQQ price, Pos-PE (90d peak), FCF Yield, 2Y drawdown, VIX, RSI14, and subsequent holding-interval alpha. Click any row to inspect.',
              '完整记录每一次 T+1 仓位切换当日的 QQQ 复权价、Pos-PE（90日峰）、FCF收益率、2年回撤、VIX、RSI14 及随后持仓区间超额保护效果（点击任一行查看复盘详情）。',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const ValueKey('rotation-ledger-window'),
                label: Text(
                  '${w('Active Window Switches', '当前周期调仓记录')} (${winSwitches.length})',
                ),
                selected: ledgerScope == 'window',
                onSelected: (_) => setState(() => ledgerScope = 'window'),
              ),
              ChoiceChip(
                key: const ValueKey('rotation-ledger-all27y'),
                label: Text(
                  '${w('All 27-Year Switches (2000–2026)', '27年全周期全部调仓 (2000–2026)')} (${all27ySwitches.length})',
                ),
                selected: ledgerScope == 'all27y',
                onSelected: (_) => setState(() => ledgerScope = 'all27y'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              showCheckboxColumn: false,
              headingRowHeight: 38,
              dataRowMinHeight: 42,
              dataRowMaxHeight: 56,
              columnSpacing: 14,
              columns: [
                DataColumn(label: Text(w('Exec Date', '执行日期'), style: s(11.5, true))),
                DataColumn(label: Text(w('QQQ Allocation Shift', 'QQQ 仓位变动'), style: s(11.5, true))),
                DataColumn(label: Text(w('Trigger Signal', '触发信号类型'), style: s(11.5, true))),
                DataColumn(label: Text(w('QQQ Adj', 'QQQ复权价'), style: s(11.5, true))),
                DataColumn(label: Text(w('Pos-PE (90d)', 'PE (90日峰)'), style: s(11.5, true))),
                DataColumn(label: Text(w('FCF%', 'FCF率'), style: s(11.5, true))),
                DataColumn(label: Text(w('DD / RSI / VIX', '回撤 / RSI / VIX'), style: s(11.5, true))),
                DataColumn(label: Text(w('Interval Strat vs QQQ', '持仓期收益 vs QQQ'), style: s(11.5, true))),
              ],
              rows: [
                for (final sw in shown.reversed)
                  () {
                    final buy = text(sw['direction']) == 'buy_qqq';
                    final fromQ = (number(sw['fromQqqWeight']) * 100).toStringAsFixed(0);
                    final toQ = (number(sw['toQqqWeight']) * 100).toStringAsFixed(0);
                    final ex = number(sw['intervalExcessVsQqq']);
                    return DataRow(
                      onSelectChanged: (_) => _showSwitchDialog(sw),
                      cells: [
                        DataCell(Text(text(sw['date']), style: s(12, true))),
                        DataCell(
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: (buy ? p.positive : _amber).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              '$fromQ% → $toQ% QQQ',
                              style: s(11.5, true, buy ? p.positive : _amber),
                            ),
                          ),
                        ),
                        DataCell(
                          SizedBox(
                            width: 210,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  loc(sw['signalLabel']),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: s(12, true),
                                ),
                                Text(
                                  loc(sw['explanation']),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: s(10.5, false, p.muted),
                                ),
                              ],
                            ),
                          ),
                        ),
                        DataCell(Text('\$${_dec(sw['qqqAdj'], 2)}', style: s(12, true))),
                        DataCell(
                          Text(
                            '${_dec(sw['posPe'], 1)}x (${_dec(sw['peak90Pe'], 1)}x)',
                            style: s(11.8),
                          ),
                        ),
                        DataCell(Text('${_dec(sw['fcfYieldPct'], 2)}%', style: s(11.8))),
                        DataCell(
                          Text(
                            '${_dec(sw['dd2yPct'], 1)}% / ${_dec(sw['rsi14'], 1)} / ${_dec(sw['vix'], 1)}',
                            style: s(11.8),
                          ),
                        ),
                        DataCell(
                          Text(
                            '${_pct(sw['intervalStrategyReturn'], 1)} vs ${_pct(sw['intervalQqqReturn'], 1)} (${_pct(ex, 1)})',
                            style: s(11.8, true, ex >= 0 ? p.positive : p.muted),
                          ),
                        ),
                      ],
                    );
                  }(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showSwitchDialog(Map<String, dynamic> sw) {
    final fromQ = (number(sw['fromQqqWeight']) * 100).toStringAsFixed(1);
    final toQ = (number(sw['toQqqWeight']) * 100).toStringAsFixed(1);
    final toS = (number(sw['toSchdWeight']) * 100).toStringAsFixed(1);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        title: Text(
          '${text(sw['switchId'])} · ${text(sw['date'])} · ${loc(sw['signalLabel'])}',
          style: s(16.5, true),
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${w('Signal Date (T)', '信号触发日 (T)')}: ${text(sw['signalDate'])} → ${w('Execution Date (T+1)', '收盘执行日 (T+1)')}: ${text(sw['date'])}',
                  style: s(12, true, _teal),
                ),
                const SizedBox(height: 6),
                Text(
                  '${w('Target Allocation', '目标配比')}: $fromQ% QQQ → $toQ% QQQ : $toS% SCHD (${sw['holdingDays']} ${w('trading days until', '个交易日至')} ${text(sw['nextSwitchDate'])})',
                  style: s(12.5, true),
                ),
                const SizedBox(height: 10),
                Text(loc(sw['explanation']), style: s(12.5)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    _miniTag('QQQ \$${_dec(sw['qqqAdj'], 2)}', _teal, true),
                    _miniTag('Pos-PE ${_dec(sw['posPe'], 1)}x (Peak ${_dec(sw['peak90Pe'], 1)}x)', _teal, false),
                    _miniTag('FCF ${_dec(sw['fcfYieldPct'], 2)}%', _teal, false),
                    _miniTag('2Y DD ${_dec(sw['dd2yPct'], 1)}%', _amber, false),
                    _miniTag('VIX ${_dec(sw['vix'], 1)} (T: ${_dec(sw['signalDayVix'], 1)})', _amber, false),
                    _miniTag('RSI14 ${_dec(sw['rsi14'], 1)} (T: ${_dec(sw['signalDayRsi14'], 1)})', _sky, false),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '${w('Holding Interval Return', '随后持仓区间表现')}: ${mode.toUpperCase()} ${_pct(sw['intervalStrategyReturn'])} · QQQ ${_pct(sw['intervalQqqReturn'])} · SCHD ${_pct(sw['intervalSchdReturn'])} (${w('Alpha vs QQQ', '相对QQQ超额')} ${_pct(sw['intervalExcessVsQqq'])})',
                  style: s(12, true, number(sw['intervalExcessVsQqq']) >= 0 ? p.positive : p.muted),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(w('Close', '关闭')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onCompany('QQQ');
            },
            child: Text(w('Research QQQ', '研究 QQQ')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return _panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(
                'Loading audited QQQ ⇄ SCHD Valuation & Panic Rotation portfolio…',
                '正在读取已校验的 QQQ ⇄ SCHD 估值与恐慌共振轮动策略组合…',
              ),
              style: s(),
            ),
            const SizedBox(height: 12),
            const LinearProgressIndicator(color: _teal),
          ],
        ),
      );
    }

    if (failed || data == null) {
      return _panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(
                'QQQ ⇄ SCHD Rotation portfolio could not be loaded.',
                '暂时无法读取 QQQ ⇄ SCHD 估值恐慌轮动策略组合。',
              ),
              style: s(16, true),
            ),
            const SizedBox(height: 4),
            Text(
              w(
                'No synthetic returns are substituted. Please retry.',
                '绝不使用模拟示例数据替代，请点击重试。',
              ),
              style: s(12, false, p.muted),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: load,
              icon: const Icon(Icons.refresh),
              label: Text(w('Retry', '重试')),
            ),
          ],
        ),
      );
    }

    final curve = asList(asMap(data?['backtest'])['curve']);
    if (curve.length < 2) {
      return _panel(
        Text(
          w(
            'No observed QQQ ⇄ SCHD backtest history is available before this cutoff (${widget.asOf}).',
            '该截止日（${widget.asOf}）之前尚无可用回测历史记录。',
          ),
          style: s(14),
        ),
      );
    }

    final radar = asMap(data?['liveRadar']);
    final alloc = asMap(asMap(radar['allocations'])[mode]);
    final qWeight = number(alloc['qqqWeight']);
    final stripColor = qWeight >= 0.8 ? p.positive : qWeight <= 0.1 ? _amber : _sky;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (radar.isNotEmpty) ...[
          Container(
            key: const ValueKey('rotation-top-live-strip'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: stripColor.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: stripColor.withValues(alpha: 0.45)),
            ),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.bolt_rounded, size: 17, color: stripColor),
                Text(
                  '${mode.toUpperCase()} ${w('Model Target State', '当前模型目标状态')} (${text(radar['asOfDate'], widget.asOf)}): ${loc(alloc['stateLabel'])}',
                  style: s(13, true),
                ),
                Text(
                  'VIX ${_dec(radar['vix'], 1)} · Pos-PE ${_dec(radar['posPe'], 1)}x',
                  style: s(12, false, p.muted),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('rotation-jump-radar'),
                  onPressed: () {
                    final ctx = _liveRadarKey.currentContext;
                    if (ctx != null) {
                      Scrollable.ensureVisible(
                        ctx,
                        duration: const Duration(milliseconds: 260),
                        alignment: 0.05,
                      );
                    }
                  },
                  icon: const Icon(Icons.arrow_downward_rounded, size: 14),
                  label: Text(
                    w('Signal Radar & Triggers ↓', '信号雷达与触发预案 ↓'),
                    style: s(11.5, true),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        _buildModeAndWindowBar(curve),
        const SizedBox(height: 16),
        _buildPerformanceModule(curve),
        const SizedBox(height: 16),
        _buildBlueprintAndShowdownModule(),
        const SizedBox(height: 16),
        Container(
          key: _liveRadarKey,
          child: _buildLiveRadarAndSopModule(),
        ),
        const SizedBox(height: 16),
        _buildRegimeAttributionModule(),
        const SizedBox(height: 16),
        _buildSwitchLedgerModule(),
      ],
    );
  }
}

class _RotationEquityChartPainter extends CustomPainter {
  _RotationEquityChartPainter({
    required this.rows,
    required this.enabledCurves,
    required this.logScale,
    required this.showDrawdown,
    required this.hoverIndex,
    required this.palette,
    required this.colorFor,
  });

  final List<Map<String, dynamic>> rows;
  final Set<String> enabledCurves;
  final bool logScale;
  final bool showDrawdown;
  final int hoverIndex;
  final Palette palette;
  final Color Function(String) colorFor;

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.length < 2) return;
    const leftPad = 48.0;
    const rightPad = 12.0;
    const topPad = 10.0;
    const botPad = 22.0;
    final plotW = math.max(1.0, size.width - leftPad - rightPad);
    final plotH = math.max(1.0, size.height - topPad - botPad);

    final activeKeys = ['m6', 'm4', 'm7', 'qqq', 'schd', 'static7030']
        .where(enabledCurves.contains)
        .toList();
    if (activeKeys.isEmpty) return;

    double minY = double.infinity;
    double maxY = -double.infinity;
    final baseRow = rows.first;

    double mapRaw(Map<String, dynamic> r, String k) {
      if (showDrawdown) {
        return number(r['${k}Dd']) * 100.0;
      }
      final b = number(baseRow[k]);
      final mult = b > 0 ? number(r[k]) / b : 1.0;
      return logScale ? math.log(math.max(mult, 1e-4)) : mult;
    }

    for (final k in activeKeys) {
      for (final r in rows) {
        final v = mapRaw(r, k);
        if (v < minY) minY = v;
        if (v > maxY) maxY = v;
      }
    }
    if (!minY.isFinite || !maxY.isFinite) return;
    if ((maxY - minY).abs() < 1e-6) {
      maxY += 0.5;
      minY -= 0.5;
    } else {
      final pad = (maxY - minY) * 0.06;
      if (!showDrawdown) minY -= pad * 0.5;
      maxY += pad;
      if (showDrawdown) minY -= pad;
    }

    double toX(int i) => leftPad + (i / (rows.length - 1)) * plotW;
    double toY(double v) => topPad + (1.0 - (v - minY) / (maxY - minY)) * plotH;

    final gridPaint = Paint()
      ..color = palette.border.withValues(alpha: 0.55)
      ..strokeWidth = 0.8;

    for (var g = 0; g <= 4; g++) {
      final yVal = minY + (maxY - minY) * (g / 4.0);
      final py = toY(yVal);
      canvas.drawLine(Offset(leftPad, py), Offset(leftPad + plotW, py), gridPaint);
      final label = showDrawdown
          ? '${yVal.toStringAsFixed(0)}%'
          : '${(logScale ? math.exp(yVal) : yVal).toStringAsFixed(yVal > 2.2 || !logScale && yVal > 9 ? 1 : 2)}x';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(fontSize: 10, color: palette.muted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(math.max(0, leftPad - tp.width - 6), py - tp.height / 2));
    }

    // X-axis date ticks
    for (final frac in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final idx = (frac * (rows.length - 1)).round();
      final px = toX(idx);
      final dLabel = text(rows[idx]['date']).substring(0, 7);
      final tp = TextPainter(
        text: TextSpan(
          text: dLabel,
          style: TextStyle(fontSize: 10, color: palette.muted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = (px - tp.width / 2).clamp(leftPad, leftPad + plotW - tp.width);
      tp.paint(canvas, Offset(dx, topPad + plotH + 5));
    }

    final stride = math.max(1, (rows.length / 900).ceil());
    for (final k in activeKeys.reversed) {
      final isPrimary = const {'m6', 'm4', 'm7'}.contains(k);
      final path = Path();
      var started = false;
      for (var i = 0; i < rows.length; i += stride) {
        final pt = Offset(toX(i), toY(mapRaw(rows[i], k)));
        if (!started) {
          path.moveTo(pt.dx, pt.dy);
          started = true;
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      if ((rows.length - 1) % stride != 0) {
        path.lineTo(toX(rows.length - 1), toY(mapRaw(rows.last, k)));
      }
      final paint = Paint()
        ..color = colorFor(k)
        ..style = PaintingStyle.stroke
        ..strokeWidth = isPrimary ? 2.3 : 1.35;
      canvas.drawPath(path, paint);
    }

    if (hoverIndex >= 0 && hoverIndex < rows.length) {
      final hx = toX(hoverIndex);
      canvas.drawLine(
        Offset(hx, topPad),
        Offset(hx, topPad + plotH),
        Paint()
          ..color = palette.muted.withValues(alpha: 0.6)
          ..strokeWidth = 1.0,
      );
      for (final k in activeKeys) {
        final hy = toY(mapRaw(rows[hoverIndex], k));
        canvas.drawCircle(Offset(hx, hy), 3.4, Paint()..color = colorFor(k));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RotationEquityChartPainter old) =>
      old.rows != rows ||
      old.logScale != logScale ||
      old.showDrawdown != showDrawdown ||
      old.hoverIndex != hoverIndex ||
      old.enabledCurves.length != enabledCurves.length;
}

class _RotationWeightRibbonPainter extends CustomPainter {
  _RotationWeightRibbonPainter({
    required this.rows,
    required this.weightKey,
    required this.hoverIndex,
    required this.palette,
    required this.teal,
    required this.amber,
    required this.sky,
  });

  final List<Map<String, dynamic>> rows;
  final String weightKey;
  final int hoverIndex;
  final Palette palette;
  final Color teal;
  final Color amber;
  final Color sky;

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.length < 2) return;
    const leftPad = 48.0;
    const rightPad = 12.0;
    const topPad = 4.0;
    const botPad = 6.0;
    final plotW = math.max(1.0, size.width - leftPad - rightPad);
    final plotH = math.max(1.0, size.height - topPad - botPad);

    double toX(int i) => leftPad + (i / (rows.length - 1)) * plotW;

    // Background SCHD shield fill
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(leftPad, topPad, plotW, plotH),
        const Radius.circular(4),
      ),
      Paint()..color = sky.withValues(alpha: 0.28),
    );

    // Paint contiguous weight segments cleanly
    int segStart = 0;
    double curW = number(rows[0][weightKey]);
    for (var i = 1; i <= rows.length; i++) {
      final wVal = i < rows.length ? number(rows[i][weightKey]) : -1.0;
      if ((wVal - curW).abs() > 1e-3 || i == rows.length) {
        if (curW > 0.001) {
          final x0 = toX(segStart);
          final x1 = toX(i - 1);
          final h = plotH * curW.clamp(0.0, 1.0);
          final c = curW >= 0.95
              ? teal.withValues(alpha: 0.72)
              : curW > 0.52
                  ? amber.withValues(alpha: 0.78)
                  : sky.withValues(alpha: 0.55);
          canvas.drawRect(
            Rect.fromLTWH(x0, topPad + (plotH - h), math.max(1.2, x1 - x0), h),
            Paint()..color = c,
          );
        }
        segStart = i;
        curW = wVal;
      }
    }

    for (final pct in [100, 0]) {
      final py = pct == 100 ? topPad + 2 : topPad + plotH - 10;
      final tp = TextPainter(
        text: TextSpan(
          text: '$pct%',
          style: TextStyle(fontSize: 9.5, color: palette.muted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(math.max(0, leftPad - tp.width - 6), py));
    }

    if (hoverIndex >= 0 && hoverIndex < rows.length) {
      final hx = toX(hoverIndex);
      canvas.drawLine(
        Offset(hx, topPad),
        Offset(hx, topPad + plotH),
        Paint()
          ..color = palette.text
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RotationWeightRibbonPainter old) =>
      old.rows != rows ||
      old.weightKey != weightKey ||
      old.hoverIndex != hoverIndex;
}
