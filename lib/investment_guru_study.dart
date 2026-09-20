part of 'main.dart';

List<Map<String, dynamic>> filterGuruStudy(
  List<Map<String, dynamic>> rows, {
  String query = '',
  String method = 'all',
  double? maxTurnover,
  double? minSharpe,
  double? minCagr,
  Set<String>? followed,
}) => rows
    .where(
      (r) =>
          '${r['name']} ${r['entityName']}'.toLowerCase().contains(
            query.trim().toLowerCase(),
          ) &&
          (method == 'all' || r['basis'] == method) &&
          (maxTurnover == null ||
              (nullableNumber(r['annualTurnover']) != null &&
                  number(r['annualTurnover']) <= maxTurnover)) &&
          (minSharpe == null ||
              (nullableNumber(r['sharpe']) != null &&
                  number(r['sharpe']) >= minSharpe)) &&
          (minCagr == null ||
              (nullableNumber(r['cagr']) != null &&
                  number(r['cagr']) >= minCagr)) &&
          (followed == null || followed.contains(r['id'])),
    )
    .toList();

class GuruStudyPanel extends StatefulWidget {
  const GuruStudyPanel({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.gurus,
    required this.onExplore,
    required this.onFollow,
    this.initialSelection = const {},
    this.onSelection,
  });
  final ApiClient api;
  final Palette palette;
  final String asOf;
  final List<Map<String, dynamic>> gurus;
  final void Function(String, String?) onExplore;
  final Future<void> Function(Map<String, dynamic>) onFollow;
  final Map<String, dynamic> initialSelection;
  final ValueChanged<Map<String, dynamic>>? onSelection;
  @override
  State<GuruStudyPanel> createState() => _GuruStudyPanelState();
}

class _GuruStudyPanelState extends State<GuruStudyPanel> {
  final search = TextEditingController();
  final chartsKey = GlobalKey();
  final directoryKeys = <String, GlobalKey>{};
  Map<String, dynamic>? data, detail;
  List<String> shortlist = [];
  String inspecting = '',
      period = 'common',
      method = 'all',
      turnover = 'any',
      directorySort = 'turnover',
      quarter = '';
  bool loading = true,
      failed = false,
      detailLoading = false,
      detailFailed = false;
  bool highSharpe = false,
      more = false,
      followingOnly = false,
      positiveReturn = false,
      followBusy = false;
  int serial = 0, detailSerial = 0;
  bool seeded = false;
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  TextStyle s([double size = 14, bool bold = false, Color? color]) => TextStyle(
    fontSize: size,
    height: 1.35,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? p.text,
  );
  String pct(dynamic v) => nullableNumber(v) == null
      ? '—'
      : '${(number(v) * 100).toStringAsFixed(2)}%';
  String ratio(dynamic v) =>
      nullableNumber(v) == null ? '—' : number(v).toStringAsFixed(2);
  Map<String, dynamic> manager(String id) =>
      widget.gurus.where((g) => g['id'] == id).firstOrNull ??
      asList(data?['rows']).where((g) => g['id'] == id).firstOrNull ??
      {'id': id, 'name': id};
  List<Map<String, dynamic>> get rows => [
    for (final r in asList(data?['rows'])) {...manager(r['id']), ...r},
  ];
  // The directory includes managers without a comparable simulation too.
  // Missing performance must never remove a manager's holdings entry point.
  List<Map<String, dynamic>> get catalog {
    final byId = <String, Map<String, dynamic>>{};
    for (final g in [
      ...widget.gurus,
      ...asList(data?['unavailable']),
      ...rows,
    ]) {
      final id = text(g['id']);
      if (id.isNotEmpty) byId[id] = {...?byId[id], ...g};
    }
    return byId.values.toList();
  }

  List<Map<String, dynamic>> filtered(List<Map<String, dynamic>> source) =>
      filterGuruStudy(
        source,
        query: search.text,
        method: method,
        maxTurnover: turnover == 'any' ? null : double.parse(turnover),
        minSharpe: highSharpe ? 1 : null,
        minCagr: positiveReturn ? 0 : null,
        followed: followingOnly
            ? widget.gurus
                  .where((g) => g['followed'] == true)
                  .map((g) => text(g['id']))
                  .toSet()
            : null,
      );
  List<Map<String, dynamic>> get matches => filtered(rows);
  List<Map<String, dynamic>> get directoryMatches {
    final result = filtered(catalog);
    final field = switch (directorySort) {
      'cagr' => 'cagr',
      'sharpe' => 'sharpe',
      _ => 'annualTurnover',
    };
    result.sort((a, b) {
      if (directorySort != 'name') {
        final av = nullableNumber(a[field]), bv = nullableNumber(b[field]);
        if (av == null && bv != null) return 1;
        if (av != null && bv == null) return -1;
        if (av != null && bv != null && av != bv) {
          return directorySort == 'turnover'
              ? av.compareTo(bv)
              : bv.compareTo(av);
        }
      }
      return text(
        a['name'],
      ).toLowerCase().compareTo(text(b['name']).toLowerCase());
    });
    return result;
  }

