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
  late List<Map<String, dynamic>> gurus;
  bool showStudy = false;

  @override
  void initState() {
    super.initState();
    selection = {...widget.initialSelection};
    gurus = widget.gurus;
  }

  @override
  void didUpdateWidget(covariant GuruDiscoveryDesk oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.gurus.isNotEmpty && widget.gurus != oldWidget.gurus) {
      gurus = widget.gurus;
    }
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

  void openStudy() {
    if (!showStudy) {
      setState(() => showStudy = true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => reveal(studyKey));
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
        gurus: gurus,
        onCatalog: (value) {
          if (value.isEmpty || identical(value, gurus)) return;
          setState(() => gurus = value);
        },
        initialSelection: asMap(selection['holdings']),
        onSelection: (value) {
          selection['holdings'] = value;
          widget.onSelection?.call({...selection});
        },
        onExplore: widget.onExplore,
        onCompany: widget.onCompany,
        onStudy: openStudy,
      ),
      const SizedBox(height: 28),
      Wrap(
        key: studyKey,
        spacing: 12,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            context.tr('风格与业绩对比', 'Style & performance'),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: widget.palette.text,
            ),
          ),
          TextButton.icon(
            onPressed: () => reveal(holdingsKey),
            icon: const Icon(Icons.arrow_upward, size: 16),
            label: Text(context.tr('返回排行', 'Back to rankings')),
          ),
        ],
      ),
      const SizedBox(height: 8),
      if (!showStudy)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: widget.palette.panel,
            border: Border.all(color: widget.palette.border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final copy = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.insights_outlined, color: widget.palette.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      context.tr(
                        '按需加载换手率、复合收益与夏普对比，不影响上方持仓排行首屏。',
                        'Load turnover, CAGR and Sharpe comparisons on demand without delaying rankings.',
                      ),
                      style: TextStyle(
                        fontSize: 13,
                        color: widget.palette.muted,
                      ),
                    ),
                  ),
                ],
              );
              final action = FilledButton.icon(
                key: const ValueKey('load-guru-study'),
                onPressed: openStudy,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(context.tr('加载对比', 'Load comparison')),
              );
              if (constraints.maxWidth < 520) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    copy,
                    const SizedBox(height: 14),
                    Align(alignment: Alignment.centerLeft, child: action),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: copy),
                  const SizedBox(width: 12),
                  action,
                ],
              );
            },
          ),
        )
      else ...[
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
          gurus: gurus,
          initialSelection: selection,
          onSelection: (value) {
            selection = {...value, 'holdings': selection['holdings']};
            widget.onSelection?.call({...selection});
          },
          onExplore: widget.onExplore,
          onFollow: widget.onFollow,
        ),
      ],
    ],
  );
}

double? guruShareChange(Map<String, dynamic> holding) {
  final prior = nullableNumber(holding['previousShares']);
  final delta = nullableNumber(holding['changeShares']);
  return prior != null && prior > 0 && delta != null ? delta / prior : null;
}

bool _guruIsActiveHolder(Map<String, dynamic> m) {
  if (m['action'] == 'sold_out') return false;
  final shares = nullableNumber(m['shares']);
  if (shares != null) return shares > 0;
  return (nullableNumber(m['weight']) ?? 0) > 0;
}

class _GuruRowStats {
  const _GuruRowStats({
    required this.row,
    required this.scoped,
    required this.held,
    required this.buyers,
    required this.sellers,
    required this.holdersCount,
    required this.core5Count,
    required this.core10Count,
    required this.sumWeight,
    required this.maxWeight,
    required this.buyerWeight,
    required this.sellerWeight,
    required this.newCount,
    required this.increasedCount,
    required this.reducedCount,
    required this.exitedCount,
  });

  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> scoped;
  final List<Map<String, dynamic>> held;
  final List<Map<String, dynamic>> buyers;
  final List<Map<String, dynamic>> sellers;
  final int holdersCount;
  final int core5Count;
  final int core10Count;
  final double sumWeight;
  final double maxWeight;
  final double buyerWeight;
  final double sellerWeight;
  final int newCount;
  final int increasedCount;
  final int reducedCount;
  final int exitedCount;

  int get adds => newCount + increasedCount;
  int get trims => reducedCount + exitedCount;
  int get netAdds => adds - trims;
  int get netTrims => trims - adds;
}

_GuruRowStats _computeGuruRowStats(
  Map<String, dynamic> row,
  Set<String> selected,
) {
  final scoped = asList(
    row['managers'],
  ).where((m) => selected.contains(text(m['guruId']))).toList();
  final held = scoped.where(_guruIsActiveHolder).toList()
    ..sort(
      (a, b) => (nullableNumber(b['weight']) ?? 0).compareTo(
        nullableNumber(a['weight']) ?? 0,
      ),
    );
  final buyers =
      scoped
          .where((m) => m['action'] == 'new' || m['action'] == 'increased')
          .toList()
        ..sort(
          (a, b) => (nullableNumber(b['weight']) ?? 0).compareTo(
            nullableNumber(a['weight']) ?? 0,
          ),
        );
  final sellers =
      scoped
          .where((m) => m['action'] == 'sold_out' || m['action'] == 'reduced')
          .toList()
        ..sort((a, b) {
          final aExit = a['action'] == 'sold_out' ? 1 : 0;
          final bExit = b['action'] == 'sold_out' ? 1 : 0;
          if (bExit != aExit) return bExit.compareTo(aExit);
          final aw =
              nullableNumber(a['previousWeight']) ??
              nullableNumber(a['weight']) ??
              0;
          final bw =
              nullableNumber(b['previousWeight']) ??
              nullableNumber(b['weight']) ??
              0;
          return bw.compareTo(aw);
        });
  var core5 = 0, core10 = 0;
  var sumWeight = 0.0, maxWeight = 0.0;
  for (final m in held) {
    final w = nullableNumber(m['weight']) ?? 0;
    sumWeight += w;
    if (w > maxWeight) maxWeight = w;
    if (w >= 0.05) core5++;
    if (w >= 0.10) core10++;
  }
  final buyerWeight = buyers.fold<double>(
    0.0,
    (s, m) => s + (nullableNumber(m['weight']) ?? 0),
  );
  final sellerWeight = sellers.fold<double>(
    0.0,
    (s, m) =>
        s +
        (nullableNumber(m['previousWeight']) ??
            nullableNumber(m['weight']) ??
            0),
  );
  final newCount = scoped.where((m) => m['action'] == 'new').length;
  final increasedCount = scoped.where((m) => m['action'] == 'increased').length;
  final reducedCount = scoped.where((m) => m['action'] == 'reduced').length;
  final exitedCount = scoped.where((m) => m['action'] == 'sold_out').length;
  return _GuruRowStats(
    row: row,
    scoped: scoped,
    held: held,
    buyers: buyers,
    sellers: sellers,
    holdersCount: held.length,
    core5Count: core5,
    core10Count: core10,
    sumWeight: sumWeight,
    maxWeight: maxWeight,
    buyerWeight: buyerWeight,
    sellerWeight: sellerWeight,
    newCount: newCount,
    increasedCount: increasedCount,
    reducedCount: reducedCount,
    exitedCount: exitedCount,
  );
}

