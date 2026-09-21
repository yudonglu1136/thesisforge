part of 'main.dart';

// Retained as a pure compatibility helper for saved local filters and tests.
// The redesigned discovery API already ranks its compact server result.
List<Map<String, dynamic>> filterFundamentals(
  List<Map<String, dynamic>> input, {
  String screen = 'all',
  String query = '',
  String sort = 'change',
  bool belowValue = false,
  FundamentalRules rules = const FundamentalRules(),
}) {
  final result = input.where((row) {
    final screens = (row['screens'] as List? ?? const []);
    final screenPass = screen == 'combined'
        ? rules.accepts(row)
        : screen == 'all' || screens.contains(screen);
    final queryPass = '${row['ticker']} ${row['name']}'.toLowerCase().contains(
      query.trim().toLowerCase(),
    );
    final gap = nullableNumber(row['modelGap']);
    return screenPass && queryPass && (!belowValue || gap != null && gap > 0);
  }).toList();
  double? sortValue(Map<String, dynamic> row) {
    if (sort == 'value') return nullableNumber(row['modelGap']);
    if (sort == 'growth') {
      return nullableNumber(asMap(row['metrics'])['revenueGrowth']);
    }
    final key = screen == 'profit'
        ? 'operatingMargin'
        : {'cash', 'divergence'}.contains(screen)
        ? 'fcfMargin'
        : 'revenueGrowth';
    return nullableNumber(asMap(row['changes'])[key]);
  }

  result.sort((a, b) {
    if (sort == 'matches') {
      final matched = rules.hits(b).compareTo(rules.hits(a));
      if (matched != 0) return matched;
    } else {
      final av = sortValue(a), bv = sortValue(b);
      if (av == null && bv != null) return 1;
      if (bv == null && av != null) return -1;
      final ordered = sort == 'change' && screen == 'divergence'
          ? (av ?? 0).compareTo(bv ?? 0)
          : (bv ?? 0).compareTo(av ?? 0);
      if (ordered != 0) return ordered;
    }
    return text(a['ticker']).compareTo(text(b['ticker']));
  });
  return result;
}

const _fundamentalLenses = <String>[
  'growth_profit_sync',
  'slowing_growth_margin_up',
  'profit_cash_weakening',
  'per_share_dilution',
  'capital_return_pending',
  'operating_pricing_divergence',
];

