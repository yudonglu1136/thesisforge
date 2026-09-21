part of 'main.dart';

// This screen composes existing read-only disclosures and the original study.
// Missing entries are unknown, not zero positions or inferred exits.
class GuruDiscoveryDesk extends StatefulWidget {
  const GuruDiscoveryDesk({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.gurus,
    required this.onExplore,
    required this.onFollow,
    required this.onCompany,
    this.initialSelection = const {},
    this.onSelection,
  });
  final ApiClient api;
  final Palette palette;
  final String asOf;
  final List<Map<String, dynamic>> gurus;
  final void Function(String, String?) onExplore;
  final Future<void> Function(Map<String, dynamic>) onFollow;
  final ValueChanged<String> onCompany;
  final Map<String, dynamic> initialSelection;
  final ValueChanged<Map<String, dynamic>>? onSelection;
  @override
  State<GuruDiscoveryDesk> createState() => _GuruDiscoveryDeskState();
}

class _GuruDiscoveryDeskState extends State<GuruDiscoveryDesk> {
  final studyKey = GlobalKey(), holdingsKey = GlobalKey();
  late Map<String, dynamic> selection;
  @override
  void initState() {
    super.initState();
    selection = {...widget.initialSelection};
  }

  void reveal(GlobalKey key) {
    final target = key.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 300),
        alignment: 0,
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      GuruHoldingsMatrix(
        key: holdingsKey,
        api: widget.api,
        palette: widget.palette,
        asOf: widget.asOf,
        gurus: widget.gurus,
        initialSelection: asMap(selection['holdings']),
        onSelection: (value) {
          selection['holdings'] = value;
          widget.onSelection?.call({...selection});
        },
        onExplore: widget.onExplore,
        onCompany: widget.onCompany,
        onStudy: () => reveal(studyKey),
      ),
      const SizedBox(height: 28),
      Row(
        key: studyKey,
        children: [
          Expanded(
            child: Text(
              context.tr('风格与业绩对比', 'Style & performance'),
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: widget.palette.text,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: () => reveal(holdingsKey),
            icon: const Icon(Icons.arrow_upward, size: 16),
            label: Text(context.tr('返回持仓', 'Back to holdings')),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        context.tr(
          '保留你的学习清单。点击图点与头像联动，再深入季度持仓。',
          'Keep your study shortlist. Select a chart point or portrait, then explore quarterly holdings.',
        ),
        style: TextStyle(fontSize: 13, color: widget.palette.muted),
      ),
      const SizedBox(height: 16),
      GuruStudyPanel(
        api: widget.api,
        palette: widget.palette,
        asOf: widget.asOf,
        gurus: widget.gurus,
        initialSelection: selection,
        onSelection: (value) {
          selection = {...value, 'holdings': selection['holdings']};
          widget.onSelection?.call({...selection});
        },
        onExplore: widget.onExplore,
        onFollow: widget.onFollow,
      ),
    ],
  );
}

double? guruShareChange(Map<String, dynamic> holding) {
  final prior = nullableNumber(holding['previousShares']);
  final delta = nullableNumber(holding['changeShares']);
  return prior != null && prior > 0 && delta != null ? delta / prior : null;
}

List<Map<String, dynamic>> filterGuruMatrix(
  List<Map<String, dynamic>> rows,
  Set<String> selected, {
  String query = '',
  bool concentrated = false,
  String sort = 'holders',
}) {
  final result = rows.where((row) {
    final people = asList(
      row['managers'],
    ).where((m) => selected.contains(m['guruId']));
    return people.isNotEmpty &&
        (!concentrated ||
            people.any((m) => (nullableNumber(m['weight']) ?? -1) >= .10)) &&
        '${row['ticker']} ${row['name']}'.toLowerCase().contains(
          query.trim().toLowerCase(),
        );
  }).toList();
  double rank(Map<String, dynamic> row) {
    final people = asList(
      row['managers'],
    ).where((m) => selected.contains(m['guruId']));
    if (sort == 'weight') {
      return people.fold(0.0, (v, m) => math.max(v, number(m['weight'])));
    }
    if (sort == 'changes') {
      return people
          .where(
            (m) => {
              'new',
              'increased',
              'reduced',
              'sold_out',
            }.contains(m['action']),
          )
          .length
          .toDouble();
    }
    return number(row['managerCount']);
  }

  result.sort(
    (a, b) => sort == 'ticker'
        ? text(a['ticker']).compareTo(text(b['ticker']))
        : rank(b).compareTo(rank(a)) != 0
        ? rank(b).compareTo(rank(a))
        : text(a['ticker']).compareTo(text(b['ticker'])),
  );
  return result;
}

class GuruHoldingsMatrix extends StatefulWidget {
  const GuruHoldingsMatrix({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.gurus,
    required this.onExplore,
    required this.onCompany,
    required this.onStudy,
    this.initialSelection = const {},
    this.onSelection,
  });
  final ApiClient api;
  final Palette palette;
  final String asOf;
  final List<Map<String, dynamic>> gurus;
  final void Function(String, String?) onExplore;
  final ValueChanged<String> onCompany;
  final VoidCallback onStudy;
  final Map<String, dynamic> initialSelection;
  final ValueChanged<Map<String, dynamic>>? onSelection;
  @override
  State<GuruHoldingsMatrix> createState() => _GuruHoldingsMatrixState();
}

class _GuruHoldingsMatrixState extends State<GuruHoldingsMatrix> {
  final managerSearch = TextEditingController(),
      stockSearch = TextEditingController();
  final horizontal = ScrollController();
  Map<String, dynamic>? data;
  final Map<String, Map<String, dynamic>> companyDetails = {};
  List<String> selected = [];
  String quarter = '',
      ticker = '',
      focusedGuru = '',
      capitalFilter = 'all',
      mode = 'weight',
      sort = 'holders';
  bool loading = true,
      failed = false,
      concentrated = false,
      changesDetail = false;
  int request = 0, managerPage = 0, stockPage = 0;
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  TextStyle s([double size = 13, bool bold = false, Color? color]) => TextStyle(
    fontSize: size,
    height: 1.3,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? p.text,
  );
  String pct(dynamic value, {bool signed = false}) =>
      nullableNumber(value) == null
      ? '—'
      : '${signed && number(value) > 0 ? '+' : ''}${(number(value) * 100).toStringAsFixed(2)}%';
  List<Map<String, dynamic>> get rows => asList(data?['rows']);
  List<Map<String, dynamic>> get matches => filterGuruMatrix(
    rows,
    selected.toSet(),
    query: stockSearch.text,
    concentrated: concentrated,
    sort: sort,
  );
  Map<String, dynamic> get current =>
      matches.where((r) => r['ticker'] == ticker).firstOrNull ?? {};
  Map<String, dynamic> manager(String id) =>
      widget.gurus.where((g) => g['id'] == id).firstOrNull ??
      {'id': id, 'name': id};
  List<String> get validSelected =>
      selected.where((id) => widget.gurus.any((g) => g['id'] == id)).toList();
  String qLabel(String value) => value.length < 7
      ? value
      : '${value.substring(0, 4)} Q${(int.parse(value.substring(5, 7)) + 2) ~/ 3}';