List<Map<String, dynamic>> filterGuruMatrix(
  List<Map<String, dynamic>> rows,
  Set<String> selected, {
  String query = '',
  bool concentrated = false,
  String sort = 'holders',
  String board = 'matrix',
  bool multiHolderOnly = false,
}) {
  if (selected.isEmpty) return const [];
  final needle = query.trim().toLowerCase();
  final statsList = <_GuruRowStats>[];
  for (final row in rows) {
    if (needle.isNotEmpty &&
        !'${row['ticker']} ${row['name']}'.toLowerCase().contains(needle)) {
      continue;
    }
    final st = _computeGuruRowStats(row, selected);
    if (st.scoped.isEmpty) continue;
    if (concentrated &&
        !st.scoped.any((m) => (nullableNumber(m['weight']) ?? -1) >= .10)) {
      continue;
    }
    if (board == 'conviction') {
      if (st.holdersCount == 0) continue;
      if (multiHolderOnly && st.holdersCount < 2) continue;
    } else if (board == 'net_adds') {
      if (st.netAdds <= 0) continue;
    } else if (board == 'net_trims') {
      if (st.netTrims <= 0) continue;
    }
    statsList.add(st);
  }

  int cmpDouble(double a, double b) => b.compareTo(a);
  int cmpInt(int a, int b) => b.compareTo(a);
  int cmpTicker(_GuruRowStats a, _GuruRowStats b) =>
      text(a.row['ticker']).compareTo(text(b.row['ticker']));

  statsList.sort((a, b) {
    if (sort == 'ticker') return cmpTicker(a, b);
    if (board == 'conviction') {
      if (sort == 'weight' || sort == 'max_weight') {
        final c = cmpDouble(a.maxWeight, b.maxWeight);
        if (c != 0) return c;
        final c2 = cmpDouble(a.sumWeight, b.sumWeight);
        return c2 != 0 ? c2 : cmpTicker(a, b);
      }
      if (sort == 'holders') {
        final c = cmpInt(a.holdersCount, b.holdersCount);
        if (c != 0) return c;
        final c2 = cmpDouble(a.sumWeight, b.sumWeight);
        return c2 != 0 ? c2 : cmpTicker(a, b);
      }
      if (sort == 'core') {
        final c = cmpInt(a.core5Count, b.core5Count);
        if (c != 0) return c;
        final c2 = cmpDouble(a.sumWeight, b.sumWeight);
        return c2 != 0 ? c2 : cmpTicker(a, b);
      }
      final c = cmpDouble(a.sumWeight, b.sumWeight);
      if (c != 0) return c;
      final c2 = cmpInt(a.holdersCount, b.holdersCount);
      return c2 != 0 ? c2 : cmpTicker(a, b);
    }
    if (board == 'net_adds') {
      if (sort == 'buyer_weight') {
        final c = cmpDouble(a.buyerWeight, b.buyerWeight);
        if (c != 0) return c;
      } else if (sort == 'new_positions') {
        final c = cmpInt(a.newCount, b.newCount);
        if (c != 0) return c;
      }
      final c = cmpInt(a.netAdds, b.netAdds);
      if (c != 0) return c;
      final c2 = cmpInt(a.adds, b.adds);
      if (c2 != 0) return c2;
      final c3 = cmpDouble(a.buyerWeight, b.buyerWeight);
      return c3 != 0 ? c3 : cmpTicker(a, b);
    }
    if (board == 'net_trims') {
      if (sort == 'exits') {
        final c = cmpInt(a.exitedCount, b.exitedCount);
        if (c != 0) return c;
      } else if (sort == 'seller_weight') {
        final c = cmpDouble(a.sellerWeight + a.sumWeight, b.sellerWeight + b.sumWeight);
        if (c != 0) return c;
      }
      final c = cmpInt(a.netTrims, b.netTrims);
      if (c != 0) return c;
      final c2 = cmpInt(a.trims, b.trims);
      if (c2 != 0) return c2;
      final c3 = cmpDouble(a.sumWeight + a.sellerWeight, b.sumWeight + b.sellerWeight);
      return c3 != 0 ? c3 : cmpTicker(a, b);
    }
    // Matrix sort compatibility
    if (sort == 'weight') {
      final c = cmpDouble(a.maxWeight, b.maxWeight);
      return c != 0 ? c : cmpTicker(a, b);
    }
    if (sort == 'changes') {
      final c = cmpInt(a.adds + a.trims, b.adds + b.trims);
      return c != 0 ? c : cmpTicker(a, b);
    }
    final c = cmpDouble(
      nullableNumber(a.row['managerCount']) ?? a.holdersCount.toDouble(),
      nullableNumber(b.row['managerCount']) ?? b.holdersCount.toDouble(),
    );
    return c != 0 ? c : cmpTicker(a, b);
  });

  return statsList.map((st) => st.row).toList();
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
    this.onCatalog,
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
  final ValueChanged<List<Map<String, dynamic>>>? onCatalog;
  @override
  State<GuruHoldingsMatrix> createState() => _GuruHoldingsMatrixState();
}

class _GuruHoldingsMatrixState extends State<GuruHoldingsMatrix> {
  static const int _leaderboardPageSize = 10;
  static const int _matrixPageSize = 5;

  final managerSearch = TextEditingController(),
      stockSearch = TextEditingController();
  final horizontal = ScrollController();
  Timer? companyDetailTimer;
  Map<String, dynamic>? data;
  final Map<String, Map<String, dynamic>> companyDetails = {};
  List<String> selected = [];
  bool allGurusScope = true;
  bool showGuruDrawer = false;
  bool multiHolderOnly = false;
  String board = 'conviction';
  String quarter = '',
      ticker = '',
      focusedGuru = '',
      capitalFilter = 'all',
      mode = 'weight',
      sort = 'conviction';
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

  String pct(dynamic value, {bool signed = false, int digits = 2}) =>
      nullableNumber(value) == null
      ? '—'
      : '${signed && number(value) > 0 ? '+' : ''}${(number(value) * 100).toStringAsFixed(digits)}%';

  List<Map<String, dynamic>> get rows => asList(data?['rows']);

  List<Map<String, dynamic>> get availableGurus {
    final embedded = asList(data?['gurus']);
    return embedded.isNotEmpty ? embedded : widget.gurus;
  }

  Set<String> get reportedGuruSet {
    final raw = data?['reportedGuruIds'];
    if (raw is List && raw.isNotEmpty) {
      return raw.map((e) => text(e)).where((s) => s.isNotEmpty).toSet();
    }
    final inferred = <String>{};
    for (final row in rows) {
      for (final m in asList(row['managers'])) {
        final id = text(m['guruId']);
        if (id.isNotEmpty) inferred.add(id);
      }
    }
    return inferred;
  }

  bool matchesCapital(Map<String, dynamic> g) {
    if (capitalFilter == 'all') return true;
    final structure = asMap(g['capitalStructure']);
    return structure['category'] == capitalFilter;
  }

  List<String> get effectiveSelected {
    final baseIds = allGurusScope
        ? availableGurus.map((g) => text(g['id'])).toList()
        : selected
              .where((id) => availableGurus.any((g) => g['id'] == id))
              .toList();
    if (capitalFilter == 'all') return baseIds;
    return baseIds.where((id) => matchesCapital(manager(id))).toList();
  }

  Set<String> get activeGuruSet => effectiveSelected.toSet();

  List<Map<String, dynamic>> boardRows(String targetBoard, {String? sortBy}) =>
      filterGuruMatrix(
        rows,
        activeGuruSet,
        query: stockSearch.text,
        concentrated: concentrated,
        sort: sortBy ?? _defaultSortForBoard(targetBoard),
        board: targetBoard,
        multiHolderOnly: targetBoard == 'conviction' && multiHolderOnly,
      );