  Map<String, dynamic> metric(String id) =>
      asList(data?['rows']).where((g) => g['id'] == id).firstOrNull ?? {};
  List<Map<String, dynamic>> get quarters =>
      asList(detail?['history']).reversed.toList();
  String quarterLabel(Map<String, dynamic> q) => text(q['quarter']).isNotEmpty
      ? text(q['quarter'])
      : '${text(q['reportDate']).substring(0, 4)} Q${(int.parse(text(q['reportDate']).substring(5, 7)) + 2) ~/ 3}';
  String get periodLabel => switch (period) {
    '1Y' => w('Trailing 1 year', '最近 1 年'),
    '3Y' => w('Trailing 3 years', '最近 3 年'),
    _ => w('Common history', '共同历史区间'),
  };

  @override
  void initState() {
    super.initState();
    final v = widget.initialSelection;
    seeded = v.containsKey('shortlist');
    shortlist = List<String>.from(v['shortlist'] ?? []).take(3).toList();
    inspecting = text(v['inspecting']);
    period = text(v['period'], 'common');
    method = text(v['method'], 'all');
    turnover = text(v['turnover'], 'any');
    directorySort = text(v['directorySort'], 'turnover');
    search.text = text(v['query']);
    highSharpe = v['highSharpe'] == true;
    followingOnly = v['followingOnly'] == true;
    positiveReturn = v['positiveReturn'] == true;
    quarter = text(v['quarter']);
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant GuruStudyPanel old) {
    super.didUpdateWidget(old);
    if (old.asOf != widget.asOf || old.api != widget.api) {
      data = null;
      detail = null;
      unawaited(load());
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void remember() => widget.onSelection?.call({
    'shortlist': shortlist.toList(),
    'inspecting': inspecting,
    'period': period,
    'method': method,
    'turnover': turnover,
    'directorySort': directorySort,
    'query': search.text,
    'highSharpe': highSharpe,
    'followingOnly': followingOnly,
    'positiveReturn': positiveReturn,
    'quarter': quarter,
  });
  void change(VoidCallback action) {
    setState(action);
    remember();
  }

  Future<void> load() async {
    final request = ++serial;
    setState(() {
      loading = true;
      failed = false;
      data = null;
    });
    try {
      final next = await widget.api.getJson(
        '/api/investment/guru-study?asOf=${widget.asOf}&period=$period',
      );
      if (!mounted || request != serial) return;
      if (next['asOf'] != widget.asOf || next['period'] != period) {
        throw StateError('mismatched study');
      }
      setState(() {
        data = next;
        if (shortlist.isEmpty && !seeded) {
          final ids = asList(next['rows']).map((r) => text(r['id'])).toSet();
          shortlist = ['bill-ackman', 'li-lu'].where(ids.contains).toList();
        }
        seeded = true;
        if (!catalog.any((g) => g['id'] == inspecting)) {
          inspecting = shortlist.firstOrNull ?? '';
        }
      });
      remember();
      if (inspecting.isNotEmpty) unawaited(loadQuarters());
    } catch (_) {
      if (mounted && request == serial) setState(() => failed = true);
    } finally {
      if (mounted && request == serial) setState(() => loading = false);
    }
  }

  Future<void> loadQuarters() async {
    final request = ++detailSerial, id = inspecting, cutoff = widget.asOf;
    setState(() {
      detailLoading = true;
      detailFailed = false;
      detail = null;
    });
    try {
      final next = await widget.api.getJson(
        '/api/investment/gurus/${Uri.encodeComponent(id)}?asOf=$cutoff',
      );
      if (!mounted ||
          request != detailSerial ||
          id != inspecting ||
          cutoff != widget.asOf) {
        return;
      }
      if (asMap(next['guru'])['id'] != id || next['asOf'] != cutoff) {
        throw StateError('mismatched manager');
      }
      setState(() {
        detail = next;
        if (!quarters.any((q) => q['accessionNumber'] == quarter)) {
          quarter = text(quarters.firstOrNull?['accessionNumber']);
        }
      });
      remember();
    } catch (_) {
      if (mounted && request == detailSerial) {
        setState(() => detailFailed = true);
      }
    } finally {
      if (mounted && request == detailSerial) {
        setState(() => detailLoading = false);
      }
    }
  }

  void reveal(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = key.currentContext;
      if (mounted && target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: .12,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
  }

  void select(String id, {bool revealInList = false}) {
    final changed = inspecting != id;
    change(() {
      if (changed) quarter = '';
      inspecting = id;
    });
    if (changed || detail == null) unawaited(loadQuarters());
    if (revealInList) reveal(directoryKeys.putIfAbsent(id, GlobalKey.new));
  }

  void compare(String id) {
    if (shortlist.contains(id)) {
      remove(id);
      return;
    }
    if (shortlist.length == 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            w(
              'Your shortlist has 3 managers. Remove one to add another.',
              '清单最多 3 位经理，请先移除一位再添加。',
            ),
          ),
        ),
      );
      return;
    }
    change(() => shortlist.add(id));
  }