  @override
  void initState() {
    super.initState();
    final v = widget.initialSelection;
    selected = List<String>.from(
      v['selected'] ??
          ['li-lu', 'warren-buffett', 'chase-coleman', 'bill-ackman'],
    );
    quarter = text(v['quarter']);
    ticker = text(v['ticker']);
    focusedGuru = text(v['focusedGuru'], selected.firstOrNull ?? '');
    final savedCapitalFilter = text(v['capitalFilter'], 'all');
    capitalFilter =
        {
          'all',
          'permanent',
          'owner_controlled',
          'mixed',
          'external_client',
          'archived',
        }.contains(savedCapitalFilter)
        ? savedCapitalFilter
        : 'all';
    mode = text(v['mode'], 'weight');
    sort = text(v['sort'], 'holders');
    concentrated = v['concentrated'] == true;
    stockSearch.text = text(v['query']);
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant GuruHoldingsMatrix old) {
    super.didUpdateWidget(old);
    if (old.asOf != widget.asOf || old.api != widget.api) {
      quarter = '';
      data = null;
      companyDetails.clear();
      unawaited(load());
    }
  }

  @override
  void dispose() {
    managerSearch.dispose();
    stockSearch.dispose();
    horizontal.dispose();
    super.dispose();
  }

  void remember() => widget.onSelection?.call({
    'selected': selected.toList(),
    'quarter': quarter,
    'ticker': ticker,
    'focusedGuru': focusedGuru,
    'capitalFilter': capitalFilter,
    'mode': mode,
    'sort': sort,
    'concentrated': concentrated,
    'query': stockSearch.text,
  });
  void update(VoidCallback action, {bool reset = false}) {
    final previousTicker = ticker;
    setState(() {
      action();
      if (reset) stockPage = 0;
      if (!matches.any((r) => r['ticker'] == ticker)) {
        ticker = text(matches.firstOrNull?['ticker']);
      }
    });
    remember();
    if (ticker.isNotEmpty && ticker != previousTicker) {
      unawaited(loadCompanyDetail(ticker));
    }
  }

  Future<void> loadCompanyDetail(String symbol) async {
    if (companyDetails.containsKey(symbol)) return;
    final cutoff = widget.asOf;
    try {
      final detail = await widget.api.getJson(
        '/api/investment/opportunities/${Uri.encodeComponent(symbol)}?asOf=$cutoff',
      );
      if (!mounted || cutoff != widget.asOf || detail['ticker'] != symbol) {
        return;
      }
      setState(() => companyDetails[symbol] = detail);
    } catch (_) {
      // Ownership remains usable when a company has no compatible model or
      // dated price. The detail panel keeps those values explicitly unknown.
    }
  }