class FundamentalsPanel extends StatefulWidget {
  const FundamentalsPanel({
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
  final void Function(String ticker, String section) onCompany;
  final Map<String, dynamic> initialSelection;
  final ValueChanged<Map<String, dynamic>>? onSelection;
  @override
  State<FundamentalsPanel> createState() => _FundamentalsPanelState();
}

class _FundamentalsPanelState extends State<FundamentalsPanel> {
  final search = TextEditingController();
  final detailAnchor = GlobalKey();
  Map<String, dynamic>? data, detail, institutionalDetail;
  List<Map<String, dynamic>> observations = const [];
  String lens = 'slowing_growth_margin_up', ticker = '';
  String detailTab = 'business';
  bool loading = true,
      failed = false,
      detailLoading = false,
      detailFailed = false,
      institutionalLoading = false,
      institutionalFailed = false;
  bool mobileDetail = false, saving = false;
  double? minGrowth, minMargin, minFcfMargin;
  int serial = 0, detailSerial = 0, institutionalSerial = 0;
  final institutionalCache = <String, Map<String, dynamic>>{};
  Timer? debounce;
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  TextStyle st([
    double size = 14,
    bool bold = false,
    Color? color,
    double height = 1.35,
  ]) => TextStyle(
    fontSize: size,
    height: height,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? p.text,
  );
  String bi(dynamic value) {
    final row = asMap(value);
    return w(text(row['en']), text(row['zh']));
  }

  String pct(dynamic value, {int digits = 1, bool sign = true}) {
    final v = nullableNumber(value);
    return v == null
        ? '—'
        : '${sign && v >= 0 ? '+' : ''}${(v * 100).toStringAsFixed(digits)}%';
  }

  String amount(dynamic value) {
    final v = nullableNumber(value);
    if (v == null) return '—';
    final a = v.abs(), s = v < 0 ? '-' : '';
    if (a >= 1e12) return '$s${(a / 1e12).toStringAsFixed(1)}T';
    if (a >= 1e9) return '$s${(a / 1e9).toStringAsFixed(1)}B';
    if (a >= 1e6) return '$s${(a / 1e6).toStringAsFixed(1)}M';
    return v.toStringAsFixed(1);
  }

  List<Map<String, dynamic>> get rows => asList(data?['rows']).where((row) {
    final m = asMap(row['metrics']),
        g = nullableNumber(m['revenueGrowth']),
        margin = nullableNumber(m['operatingMargin']),
        fcf = nullableNumber(m['fcfMargin']);
    return (minGrowth == null || g != null && g >= minGrowth!) &&
        (minMargin == null || margin != null && margin >= minMargin!) &&
        (minFcfMargin == null || fcf != null && fcf >= minFcfMargin!);
  }).toList();

  @override
  void initState() {
    super.initState();
    final saved = widget.initialSelection;
    final restored = text(saved['lens'], text(saved['screen']));
    if (_fundamentalLenses.contains(restored)) lens = restored;
    ticker = text(saved['ticker']);
    search.text = text(saved['query']);
    minGrowth = nullableNumber(saved['minRevenueGrowth']);
    minMargin = nullableNumber(saved['minOperatingMargin']);
    minFcfMargin = nullableNumber(saved['minFcfMargin']);
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant FundamentalsPanel old) {
    super.didUpdateWidget(old);
    if (old.asOf != widget.asOf || old.api != widget.api) unawaited(load());
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    serial++;
    detailSerial++;
    institutionalSerial++;
    super.dispose();
  }

  void remember() => widget.onSelection?.call({
    'lens': lens,
    'ticker': ticker,
    'query': search.text,
    'minRevenueGrowth': minGrowth,
    'minOperatingMargin': minMargin,
    'minFcfMargin': minFcfMargin,
  });

  Future<void> load() async {
    final id = ++serial;
    setState(() {
      loading = true;
      failed = false;
    });
    final uri = Uri(
      path: '/api/investment/fundamentals',
      queryParameters: {
        'asOf': widget.asOf,
        'lens': lens,
        if (search.text.trim().isNotEmpty) 'search': search.text.trim(),
        if (minGrowth != null) 'minRevenueGrowth': '$minGrowth',
        if (minMargin != null) 'minOperatingMargin': '$minMargin',
        if (minFcfMargin != null) 'minFcfMargin': '$minFcfMargin',
        'limit': '80',
      },
    );
    try {
      final result = await widget.api.getJson(uri.toString());
      if (result['version'] != 'fundamental-research-v2' ||
          result['asOf'] != widget.asOf) {
        throw StateError('fundamental_cutoff_mismatch');
      }
      if (!mounted || id != serial) return;
      setState(() {
        data = result;
        loading = false;
        final available = rows;
        if (!available.any((row) => row['ticker'] == ticker)) {
          ticker = text(
            available
                .where((row) => row['ticker'] == 'UBER')
                .firstOrNull?['ticker'],
            text(available.firstOrNull?['ticker']),
          );
        }
      });
      remember();
      if (ticker.isNotEmpty) unawaited(loadDetail());
    } catch (_) {
      if (mounted && id == serial) {
        setState(() {
          loading = false;
          failed = true;
        });
      }
    }
  }

  Future<void> loadDetail() async {
    if (ticker.isEmpty) return;
    final id = ++detailSerial, symbol = ticker;
    setState(() {
      detailLoading = true;
      detailFailed = false;
      detail = null;
      observations = const [];
      institutionalDetail = null;
      institutionalFailed = false;
      institutionalLoading = false;
    });
    try {
      final result = await widget.api.getJson(
        '/api/investment/fundamentals/${Uri.encodeComponent(symbol)}?asOf=${widget.asOf}&lens=${Uri.encodeQueryComponent(lens)}',
      );
      if (result['version'] != 'fundamental-research-v2' ||
          result['ticker'] != symbol ||
          result['asOf'] != widget.asOf) {
        throw StateError('fundamental_company_mismatch');
      }
      if (mounted && id == detailSerial) {
        setState(() => detail = result);
        unawaited(loadObservations(symbol));
      }
    } catch (_) {
      if (mounted && id == detailSerial) setState(() => detailFailed = true);
    } finally {
      if (mounted && id == detailSerial) setState(() => detailLoading = false);
    }
  }

  Future<void> loadObservations(String symbol) async {
    try {
      final uri = Uri(
        path: '/api/investment/fundamental-observations',
        queryParameters: {'ticker': symbol},
      );
      final result = await widget.api.getJson(uri.toString());
      if (!mounted || symbol != ticker) return;
      setState(() => observations = asList(result['rows']));
    } catch (_) {
      // The private journal is optional; company evidence remains usable.
    }
  }

  void scheduleSearch(String _) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 260), () {
      if (mounted) unawaited(load());
    });
  }

  void selectLens(String value) {
    if (value == lens) return;
    setState(() {
      lens = value;
      mobileDetail = false;
      ticker = '';
    });
    remember();
    unawaited(load());
  }

  void selectCompany(Map<String, dynamic> row, bool compact) {
    setState(() {
      ticker = text(row['ticker']);
      mobileDetail = compact;
      detailTab = 'business';
    });
    remember();
    unawaited(loadDetail());
    if (compact) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = detailAnchor.currentContext;
        if (mounted && target != null) {
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 220),
          );
        }
      });
    }
  }

  void selectDetailTab(String value) {
    if (detailTab == value) return;
    setState(() => detailTab = value);
    if (value == '13f') unawaited(loadInstitutionalDetail());
  }

  Future<void> loadInstitutionalDetail() async {
    if (ticker.isEmpty) return;
    final symbol = ticker, cacheKey = '${widget.asOf}|$symbol';
    final cached = institutionalCache[cacheKey];
    if (cached != null) {
      if (mounted && symbol == ticker) {
        setState(() {
          institutionalDetail = cached;
          institutionalFailed = false;
        });
      }
      return;
    }
    final id = ++institutionalSerial;
    setState(() {
      institutionalLoading = true;
      institutionalFailed = false;
    });
    try {
      final result = await widget.api.getJson(
        '/api/investment/13f-insights/${Uri.encodeComponent(symbol)}?asOf=${widget.asOf}',
      );
      if (text(result['ticker']) != symbol ||
          text(result['asOf']) != widget.asOf) {
        throw StateError('institutional_detail_mismatch');
      }
      if (!mounted || id != institutionalSerial || symbol != ticker) return;
      institutionalCache[cacheKey] = result;
      setState(() => institutionalDetail = result);
    } catch (_) {
      if (mounted && id == institutionalSerial && symbol == ticker) {
        setState(() => institutionalFailed = true);
      }
    } finally {
      if (mounted && id == institutionalSerial) {
        setState(() => institutionalLoading = false);
      }
    }
  }

  Widget panel(
    Widget child, {
    EdgeInsets padding = const EdgeInsets.all(18),
    Color? color,
  }) => Material(
    color: color ?? p.panel,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: p.border),
      borderRadius: BorderRadius.circular(12),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
  Widget statusPill(String label, {Color? color}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: (color ?? p.accent).withValues(alpha: .10),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(label, style: st(10, true, color ?? p.accent)),
  );
  String lensTitle(String id) => switch (id) {
    'growth_profit_sync' => w('Growth + profit', '增长与盈利同步改善'),
    'slowing_growth_margin_up' => w(
      'Slower growth, better margin',
      '增长减速、盈利改善',
    ),
    'profit_cash_weakening' => w('Profit up, cash weaker', '利润增长、现金转化走弱'),
    'per_share_dilution' => w('Per-share dilution', '公司增长、每股结果被稀释'),
    'capital_return_pending' => w('Capital awaiting return', '资本投入增加、回报待兑现'),
    _ => w('Operations vs price', '经营变化与市场定价分歧'),
  };
  IconData lensIcon(String id) => switch (id) {
    'growth_profit_sync' => Icons.trending_up,
    'slowing_growth_margin_up' => Icons.swap_vert,
    'profit_cash_weakening' => Icons.water_drop_outlined,
    'per_share_dilution' => Icons.call_split,
    'capital_return_pending' => Icons.construction_outlined,
    _ => Icons.balance_outlined,
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, c) {
      final compact = c.maxWidth < 900;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w('Business change research', '企业经营研究工作台'),
                      style: st(compact ? 27 : 34, true, null, 1.12),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      w(
                        'Find a change, inspect its drivers, look for contrary evidence, then test what the price assumes.',
                        '发现经营变化，理解变化驱动，检查相反证据，再判断市场定价。',
                      ),
                      style: st(14, false, p.muted),
                    ),
                  ],
                ),
              ),
              if (!compact)
                statusPill(w('Fact OS · reported PIT', 'Fact OS · 原始披露 PIT')),
            ],
          ),
          const SizedBox(height: 18),
          _lensStrip(compact),
          const SizedBox(height: 12),
          _searchAndAdvanced(),
          const SizedBox(height: 12),
          if (loading)
            _loadingState()
          else if (failed)
            _errorState()
          else if (rows.isEmpty)
            _emptyState()
          else if (compact && mobileDetail) ...[
            SizedBox(key: detailAnchor),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => mobileDetail = false),
                icon: const Icon(Icons.arrow_back),
                label: Text(w('Back to changes', '返回变化列表')),
              ),
            ),
            _detailPanel(),
          ] else if (compact)
            _resultList(true)
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 4, child: _resultList(false)),
                const SizedBox(width: 16),
                Expanded(flex: 6, child: _detailPanel()),
              ],
            ),
          const SizedBox(height: 16),
          _methodNote(),
        ],
      );
    },
  );

  Widget _lensStrip(bool compact) => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.radar, color: p.accent, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                w('Start with a research question', '先从值得研究的变化开始'),
                style: st(14, true),
              ),
            ),
            if (!compact)
              Text(
                w('Not a score or buy signal', '不是评分或买入信号'),
                style: st(11, false, p.muted),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: compact ? 54 : 62,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _fundamentalLenses.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, index) {
              final id = _fundamentalLenses[index],
                  selected = id == lens,
                  count = asMap(data?['counts'])[id];
              return ChoiceChip(
                key: ValueKey('fund-lens-$id'),
                avatar: Icon(
                  lensIcon(id),
                  size: 16,
                  color: selected ? p.background : p.muted,
                ),
                label: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lensTitle(id)),
                    if (count != null)
                      Text(
                        '$count',
                        style: st(
                          9,
                          false,
                          selected
                              ? p.background.withValues(alpha: .75)
                              : p.muted,
                        ),
                      ),
                  ],
                ),
                selected: selected,
                onSelected: (_) => selectLens(id),
              );
            },
          ),
        ),
      ],
    ),
  );

  Widget _searchAndAdvanced() => Column(
    children: [
      panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune, color: p.accent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    w('Set your evidence thresholds', '调整你的筛选参数'),
                    style: st(14, true),
                  ),
                ),
                if ([minGrowth, minMargin, minFcfMargin].any((v) => v != null))
                  TextButton.icon(
                    key: const ValueKey('fundamental-clear-thresholds'),
                    onPressed: () {
                      setState(() {
                        minGrowth = null;
                        minMargin = null;
                        minFcfMargin = null;
                      });
                      remember();
                      unawaited(load());
                    },
                    icon: const Icon(Icons.restart_alt, size: 16),
                    label: Text(w('Clear', '清除')),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _filterCard(
                    key: const ValueKey('fund-filter-growth'),
                    icon: Icons.trending_up,
                    title: w('Revenue growth', '收入增速'),
                    subtitle: w('Quarterly YoY', '单季度同比'),
                    value: minGrowth,
                    onChanged: (value) => _changeThreshold('growth', value),
                  ),
                  const SizedBox(width: 10),
                  _filterCard(
                    key: const ValueKey('fund-filter-margin'),
                    icon: Icons.show_chart,
                    title: w('Profitability', '盈利能力'),
                    subtitle: w('TTM operating margin', 'TTM 经营利润率'),
                    value: minMargin,
                    onChanged: (value) => _changeThreshold('margin', value),
                  ),
                  const SizedBox(width: 10),
                  _filterCard(
                    key: const ValueKey('fund-filter-fcf'),
                    icon: Icons.water_drop_outlined,
                    title: w('Cash flow', '现金流'),
                    subtitle: w('TTM FCF margin', 'TTM FCF 利润率'),
                    value: minFcfMargin,
                    onChanged: (value) => _changeThreshold('fcf', value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              w(
                'These are user filters on reported Fact OS metrics; they do not change the signal formulas or create a stock rating.',
                '这些参数只筛选 Fact OS 已披露指标，不会修改信号公式，也不会生成股票评分。',
              ),
              style: st(9, false, p.muted),
            ),
          ],
        ),
        padding: const EdgeInsets.all(14),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('fundamental-search'),
              controller: search,
              onChanged: scheduleSearch,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: w(
                  'Search every Fact OS company — valuation model not required',
                  '搜索全部 Fact OS 公司——不要求已有估值模型',
                ),
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          search.clear();
                          unawaited(load());
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          ),
        ],
      ),
    ],
  );

  void _changeThreshold(String kind, double? value) {
    setState(() {
      if (kind == 'growth') minGrowth = value;
      if (kind == 'margin') minMargin = value;
      if (kind == 'fcf') minFcfMargin = value;
    });
    remember();
    unawaited(load());
  }

  Widget _filterCard({
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required double? value,
    required ValueChanged<double?> onChanged,
  }) => Container(
    key: key,
    width: 238,
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 9),
    decoration: BoxDecoration(
      color: value == null ? p.card : p.accent.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(
        color: value == null ? p.border : p.accent.withValues(alpha: .55),
      ),
    ),
    child: Row(
      children: [
        Icon(icon, size: 18, color: value == null ? p.muted : p.accent),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: st(12, true)),
              Text(subtitle, style: st(9, false, p.muted)),
            ],
          ),
        ),
        DropdownButton<double?>(
          key: ValueKey('$title-$value'),
          value: value,
          dropdownColor: p.card,
          underline: const SizedBox.shrink(),
          items: [
            DropdownMenuItem(value: null, child: Text(w('Any', '不限'))),
            for (final option in const [
              -.10,
              0.0,
              .05,
              .10,
              .15,
              .20,
              .25,
              .30,
            ])
              DropdownMenuItem(
                value: option,
                child: Text('${(option * 100).round()}%'),
              ),
          ],
          onChanged: onChanged,
        ),
      ],
    ),
  );

  Widget _loadingState() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LinearProgressIndicator(minHeight: 2),
        const SizedBox(height: 14),
        Text(
          w('Scanning compact reported facts…', '正在扫描紧凑的已披露事实…'),
          style: st(14, true),
        ),
        const SizedBox(height: 5),
        Text(
          w(
            'Company history and sources load only after you select a result.',
            '只有点选结果后才加载公司历史和来源。',
          ),
          style: st(11, false, p.muted),
        ),
      ],
    ),
  );
  Widget _errorState() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w('Fundamental facts could not be read.', '基本面事实暂时无法读取。'),
          style: st(18, true),
        ),
        const SizedBox(height: 7),
        Text(
          w('No cached valuation-model list is substituted.', '不会用估值模型旧列表替代。'),
          style: st(12, false, p.muted),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => unawaited(load()),
          child: Text(w('Retry Fact OS', '重试 Fact OS')),
        ),
      ],
    ),
  );
  Widget _emptyState() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w('No comparable changes match this view.', '当前视图没有可比变化。'),
          style: st(18, true),
        ),
        const SizedBox(height: 6),
        Text(
          w(
            'Try another question, clear the search, or relax advanced filters.',
            '请更换研究问题、清除搜索或放宽高级筛选。',
          ),
          style: st(12, false, p.muted),
        ),
        TextButton(
          onPressed: () {
            search.clear();
            setState(() {
              minGrowth = null;
              minMargin = null;
              minFcfMargin = null;
            });
            remember();
            unawaited(load());
          },
          child: Text(w('Reset', '重置')),
        ),
      ],
    ),
  );

  Widget _resultList(bool compact) => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${lensTitle(lens)} · ${data?['totalMatches'] ?? rows.length}',
                    style: st(18, true),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    bi(data?['rankingBasis']),
                    style: st(10, false, p.muted),
                  ),
                ],
              ),
            ),
            Text(
              '${asMap(data?['coverage'])['factCompanies'] ?? '—'} ${w('fact companies', '家事实公司')}',
              style: st(10, true, p.accent),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final row in rows) _resultRow(row, compact),
      ],
    ),
    padding: const EdgeInsets.all(14),
  );
  Widget _resultRow(Map<String, dynamic> row, bool compact) {
    final selected = row['ticker'] == ticker;
    final signal = asMap(row['primarySignal']);
    final metrics = asMap(row['metrics']);
    return Material(
      color: selected ? p.accent.withValues(alpha: .07) : Colors.transparent,
      child: InkWell(
        key: ValueKey('fund-row-${row['ticker']}'),
        onTap: () => selectCompany(row, compact),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: p.border),
              left: BorderSide(
                color: selected ? p.accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _tickerMark(text(row['ticker'])),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${row['ticker']}  ${row['name']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: st(14, true),
                        ),
                        Text(
                          '${row['period_end']} · ${w('available', '可用')} ${row['available_at']}',
                          style: st(10, false, p.muted),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 17),
                ],
              ),
              const SizedBox(height: 10),
              Text(bi(signal['summary']), style: st(12, true)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 5,
                children: [
                  _miniMetric(
                    w('Revenue', '收入'),
                    pct(metrics['revenueGrowth']),
                  ),
                  _miniMetric(
                    w('Op. margin', '经营利润率'),
                    pct(metrics['operatingMargin'], sign: false),
                  ),
                  _miniMetric(
                    w('FCF margin', 'FCF 率'),
                    pct(metrics['fcfMargin'], sign: false),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.help_outline, size: 14, color: p.secondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      bi(signal['question']),
                      style: st(10, false, p.secondary),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tickerMark(String symbol) => Container(
    width: 38,
    height: 38,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: p.card,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: p.border),
    ),
    child: Text(
      symbol.characters.take(3).toString(),
      style: st(10, true, p.accent),
    ),
  );
  Widget _miniMetric(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: BoxDecoration(
      color: p.card,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text('$label  $value', style: st(9, true, p.muted)),
  );

  Widget _detailPanel() {
    if (detailLoading) {
      return panel(
        const Center(
          child: Padding(
            padding: EdgeInsets.all(42),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }
    if (detailFailed) {
      return panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w('Company evidence could not be loaded.', '公司证据加载失败。'),
              style: st(16, true),
            ),
            TextButton(
              onPressed: () => unawaited(loadDetail()),
              child: Text(w('Retry company facts', '重试公司事实')),
            ),
          ],
        ),
      );
    }
    if (detail == null) {
      return panel(
        Text(
          w('Select a company to open its research record.', '选择公司，打开研究记录。'),
          style: st(13, false, p.muted),
        ),
      );
    }
    final company = asMap(detail?['company']),
        judgment = asMap(detail?['judgment']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        panel(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _tickerMark(ticker),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${detail?['ticker']} · ${company['name'] ?? ''}',
                          style: st(20, true),
                        ),
                        Text(
                          '${company['period_end']} · ${w('publicly available', '公开可用')} ${company['available_at']} · ${detail?['economicTemplate']}',
                          style: st(10, false, p.muted),
                        ),
                      ],
                    ),
                  ),
                  statusPill(w('Evidence-led', '证据优先')),
                ],
              ),
              const SizedBox(height: 14),
              _detailTabs(),
              if (detailTab == 'business') ...[
                const SizedBox(height: 16),
                Text(
                  w('OPERATING JUDGMENT', '经营判断'),
                  style: st(10, true, p.accent),
                ),
                const SizedBox(height: 6),
                Text(bi(judgment['summary']), style: st(21, true, null, 1.25)),
                const SizedBox(height: 12),
                _importantChanges(),
                const SizedBox(height: 12),
                _counterEvidence(),
                const SizedBox(height: 15),
                _researchActions(),
              ],
            ],
          ),
        ),
        if (detailTab == 'valuation') ...[
          const SizedBox(height: 12),
          _valuationBreakdown(),
        ] else if (detailTab == 'financials') ...[
          const SizedBox(height: 12),
          _trendCard(),
          const SizedBox(height: 12),
          _analysisSections(),
        ] else if (detailTab == '13f') ...[
          const SizedBox(height: 12),
          _institutionalTab(),
        ],
      ],
    );
  }

  Widget _detailTabs() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: SegmentedButton<String>(
      key: const ValueKey('fundamental-detail-tabs'),
      segments: [
        ButtonSegment(
          value: 'business',
          icon: const Icon(Icons.fact_check_outlined, size: 16),
          label: Text(w('Business', '经营研究')),
        ),
        ButtonSegment(
          value: 'valuation',
          icon: const Icon(Icons.calculate_outlined, size: 16),
          label: Text(w('Valuation', '估值拆解')),
        ),
        ButtonSegment(
          value: 'financials',
          icon: const Icon(Icons.query_stats, size: 16),
          label: Text(w('Financials', '财务趋势')),
        ),
        ButtonSegment(
          value: '13f',
          icon: const Icon(Icons.account_balance_outlined, size: 16),
          label: Text(w('13F insights', '13F 洞察')),
        ),
      ],
      selected: {detailTab},
      showSelectedIcon: false,
      onSelectionChanged: (values) => selectDetailTab(values.first),
    ),
  );

  String _currencyValue(dynamic value, String currency, {int digits = 2}) {
    final number = nullableNumber(value);
    if (number == null) return '—';
    return '$currency ${number.toStringAsFixed(digits)}';
  }

  String _parameterLabel(String key, String fallback) => switch (key) {
    'valuationRevenue' => w('Forward revenue used', '估值采用的前瞻收入'),
    'evSalesMultiple' => w('EV / sales multiple', 'EV / 销售额倍数'),
    'normalizedNetIncome' => w('Normalized net income', '标准化净利润'),
    'normalizedMargin' => w('Normalized net margin', '标准化净利率'),
    'targetPE' => w('Target P / E', '目标市盈率'),
    'valuationFreeCashFlow' => w('FCFE starting cash flow', 'FCFE 起始现金流'),
    'targetFCFYield' => w('Target FCF yield', '目标 FCF 收益率'),
    'sharesM' => w('Diluted shares', '摊薄股数'),
    'netCashM' => w('Net cash / (debt)', '净现金 /（净债务）'),
    'discountRate' => w('Discount rate', '折现率'),
    'terminalGrowth' => w('Terminal growth', '永续增长率'),
    'initialGrowth' => w('Initial DCF growth', 'DCF 初始增速'),
    'terminalValueShare' => w('Terminal value share', '终值占比'),
    _ => fallback,
  };

  String _parameterValue(Map<String, dynamic> row, String currency) {
    final value = nullableNumber(row['value']);
    if (value == null) return '—';
    return switch (text(row['format'])) {
      'currency_m' => '$currency ${amount(value * 1000000)}',
      'shares_m' => '${amount(value * 1000000)} ${w('shares', '股')}',
      'multiple' => '${value.toStringAsFixed(2)}×',
      'percent_points' => '${value.toStringAsFixed(1)}%',
      'ratio_percent' => '${(value * 100).toStringAsFixed(1)}%',
      _ => value.toStringAsFixed(2),
    };
  }

  String _componentLabel(Map<String, dynamic> component) => switch (text(
    component['key'],
  )) {
    'ev-sales-equity-value' => w('EV / sales equity value', 'EV / 销售额估值'),
    'normalized-earnings-power' => w('Normalized earnings power', '标准化盈利能力估值'),
    'fcfe-dcf' => w('Five-year FCFE DCF', '五年期 FCFE DCF'),
    _ => text(component['label']),
  };

  Widget _valuationBreakdown() {
    final valuation = asMap(detail?['valuation']);
    final breakdown = asMap(valuation['breakdown']);
    if (valuation['valuationStatus'] != 'available' || breakdown.isEmpty) {
      return panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.calculate_outlined, color: p.muted, size: 26),
            const SizedBox(height: 10),
            Text(
              w('No published valuation model', '暂无已发布估值模型'),
              style: st(17, true),
            ),
            const SizedBox(height: 5),
            Text(
              w(
                'The financial facts remain researchable. ThesisForge will not substitute a generic multiple or infer missing model inputs.',
                '财务事实仍可研究；ThesisForge 不会用通用倍数代替，也不会推断缺失的模型输入。',
              ),
              style: st(11, false, p.muted),
            ),
          ],
        ),
      );
    }
    final currency = text(breakdown['currency'], 'USD');
    final price = asMap(valuation['price']);
    final components = asList(breakdown['components']);
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w('Published valuation, fully explained', '已发布估值完整拆解'),
                      style: st(17, true),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${breakdown['period']} · ${w('published', '发布于')} ${breakdown['availableAt']} · ${breakdown['modelVersion']}',
                      style: st(9, false, p.muted),
                    ),
                  ],
                ),
              ),
              statusPill(
                breakdown['priceExcludedFromFairValue'] == true
                    ? w('Price excluded', '不使用市场价格')
                    : w('Published model', '已发布模型'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _valuationMetric(
                w('Market price', '市场价格'),
                _currencyValue(
                  price['value'],
                  text(price['currency'], currency),
                ),
              ),
              _valuationMetric(
                w('Model value', '模型价值'),
                _currencyValue(breakdown['fairValue'], currency),
                color: p.accent,
              ),
              _valuationMetric(
                w('Model / price − 1', '模型 / 价格 − 1'),
                pct(valuation['modelGap']),
                color:
                    nullableNumber(valuation['modelGap']) != null &&
                        number(valuation['modelGap']) >= 0
                    ? p.accent
                    : p.secondary,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              text(breakdown['formula'], text(breakdown['method'])),
              style: st(10, false, p.muted),
            ),
          ),
          const SizedBox(height: 10),
          for (final component in components)
            _valuationComponent(component, currency),
          if (nullableNumber(breakdown['weightedValue']) != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: .07),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.accent.withValues(alpha: .35)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      w('Weighted component result', '子模型加权结果'),
                      style: st(11, true),
                    ),
                  ),
                  Text(
                    _currencyValue(breakdown['weightedValue'], currency),
                    style: st(14, true, p.accent),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 9),
          Text(
            w(
              'Every number above is read from the same published model observation. Missing parameters remain missing; this is not a newly generated valuation.',
              '以上数字均来自同一条已发布模型记录。缺失参数保持缺失；这里不会重新生成估值。',
            ),
            style: st(9, false, p.muted),
          ),
        ],
      ),
    );
  }

  Widget _valuationMetric(String label, String value, {Color? color}) =>
      Container(
        width: 156,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: st(9, false, p.muted)),
            const SizedBox(height: 4),
            Text(value, style: st(15, true, color ?? p.text)),
          ],
        ),
      );

  Widget _valuationComponent(
    Map<String, dynamic> component,
    String currency,
  ) => Container(
    margin: const EdgeInsets.only(bottom: 9),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: p.card.withValues(alpha: .7),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: p.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(_componentLabel(component), style: st(13, true)),
            ),
            if (nullableNumber(component['weight']) != null)
              statusPill(
                '${(number(component['weight']) * 100).toStringAsFixed(0)}% ${w('weight', '权重')}',
              ),
            const SizedBox(width: 8),
            Text(
              _currencyValue(component['output'], currency),
              style: st(14, true, p.accent),
            ),
          ],
        ),
        if (text(component['description']).isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(text(component['description']), style: st(9, false, p.muted)),
        ],
        const SizedBox(height: 9),
        Wrap(
          spacing: 8,
          runSpacing: 7,
          children: [
            for (final parameter in asList(component['parameters']))
              Container(
                constraints: const BoxConstraints(minWidth: 128),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                decoration: BoxDecoration(
                  color: p.panel,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _parameterLabel(
                        text(parameter['key']),
                        text(parameter['label']),
                      ),
                      style: st(8, false, p.muted),
                    ),
                    Text(
                      _parameterValue(parameter, currency),
                      style: st(10, true),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    ),
  );

  String _whole(dynamic value) {
    final v = nullableNumber(value)?.round();
    if (v == null) return '—';
    return '$v'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  }

  String _sharesK(dynamic value) {
    final v = nullableNumber(value);
    if (v == null) return '—';
    final shares = v * 1000;
    if (shares.abs() >= 1e9) return '${(shares / 1e9).toStringAsFixed(2)}B';
    if (shares.abs() >= 1e6) return '${(shares / 1e6).toStringAsFixed(1)}M';
    if (shares.abs() >= 1e3) return '${(shares / 1e3).toStringAsFixed(1)}K';
    return _whole(shares);
  }

  String _usdM(dynamic value) {
    final v = nullableNumber(value);
    if (v == null) return '—';
    if (v.abs() >= 1000000) return '\$${(v / 1000000).toStringAsFixed(1)}T';
    if (v.abs() >= 1000) return '\$${(v / 1000).toStringAsFixed(1)}B';
    return '\$${v.toStringAsFixed(1)}M';
  }

  String _quarterLabel(String value) {
    final parts = value.split('-');
    if (parts.length != 3) return value;
    final month = int.tryParse(parts[1]) ?? 0;
    return '${parts[0]}/Q${(month / 3).ceil().clamp(1, 4)}';
  }

  Widget _institutionalTab() {
    if (institutionalLoading) {
      return panel(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 50),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (institutionalFailed) {
      return panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(
                '13F history is unavailable for this security.',
                '该证券暂时没有可用的 13F 历史。',
              ),
              style: st(15, true),
            ),
            TextButton(
              onPressed: () => unawaited(loadInstitutionalDetail()),
              child: Text(w('Retry 13F evidence', '重试 13F 证据')),
            ),
          ],
        ),
      );
    }
    final root = institutionalDetail;
    if (root == null) return panel(const SizedBox(height: 120));
    final row = asMap(root['row']),
        details = asMap(root['details']),
        analysis = asMap(details['analysis']);
    final points = asList(details['history'])
        .map(
          (item) => _InsightHistoryPoint(
            reportDate: text(item['reportDate']),
            holders: nullableNumber(item['holders']),
            sharesK: nullableNumber(item['institutionalSharesK']),
            ownershipPct: nullableNumber(item['institutionalOwnershipPct']),
            shareBasisFactor: nullableNumber(item['shareBasisFactor']) ?? 1,
            shareBasisDate: text(item['shareBasisDate']),
          ),
        )
        .where((point) => point.reportDate.isNotEmpty)
        .toList();
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w('Institutional ownership, in context', '机构持仓变化与背景'),
                      style: st(17, true),
                    ),
                    Text(
                      '${_quarterLabel(text(root['reportDate']))} · ${w('publicly available', '公开可用')} ${root['availableAt']}',
                      style: st(9, false, p.muted),
                    ),
                  ],
                ),
              ),
              Text(
                '${_whole(row['holders'])} ${w('holders', '家机构')}',
                style: st(12, true, p.accent),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _institutionMetric(w('New', '新建'), row['newPositions'], p.accent),
              _institutionMetric(w('Added', '增持'), row['increases'], p.accent),
              _institutionMetric(
                w('Reduced', '减持'),
                row['reductions'],
                p.secondary,
              ),
              _institutionMetric(w('Exited', '清仓'), row['exits'], p.secondary),
            ],
          ),
          if (analysis.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: .07),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: p.accent.withValues(alpha: .35)),
              ),
              child: Text(
                _institutionHeadline(text(analysis['headlineKey'])),
                style: st(12, true),
              ),
            ),
          ],
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (_, constraints) {
              final holders = _fundInstitutionChart(points, true);
              final ownership = _fundInstitutionChart(points, false);
              if (constraints.maxWidth < 570) {
                return Column(
                  children: [holders, const SizedBox(height: 10), ownership],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: holders),
                  const SizedBox(width: 10),
                  Expanded(child: ownership),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Text(w('Changes worth researching', '值得研究的变动'), style: st(15, true)),
          const SizedBox(height: 3),
          Text(
            w(
              'Important adds and reductions, including reported share change, portfolio weight and continuity.',
              '同时呈现重要增持与减持，包括申报股数变化、组合权重和历史连续性。',
            ),
            style: st(9, false, p.muted),
          ),
          const SizedBox(height: 8),
          if (asList(analysis['importantChanges']).isEmpty)
            Text(
              w(
                'No comparable institution-level changes are available.',
                '暂无可比的机构级变动。',
              ),
              style: st(11, false, p.muted),
            )
          else
            for (final change in asList(analysis['importantChanges']).take(12))
              _fundInstitutionChange(change),
          const SizedBox(height: 10),
          Text(
            w(
              '13F filings are delayed public snapshots, not live trades. Portfolio weights use each filer’s reported common-stock book, not total AUM.',
              '13F 是延迟披露的公开持仓快照，不是实时交易；组合权重以各机构申报普通股组合为分母，并非完整 AUM。',
            ),
            style: st(9, false, p.muted),
          ),
        ],
      ),
    );
  }

  Widget _institutionMetric(String label, dynamic value, Color color) =>
      Container(
        width: 104,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: color.withValues(alpha: .25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_whole(value), style: st(16, true, color)),
            Text(label, style: st(9, false, p.muted)),
          ],
        ),
      );

  String _institutionHeadline(String key) {
    if (key == 'balanced_breadth_net_increase') {
      return w(
        'Adding and reducing breadth is close, while reported shares increased. Trace the source and whether important filers also raised portfolio weight.',
        '本季增减机构数接近，但申报持股净增加。应继续追查增量来源，以及主要增持机构是否同步提高组合权重。',
      );
    }
    if (key == 'balanced_breadth_net_decrease') {
      return w(
        'Adding and reducing breadth is close, while reported shares decreased. Trace which important filers drove the decline.',
        '本季增减机构数接近，但申报持股净减少。应继续追查哪些重要机构主导了下降。',
      );
    }
    if (key.startsWith('positive')) {
      return w(
        'More institutions added. Check whether aggregate shares and portfolio weights confirm the breadth.',
        '更多机构选择增持；还需核对汇总股数与组合权重是否支持这一广度。',
      );
    }
    if (key.startsWith('negative')) {
      return w(
        'More institutions reduced. Check whether the largest moves came from core positions.',
        '更多机构选择减持；还需核对主要变化是否来自核心仓位。',
      );
    }
    return w(
      'Institution breadth and aggregate shares point in different directions. Treat this as a disagreement to investigate.',
      '机构数量与汇总股数方向不一致，应将其视为需要调查的分歧。',
    );
  }

  Widget _fundInstitutionChart(
    List<_InsightHistoryPoint> points,
    bool holders,
  ) {
    final latest = points.lastOrNull;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.card.withValues(alpha: .65),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  holders
                      ? w('Institution count history', '持有机构数量变化')
                      : w('Institutional ownership history', '机构持股与占总股本变化'),
                  style: st(12, true),
                ),
              ),
              if (latest != null)
                Text(
                  holders
                      ? '${_whole(latest.holders)} ${w('filers', '家')}'
                      : '${_sharesK(latest.sharesK)}${latest.ownershipPct == null ? '' : ' · ${latest.ownershipPct!.toStringAsFixed(1)}%'}',
                  style: st(10, true, p.accent),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            holders
                ? w(
                    'Distinct 13F filers reporting the stock',
                    '申报持有该股票的 13F 机构数量',
                  )
                : w(
                    'Shares normalized for splits to the current basis · % outstanding',
                    '历史股数按拆股折算至当前口径 · 占总股本比例',
                  ),
            style: st(8, false, p.muted),
          ),
          const SizedBox(height: 10),
          if (points.length < 2)
            SizedBox(
              height: 145,
              child: Center(
                child: Text(
                  w('More quarters are needed for a trend.', '至少需要两个季度才能显示趋势。'),
                  style: st(10, false, p.muted),
                ),
              ),
            )
          else
            SizedBox(
              height: 155,
              child: _InsightHistoryInteractiveChart(
                points: points,
                series: holders
                    ? _InsightHistorySeries.holders
                    : _InsightHistorySeries.shares,
                primaryScale: holders
                    ? _InsightAxisScale.count
                    : _InsightAxisScale.sharesThousands,
                accent: p.accent,
                secondary: p.secondary,
                grid: p.border,
                panel: p.panel,
                textColor: p.text,
                muted: p.muted,
                quarterLabel: _quarterLabel,
                tooltipLines: (point) => holders
                    ? ['${_whole(point.holders)} ${w('filers', '家机构')}']
                    : [
                        '${w('Shares', '机构持股')} ${_sharesK(point.sharesK)}',
                        '${w('% outstanding', '占总股本')} ${point.ownershipPct == null ? '—' : '${point.ownershipPct!.toStringAsFixed(2)}%'}',
                        if (point.shareBasisDate.isNotEmpty)
                          '${w('Share basis', '股数口径')} ${point.shareBasisDate}',
                      ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _fundInstitutionChange(Map<String, dynamic> change) {
    final action = text(change['action']);
    final positive = {'new', 'increased'}.contains(action);
    final color = positive ? p.accent : p.secondary;
    final previousWeight = nullableNumber(change['previousWeight']);
    final currentWeight = nullableNumber(change['currentWeight']);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  text(change['name']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: st(11, true),
                ),
              ),
              statusPill(switch (action) {
                'new' => w('New', '新建'),
                'increased' => w('Added', '增持'),
                'reduced' => w('Reduced', '减持'),
                _ => w('Exited', '清仓'),
              }, color: color),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            runSpacing: 5,
            children: [
              Text(
                '${w('Share change', '股数变化')} ${_sharesK(change['unitsChangeK'])}',
                style: st(9, false, p.text),
              ),
              Text(
                '${w('Weight', '组合权重')} ${previousWeight == null ? '—' : pct(previousWeight)} → ${currentWeight == null ? '—' : pct(currentWeight)}',
                style: st(9, false, p.text),
              ),
              Text(
                '${w('Reported value change', '申报市值变化')} ${_usdM(change['reportedValueChangeM'])}',
                style: st(9, false, p.text),
              ),
              Text(
                text(change['continuity']).replaceAll('_', ' '),
                style: st(9, false, p.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _importantChanges() {
    final items = asList(detail?['importantChanges']);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < items.length; i++)
          Container(
            constraints: const BoxConstraints(minWidth: 150, maxWidth: 235),
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: p.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${i + 1}', style: st(10, true, p.accent)),
                const SizedBox(height: 5),
                Text(bi(items[i]['summary']), style: st(11, true)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _counterEvidence() {
    final counter = asMap(detail?['counterEvidence']),
        warning = counter['severity'] == 'warning';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (warning ? p.secondary : p.muted).withValues(alpha: .08),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: (warning ? p.secondary : p.border).withValues(alpha: .65),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            warning ? Icons.warning_amber : Icons.search_off,
            size: 18,
            color: warning ? p.secondary : p.muted,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  warning
                      ? w('Contrary evidence', '相反证据')
                      : w('Explanation gap', '解释缺口'),
                  style: st(11, true, warning ? p.secondary : p.muted),
                ),
                const SizedBox(height: 3),
                Text(bi(counter['statement']), style: st(11)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _researchActions() {
    final hasModel =
        asMap(detail?['valuation'])['valuationStatus'] == 'available';
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          key: const ValueKey('fund-save-observation'),
          onPressed: saving ? null : () => unawaited(_saveObservation()),
          icon: const Icon(Icons.bookmark_add_outlined, size: 17),
          label: Text(
            w(
              saving ? 'Saving…' : 'Save observation',
              saving ? '保存中…' : '保存观察',
            ),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _showSources,
          icon: const Icon(Icons.source_outlined, size: 17),
          label: Text(w('View sources', '查看来源')),
        ),
        OutlinedButton.icon(
          onPressed: _showValidationQuestion,
          icon: const Icon(Icons.fact_check_outlined, size: 17),
          label: Text(w('Continue validation', '继续验证')),
        ),
        if (observations.isNotEmpty)
          OutlinedButton.icon(
            key: const ValueKey('fund-review-observation'),
            onPressed: () => unawaited(_reviewObservation()),
            icon: const Icon(Icons.history_outlined, size: 17),
            label: Text(
              w(
                'Review saved (${observations.length})',
                '复核已保存观察（${observations.length}）',
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: hasModel ? () => widget.onCompany(ticker, 'value') : null,
          icon: const Icon(Icons.calculate_outlined, size: 17),
          label: Text(
            hasModel
                ? w('Valuation assumptions', '估值假设')
                : w('No valuation model', '暂无估值模型'),
          ),
        ),
      ],
    );
  }

  Future<void> _saveObservation() async {
    setState(() => saving = true);
    try {
      final result = await widget.api
          .postJson('/api/investment/fundamental-observations', {
            'operationId': 'fund_${DateTime.now().microsecondsSinceEpoch}',
            'ticker': ticker,
            'asOf': widget.asOf,
            'lens': lens,
            'note': bi(asMap(detail?['judgment'])['question']),
          });
      if (result['id'] == null) throw StateError('observation_not_saved');
      await loadObservations(ticker);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              w(
                'Observation saved with its evidence and method version.',
                '观察已连同证据与方法版本保存。',
              ),
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              w('Observation was not saved. Try again.', '观察未保存，请重试。'),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _reviewObservation() async {
    if (observations.isEmpty) return;
    final id = text(observations.last['id']);
    try {
      final result = await widget.api.getJson(
        '/api/investment/fundamental-observations/${Uri.encodeComponent(id)}/review?asOf=${widget.asOf}',
      );
      if (!mounted) return;
      final comparable = result['comparableMethod'] == true;
      final changed = result['changed'] == true;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(w('Observation review', '观察复核')),
          content: Text(
            comparable
                ? changed
                      ? w(
                          'New facts or a new reporting period are available. Recheck the saved thesis against the current evidence.',
                          '已有新事实或新报告期。请用当前证据重新核对已保存命题。',
                        )
                      : w(
                          'The saved evidence is still current under the same method version.',
                          '在相同方法版本下，已保存证据仍是当前版本。',
                        )
                : w(
                    'The method version changed. Compare definitions before judging the thesis outcome.',
                    '方法版本已变化，判断命题结果前请先比较定义。',
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(w('Close', '关闭')),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(w('Review could not be loaded.', '暂时无法加载复核。')),
          ),
        );
      }
    }
  }

  void _showValidationQuestion() {
    final question = bi(asMap(detail?['judgment'])['question']);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(w('Next validation question', '下一步验证问题')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(question, style: st(15, true)),
            const SizedBox(height: 12),
            for (final gap in asList(detail?['researchGaps']))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('• ${bi(gap)}', style: st(12, false, p.muted)),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(w('Close', '关闭')),
          ),
        ],
      ),
    );
  }

  void _showSources() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Container(
        color: p.panel,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .78,
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(w('Reported fact lineage', '已披露事实来源'), style: st(20, true)),
            const SizedBox(height: 5),
            Text(
              '${detail?['reportedBasis']} · ${detail?['restatedBasis']}',
              style: st(11, false, p.muted),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                children: [
                  for (final source in asList(detail?['sources']))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.description_outlined),
                      title: Text(
                        '${source['fiscalPeriod']} · ${source['periodEnd']}',
                        style: st(13, true),
                      ),
                      subtitle: Text(
                        '${w('available', '可用')} ${source['availableAt']} · Sharadar SF1 ARQ',
                        style: st(10, false, p.muted),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trendCard() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w('Growth and operating conversion', '增长与经营转化'),
                    style: st(16, true),
                  ),
                  Text(
                    w(
                      'Reported quarters; margins are trailing four-quarter calculations.',
                      '原始报告季度；利润率按过去四个完整季度计算。',
                    ),
                    style: st(10, false, p.muted),
                  ),
                ],
              ),
            ),
            statusPill(w('No zero-fill', '不补零'), color: p.muted),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 230,
          child: _FundamentalTrendChart(
            rows: asList(detail?['trend']),
            palette: p,
            language: LanguageScope.of(context),
          ),
        ),
      ],
    ),
  );
  Widget _analysisSections() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(w('Research map', '研究地图'), style: st(17, true)),
        const SizedBox(height: 5),
        Text(
          w(
            'Every value keeps its formula, comparison and availability state.',
            '每个数值都保留公式、比较值和可用状态。',
          ),
          style: st(10, false, p.muted),
        ),
        const SizedBox(height: 8),
        for (final section in asList(detail?['sections']))
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 12),
            title: Text(bi(section['title']), style: st(13, true)),
            subtitle: section['note'] == null
                ? null
                : Text(bi(section['note']), style: st(9, false, p.secondary)),
            children: [
              for (final row in asList(section['rows'])) _metricDefinition(row),
            ],
          ),
      ],
    ),
  );
  Widget _metricDefinition(Map<String, dynamic> row) {
    final value = nullableNumber(row['value']),
        comparison = nullableNumber(row['comparison']),
        id = text(row['id']);
    final money =
        id.contains('debt') ||
        id.contains('Financing') ||
        id == 'workingCapital' ||
        id == 'marketPrice' ||
        id == 'dividends';
    final valueText = money
        ? amount(value)
        : id == 'interestCoverage'
        ? (value == null ? '—' : '${value.toStringAsFixed(1)}×')
        : pct(value, sign: false);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(bi(row['label']), style: st(11, true)),
                Text(text(row['formula']), style: st(9, false, p.muted)),
              ],
            ),
          ),
          Expanded(
            child: Text(
              valueText,
              textAlign: TextAlign.right,
              style: st(12, true, value == null ? p.muted : p.text),
            ),
          ),
          Expanded(
            child: Text(
              comparison == null
                  ? text(row['status'])
                  : pct(comparison, sign: false),
              textAlign: TextAlign.right,
              style: st(10, false, p.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _methodNote() => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: Text(
      w('Coverage, definitions and limitations', '覆盖、定义与限制'),
      style: st(12, true),
    ),
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: Text(
          w(
            'Discovery is calculated from compact Sharadar SF1 ARQ facts visible by the selected date. TTM requires four complete reported quarters. Restated MRQ/MRY data is never mixed into historical PIT. Missing values remain missing. Net common financing is not gross buybacks; capital return is explicitly pre-tax. Working-capital balances are not described as cash-flow contributions. Valuation is a separate optional layer.',
            '发现页基于所选日期可见的 Sharadar SF1 ARQ 紧凑事实计算。TTM 要求四个完整报告季度。重述的 MRQ/MRY 不会混入历史 PIT。缺失值保持缺失。股票净融资不是总回购额；资本回报明确为税前口径；营运资本余额不会被解释成现金流贡献。估值是独立的可选层。',
          ),
          style: st(11, false, p.muted),
        ),
      ),
    ],
  );
}