  void remove(String id) {
    change(() => shortlist.remove(id));
  }

  void resetFilters() => change(() {
    search.clear();
    method = 'all';
    turnover = 'any';
    highSharpe = false;
    followingOnly = false;
    positiveReturn = false;
  });
  Widget box(Widget child, {EdgeInsets padding = const EdgeInsets.all(16)}) =>
      Container(
        padding: padding,
        decoration: BoxDecoration(
          color: p.panel,
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      );
  Widget dropdown(
    String key,
    String value,
    List<(String, String)> options,
    ValueChanged<String> onChange, {
    double width = 160,
  }) => SizedBox(
    width: width,
    child: DropdownButtonFormField<String>(
      key: ValueKey('$key-$value'),
      initialValue: value,
      isExpanded: true,
      style: s(13),
      dropdownColor: p.panel,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      items: [
        for (final o in options)
          DropdownMenuItem(
            value: o.$1,
            child: Text(o.$2, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChange(v);
      },
    ),
  );
  Widget chip(String label, bool selected, VoidCallback action) => ChoiceChip(
    label: Text(label, style: s(12)),
    selected: selected,
    onSelected: (_) => action(),
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
  );

  @override
  Widget build(BuildContext context) {
    final visible = matches, range = asMap(data?['range']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (_, c) {
            final controls = Wrap(
              spacing: 8,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                dropdown(
                  'period',
                  period,
                  [
                    ('common', w('Common history', '共同历史区间')),
                    ('1Y', w('Trailing 1 year', '最近 1 年')),
                    ('3Y', w('Trailing 3 years', '最近 3 年')),
                  ],
                  (v) {
                    change(() => period = v);
                    unawaited(load());
                  },
                  width: 172,
                ),
                chip('1Y', period == '1Y', () {
                  change(() => period = period == '1Y' ? 'common' : '1Y');
                  unawaited(load());
                }),
                chip('3Y', period == '3Y', () {
                  change(() => period = period == '3Y' ? 'common' : '3Y');
                  unawaited(load());
                }),
                if (!loading && range.isNotEmpty)
                  Text(
                    '${range['start']} — ${range['end']}   ·   ${number(range['years']).toStringAsFixed(2)} ${w('years in common', '年共同历史')}',
                    style: s(12, false, p.muted),
                  ),
              ],
            );
            final input = TextField(
              controller: search,
              onChanged: (_) => change(() {}),
              style: s(13),
              decoration: InputDecoration(
                hintText: w(
                  'Search Guru (e.g. Ackman, Li Lu, Buffett)',
                  '搜索经理（如 Ackman、Li Lu、Buffett）',
                ),
                prefixIcon: Icon(Icons.search, size: 20, color: p.muted),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 12,
                ),
              ),
            );
            return c.maxWidth >= 1050
                ? Row(
                    children: [
                      SizedBox(width: c.maxWidth * .34, child: input),
                      const SizedBox(width: 20),
                      Expanded(child: controls),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [input, const SizedBox(height: 12), controls],
                  );
          },
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (_, c) => Padding(
            padding: EdgeInsets.only(
              left: c.maxWidth >= 1150 ? c.maxWidth * .34 + 20 : 0,
            ),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                dropdown(
                  'turnover',
                  turnover,
                  [
                    ('any', w('Turnover: Any', '换手率：不限')),
                    ('0.5', w('Turnover ≤ 50%', '换手率 ≤ 50%')),
                    ('1', w('Turnover ≤ 100%', '换手率 ≤ 100%')),
                  ],
                  (v) => change(() => turnover = v),
                  width: 170,
                ),
                dropdown(
                  'method',
                  method,
                  [
                    ('all', w('Method: All', '口径：全部')),
                    ('strict', w('Cash-preserving', '未覆盖留现金')),
                    ('proxy', w('Subset proxy', '可定价子集代理')),
                  ],
                  (v) => change(() => method = v),
                  width: 165,
                ),
                chip(
                  w('More filters', '更多筛选'),
                  more,
                  () => change(() => more = !more),
                ),
                chip(
                  w('Lower turnover', '低换手率'),
                  turnover == '0.5',
                  () => change(
                    () => turnover = turnover == '0.5' ? 'any' : '0.5',
                  ),
                ),
                chip(
                  w('Sharpe ≥ 1', '夏普 ≥ 1'),
                  highSharpe,
                  () => change(() => highSharpe = !highSharpe),
                ),
                if (directoryMatches.length != catalog.length)
                  TextButton(
                    onPressed: resetFilters,
                    child: Text(w('Reset filters', '重置筛选')),
                  ),
              ],
            ),
          ),
        ),
        if (more)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                chip(
                  w('Following only', '仅已关注'),
                  followingOnly,
                  () => change(() => followingOnly = !followingOnly),
                ),
                chip(
                  w('Positive CAGR', '复合收益率 ≥ 0'),
                  positiveReturn,
                  () => change(() => positiveReturn = !positiveReturn),
                ),
                Text(
                  w(
                    'Lower turnover means ≤ 50% per year. Filters do not change the common comparison dates.',
                    '低换手率指每年 ≤ 50%。筛选不会改变共同对比日期。',
                  ),
                  style: s(12, false, p.muted),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        if (loading)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(minHeight: 2),
                const SizedBox(height: 8),
                Text(
                  w('Aligning the comparison dates…', '正在对齐对比日期…'),
                  style: s(12, false, p.muted),
                ),
              ],
            ),
          ),
        if (failed)
          box(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w(
                    'The comparison could not load. Your shortlist is unchanged.',
                    '暂时无法加载对比，学习清单保持不变。',
                  ),
                  style: s(),
                ),
                TextButton(
                  onPressed: load,
                  child: Text(w('Retry comparison', '重试对比')),
                ),
              ],
            ),
          ),
        ...[
          shortlistPanel(),
          if (search.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final g in visible)
                    ActionChip(
                      avatar: GuruAvatar(
                        guru: {...g, 'avatarUrl': g['avatar']},
                        palette: p,
                        size: 22,
                      ),
                      label: Text(text(g['name']), style: s(12)),
                      onPressed: () =>
                          select(text(g['id']), revealInList: true),
                    ),
                ],
              ),
            ),
          SizedBox(key: chartsKey, height: 14),
          if (!failed && !loading && visible.isEmpty)
            box(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    directoryMatches.isNotEmpty
                        ? w(
                            'These managers have no comparable chart points.',
                            '这些经理暂无可比的图表数据点。',
                          )
                        : rows.isEmpty
                        ? w(
                            'No comparable simulations at this date.',
                            '此日期没有可比模拟数据。',
                          )
                        : w('No managers match these filters.', '没有符合这些条件的经理。'),
                    style: s(17, true),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    w(
                      'You can still explore quarterly holdings. Missing returns are not shown as zero.',
                      '仍可查看季度持仓。缺失收益不会按零展示。',
                    ),
                    style: s(13, false, p.muted),
                  ),
                  Wrap(
                    spacing: 12,
                    children: [
                      TextButton(
                        onPressed: resetFilters,
                        child: Text(w('Clear filters', '清空筛选')),
                      ),
                      TextButton(
                        onPressed: pickManager,
                        child: Text(w('Browse managers', '浏览经理')),
                      ),
                    ],
                  ),
                ],
              ),
            )
          else if (!failed && !loading)
            LayoutBuilder(
              builder: (_, c) {
                Widget chart(String field) => GuruStudyScatter(
                  rows: visible,
                  allRows: rows,
                  field: field,
                  palette: p,
                  shortlist: shortlist,
                  inspecting: inspecting,
                  benchmark: asMap(data?['benchmark']),
                  range: range,
                  onSelect: (id) => select(id, revealInList: true),
                );
                return c.maxWidth >= 900
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: chart('cagr')),
                          const SizedBox(width: 14),
                          Expanded(child: chart('sharpe')),
                        ],
                      )
                    : Column(
                        children: [
                          chart('cagr'),
                          const SizedBox(height: 14),
                          chart('sharpe'),
                        ],
                      );
              },
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              InkWell(
                onTap: showMethod,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        w(
                          '13F simulations, not fund returns. Costs excluded. Sharpe uses 0% Rf.',
                          '13F 模拟，非基金实盘收益；不含成本；夏普无风险利率为 0%。',
                        ),
                        style: s(11, false, p.muted),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.info_outline, size: 15, color: p.muted),
                  ],
                ),
              ),
              Text(
                w(
                  '${visible.length} plotted / ${directoryMatches.length} listed · ${directoryMatches.length - visible.length} without comparable simulation',
                  '${visible.length} 位入图 / ${directoryMatches.length} 位列出 · ${directoryMatches.length - visible.length} 位暂无可比模拟',
                ),
                style: s(11, false, p.muted),
              ),
            ],
          ),
          const SizedBox(height: 24),
          directoryPanel(),
        ],
      ],
    );
  }

  Widget directoryPanel() {
    final list = directoryMatches;
    return box(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text(w('All Gurus', '全部 Guru'), style: s(23, true)),
                    Text(
                      w(
                        '${list.length} / ${catalog.length} managers',
                        '${list.length} / ${catalog.length} 位经理',
                      ),
                      style: s(13, true, p.accent),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  w(
                    'Click a portrait to see quarters and holdings. Chart selections highlight the same person here. Compare up to 3; explore everyone.',
                    '点击头像展开季度与持仓入口；点击图上的点，会定位并高亮这里的同一位经理。最多比较 3 位，浏览不限人数。',
                  ),
                  style: s(13, false, p.muted),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 340),
                      child: TextField(
                        controller: search,
                        onChanged: (_) => change(() {}),
                        style: s(13),
                        decoration: InputDecoration(
                          hintText: w('Find a Guru in the list', '在列表中搜索经理'),
                          prefixIcon: const Icon(Icons.search, size: 20),
                          isDense: true,
                        ),
                      ),
                    ),
                    dropdown(
                      'directory-sort',
                      directorySort,
                      [
                        ('turnover', w('Turnover: low to high', '换手率：从低到高')),
                        ('cagr', w('CAGR: high to low', '年化收益：从高到低')),
                        ('sharpe', w('Sharpe: high to low', '夏普：从高到低')),
                        ('name', w('Name: A–Z', '姓名：A–Z')),
                      ],
                      (v) => change(() => directorySort = v),
                      width: 210,
                    ),
                    if (list.length != catalog.length)
                      TextButton(
                        onPressed: resetFilters,
                        child: Text(w('Show all Gurus', '显示全部经理')),
                      ),
                    TextButton.icon(
                      onPressed: () => reveal(chartsKey),
                      icon: const Icon(Icons.north, size: 16),
                      label: Text(w('Back to charts', '返回图表')),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  loading
                      ? w(
                          'Updating comparison metrics… Holdings remain accessible.',
                          '正在更新对比指标…仍可查看持仓。',
                        )
                      : failed
                      ? w(
                          'Comparison unavailable. Open a portrait to explore holdings or retry above.',
                          '对比数据暂不可用，可点击头像查看持仓，或在上方重试。',
                        )
                      : w(
                          '$periodLabel · Same filters and dates as both charts. Missing metrics are shown as —.',
                          '$periodLabel · 与两张图使用相同筛选和日期。缺失指标显示为 —。',
                        ),
                  style: s(11, false, p.muted),
                ),
              ],
            ),
          ),
          if (list.isEmpty && !loading)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                w(
                  'No matches in the directory. Clear filters to browse everyone.',
                  '列表中没有匹配项，清空筛选即可浏览全部经理。',
                ),
                style: s(14, false, p.muted),
              ),
            ),
          for (final g in list) directoryRow(g),
        ],
      ),
      padding: EdgeInsets.zero,
    );
  }

  Widget directoryRow(Map<String, dynamic> g) {
    final id = text(g['id']),
        active = id == inspecting,
        compared = shortlist.contains(id);
    final metricValues = [
      (w('Annual turnover', '年化换手率'), pct(g['annualTurnover'])),
      (w('CAGR', '复合年化收益'), pct(g['cagr'])),
      (w('Sharpe', '夏普'), ratio(g['sharpe'])),
    ];
    final identity = Semantics(
      button: true,
      selected: active,
      label: w('Inspect ${g['name']}', '研究 ${g['name']}'),
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('guru-directory-person-$id'),
        onTap: () => select(id),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: active ? p.accent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: GuruAvatar(
                  guru: {...g, 'avatarUrl': g['avatarUrl'] ?? g['avatar']},
                  palette: p,
                  size: 48,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(text(g['name']), style: s(16, true)),
                    Text(
                      text(g['entityName']),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: s(11, false, p.muted),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      active && metric(id).isEmpty
                          ? w(
                              'Inspecting · no comparable chart point',
                              '正在研究 · 暂无可比图表数据点',
                            )
                          : active
                          ? w(
                              'Inspecting · highlighted on both charts',
                              '正在研究 · 两张图已同步高亮',
                            )
                          : compared
                          ? w('In your comparison', '已加入比较')
                          : g['basis'] == 'strict'
                          ? w('Cash-preserving simulation', '未覆盖留现金模拟')
                          : g['basis'] == 'proxy'
                          ? w('Subset proxy simulation', '可定价子集代理模拟')
                          : loading
                          ? w('Loading metrics', '正在加载指标')
                          : w(
                              'No comparable simulation · holdings available separately',
                              '暂无可比模拟 · 可单独查看持仓',
                            ),
                      style: s(
                        11,
                        active || compared,
                        active
                            ? p.accent
                            : compared
                            ? const Color(0xFF72B7FF)
                            : p.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final metrics = Row(
      children: [
        for (final stat in metricValues)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(stat.$2, style: s(19, true)),
                const SizedBox(height: 3),
                Text(stat.$1, style: s(11, false, p.muted)),
              ],
            ),
          ),
      ],
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Tooltip(
          message: w(
            compared
                ? 'Remove ${g['name']} from comparison'
                : 'Compare ${g['name']}',
            '${compared ? '移除比较' : '比较'} ${g['name']}',
          ),
          child: OutlinedButton.icon(
            key: ValueKey('guru-directory-compare-$id'),
            onPressed: () => compare(id),
            icon: Icon(compared ? Icons.check : Icons.add, size: 16),
            label: Text(compared ? w('Comparing', '已比较') : w('Compare', '比较')),
          ),
        ),
        TextButton.icon(
          key: ValueKey('guru-directory-holdings-$id'),
          onPressed: () {
            final selectedQuarter =
                active && !detailLoading && !detailFailed && quarter.isNotEmpty
                ? quarter
                : null;
            select(id);
            widget.onExplore(id, selectedQuarter);
          },
          icon: const Icon(Icons.arrow_forward, size: 16),
          label: Text(w('Holdings', '持仓')),
        ),
      ],
    );
    return Container(
      key: directoryKeys.putIfAbsent(id, GlobalKey.new),
      decoration: BoxDecoration(
        color: active ? p.accent.withValues(alpha: .075) : Colors.transparent,
        border: Border(
          top: BorderSide(color: p.border),
          left: BorderSide(
            color: active ? p.accent : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (_, c) => c.maxWidth >= 920
                ? Row(
                    children: [
                      Expanded(flex: 12, child: identity),
                      const SizedBox(width: 22),
                      Expanded(flex: 10, child: metrics),
                      const SizedBox(width: 16),
                      SizedBox(width: 225, child: actions),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      identity,
                      const SizedBox(height: 10),
                      metrics,
                      const SizedBox(height: 10),
                      actions,
                    ],
                  ),
          ),
          if (active) ...[
            const SizedBox(height: 10),
            BacktestPreview(
              key: ValueKey('guru-directory-simulation-$id'),
              guru: {...g, 'type': text(g['type'], 'manager13f')},
              api: widget.api,
              palette: p,
            ),
            const SizedBox(height: 8),
            Text(
              w(
                'Disclosure-date copy simulation: after each public filing, rebalance to the reported common-long weights at the first tradable close. Compare with SPY over the same dates. This is not the manager’s fund NAV and cannot capture quarter-end trading, shorts, private assets or undisclosed cash.',
                '披露日复制模拟：每次申报公开后，在首个可交易收盘按已披露普通股多头权重调仓，并与同区间 SPY 对比。这不是经理的基金净值，无法反映季度内交易、空头、非上市资产或未披露现金。',
              ),
              style: s(11, false, p.muted),
            ),
            const SizedBox(height: 10),
            studyAction(),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => reveal(chartsKey),
                icon: const Icon(Icons.north, size: 16),
                label: Text(w('See highlighted charts', '查看图表高亮')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget shortlistPanel() => box(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 6,
          children: [
            RichText(
              text: TextSpan(
                style: s(21, true),
                children: [
                  TextSpan(text: w('Your study shortlist', '你的学习清单')),
                  TextSpan(
                    text: w(
                      ' · ${shortlist.length} selected',
                      ' · 已选 ${shortlist.length} 位',
                    ),
                    style: s(18, true, p.accent),
                  ),
                ],
              ),
            ),
            Text(
              w(
                'Each dot is a manager. Select one to explore.',
                '每个点代表一位经理，点击即可研究。',
              ),
              style: s(12, false, p.muted),
            ),
          ],
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (_, c) {
            final items = [
              for (final id in shortlist) shortlistCard(id),
              if (shortlist.length < 3) addCard(),
            ];
            if (c.maxWidth < 800) {
              return Column(
                children: [
                  for (final item in items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: item,
                    ),
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: VerticalDivider(width: 1, color: p.border),
                      ),
                    Expanded(
                      flex: shortlist.length == 2 && i == 2 ? 5 : 11,
                      child: items[i],
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    ),
  );
  Widget addCard() => OutlinedButton(
    onPressed: pickManager,
    style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(14)),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.add_circle_outline, size: 44, color: p.muted),
        const SizedBox(height: 10),
        Text(w('Add a Guru', '添加经理'), style: s(14, true)),
        const SizedBox(height: 5),
        Text(
          w('Build your shortlist\n(3 max)', '建立学习清单\n（最多 3 位）'),
          textAlign: TextAlign.center,
          style: s(12, false, p.muted),
        ),
      ],
    ),
  );
  Widget shortlistCard(String id) {
    final g = manager(id),
        m = metric(id),
        active = inspecting == id,
        color = active ? p.accent : const Color(0xFF72B7FF);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            InkWell(
              onTap: () => select(id, revealInList: true),
              borderRadius: BorderRadius.circular(50),
              child: GuruAvatar(
                guru: {...g, 'avatarUrl': g['avatar']},
                palette: p,
                size: 92,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextButton(
                    onPressed: () => select(id, revealInList: true),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      alignment: Alignment.centerLeft,
                      minimumSize: const Size(0, 28),
                    ),
                    child: Text(text(g['name']), style: s(20, true)),
                  ),
                  Text(
                    text(g['entityName']),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: s(12, false, p.muted),
                  ),
                  const SizedBox(height: 7),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .12),
                      border: Border.all(color: color.withValues(alpha: .5)),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      active ? w('Inspecting', '正在研究') : w('Comparing', '正在比较'),
                      style: s(11, true, color),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: w('Remove ${g['name']}', '移除 ${g['name']}'),
              onPressed: () => remove(id),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, size: 15, color: p.muted),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            for (final stat in [
              ('annualTurnover', w('Annual turnover', '年化换手率')),
              ('cagr', 'CAGR'),
              ('sharpe', 'Sharpe'),
            ])
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loading
                          ? '—'
                          : stat.$1 == 'sharpe'
                          ? ratio(m[stat.$1])
                          : pct(m[stat.$1]),
                      style: s(22, true),
                    ),
                    const SizedBox(height: 3),
                    Text(stat.$2, style: s(13, false, p.muted)),
                  ],
                ),
              ),
          ],
        ),
        if (!loading && m.isEmpty)
          Text(
            w('No comparable return history', '暂无可比收益历史'),
            style: s(11, false, p.secondary),
          ),
      ],
    );
  }

  Future<void> pickManager() async {
    var query = '';
    final id = await showDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) {
          final list = widget.gurus
              .where(
                (g) => '${g['name']} ${g['entityName']}'.toLowerCase().contains(
                  query.toLowerCase(),
                ),
              )
              .toList();
          return AlertDialog(
            backgroundColor: p.panel,
            title: Text(w('Choose a manager to study', '选择要研究的经理')),
            content: SizedBox(
              width: 540,
              height: 440,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    onChanged: (v) => update(() => query = v),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: w('Search by manager or firm', '搜索经理或机构'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: list.isEmpty
                        ? Center(
                            child: Text(w('No matching managers', '没有匹配的经理')),
                          )
                        : ListView.builder(
                            itemCount: list.length,
                            itemBuilder: (_, i) {
                              final g = list[i],
                                  m = metric(text(g['id'])),
                                  selected = shortlist.contains(g['id']);
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                leading: GuruAvatar(
                                  guru: {...g, 'avatarUrl': g['avatar']},
                                  palette: p,
                                  size: 42,
                                ),
                                title: Text(text(g['name'])),
                                subtitle: Text(
                                  m.isEmpty
                                      ? w(
                                          'Quarterly holdings · no comparable simulation',
                                          '季度持仓 · 暂无可比模拟',
                                        )
                                      : w(
                                          '${pct(m['annualTurnover'])} turnover · ${pct(m['cagr'])} CAGR · ${ratio(m['sharpe'])} Sharpe',
                                          '换手率 ${pct(m['annualTurnover'])} · CAGR ${pct(m['cagr'])} · 夏普 ${ratio(m['sharpe'])}',
                                        ),
                                  style: s(12, false, p.muted),
                                ),
                                trailing: Icon(
                                  selected
                                      ? Icons.check_circle_outline
                                      : Icons.add,
                                  color: selected ? p.accent : p.muted,
                                ),
                                onTap: () =>
                                    Navigator.pop(dialog, text(g['id'])),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(w('Cancel', '取消')),
              ),
            ],
          );
        },
      ),
    );
    if (mounted && id != null) {
      if (!shortlist.contains(id)) compare(id);
      select(id, revealInList: true);
    }
  }

  Widget studyAction() {
    final g = manager(inspecting);
    final controls = Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (detailLoading)
          Text(w('Loading quarters…', '正在加载季度…'), style: s(12, false, p.muted))
        else if (detailFailed)
          TextButton(
            onPressed: loadQuarters,
            child: Text(w('Retry quarters', '重试季度')),
          )
        else if (quarters.isNotEmpty) ...[
          dropdown(
            'quarter',
            quarter,
            [
              for (final q in quarters)
                (text(q['accessionNumber']), quarterLabel(q)),
            ],
            (v) => change(() => quarter = v),
            width: 140,
          ),
          for (final q in quarters.take(3))
            chip(
              quarterLabel(q),
              quarter == q['accessionNumber'],
              () => change(() => quarter = text(q['accessionNumber'])),
            ),
        ] else
          Text(
            w('No disclosed quarters at this cutoff', '截止日期前暂无披露季度'),
            style: s(12, false, p.muted),
          ),
      ],
    );
    return box(
      LayoutBuilder(
        builder: (_, c) {
          final person = Row(
            children: [
              GuruAvatar(
                guru: {...g, 'avatarUrl': g['avatar']},
                palette: p,
                size: 64,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w(
                        "Study ${g['name']}'s decisions",
                        '研究 ${g['name']} 的决策',
                      ),
                      style: s(20, true),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      w(
                        'Select a stock next to test its valuation.',
                        '下一步选一只股票，检验它的估值。',
                      ),
                      style: s(13, false, p.muted),
                    ),
                  ],
                ),
              ),
            ],
          );
          final actions = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                onPressed: detailLoading || detailFailed || quarter.isEmpty
                    ? null
                    : () => widget.onExplore(inspecting, quarter),
                style: FilledButton.styleFrom(minimumSize: const Size(44, 40)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(w('Explore quarterly holdings', '查看季度持仓')),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward, size: 17),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: followBusy
                      ? null
                      : () async {
                          setState(() => followBusy = true);
                          try {
                            await widget.onFollow(g);
                          } finally {
                            if (mounted) setState(() => followBusy = false);
                          }
                        },
                  icon: Icon(
                    g['followed'] == true ? Icons.check : Icons.add,
                    size: 16,
                  ),
                  label: Text(
                    g['followed'] == true
                        ? w('Following', '已关注')
                        : w('Follow', '关注'),
                  ),
                  style: TextButton.styleFrom(minimumSize: const Size(44, 30)),
                ),
              ),
            ],
          );
          return c.maxWidth >= 1050
              ? Row(
                  children: [
                    Expanded(flex: 10, child: person),
                    const SizedBox(width: 16),
                    Expanded(flex: 11, child: controls),
                    const SizedBox(width: 16),
                    SizedBox(width: 250, child: actions),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    person,
                    const SizedBox(height: 14),
                    controls,
                    const SizedBox(height: 14),
                    actions,
                  ],
                );
        },
      ),
    );
  }

  void showMethod() => showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      backgroundColor: p.panel,
      title: Text(w('How to read this comparison', '如何阅读这组对比')),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                w(
                  'Cash-preserving: uncovered holdings remain cash. Subset proxy: only priceable holdings are included, then weights are rescaled. These are different simulation methods, not actual manager or fund returns.',
                  '未覆盖留现金：缺少价格的持仓权重保留为现金。子集代理：只保留可定价持仓，并重新归一化权重。两者为不同模拟口径，不是经理或基金的实盘收益。',
                ),
                style: s(),
              ),
              const SizedBox(height: 14),
              Text(
                w(
                  'Annual one-way turnover compares target weights to drifted pre-rebalance weights, including cash. Initial funding and forced corporate actions are excluded. CAGR is geometric annualized return. Sharpe uses daily returns, 252 sessions and 0% risk-free rate. Costs, tax, shorts and private assets are excluded.',
                  '年化单边换手率对比新目标权重与调仓前漂移权重，包含现金；排除初次建仓和强制公司行动。CAGR 为几何年化收益；夏普使用日收益、252 个交易日、0% 无风险利率。不含成本、税费、空头和私有资产。',
                ),
                style: s(),
              ),
              const SizedBox(height: 14),
              Text(
                w(
                  'All points and SPY use the same overlapping dates from stored 5-year simulations. Filters keep that window fixed. This is a retrospective, current-manager sample, not a prediction or proof that turnover causes performance. Renaissance represents public 13F holdings, not Medallion.',
                  '所有点和 SPY 使用已存 5 年模拟中的共同日期，筛选不会改变区间。这是当前经理样本的历史回看，不是预测，也不能证明换手率导致收益变化。Renaissance 仅代表公开 13F 持仓，不是 Medallion。',
                ),
                style: s(),
              ),
              if (asList(data?['unavailable']).isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(w('Unavailable simulations', '不可用模拟'), style: s(15, true)),
                for (final g in asList(data?['unavailable']))
                  Text(text(g['name']), style: s(12, false, p.muted)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: Text(w('Got it', '知道了')),
        ),
      ],
    ),
  );
}