  Future<void> load() async {
    final serial = ++request, cutoff = widget.asOf, target = quarter;
    setState(() {
      loading = true;
      failed = false;
      data = null;
    });
    try {
      final next = await widget.api.getJson(
        '/api/investment/guru-holdings?asOf=$cutoff${target.isEmpty ? '' : '&quarter=$target'}',
      );
      if (!mounted || serial != request || cutoff != widget.asOf) return;
      if (next['asOf'] != cutoff ||
          (target.isNotEmpty && next['reportDate'] != target)) {
        throw StateError('mismatched disclosure date');
      }
      update(() {
        data = next;
        quarter = text(next['reportDate']);
      }, reset: true);
    } catch (_) {
      if (mounted && serial == request) setState(() => failed = true);
    } finally {
      if (mounted && serial == request) setState(() => loading = false);
    }
  }

  Future<void> exploreQuarter(String id) async {
    final target = quarter, cutoff = widget.asOf;
    try {
      final profile = await widget.api.getJson(
        '/api/investment/gurus/${Uri.encodeComponent(id)}?asOf=$cutoff',
      );
      if (!mounted || target != quarter || cutoff != widget.asOf) return;
      final filing = asList(
        profile['history'],
      ).where((f) => f['reportDate'] == target).firstOrNull;
      if (filing != null) {
        widget.onExplore(id, text(filing['accessionNumber']));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              w(
                'No filing is available for this Guru in ${qLabel(target)}. Explore their available history instead.',
                '该 Guru 在 ${qLabel(target)} 没有可用披露，可查看其他历史季度。',
              ),
            ),
            action: SnackBarAction(
              label: w('View history', '查看历史'),
              onPressed: () => widget.onExplore(id, null),
            ),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            w('Could not load this filing. Please try again.', '无法加载披露，请重试。'),
          ),
        ),
      );
    }
  }

  Widget panel(Widget child, {EdgeInsets padding = const EdgeInsets.all(12)}) =>
      Container(
        padding: padding,
        decoration: BoxDecoration(
          color: p.panel,
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      );
  Widget chip(String en, String zh, bool active, VoidCallback action) =>
      ChoiceChip(
        label: Text(w(en, zh), style: s(12)),
        selected: active,
        onSelected: (_) => action(),
        visualDensity: VisualDensity.compact,
      );
  Widget avatar(Map<String, dynamic> g, double size) => GuruAvatar(
    guru: {...g, 'avatarUrl': g['avatar']},
    palette: p,
    size: size,
  );
  Widget search(
    TextEditingController controller,
    String en,
    String zh,
    VoidCallback action,
  ) => TextField(
    controller: controller,
    style: s(12),
    onChanged: (_) => action(),
    decoration: InputDecoration(
      hintText: w(en, zh),
      prefixIcon: const Icon(Icons.search, size: 18),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
    ),
  );
  Widget selectControl(
    String key,
    String value,
    List<(String, String)> options,
    ValueChanged<String> action,
    double width,
  ) => SizedBox(
    width: width,
    child: DropdownButtonFormField<String>(
      key: ValueKey('matrix-$key-$value'),
      initialValue: value,
      isExpanded: true,
      style: s(12),
      dropdownColor: p.panel,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
      items: options
          .map(
            (e) => DropdownMenuItem(
              value: e.$1,
              child: Text(e.$2, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) action(v);
      },
    ),
  );

  String actionName(Map<String, dynamic> m) => switch (m['action']) {
    'new' => w('New', '新建'),
    'increased' => w('Added', '加仓'),
    'reduced' => w('Reduced', '减仓'),
    'sold_out' => w('Exited', '清仓'),
    'unchanged' => w('Unchanged', '不变'),
    'mixed_claims' => w('Mixed claims', '多类证券'),
    _ => w('Reported', '已披露'),
  };
  Color actionColor(Map<String, dynamic> m) => switch (m['action']) {
    'new' || 'increased' => p.accent,
    'reduced' => p.secondary,
    'sold_out' => p.negative,
    _ => p.muted,
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, c) {
      final desktop = c.maxWidth >= 1000;
      final work = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          toolbar(),
          const SizedBox(height: 8),
          if (loading)
            panel(
              const Padding(
                padding: EdgeInsets.all(24),
                child: LinearProgressIndicator(),
              ),
            )
          else if (failed)
            panel(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w('Could not load this quarter.', '暂时无法加载此季度。'),
                    style: s(16, true),
                  ),
                  TextButton(
                    onPressed: load,
                    child: Text(w('Retry disclosures', '重试披露')),
                  ),
                ],
              ),
            )
          else ...[
            table(availableWidth: desktop ? c.maxWidth - 232 : c.maxWidth),
            const SizedBox(height: 8),
            if (!desktop && c.maxWidth < 700)
              Text(
                w(
                  'Swipe across the table to compare all columns.',
                  '横向滑动表格，比较全部列。',
                ),
                style: s(11, false, p.accent),
              ),
            Text(
              w(
                '% / shading = each Guru’s reported book weight. Consensus counts cover all reporting Gurus, not just those selected. Labels show reported share changes, not live trades. Missing rows are not exits.',
                '百分比与颜色深浅 = 单个 Guru 的披露持仓权重。共识人数统计全部已披露 Guru，不仅是勾选的人。标签表示披露股数变化，非实时交易；缺失记录不代表清仓。',
              ),
              style: s(11, false, p.muted),
            ),
            Text(
              w(
                '${asMap(data?['coverage'])['reportedManagers'] ?? '—'} managers in this disclosure view · All ${widget.gurus.length} profiles remain available below.',
                '此披露视图包含 ${asMap(data?['coverage'])['reportedManagers'] ?? '—'} 位经理 · 下方保留全部 ${widget.gurus.length} 个资料。',
              ),
              style: s(11, false, p.muted),
            ),
            if (asMap(data?['coverage'])['scope'] != 'full_current_books')
              Text(
                w(
                  'Historical extracts are partial. View the filing for complete holdings.',
                  '历史摘录并非完整持仓，请查看原始披露。',
                ),
                style: s(11, false, p.secondary),
              ),
            const SizedBox(height: 12),
            if (current.isNotEmpty) companyDetail(),
          ],
        ],
      );
      return desktop
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 220, height: 800, child: rail()),
                const SizedBox(width: 12),
                Expanded(child: work),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 430 * MediaQuery.textScalerOf(context).scale(1),
                  child: rail(),
                ),
                const SizedBox(height: 12),
                work,
              ],
            );
    },
  );

  Widget rail() {
    final catalog = widget.gurus.where((g) {
      final structure = asMap(g['capitalStructure']);
      return (capitalFilter == 'all' ||
              structure['category'] == capitalFilter) &&
          '${g['name']} ${g['entityName']}'.toLowerCase().contains(
            managerSearch.text.trim().toLowerCase(),
          );
    }).toList();
    catalog.sort((a, b) {
      final ai = selected.indexOf(text(a['id']));
      final bi = selected.indexOf(text(b['id']));
      if (ai >= 0 && bi >= 0) return ai.compareTo(bi);
      if (ai >= 0) return -1;
      if (bi >= 0) return 1;
      return text(a['name']).compareTo(text(b['name']));
    });
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            w(
              'All Gurus (${widget.gurus.length})',
              '全部 Guru（${widget.gurus.length}）',
            ),
            style: s(17, true),
          ),
          const SizedBox(height: 10),
          search(
            managerSearch,
            'Search Guru name',
            '搜索 Guru 姓名',
            () => setState(() {}),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('guru-capital-filter-$capitalFilter'),
            initialValue: capitalFilter,
            isExpanded: true,
            style: s(11),
            dropdownColor: p.panel,
            decoration: InputDecoration(
              labelText: w('Capital structure', '资本结构'),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
            ),
            items:
                [
                      ('all', w('All structures', '全部结构')),
                      ('permanent', w('Permanent capital', '永续资本')),
                      (
                        'owner_controlled',
                        w('Owner / family capital', '所有者 / 家族资本'),
                      ),
                      ('mixed', w('Mixed capital', '混合资本')),
                      (
                        'external_client',
                        w('External / client capital', '外部 / 客户资本'),
                      ),
                      ('archived', w('Historical vehicle', '历史载体')),
                    ]
                    .map(
                      (e) => DropdownMenuItem(value: e.$1, child: Text(e.$2)),
                    )
                    .toList(),
            onChanged: (value) =>
                update(() => capitalFilter = value ?? 'all', reset: true),
          ),
          const SizedBox(height: 6),
          Text(
            w(
              'Permanent means no ordinary outside-investor redemption. Family capital and mixed managers are shown separately.',
              '“永续”仅指没有普通外部投资者赎回机制；家族资本与混合型机构单独列示。',
            ),
            style: s(10, false, p.muted),
          ),
          Wrap(
            children: [
              TextButton(
                onPressed: () => update(() {
                  selected = widget.gurus.map((g) => text(g['id'])).toList();
                  managerPage = 0;
                }, reset: true),
                child: Text(
                  w('Select all', '全选'),
                  style: s(11, false, p.accent),
                ),
              ),
              TextButton(
                onPressed: () => update(() {
                  selected = [];
                  managerPage = 0;
                }, reset: true),
                child: Text(w('Clear', '清空'), style: s(11, false, p.muted)),
              ),
            ],
          ),
          Expanded(
            child: catalog.isEmpty
                ? Text(
                    w('No Gurus match.', '没有匹配的 Guru。'),
                    style: s(12, false, p.muted),
                  )
                : ListView.builder(
                    key: const ValueKey('matrix-guru-list'),
                    itemCount: catalog.length,
                    itemBuilder: (_, i) {
                      final g = catalog[i],
                          id = text(g['id']),
                          active = selected.contains(id);
                      final structure = asMap(g['capitalStructure']);
                      final category = text(
                        structure['category'],
                        'unclassified',
                      );
                      final capitalLabel = w(
                        text(structure['label'], 'Not classified'),
                        text(structure['labelZh'], '尚未分类'),
                      );
                      final capitalDetail = w(
                        text(
                          structure['detail'],
                          'This capital structure has not been verified.',
                        ),
                        text(structure['detailZh'], '该资本结构尚未核实。'),
                      );
                      final capitalColor = switch (category) {
                        'permanent' => p.accent,
                        'mixed' => p.secondary,
                        'owner_controlled' => const Color(0xFF76BCEB),
                        _ => p.muted,
                      };
                      return SizedBox(
                        height: 52,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 28,
                              child: Checkbox(
                                value: active,
                                semanticLabel: w(
                                  'Show ${g['name']}',
                                  '显示 ${g['name']}',
                                ),
                                onChanged: (_) => update(() {
                                  if (active) {
                                    selected.remove(id);
                                  } else {
                                    selected.add(id);
                                  }
                                  managerPage = 0;
                                }, reset: true),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: InkWell(
                                key: ValueKey('matrix-portrait-$id'),
                                onTap: () => unawaited(exploreQuarter(id)),
                                child: Row(
                                  children: [
                                    avatar(g, 28),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            text(g['name']),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: s(12),
                                          ),
                                          Tooltip(
                                            message: capitalDetail,
                                            child: Text(
                                              capitalLabel,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: s(9, false, capitalColor),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 10),
          InkWell(
            key: const ValueKey('matrix-study-link'),
            onTap: widget.onStudy,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(Icons.bar_chart, color: p.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          w('Style & performance', '风格与业绩对比'),
                          style: s(12, true, p.accent),
                        ),
                        Text(
                          w('Turnover · CAGR · Sharpe', '换手率 · 复合收益 · 夏普'),
                          style: s(10, false, p.muted),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.arrow_forward, size: 16, color: p.accent),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget toolbar() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.people_outline, color: p.accent, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                w('Consensus = shared holdings', '共识持仓 = 多位 Guru 共同持有'),
                style: s(15, true, p.accent),
              ),
            ),
            Tooltip(
              triggerMode: TooltipTriggerMode.tap,
              message: w(
                'Read across a row to compare one stock across Gurus. Read down a column to see one Guru’s holdings. Percentages are weights in each Guru’s reported book, not a combined portfolio or total fund assets. Holder counts cover all reporting Gurus for this quarter, not just your selection. Added / Reduced describe reported share changes, not live trades. Missing entries do not mean an exit.',
                '横向看同一只股票由哪些 Guru 持有，纵向看某位 Guru 的持仓。百分比是各自披露持仓中的权重，不是合并组合权重，也不代表基金全部资产。持有人数统计该季度所有已披露 Guru，不仅是勾选的人。加减仓指披露股数变化，非实时交易；缺失记录不代表清仓。',
              ),
              child: Semantics(
                label: w('How to read consensus holdings', '如何读共识持仓'),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(Icons.info_outline, size: 18, color: p.muted),
                ),
              ),
            ),
          ],
        ),
        Text(
          w(
            'Overlap is not unanimous conviction or a buy signal. A Guru may still hold a stock while reducing it.',
            '共同持有不代表一致看多或买入建议；仍持有的 Guru 也可能正在减仓。',
          ),
          style: s(12, false, p.muted),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (quarter.isNotEmpty &&
                (data?['quarters'] as List? ?? []).contains(quarter))
              selectControl(
                'quarter',
                quarter,
                [
                  for (final q in data!['quarters'])
                    (q as String, '${qLabel(q)} ($q)'),
                ],
                (v) {
                  quarter = v;
                  unawaited(load());
                },
                185,
              ),
            chip(
              'Holding weight',
              '持仓权重',
              mode == 'weight',
              () => update(() => mode = 'weight'),
            ),
            chip(
              'Quarterly change',
              '季度变化',
              mode == 'change',
              () => update(() => mode = 'change'),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  label: w('Only positions of at least 10%', '只显示至少 10% 的持仓'),
                  child: Switch(
                    key: const ValueKey('matrix-concentrated'),
                    value: concentrated,
                    onChanged: (v) =>
                        update(() => concentrated = v, reset: true),
                  ),
                ),
                Flexible(
                  child: Text(
                    w('Only ≥ 10% positions', '只看 ≥ 10% 重仓'),
                    style: s(12),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 200,
              child: search(
                stockSearch,
                'Find a company',
                '查找公司',
                () => update(() {}, reset: true),
              ),
            ),
            selectControl(
              'sort',
              sort,
              [
                ('holders', w('Most holders', '持有人数最多')),
                ('changes', w('Most quarterly moves', '季度变动最多')),
                ('weight', w('Highest conviction', '持仓权重最高')),
                ('ticker', w('Ticker A–Z', '代码 A–Z')),
              ],
              (v) => update(() => sort = v, reset: true),
              175,
            ),
            Text(
              w('Available by ${widget.asOf}', '披露截至 ${widget.asOf}'),
              style: s(11, false, p.muted),
            ),
          ],
        ),
      ],
    ),
  );

  Widget table({required double availableWidth}) {
    final perPage = availableWidth >= 700 && availableWidth < 840 ? 3 : 4;
    final chosen = validSelected;
    final start = math.min(
      managerPage * perPage,
      math.max(0, chosen.length - 1),
    );
    final columns = chosen.skip(start).take(perPage).map(manager).toList();
    final list = matches, pageRows = list.skip(stockPage * 5).take(5).toList();
    if (chosen.isEmpty || list.isEmpty) {
      return panel(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              chosen.isEmpty
                  ? w('Choose Gurus to compare', '选择 Guru 开始比较')
                  : w('No disclosed holdings match.', '没有匹配的已披露持仓。'),
              style: s(17, true),
            ),
            const SizedBox(height: 8),
            Text(
              w(
                'Change your selection or filters. An unavailable book is not a zero holding.',
                '请调整选择或筛选；没有可用披露不代表零持仓。',
              ),
              style: s(12, false, p.muted),
            ),
            if (chosen.isNotEmpty)
              TextButton(
                onPressed: () => update(() {
                  stockSearch.clear();
                  concentrated = false;
                }, reset: true),
                child: Text(w('Clear stock filters', '清空股票筛选')),
              ),
          ],
        ),
      );
    }
    return panel(
      padding: EdgeInsets.zero,
      Column(
        children: [
          LayoutBuilder(
            builder: (_, c) {
              final width = math.max(
                c.maxWidth,
                155 + columns.length * 126 + 180.0,
              );
              final cw = (width - 155 - 180) / columns.length;
              Widget cell(Widget child, double width, {Color? color}) =>
                  Container(
                    width: width,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    color: color,
                    child: child,
                  );
              return Scrollbar(
                controller: horizontal,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: horizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: width,
                    child: Column(
                      children: [
                        IntrinsicHeight(
                          child: Row(
                            children: [
                              cell(
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    w('Company', '公司'),
                                    style: s(14, true),
                                  ),
                                ),
                                155,
                                color: p.card,
                              ),
                              for (final g in columns)
                                cell(
                                  InkWell(
                                    onTap: () => unawaited(
                                      exploreQuarter(text(g['id'])),
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        avatar(g, 48),
                                        const SizedBox(height: 4),
                                        Text(
                                          text(g['name']),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: s(13, true),
                                        ),
                                        Text(
                                          text(g['entityName']),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: s(10, false, p.muted),
                                        ),
                                      ],
                                    ),
                                  ),
                                  cw,
                                  color: p.card,
                                ),
                              cell(
                                Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        IconButton(
                                          tooltip: w(
                                            'Previous Gurus',
                                            '上一组 Guru',
                                          ),
                                          constraints: const BoxConstraints(
                                            minWidth: 32,
                                            minHeight: 32,
                                          ),
                                          padding: EdgeInsets.zero,
                                          onPressed: managerPage > 0
                                              ? () =>
                                                    update(() => managerPage--)
                                              : null,
                                          icon: const Icon(
                                            Icons.chevron_left,
                                            size: 18,
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            '${start + 1}–${math.min(start + perPage, chosen.length)} / ${chosen.length}',
                                            style: s(11),
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: w('Next Gurus', '下一组 Guru'),
                                          constraints: const BoxConstraints(
                                            minWidth: 32,
                                            minHeight: 32,
                                          ),
                                          padding: EdgeInsets.zero,
                                          onPressed:
                                              start + perPage < chosen.length
                                              ? () =>
                                                    update(() => managerPage++)
                                              : null,
                                          icon: const Icon(
                                            Icons.chevron_right,
                                            size: 18,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      w('Consensus', '共识概览'),
                                      style: s(14, true),
                                    ),
                                    Text(
                                      w(
                                        'All reporting Gurus · this quarter',
                                        '该季度全部已披露 Guru',
                                      ),
                                      style: s(10, false, p.muted),
                                    ),
                                  ],
                                ),
                                180,
                                color: p.card,
                              ),
                            ],
                          ),
                        ),
                        for (final row in pageRows)
                          IntrinsicHeight(
                            child: Row(
                              children: [
                                cell(
                                  InkWell(
                                    key: ValueKey(
                                      'matrix-stock-${row['ticker']}',
                                    ),
                                    onTap: () => update(() {
                                      ticker = text(row['ticker']);
                                      focusedGuru = '';
                                    }),
                                    child: Row(
                                      children: [
                                        StockLogo(
                                          ticker: text(row['ticker']),
                                          palette: p,
                                          size: 30,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                text(row['ticker']),
                                                style: s(12, true),
                                              ),
                                              Text(
                                                text(row['name']),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: s(10, false, p.muted),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  155,
                                  color: ticker == row['ticker']
                                      ? p.accent.withValues(alpha: .10)
                                      : null,
                                ),
                                for (final g in columns)
                                  SizedBox(
                                    width: cw,
                                    child: holdingCell(row, g),
                                  ),
                                cell(
                                  InkWell(
                                    onTap: () => update(() {
                                      ticker = text(row['ticker']);
                                      focusedGuru = '';
                                    }),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                w(
                                                  '${row['managerCount']} holders',
                                                  '${row['managerCount']} 位持有者',
                                                ),
                                                style: s(13, true),
                                              ),
                                              Text(
                                                w(
                                                  '${row['adds']} new / added · ${row['trims']} reduced / exited',
                                                  '${row['adds']} 新增 / 加仓 · ${row['trims']} 减仓 / 清仓',
                                                ),
                                                style: s(10, false, p.muted),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const Icon(Icons.expand_more, size: 16),
                                      ],
                                    ),
                                  ),
                                  180,
                                  color: ticker == row['ticker']
                                      ? p.card
                                      : null,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    w(
                      '${stockPage * 5 + 1}–${math.min(stockPage * 5 + 5, list.length)} / ${list.length} stocks · ${chosen.length} Gurus selected',
                      '${stockPage * 5 + 1}–${math.min(stockPage * 5 + 5, list.length)} / ${list.length} 只股票 · 已选 ${chosen.length} 位 Guru',
                    ),
                    style: s(11, false, p.muted),
                  ),
                ),
                IconButton(
                  tooltip: w('Previous stocks', '上一页股票'),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: stockPage > 0
                      ? () => update(() => stockPage--)
                      : null,
                  icon: const Icon(Icons.chevron_left, size: 18),
                ),
                IconButton(
                  tooltip: w('Next stocks', '下一页股票'),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: (stockPage + 1) * 5 < list.length
                      ? () => update(() => stockPage++)
                      : null,
                  icon: const Icon(Icons.chevron_right, size: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget holdingCell(Map<String, dynamic> row, Map<String, dynamic> guru) {
    final m = asList(
      row['managers'],
    ).where((m) => m['guruId'] == guru['id']).firstOrNull;
    final active = ticker == row['ticker'] && focusedGuru == guru['id'];
    final weight = m == null ? null : nullableNumber(m['weight']);
    final tint = mode == 'weight'
        ? p.accent
        : m == null
        ? p.muted
        : actionColor(m);
    return Tooltip(
      message: m == null
          ? w(
              'No row in this disclosure view. This does not establish a zero position.',
              '此披露视图没有记录，不能据此认定零持仓。',
            )
          : '${m['reportDate']} · ${w('Filed', '披露')} ${m['availableAt']} · ${w('Reported book weight, not fund assets', '披露持仓权重，非基金总资产')}',
      child: InkWell(
        key: ValueKey('matrix-cell-${row['ticker']}-${guru['id']}'),
        onTap: () {
          if (m == null) {
            unawaited(exploreQuarter(text(guru['id'])));
            return;
          }
          update(() {
            ticker = text(row['ticker']);
            focusedGuru = text(guru['id']);
          });
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 62),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            color: weight == null
                ? null
                : tint.withValues(
                    alpha: (.025 + weight.clamp(0, .4) * .9).toDouble(),
                  ),
            border: Border.all(
              color: active ? p.accent : p.border.withValues(alpha: .45),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                m == null
                    ? w('View filing', '查看披露')
                    : mode == 'weight'
                    ? pct(weight)
                    : guruShareChange(m) == null
                    ? '—'
                    : pct(guruShareChange(m), signed: true),
                style: s(
                  m == null ? 11 : 15,
                  m != null,
                  m == null ? p.muted : null,
                ),
              ),
              if (m != null)
                Text(actionName(m), style: s(11, false, actionColor(m))),
            ],
          ),
        ),
      ),
    );
  }

  Widget companyDetail() {
    final row = current,
        people = asList(row['managers']),
        detail =
            companyDetails[text(row['ticker'])] ?? const <String, dynamic>{},
        price = asMap(detail['price']),
        value = asMap(detail['valuation']);
    final adds = people
        .where((m) => {'new', 'increased'}.contains(m['action']))
        .toList();
    final trims = people
        .where((m) => {'reduced', 'sold_out'}.contains(m['action']))
        .toList();
    final others = people
        .where(
          (m) => !{
            'new',
            'increased',
            'reduced',
            'sold_out',
          }.contains(m['action']),
        )
        .toList();
    Widget metric(
      String en,
      String zh,
      dynamic amount,
      String date, {
      bool ratio = false,
      String currency = '',
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(w(en, zh), style: s(10, false, p.muted)),
        Text(
          ratio
              ? pct(amount)
              : nullableNumber(amount) == null
              ? '—'
              : '$currency ${number(amount).toStringAsFixed(2)}',
          style: s(
            17,
            true,
            ratio ? (number(amount) < 0 ? p.negative : p.accent) : null,
          ),
        ),
        Text(date, style: s(10, false, p.muted)),
      ],
    );
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (_, c) => Wrap(
              spacing: 18,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: math.min(c.maxWidth, 260),
                  child: Row(
                    children: [
                      StockLogo(
                        ticker: text(row['ticker']),
                        palette: p,
                        size: 40,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(text(row['ticker']), style: s(23, true)),
                            Text(
                              text(row['name']),
                              style: s(11, false, p.muted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                metric(
                  'Market price',
                  '市场价格',
                  price['value'],
                  text(price['date']),
                  currency: text(price['currency']),
                ),
                metric(
                  'Published value',
                  '已发布模型价值',
                  value['fairValue'],
                  text(value['date']),
                  currency: text(value['currency']),
                ),
                metric(
                  'Model / price − 1',
                  '模型 / 股价 − 1',
                  detail['modelGap'],
                  '',
                  ratio: true,
                ),
                FilledButton.icon(
                  key: const ValueKey('matrix-research'),
                  onPressed: () => widget.onCompany(text(row['ticker'])),
                  icon: const Icon(Icons.arrow_forward, size: 16),
                  label: Text(w('Valuation & financials', '估值与财务')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            w(
              '${row['managerCount']} holders · ${qLabel(quarter)} · ${people.length} disclosed entries',
              '${row['managerCount']} 位持有者 · ${qLabel(quarter)} · ${people.length} 条披露',
            ),
            style: s(11, false, p.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              chip(
                'Holding sources',
                '持仓来源',
                !changesDetail,
                () => update(() => changesDetail = false),
              ),
              chip(
                'Quarterly changes',
                '季度变化',
                changesDetail,
                () => update(() => changesDetail = true),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (_, c) {
              final groups = [
                group(
                  w('New & added (${adds.length})', '新建与加仓（${adds.length}）'),
                  adds,
                  p.accent,
                ),
                group(
                  w(
                    'Reduced & exited (${trims.length})',
                    '减仓与清仓（${trims.length}）',
                  ),
                  trims,
                  p.negative,
                ),
              ];
              return c.maxWidth >= 650
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: groups[0]),
                        const SizedBox(width: 12),
                        Expanded(child: groups[1]),
                      ],
                    )
                  : Column(
                      children: [
                        groups[0],
                        const SizedBox(height: 12),
                        groups[1],
                      ],
                    );
            },
          ),
          if (!changesDetail && others.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                w(
                  'Other reported holdings (${others.length})',
                  '其他已披露持仓（${others.length}）',
                ),
                style: s(12),
              ),
              children: others.map(person).toList(),
            ),
          Text(
            w(
              '13F is delayed. Share changes may include corporate actions; book weights do not represent total fund assets.',
              '13F 披露有延迟。股数变化可能包含公司行动，持仓权重不代表基金全部资产。',
            ),
            style: s(10, false, p.muted),
          ),
        ],
      ),
    );
  }

  Widget group(String label, List<Map<String, dynamic>> people, Color color) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: s(13, true, color)),
          const SizedBox(height: 4),
          if (people.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                w('No reported moves in this group.', '此组没有已披露变动。'),
                style: s(12, false, p.muted),
              ),
            )
          else
            SizedBox(
              height: math.min(people.length * 60.0, 180),
              child: ListView(children: people.map(person).toList()),
            ),
        ],
      );
  Widget person(Map<String, dynamic> m) => Container(
    decoration: BoxDecoration(
      color: focusedGuru == m['guruId']
          ? p.accent.withValues(alpha: .12)
          : null,
      border: Border(bottom: BorderSide(color: p.border)),
    ),
    child: InkWell(
      onTap: () => widget.onExplore(text(m['guruId']), text(m['accession'])),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            avatar({...manager(text(m['guruId'])), ...m}, 30),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text(m['name']),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: s(12, true),
                  ),
                  Text(
                    '${w('Filed', '披露')} ${m['availableAt']}',
                    style: s(10, false, p.muted),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  changesDetail
                      ? pct(guruShareChange(m), signed: true)
                      : pct(m['weight']),
                  style: s(12, true),
                ),
                Text(actionName(m), style: s(10, false, actionColor(m))),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