class _FundamentalTrendChart extends StatelessWidget {
  const _FundamentalTrendChart({
    required this.rows,
    required this.palette,
    required this.language,
  });
  final List<Map<String, dynamic>> rows;
  final Palette palette;
  final AppLanguage language;
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _FundamentalTrendPainter(rows, palette, language),
    child: const SizedBox.expand(),
  );
}

class _FundamentalTrendPainter extends CustomPainter {
  _FundamentalTrendPainter(this.rows, this.p, this.language);
  final List<Map<String, dynamic>> rows;
  final Palette p;
  final AppLanguage language;
  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(45, 16, size.width - 14, size.height - 38),
        grid = Paint()
          ..color = p.border
          ..strokeWidth = 1;
    final values = rows
        .expand(
          (row) => [
            nullableNumber(row['revenueGrowth']),
            nullableNumber(row['operatingMargin']),
          ],
        )
        .whereType<double>()
        .toList();
    if (values.isEmpty) {
      _label(
        canvas,
        language == AppLanguage.zh
            ? '可比趋势不足'
            : 'Not enough comparable trend data',
        Offset(50, size.height / 2),
        p.muted,
        11,
      );
      return;
    }
    var minY = values.reduce(math.min), maxY = values.reduce(math.max);
    final padding = math.max(.02, (maxY - minY) * .18);
    minY = math.min(0, minY - padding);
    maxY += padding;
    if (maxY - minY < .05) maxY = minY + .05;
    for (var i = 0; i <= 4; i++) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final value = maxY - (maxY - minY) * i / 4;
      _label(
        canvas,
        '${(value * 100).toStringAsFixed(0)}%',
        Offset(2, y - 7),
        p.muted,
        9,
      );
    }
    for (final entry in <(String, Color)>[
      ('revenueGrowth', p.accent),
      ('operatingMargin', p.secondary),
    ]) {
      final path = Path();
      var started = false;
      for (var i = 0; i < rows.length; i++) {
        final value = nullableNumber(rows[i][entry.$1]);
        if (value == null) {
          started = false;
          continue;
        }
        final x = rows.length == 1
                ? plot.left
                : plot.left + plot.width * i / (rows.length - 1),
            y = plot.bottom - plot.height * (value - minY) / (maxY - minY);
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
        canvas.drawCircle(Offset(x, y), 2.5, Paint()..color = entry.$2);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = entry.$2
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
    if (rows.isNotEmpty) {
      _label(
        canvas,
        text(rows.first['periodEnd']),
        Offset(plot.left, plot.bottom + 9),
        p.muted,
        9,
      );
      final last = text(rows.last['periodEnd']);
      _label(
        canvas,
        last,
        Offset(plot.right - last.length * 5.5, plot.bottom + 9),
        p.muted,
        9,
      );
    }
    _label(
      canvas,
      language == AppLanguage.zh ? '收入同比' : 'Revenue YoY',
      Offset(plot.left, 0),
      p.accent,
      9,
    );
    _label(
      canvas,
      language == AppLanguage.zh ? '经营利润率' : 'Operating margin',
      Offset(plot.left + 78, 0),
      p.secondary,
      9,
    );
  }

  void _label(
    Canvas canvas,
    String value,
    Offset offset,
    Color color,
    double size,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _FundamentalTrendPainter old) =>
      old.rows != rows || old.p != p || old.language != language;
}