  String _defaultSortForBoard(String targetBoard) => switch (targetBoard) {
    'conviction' => 'conviction',
    'net_adds' => 'net_adds',
    'net_trims' => 'net_trims',
    _ => 'holders',
  };

  List<Map<String, dynamic>> get matches => filterGuruMatrix(
    rows,
    activeGuruSet,
    query: stockSearch.text,
    concentrated: concentrated,
    sort: sort,
    board: board,
    multiHolderOnly: board == 'conviction' && multiHolderOnly,
  );

  Map<String, dynamic> get current =>
      matches.where((r) => r['ticker'] == ticker).firstOrNull ?? {};

  Map<String, dynamic> manager(String id) =>
      availableGurus.where((g) => g['id'] == id).firstOrNull ??
      {'id': id, 'name': id};

  String qLabel(String value) => value.length < 7
      ? value
      : '${value.substring(0, 4)} Q${((int.parse(value.substring(5, 7)) + 2) / 3).floor()}';

  int? quarterManagerCount(String q) {
    final counts = asMap(data?['quarterCounts']);
    final n = nullableNumber(counts[q]);
    return n?.round();
  }

  String? get latestFullQuarter {
    final qs = (data?['quarters'] as List? ?? []).map((e) => text(e)).toList();
    final eligible =
        nullableNumber(asMap(data?['coverage'])['eligibleManagers'])?.round() ??
        availableGurus.length;
    if (eligible <= 0) return null;
    for (final q in qs) {
      final c = quarterManagerCount(q);
      if (c != null && c >= eligible) return q;
    }
    return qs.length > 1 ? qs[1] : null;
  }

  @override
  void initState() {
    super.initState();
    final v = widget.initialSelection;
    final hasExplicitSelected = v.containsKey('selected') && v['selected'] is List;
    allGurusScope = v.containsKey('allGurusScope')
        ? v['allGurusScope'] == true
        : !hasExplicitSelected;
    if (hasExplicitSelected) {
      selected = List<String>.from(v['selected'] as List);
    } else {
      selected = widget.gurus.map((g) => text(g['id'])).toList();
    }
    final savedBoard = text(
      v['board'],
      hasExplicitSelected && !v.containsKey('board') ? 'matrix' : 'conviction',
    );
    board = {'conviction', 'net_adds', 'net_trims', 'matrix'}.contains(savedBoard)
        ? savedBoard
        : 'conviction';
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
    sort = text(v['sort'], _defaultSortForBoard(board));
    concentrated = v['concentrated'] == true;
    multiHolderOnly = v['multiHolderOnly'] == true;
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
    companyDetailTimer?.cancel();
    managerSearch.dispose();
    stockSearch.dispose();
    horizontal.dispose();
    super.dispose();
  }

  void remember() => widget.onSelection?.call({
    'selected': effectiveSelected,
    'allGurusScope': allGurusScope,
    'board': board,
    'quarter': quarter,
    'ticker': ticker,
    'focusedGuru': focusedGuru,
    'capitalFilter': capitalFilter,
    'mode': mode,
    'sort': sort,
    'concentrated': concentrated,
    'multiHolderOnly': multiHolderOnly,
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
    if (ticker.isNotEmpty &&
        (ticker != previousTicker || !companyDetails.containsKey(ticker))) {
      scheduleCompanyDetail(ticker);
    }
  }

  void switchBoard(String nextBoard) {
    if (board == nextBoard) return;
    update(() {
      board = nextBoard;
      sort = _defaultSortForBoard(nextBoard);
    }, reset: true);
  }

  void scheduleCompanyDetail(String symbol) {
    companyDetailTimer?.cancel();
    companyDetailTimer = Timer(const Duration(milliseconds: 180), () {
      if (mounted && ticker == symbol) unawaited(loadCompanyDetail(symbol));
    });
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
        '/api/investment/guru-holdings?asOf=$cutoff${target.isEmpty ? '' : '&quarter=$target'}&bootstrap=guru-directory-v1',
      );
      if (!mounted || serial != request || cutoff != widget.asOf) return;
      if (next['asOf'] != cutoff ||
          (target.isNotEmpty && next['reportDate'] != target)) {
        throw StateError('mismatched disclosure date');
      }
      final embeddedGurus = asList(next['gurus']);
      update(() {
        data = next;
        quarter = text(next['reportDate']);
        if (allGurusScope) {
          final catalog = embeddedGurus.isNotEmpty ? embeddedGurus : widget.gurus;
          selected = catalog.map((g) => text(g['id'])).toList();
        }
      }, reset: true);
      if (embeddedGurus.isNotEmpty) widget.onCatalog?.call(embeddedGurus);
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

  Widget panel(Widget child, {EdgeInsets padding = const EdgeInsets.all(14)}) =>
      Container(
        padding: padding,
        decoration: BoxDecoration(
          color: p.panel,
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: child,
      );

  Widget chip(
    String en,
    String zh,
    bool active,
    VoidCallback action, {
    Key? key,
  }) => ChoiceChip(
    key: key,
    label: Text(w(en, zh), style: s(12, active)),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
    ),
  );

  Widget selectControl(
    String key,
    String value,
    List<(String, String)> options,
    ValueChanged<String> action,
    double width,
  ) {
    final safeValue = options.any((o) => o.$1 == value)
        ? value
        : (options.firstOrNull?.$1 ?? value);
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String>(
        key: ValueKey('matrix-$key-$safeValue'),
        initialValue: safeValue,
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
  }

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
    'new' || 'increased' => const Color(0xFF2ECC8F),
    'reduced' => p.secondary,
    'sold_out' => p.negative,
    _ => p.muted,
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, c) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        headerAndTabs(c.maxWidth),
        if (showGuruDrawer) ...[
          const SizedBox(height: 10),
          guruFilterDrawer(c.maxWidth),
        ],
        const SizedBox(height: 10),
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
          summaryCards(c.maxWidth),
          const SizedBox(height: 10),
          filterBar(c.maxWidth),
          const SizedBox(height: 10),
          if (board == 'matrix')
            matrixTable(availableWidth: c.maxWidth)
          else
            leaderboardPanel(c.maxWidth),
          const SizedBox(height: 8),
          methodologyFooter(),
          const SizedBox(height: 12),
          if (current.isNotEmpty) companyDetail(),
        ],
      ],
    ),
  );

  Widget headerAndTabs(double maxWidth) {
    final cov = asMap(data?['coverage']);
    final reported = nullableNumber(cov['reportedManagers'])?.round();
    final eligible =
        nullableNumber(cov['eligibleManagers'])?.round() ??
        availableGurus.length;
    final partialQuarter =
        !loading &&
        !failed &&
        reported != null &&
        eligible > 0 &&
        reported < eligible;
    final fullQ = latestFullQuarter;

    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.max(220, maxWidth - 36),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.leaderboard_outlined, color: p.accent, size: 20),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            w(
                              'Guru conviction & net flow rankings',
                              '大佬集中持仓与净调仓排行',
                            ),
                            style: s(16, true),
                          ),
                        ),
                        Tooltip(
                          triggerMode: TooltipTriggerMode.tap,
                          message: w(
                            'Percentages are weights in each Guru’s reported 13F common-long book, not total fund assets. Net buying = (New + Added) minus (Reduced + Exited) across active Gurus. Reported share changes are delayed 13F disclosures, not live trade signals. Missing entries do not establish a zero position.',
                            '百分比为各位大佬已披露 13F 普通股多头持仓权重，非基金全部资产。净加仓 =（新建 + 加仓人数）−（减仓 + 清仓人数）。所有变动均为 13F 延迟披露股数变化，非实时交易信号；缺失记录不代表零持仓。',
                          ),
                          child: Semantics(
                            label: w(
                              'How to read consensus holdings',
                              '如何读共识持仓',
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              child: Icon(
                                Icons.info_outline,
                                size: 17,
                                color: p.muted,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      w(
                        'Concentrated core positions, net buying (net additions), and net selling across 13F disclosures.',
                        '一眼看清机构核心重仓排行、当季净加仓排行（净加）与净减仓排行。',
                      ),
                      style: s(12, false, p.muted),
                    ),
                  ],
                ),
              ),
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
                          (
                            q as String,
                            quarterManagerCount(q) != null
                                ? '${qLabel(q)} ($q) · ${quarterManagerCount(q)}/$eligible'
                                : '${qLabel(q)} ($q)',
                          ),
                      ],
                      (v) {
                        quarter = v;
                        unawaited(load());
                      },
                      math.min(225, math.max(150, maxWidth - 40)),
                    ),
                  OutlinedButton.icon(
                    key: const ValueKey('matrix-study-link'),
                    onPressed: widget.onStudy,
                    icon: Icon(Icons.bar_chart, size: 16, color: p.accent),
                    label: Text(
                      w('Style & performance', '风格与业绩对比'),
                      style: s(12, true, p.accent),
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (partialQuarter) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: .08),
                border: Border.all(color: p.accent.withValues(alpha: .28)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 6,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    w(
                      '${qLabel(quarter)} filing season in progress: $reported / $eligible Gurus reported as of ${widget.asOf}.',
                      '${qLabel(quarter)} 披露进行中：截至 ${widget.asOf} 已收录 $reported / $eligible 位大佬持仓，其余机构待后续快照更新。',
                    ),
                    style: s(12, false, p.text),
                  ),
                  if (fullQ != null && fullQ != quarter)
                    TextButton.icon(
                      key: const ValueKey('guru-switch-full-quarter'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                      ),
                      onPressed: () {
                        quarter = fullQ;
                        unawaited(load());
                      },
                      icon: Icon(Icons.history, size: 15, color: p.accent),
                      label: Text(
                        w(
                          'Switch to ${qLabel(fullQ)} (${quarterManagerCount(fullQ) ?? eligible}/$eligible full)',
                          '查看 ${qLabel(fullQ)}（${quarterManagerCount(fullQ) ?? eligible} 位完整披露）',
                        ),
                        style: s(12, true, p.accent),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _boardTabButton(
                id: 'conviction',
                keyName: 'guru-tab-conviction',
                icon: Icons.workspace_premium_outlined,
                en: 'Concentrated Rankings',
                zh: '集中仓位排行',
                tint: p.accent,
              ),
              _boardTabButton(
                id: 'net_adds',
                keyName: 'guru-tab-net-adds',
                icon: Icons.trending_up,
                en: 'Net Buying',
                zh: '加仓排行（净加）',
                tint: const Color(0xFF2ECC8F),
              ),
              _boardTabButton(
                id: 'net_trims',
                keyName: 'guru-tab-net-trims',
                icon: Icons.trending_down,
                en: 'Net Selling',
                zh: '净减仓排行',
                tint: p.negative,
              ),
              _boardTabButton(
                id: 'matrix',
                keyName: 'guru-tab-matrix',
                icon: Icons.grid_view_outlined,
                en: 'Guru Matrix',
                zh: '持仓对比矩阵',
                tint: p.secondary,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _boardTabButton({
    required String id,
    required String keyName,
    required IconData icon,
    required String en,
    required String zh,
    required Color tint,
  }) {
    final active = board == id;
    return InkWell(
      key: ValueKey(keyName),
      borderRadius: BorderRadius.circular(8),
      onTap: () => switchBoard(id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? tint.withValues(alpha: .15) : p.card,
          border: Border.all(
            color: active ? tint : p.border,
            width: active ? 1.4 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: active ? tint : p.muted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                w(en, zh),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: s(12.5, active, active ? p.text : p.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget summaryCards(double maxWidth) {
    final conv = boardRows('conviction');
    final adds = boardRows('net_adds');
    final trims = boardRows('net_trims');

    final topConv = conv.isEmpty
        ? null
        : _computeGuruRowStats(conv.first, activeGuruSet);
    final topAdd = adds.isEmpty
        ? null
        : _computeGuruRowStats(adds.first, activeGuruSet);
    final topTrim = trims.isEmpty
        ? null
        : _computeGuruRowStats(trims.first, activeGuruSet);

    Widget kpiCard({
      required String targetBoard,
      required String titleEn,
      required String titleZh,
      required String countEn,
      required String countZh,
      required String leadEn,
      required String leadZh,
      required Color tint,
    }) {
      final active = board == targetBoard;
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => switchBoard(targetBoard),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: active ? tint.withValues(alpha: .08) : p.panel,
            border: Border.all(
              color: active ? tint.withValues(alpha: .85) : p.border,
            ),
            borderRadius: BorderRadius.circular(10),
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
                      color: tint,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      w(titleEn, titleZh),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: s(12, true, active ? tint : p.muted),
                    ),
                  ),
                  Text(w(countEn, countZh), style: s(11, false, p.muted)),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                w(leadEn, leadZh),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: s(13.5, true),
              ),
            ],
          ),
        ),
      );
    }

    final cards = [
      kpiCard(
        targetBoard: 'conviction',
        titleEn: 'Concentrated Conviction',
        titleZh: '集中仓位排行',
        countEn: '${conv.length} stocks',
        countZh: '${conv.length} 只持仓',
        leadEn: topConv == null
            ? 'No active holdings in scope'
            : '#1 ${topConv.row['ticker']} · ${topConv.holdersCount} Gurus · Max ${pct(topConv.maxWeight, digits: 1)}',
        leadZh: topConv == null
            ? '当前筛选范围内暂无持仓'
            : '榜首 ${topConv.row['ticker']} · ${topConv.holdersCount} 位持有 · 最高 ${pct(topConv.maxWeight, digits: 1)}',
        tint: p.accent,
      ),
      kpiCard(
        targetBoard: 'net_adds',
        titleEn: 'Net Buying (Net Adds)',
        titleZh: '加仓排行（净加）',
        countEn: '${adds.length} net bought',
        countZh: '${adds.length} 只净加仓',
        leadEn: topAdd == null
            ? 'No net additions in scope'
            : '#1 ${topAdd.row['ticker']} · Net +${topAdd.netAdds} (${topAdd.adds} buy / ${topAdd.trims} sell)',
        leadZh: topAdd == null
            ? '当前筛选范围内暂无净加仓'
            : '榜首 ${topAdd.row['ticker']} · 净 +${topAdd.netAdds} 位（${topAdd.adds} 加 / ${topAdd.trims} 减）',
        tint: const Color(0xFF2ECC8F),
      ),
      kpiCard(
        targetBoard: 'net_trims',
        titleEn: 'Net Selling (Net Trims)',
        titleZh: '净减仓排行',
        countEn: '${trims.length} net sold',
        countZh: '${trims.length} 只净减仓',
        leadEn: topTrim == null
            ? 'No net reductions in scope'
            : '#1 ${topTrim.row['ticker']} · Net -${topTrim.netTrims} (${topTrim.trims} sell / ${topTrim.adds} buy)',
        leadZh: topTrim == null
            ? '当前筛选范围内暂无净减仓'
            : '榜首 ${topTrim.row['ticker']} · 净 -${topTrim.netTrims} 位（${topTrim.trims} 减 / ${topTrim.adds} 加）',
        tint: p.negative,
      ),
    ];

    if (maxWidth >= 880) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: cards[0]),
          const SizedBox(width: 10),
          Expanded(child: cards[1]),
          const SizedBox(width: 10),
          Expanded(child: cards[2]),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        cards[0],
        const SizedBox(height: 8),
        cards[1],
        const SizedBox(height: 8),
        cards[2],
      ],
    );
  }

  List<(String, String)> _sortOptionsForBoard() => switch (board) {
    'conviction' => [
      ('conviction', w('Conviction weight sum', '按合计重仓权重')),
      ('weight', w('Max single weight', '按单人最高仓位')),
      ('core', w('Core ≥ 5% holders', '按 ≥5% 重仓人数')),
      ('holders', w('Most holders', '按持有人数最多')),
      ('ticker', w('Ticker A–Z', '代码 A–Z')),
    ],
    'net_adds' => [
      ('net_adds', w('Net buyers (+N)', '按净加仓人数（净加）')),
      ('buyer_weight', w('Buyer book weight', '按买方合计仓位')),
      ('new_positions', w('New positions count', '按新建仓人数')),
      ('ticker', w('Ticker A–Z', '代码 A–Z')),
    ],
    'net_trims' => [
      ('net_trims', w('Net sellers (-N)', '按净减仓人数（净减）')),
      ('exits', w('Full exits count', '按清仓人数')),
      ('seller_weight', w('Prior / remaining weight', '按涉及仓位规模')),
      ('ticker', w('Ticker A–Z', '代码 A–Z')),
    ],
    _ => [
      ('holders', w('Most holders', '持有人数最多')),
      ('changes', w('Most quarterly moves', '季度变动最多')),
      ('weight', w('Highest conviction', '持仓权重最高')),
      ('ticker', w('Ticker A–Z', '代码 A–Z')),
    ],
  };

  Widget filterBar(double maxWidth) {
    final chosenCount = effectiveSelected.length;
    final totalCount = availableGurus.length;
    final reportedSet = reportedGuruSet;
    final reportedSelectedCount = effectiveSelected
        .where(reportedSet.contains)
        .length;

    return panel(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: math.min(200, math.max(140, maxWidth - 32)),
            child: search(
              stockSearch,
              'Find a company',
              '搜索股票代码或名称',
              () => update(() {}, reset: true),
            ),
          ),
          SizedBox(
            width: math.min(185, math.max(140, maxWidth - 32)),
            child: DropdownButtonFormField<String>(
              key: ValueKey('guru-capital-filter-$capitalFilter'),
              initialValue: capitalFilter,
              isExpanded: true,
              style: s(12),
              dropdownColor: p.panel,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
              ),
              items:
                  [
                        ('all', w('All structures', '全部资金结构')),
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
                        (e) => DropdownMenuItem(
                          value: e.$1,
                          child: Text(e.$2, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
              onChanged: (value) =>
                  update(() => capitalFilter = value ?? 'all', reset: true),
            ),
          ),
          OutlinedButton.icon(
            key: const ValueKey('guru-filter-toggle'),
            onPressed: () => setState(() => showGuruDrawer = !showGuruDrawer),
            icon: Icon(
              showGuruDrawer ? Icons.expand_less : Icons.tune,
              size: 16,
              color: allGurusScope && capitalFilter == 'all'
                  ? p.muted
                  : p.accent,
            ),
            label: Text(
              allGurusScope && capitalFilter == 'all'
                  ? w(
                      'All Gurus ($reportedSelectedCount/$totalCount filed)',
                      '全部大佬（本季已披露 $reportedSelectedCount/$totalCount）',
                    )
                  : w(
                      'Gurus: $chosenCount selected',
                      '已筛选 $chosenCount 位大佬',
                    ),
              style: s(12, !allGurusScope || capitalFilter != 'all'),
            ),
          ),
          selectControl(
            'sort',
            sort,
            _sortOptionsForBoard(),
            (v) => update(() => sort = v, reset: true),
            math.min(195, math.max(145, maxWidth - 32)),
          ),
          if (board == 'matrix') ...[
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
          ],
          if (board == 'conviction')
            chip(
              '≥ 2 Gurus',
              '多人共识 (≥2位)',
              multiHolderOnly,
              () => update(
                () => multiHolderOnly = !multiHolderOnly,
                reset: true,
              ),
              key: const ValueKey('guru-multi-holder'),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                label: w('Only positions of at least 10%', '只显示至少 10% 的持仓'),
                child: Switch(
                  key: const ValueKey('matrix-concentrated'),
                  value: concentrated,
                  onChanged: (v) => update(() => concentrated = v, reset: true),
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
    );
  }

  Widget guruFilterDrawer(double maxWidth) {
    final reportedSet = reportedGuruSet;
    final catalog = availableGurus.where((g) {
      return matchesCapital(g) &&
          '${g['name']} ${g['entityName']}'.toLowerCase().contains(
            managerSearch.text.trim().toLowerCase(),
          );
    }).toList();
    catalog.sort((a, b) {
      final aRep = reportedSet.contains(text(a['id'])) ? 1 : 0;
      final bRep = reportedSet.contains(text(b['id'])) ? 1 : 0;
      if (bRep != aRep) return bRep.compareTo(aRep);
      return text(a['name']).compareTo(text(b['name']));
    });
    final activeIds = activeGuruSet;

    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: math.min(240, math.max(150, maxWidth - 40)),
                child: search(
                  managerSearch,
                  'Search Guru name',
                  '搜索大佬姓名或机构',
                  () => setState(() {}),
                ),
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  TextButton(
                    onPressed: () => update(() {
                      allGurusScope = true;
                      selected = availableGurus
                          .map((g) => text(g['id']))
                          .toList();
                      managerPage = 0;
                    }, reset: true),
                    child: Text(
                      w('Select all', '全选'),
                      style: s(12, true, p.accent),
                    ),
                  ),
                  if (reportedSet.isNotEmpty)
                    TextButton(
                      onPressed: () => update(() {
                        allGurusScope = false;
                        selected = availableGurus
                            .map((g) => text(g['id']))
                            .where(reportedSet.contains)
                            .toList();
                        managerPage = 0;
                      }, reset: true),
                      child: Text(
                        w(
                          'Reported in ${qLabel(quarter)} (${reportedSet.length})',
                          '仅选本季已披露（${reportedSet.length}）',
                        ),
                        style: s(12, false, p.text),
                      ),
                    ),
                  TextButton(
                    onPressed: () => update(() {
                      allGurusScope = false;
                      selected = [];
                      managerPage = 0;
                    }, reset: true),
                    child: Text(w('Clear', '清空'), style: s(12, false, p.muted)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (catalog.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                w('No Gurus match.', '没有匹配的 Guru。'),
                style: s(12, false, p.muted),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                key: const ValueKey('matrix-guru-list'),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final g in catalog)
                      _guruPickerChip(
                        g,
                        active: activeIds.contains(text(g['id'])),
                        reported: reportedSet.contains(text(g['id'])),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _guruPickerChip(
    Map<String, dynamic> g, {
    required bool active,
    required bool reported,
  }) {
    final id = text(g['id']);
    final structure = asMap(g['capitalStructure']);
    final capitalLabel = w(
      text(structure['label'], 'Institutional'),
      text(structure['labelZh'], '机构管理人'),
    );
    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: active ? p.accent.withValues(alpha: .08) : p.card,
        border: Border.all(
          color: active ? p.accent.withValues(alpha: .65) : p.border,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: Checkbox(
              value: active,
              semanticLabel: w('Show ${g['name']}', '显示 ${g['name']}'),
              onChanged: (_) => update(() {
                final base = effectiveSelected.toList();
                allGurusScope = false;
                if (active) {
                  base.remove(id);
                } else if (!base.contains(id)) {
                  base.add(id);
                }
                selected = base;
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
                  avatar(g, 26),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          text(g['name']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: s(11.5, true),
                        ),
                        Text(
                          reported
                              ? '${w('Filed', '已披露')} · $capitalLabel'
                              : '${w('Pending', '待披露')} · $capitalLabel',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: s(
                            9.5,
                            false,
                            reported ? p.accent : p.muted,
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
  }

  Widget emptyStatePanel() {
    final chosen = effectiveSelected;
    final reportedSet = reportedGuruSet;
    final noneReportedAmongChosen =
        chosen.isNotEmpty &&
        reportedSet.isNotEmpty &&
        chosen.where(reportedSet.contains).isEmpty;
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            chosen.isEmpty
                ? w('Choose Gurus to compare', '请选择至少一位大佬')
                : noneReportedAmongChosen
                ? w(
                    'Selected Gurus have not filed ${qLabel(quarter)} in this snapshot yet.',
                    '当前勾选的大佬尚未包含在 ${qLabel(quarter)} 已披露名单中。',
                  )
                : w('No disclosed holdings match.', '没有匹配的已披露持仓。'),
            style: s(16, true),
          ),
          const SizedBox(height: 6),
          Text(
            w(
              'Change your selection or filters. An unavailable book is not a zero holding.',
              '请调整筛选条件或查看全部已披露大佬；未披露不代表零持仓。',
            ),
            style: s(12, false, p.muted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (chosen.isEmpty || noneReportedAmongChosen || !allGurusScope)
                FilledButton.tonal(
                  onPressed: () => update(() {
                    allGurusScope = true;
                    capitalFilter = 'all';
                    selected = availableGurus
                        .map((g) => text(g['id']))
                        .toList();
                  }, reset: true),
                  child: Text(
                    w('Show all reporting Gurus', '显示全部已披露大佬'),
                  ),
                ),
              if (stockSearch.text.isNotEmpty ||
                  concentrated ||
                  multiHolderOnly)
                TextButton(
                  onPressed: () => update(() {
                    stockSearch.clear();
                    concentrated = false;
                    multiHolderOnly = false;
                  }, reset: true),
                  child: Text(w('Clear stock filters', '清空股票筛选')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget leaderboardPanel(double maxWidth) {
    final list = matches;
    if (effectiveSelected.isEmpty || list.isEmpty) {
      return emptyStatePanel();
    }
    final safePage = math.min(
      stockPage,
      ((list.length - 1) / _leaderboardPageSize).floor(),
    );
    final pageRows = list
        .skip(safePage * _leaderboardPageSize)
        .take(_leaderboardPageSize)
        .toList();
    final maxConvictionSum = list.fold<double>(0.01, (mx, r) {
      final st = _computeGuruRowStats(r, activeGuruSet);
      return math.max(mx, st.sumWeight);
    });
    final desktop = maxWidth >= 780;

    return panel(
      padding: EdgeInsets.zero,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (desktop) _leaderboardHeaderRow(),
          for (var i = 0; i < pageRows.length; i++)
            _leaderboardRow(
              pageRows[i],
              rank: safePage * _leaderboardPageSize + i + 1,
              maxConvictionSum: maxConvictionSum,
              desktop: desktop,
            ),
          _paginationFooter(
            total: list.length,
            page: safePage,
            pageSize: _leaderboardPageSize,
          ),
        ],
      ),
    );
  }

  Widget _leaderboardHeaderRow() {
    final col2 = switch (board) {
      'conviction' => w('Conviction weight', '集中仓位强度'),
      'net_adds' => w('Net buying (+N)', '净加仓强度（净加）'),
      _ => w('Net selling (-N)', '净减仓强度（净减）'),
    };
    final col3 = switch (board) {
      'conviction' => w('Quarter net flow', '当季加减动向'),
      'net_adds' => w('Current book size', '当前持仓规模'),
      _ => w('Remaining book', '剩余持仓状态'),
    };
    final col4 = switch (board) {
      'conviction' => w('Top holding Gurus (book %)', '重仓大佬与仓位占比'),
      'net_adds' => w('Who added / initiated', '新建与加仓大佬明细'),
      _ => w('Who reduced / exited', '减仓与清仓大佬明细'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: p.card,
        border: Border(bottom: BorderSide(color: p.border)),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 210,
            child: Text(w('#  Company', '#  股票标的'), style: s(11.5, true, p.muted)),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 195,
            child: Text(col2, style: s(11.5, true, p.muted)),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 165,
            child: Text(col3, style: s(11.5, true, p.muted)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(col4, style: s(11.5, true, p.muted))),
        ],
      ),
    );
  }

  Widget _leaderboardRow(
    Map<String, dynamic> row, {
    required int rank,
    required double maxConvictionSum,
    required bool desktop,
  }) {
    final sym = text(row['ticker']);
    final selectedRow = ticker == sym;
    final st = _computeGuruRowStats(row, activeGuruSet);

    final stockIdentity = Row(
      children: [
        Container(
          width: 28,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: rank <= 3
                ? p.accent.withValues(alpha: .16)
                : p.card,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            '$rank',
            style: s(11.5, true, rank <= 3 ? p.accent : p.muted),
          ),
        ),
        const SizedBox(width: 9),
        StockLogo(ticker: sym, palette: p, size: 30),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(sym, style: s(13.5, true)),
              Text(
                text(row['name']),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: s(11, false, p.muted),
              ),
            ],
          ),
        ),
      ],
    );

    final primaryMetric = _buildPrimaryMetricCell(st, maxConvictionSum);
    final secondaryMetric = _buildSecondaryMetricCell(st);
    final peoplePills = _buildGuruPills(st);

    return InkWell(
      key: ValueKey('matrix-stock-$sym'),
      onTap: () => update(() {
        ticker = sym;
        focusedGuru = '';
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selectedRow ? p.accent.withValues(alpha: .08) : null,
          border: Border(
            left: BorderSide(
              color: selectedRow ? p.accent : Colors.transparent,
              width: 3,
            ),
            bottom: BorderSide(color: p.border.withValues(alpha: .65)),
          ),
        ),
        child: desktop
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(width: 207, child: stockIdentity),
                  const SizedBox(width: 12),
                  SizedBox(width: 195, child: primaryMetric),
                  const SizedBox(width: 12),
                  SizedBox(width: 165, child: secondaryMetric),
                  const SizedBox(width: 12),
                  Expanded(child: peoplePills),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  stockIdentity,
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 14,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [primaryMetric, secondaryMetric],
                  ),
                  const SizedBox(height: 8),
                  peoplePills,
                ],
              ),
      ),
    );
  }

  Widget _buildPrimaryMetricCell(_GuruRowStats st, double maxConvictionSum) {
    if (board == 'conviction') {
      final ratio = (st.sumWeight / math.max(0.01, maxConvictionSum))
          .clamp(0.05, 1.0)
          .toDouble();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${w('Sum', '合计')} ${pct(st.sumWeight, digits: 1)}',
                style: s(13.5, true, p.accent),
              ),
              Text(
                '· ${w('Max', '最高')} ${pct(st.maxWeight, digits: 1)}',
                style: s(11.5, false, p.text),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 5,
              backgroundColor: p.border.withValues(alpha: .5),
              valueColor: AlwaysStoppedAnimation<Color>(p.accent),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            w(
              '${st.holdersCount} holders${st.core5Count > 0 ? ' · ${st.core5Count} core ≥5%' : ''}${st.core10Count > 0 ? ' (${st.core10Count} ≥10%)' : ''}',
              '${st.holdersCount} 位持有${st.core5Count > 0 ? ' · ${st.core5Count} 位 ≥5%' : ''}${st.core10Count > 0 ? '（${st.core10Count} 位 ≥10%）' : ''}',
            ),
            style: s(10.5, false, p.muted),
          ),
        ],
      );
    }

    if (board == 'net_adds') {
      const buyColor = Color(0xFF2ECC8F);
      final totalMoves = math.max(1, st.adds + st.trims);
      final buyShare = (st.adds / totalMoves).clamp(0.0, 1.0).toDouble();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: buyColor.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  w('Net +${st.netAdds}', '净 +${st.netAdds} 位'),
                  style: s(12.5, true, buyColor),
                ),
              ),
              Text(
                w(
                  '${st.newCount > 0 ? '${st.newCount} new · ' : ''}${st.increasedCount} add${st.trims > 0 ? ' / ${st.trims} trim' : ''}',
                  '${st.newCount > 0 ? '${st.newCount} 新建 · ' : ''}${st.increasedCount} 加仓${st.trims > 0 ? ' / ${st.trims} 减' : ''}',
                ),
                style: s(11, false, p.muted),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: buyShare,
              minHeight: 4,
              backgroundColor: st.trims > 0
                  ? p.negative.withValues(alpha: .45)
                  : p.border.withValues(alpha: .4),
              valueColor: const AlwaysStoppedAnimation<Color>(buyColor),
            ),
          ),
        ],
      );
    }

    // net_trims
    final totalMoves = math.max(1, st.adds + st.trims);
    final sellShare = (st.trims / totalMoves).clamp(0.0, 1.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: p.negative.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                w('Net -${st.netTrims}', '净 -${st.netTrims} 位'),
                style: s(12.5, true, p.negative),
              ),
            ),
            Text(
              w(
                '${st.exitedCount > 0 ? '${st.exitedCount} exit · ' : ''}${st.reducedCount} trim${st.adds > 0 ? ' / ${st.adds} add' : ''}',
                '${st.exitedCount > 0 ? '${st.exitedCount} 清仓 · ' : ''}${st.reducedCount} 减仓${st.adds > 0 ? ' / ${st.adds} 加' : ''}',
              ),
              style: s(11, false, p.muted),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: sellShare,
            minHeight: 4,
            backgroundColor: st.adds > 0
                ? const Color(0xFF2ECC8F).withValues(alpha: .45)
                : p.border.withValues(alpha: .4),
            valueColor: AlwaysStoppedAnimation<Color>(p.negative),
          ),
        ),
      ],
    );
  }

  Widget _buildSecondaryMetricCell(_GuruRowStats st) {
    if (board == 'conviction') {
      if (st.netAdds > 0) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w('Net +${st.netAdds} buying', '净加仓 +${st.netAdds} 位'),
              style: s(12, true, const Color(0xFF2ECC8F)),
            ),
            Text(
              w(
                '${st.adds} added · ${st.trims} trimmed',
                '${st.adds} 加/新 · ${st.trims} 减/清',
              ),
              style: s(10.5, false, p.muted),
            ),
          ],
        );
      }
      if (st.netTrims > 0) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w('Net -${st.netTrims} selling', '净减仓 -${st.netTrims} 位'),
              style: s(12, true, p.negative),
            ),
            Text(
              w(
                '${st.trims} trimmed · ${st.adds} added',
                '${st.trims} 减/清 · ${st.adds} 加/新',
              ),
              style: s(10.5, false, p.muted),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            st.adds > 0
                ? w('Balanced (${st.adds}/${st.trims})', '加减持平 (${st.adds}/${st.trims})')
                : w('Steady holdings', '持仓稳定'),
            style: s(12, false, p.muted),
          ),
          Text(
            w('No net directional skew', '当季无净增减倾斜'),
            style: s(10.5, false, p.muted),
          ),
        ],
      );
    }

    if (board == 'net_adds') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            w(
              '${st.holdersCount} holders · Max ${pct(st.maxWeight, digits: 1)}',
              '${st.holdersCount} 位持有 · 最高 ${pct(st.maxWeight, digits: 1)}',
            ),
            style: s(12, true),
          ),
          Text(
            w(
              'Buyer sum ${pct(st.buyerWeight, digits: 1)}',
              '买方合计占仓 ${pct(st.buyerWeight, digits: 1)}',
            ),
            style: s(10.5, false, p.muted),
          ),
        ],
      );
    }

    // net_trims
    if (st.holdersCount == 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(w('All exited', '已全部清仓'), style: s(12, true, p.negative)),
          Text(
            st.sellerWeight > 0
                ? w(
                    'Prior weight ${pct(st.sellerWeight, digits: 1)}',
                    '清仓前占仓 ${pct(st.sellerWeight, digits: 1)}',
                  )
                : w('0 active holders left', '当前无剩余持有'),
            style: s(10.5, false, p.muted),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w(
            '${st.holdersCount} still hold · Max ${pct(st.maxWeight, digits: 1)}',
            '仍余 ${st.holdersCount} 位持有 · 最高 ${pct(st.maxWeight, digits: 1)}',
          ),
          style: s(12, true),
        ),
        Text(
          w(
            'Remaining sum ${pct(st.sumWeight, digits: 1)}',
            '剩余合计占仓 ${pct(st.sumWeight, digits: 1)}',
          ),
          style: s(10.5, false, p.muted),
        ),
      ],
    );
  }

  Widget _buildGuruPills(_GuruRowStats st) {
    final sourceList = switch (board) {
      'conviction' => st.held,
      'net_adds' => st.buyers,
      _ => st.sellers,
    };
    final visible = sourceList.take(3).toList();
    final overflowCount = sourceList.length - visible.length;

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final m in visible) _singleGuruPill(m),
        if (overflowCount > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.border),
            ),
            child: Text('+$overflowCount', style: s(11, true, p.muted)),
          ),
      ],
    );
  }

  Widget _singleGuruPill(Map<String, dynamic> m) {
    final id = text(m['guruId']);
    final g = {...manager(id), ...m};
    final shareDelta = guruShareChange(m);
    final weightVal = nullableNumber(m['weight']);
    final prevWeightVal = nullableNumber(m['previousWeight']);

    String badgeText;
    if (board == 'conviction') {
      final act = switch (m['action']) {
        'new' => w('New', '新'),
        'increased' => '+',
        'reduced' => '−',
        _ => '',
      };
      badgeText = '${pct(weightVal, digits: 1)}${act.isEmpty ? '' : ' $act'}';
    } else if (board == 'net_adds') {
      if (m['action'] == 'new') {
        badgeText = '${w('New', '新建')} · ${pct(weightVal, digits: 1)}';
      } else {
        final deltaStr = shareDelta != null
            ? '${pct(shareDelta, signed: true, digits: 0)} · '
            : '';
        badgeText = '$deltaStr${pct(weightVal, digits: 1)}';
      }
    } else {
      if (m['action'] == 'sold_out') {
        badgeText = prevWeightVal != null && prevWeightVal > 0
            ? '${w('Exited', '清仓')} (${pct(prevWeightVal, digits: 1)})'
            : w('Exited', '清仓');
      } else {
        final deltaStr = shareDelta != null
            ? '${pct(shareDelta, signed: true, digits: 0)} · '
            : '';
        badgeText = '$deltaStr${pct(weightVal, digits: 1)}';
      }
    }

    final pillTint = actionColor(m);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        final acc = text(m['accession']);
        if (acc.isNotEmpty) {
          widget.onExplore(id, acc);
        } else {
          unawaited(exploreQuarter(id));
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: p.card,
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            avatar(g, 18),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 105),
              child: Text(
                text(g['name']),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: s(11, false),
              ),
            ),
            const SizedBox(width: 5),
            Text(
              badgeText,
              style: s(
                11,
                true,
                board == 'conviction' ? p.accent : pillTint,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _paginationFooter({
    required int total,
    required int page,
    required int pageSize,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            w(
              '${page * pageSize + 1}–${math.min((page + 1) * pageSize, total)} / $total stocks · ${effectiveSelected.length} Gurus in scope',
              '${page * pageSize + 1}–${math.min((page + 1) * pageSize, total)} / $total 只股票 · 当前纳入 ${effectiveSelected.length} 位大佬',
            ),
            style: s(11, false, p.muted),
          ),
        ),
        IconButton(
          tooltip: w('Previous stocks', '上一页股票'),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          onPressed: page > 0 ? () => update(() => stockPage = page - 1) : null,
          icon: const Icon(Icons.chevron_left, size: 18),
        ),
        IconButton(
          tooltip: w('Next stocks', '下一页股票'),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          onPressed: (page + 1) * pageSize < total
              ? () => update(() => stockPage = page + 1)
              : null,
          icon: const Icon(Icons.chevron_right, size: 18),
        ),
      ],
    ),
  );

  Widget matrixTable({required double availableWidth}) {
    final perPage = availableWidth >= 700 && availableWidth < 840 ? 3 : 4;
    final chosen = effectiveSelected;
    final list = matches;
    if (chosen.isEmpty || list.isEmpty) {
      return emptyStatePanel();
    }
    final start = math.min(
      managerPage * perPage,
      math.max(0, chosen.length - 1),
    );
    final columns = chosen.skip(start).take(perPage).map(manager).toList();
    final safePage = math.min(
      stockPage,
      ((list.length - 1) / _matrixPageSize).floor(),
    );
    final pageRows = list
        .skip(safePage * _matrixPageSize)
        .take(_matrixPageSize)
        .toList();

    return panel(
      padding: EdgeInsets.zero,
      Column(
        children: [
          LayoutBuilder(
            builder: (_, c) {
              final width = math.max(
                c.maxWidth,
                165 + columns.length * 130 + 185.0,
              );
              final cw = (width - 165 - 185) / columns.length;
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
                                    style: s(13.5, true),
                                  ),
                                ),
                                165,
                                color: p.card,
                              ),
                              for (final g in columns)
                                cell(
                                  InkWell(
                                    key: ValueKey(
                                      'matrix-header-portrait-${g['id']}',
                                    ),
                                    onTap: () => unawaited(
                                      exploreQuarter(text(g['id'])),
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        avatar(g, 42),
                                        const SizedBox(height: 4),
                                        Text(
                                          text(g['name']),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: s(12.5, true),
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
                                              ? () => update(() => managerPage--)
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
                                              ? () => update(() => managerPage++)
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
                                      style: s(13.5, true),
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
                                185,
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
                                                style: s(12.5, true),
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
                                  165,
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
                                                style: s(12.5, true),
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
                                  185,
                                  color: ticker == row['ticker'] ? p.card : null,
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
          _paginationFooter(
            total: list.length,
            page: safePage,
            pageSize: _matrixPageSize,
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

  Widget methodologyFooter() {
    final cov = asMap(data?['coverage']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w(
            'Book weights reflect reported Form 13F common-long holdings, not total fund AUM. Net buying & net selling rank quarterly disclosed manager counts (New + Added vs Reduced + Exited); missing filings are not exits.',
            '持仓权重基于各机构 Form 13F 已披露美股多头市值计算，不代表基金总资产。净加仓与净减仓按当季披露动作净人数（新建+加仓 vs 减仓+清仓）排序；未披露不代表清仓。',
          ),
          style: s(11, false, p.muted),
        ),
        const SizedBox(height: 2),
        Text(
          w(
            '${cov['reportedManagers'] ?? '—'} managers in ${qLabel(quarter)} disclosure view · All ${availableGurus.length} profiles remain available.',
            '${qLabel(quarter)} 视图已纳入 ${cov['reportedManagers'] ?? '—'} 位管理人 · 共覆盖 ${availableGurus.length} 位机构档案。',
          ),
          style: s(11, false, p.muted),
        ),
        if (cov['scope'] != null && cov['scope'] != 'full_current_books')
          Text(
            w(
              'Historical extracts are partial. View the filing for complete holdings.',
              '历史季度摘录可能仅含主要持仓与变动，点击大佬可查看完整原始披露。',
            ),
            style: s(11, false, p.secondary),
          ),
      ],
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
        if (date.isNotEmpty) Text(date, style: s(10, false, p.muted)),
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
                  width: math.min(c.maxWidth, 250),
                  child: Row(
                    children: [
                      StockLogo(
                        ticker: text(row['ticker']),
                        palette: p,
                        size: 38,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(text(row['ticker']), style: s(21, true)),
                            Text(
                              text(row['name']),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
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
              '${row['managerCount']} 位持有者 · ${qLabel(quarter)} · ${people.length} 条披露记录',
            ),
            style: s(11, false, p.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              chip(
                'Holding weights',
                '持仓权重明细',
                !changesDetail,
                () => update(() => changesDetail = false),
              ),
              chip(
                'Quarterly share Δ',
                '季度股数变化',
                changesDetail,
                () => update(() => changesDetail = true),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (_, c) {
              final groups = [
                group(
                  w('New & added (${adds.length})', '新建与加仓（${adds.length}）'),
                  adds,
                  const Color(0xFF2ECC8F),
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
                        const SizedBox(width: 14),
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
                  'Unchanged / other reported (${others.length})',
                  '持仓不变及其他披露（${others.length}）',
                ),
                style: s(12),
              ),
              children: others.map(person).toList(),
            ),
          const SizedBox(height: 6),
          Text(
            w(
              '13F is delayed. Share changes may include corporate actions; book weights do not represent total fund assets.',
              '13F 披露存在延迟。股数变动可能受拆合股等公司行动影响，持仓权重不代表基金全部资产。',
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
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                w('No reported moves in this group.', '此组没有已披露变动。'),
                style: s(12, false, p.muted),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 210),
              child: ListView(
                shrinkWrap: true,
                children: people.map(person).toList(),
              ),
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
            avatar({...manager(text(m['guruId'])), ...m}, 28),
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
                    '${w('Filed', '披露')} ${m['availableAt'] ?? '—'}',
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
