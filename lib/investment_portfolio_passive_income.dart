part of 'main.dart';

// Calm, low-glare institutional dark-mode palette:
// Steel-sky blue for Calls, lilac for Puts, sage-teal for cash dividends, coral-rose for realized option losses.
Color passiveCallColor(Palette p) =>
    p.colorBlind ? const Color(0xFF6BA3E8) : const Color(0xFF6B9FD4);

Color passivePutColor(Palette p) =>
    p.colorBlind ? const Color(0xFFD8A45B) : const Color(0xFF9B8AE6);

Color passiveDividendColor(Palette p) =>
    p.colorBlind ? const Color(0xFF9F8FEF) : const Color(0xFF4CA98E);

Color passiveLossColor(Palette p) =>
    p.colorBlind ? const Color(0xFFE5865E) : const Color(0xFFE06C75);

class PortfolioPassiveIncomeCard extends StatefulWidget {
  const PortfolioPassiveIncomeCard({
    super.key,
    required this.passiveIncome,
    required this.currency,
    required this.palette,
    required this.hideAmounts,
    this.onCompany,
  });

  final Map<String, dynamic> passiveIncome;
  final String currency;
  final Palette palette;
  final bool hideAmounts;
  final void Function(String ticker, String section)? onCompany;

  @override
  State<PortfolioPassiveIncomeCard> createState() =>
      _PortfolioPassiveIncomeCardState();
}

class _PortfolioPassiveIncomeCardState
    extends State<PortfolioPassiveIncomeCard> {
  String? selectedScope;
  int? hoveredIndex;
  bool showLedger = false;

  String w(String en, String zh) => context.tr(zh, en);

  String fmtMoney(dynamic v, {bool signed = false}) {
    if (widget.hideAmounts) return '••••';
    final n = nullableNumber(v);
    if (n == null || !n.isFinite) return '—';
    final prefix = n < 0 ? '-' : (signed && n > 0 ? '+' : '');
    return '$prefix${widget.currency} ${formatNumber(n.abs())}';
  }

  String fmtPct(dynamic v, {bool signed = true}) {
    final n = nullableNumber(v);
    if (n == null || !n.isFinite) return '—';
    final prefix = signed && n > 0 ? '+' : '';
    return '$prefix${(n * 100).toStringAsFixed(1)}%';
  }

  String fmtShare(double part, double whole) {
    if (!part.isFinite || !whole.isFinite || whole <= 0) return '—';
    return '${(part / whole * 100).toStringAsFixed(1)}%';
  }

  List<String> _resolveYears(
    Map<String, dynamic> data,
    List<Map<String, dynamic>> allMonths,
  ) {
    final raw = data['availableYears'];
    if (raw is List && raw.isNotEmpty) {
      return raw.map((e) => text(e)).where((s) => s.length == 4).toList();
    }
    final yrs = <String>{};
    for (final m in allMonths) {
      final ym = text(m['month']);
      if (ym.length >= 4) yrs.add(ym.substring(0, 4));
    }
    final sorted = yrs.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  Map<String, dynamic> _resolveYearData(
    String year,
    Map<String, dynamic> data,
    List<Map<String, dynamic>> allMonths,
  ) {
    final annual = asMap(data['annual']);
    final stored = asMap(annual[year]);
    if (stored.isNotEmpty) return stored;

    // Fallback synthesis for minimal fixtures that omit precomputed `annual`
    final yrMonths = allMonths
        .where((m) => text(m['month']).startsWith('$year-'))
        .toList();
    final monthByYm = {for (final m in allMonths) text(m['month']): m};
    final priorYear = ((int.tryParse(year) ?? 2026) - 1).toString().padLeft(
      4,
      '0',
    );
    final monthly12 = <Map<String, dynamic>>[];
    var divSum = 0.0, callSum = 0.0, putSum = 0.0, optSum = 0.0;
    var divCount = 0, callCount = 0, putCount = 0, optCount = 0;
    for (var m = 1; m <= 12; m++) {
      final mm = m.toString().padLeft(2, '0');
      final ym = '$year-$mm';
      final priorYm = '$priorYear-$mm';
      final cur = monthByYm[ym];
      final prev = monthByYm[priorYm];
      final d = number(cur?['dividends']);
      final hasSplit = cur != null &&
          (cur.containsKey('callPnl') || cur.containsKey('putPnl'));
      final c = hasSplit ? number(cur['callPnl']) : number(cur?['expiredCalls']);
      final pt = hasSplit ? number(cur['putPnl']) : 0.0;
      final o = cur != null && cur.containsKey('optionsPnl')
          ? number(cur['optionsPnl'])
          : c + pt;
      final prevHasSplit = prev != null &&
          (prev.containsKey('priorYearCallPnl') ||
              prev.containsKey('callPnl') ||
              prev.containsKey('putPnl'));
      final pCall = prevHasSplit
          ? number(prev['callPnl'])
          : number(prev?['expiredCalls']);
      final pPut = prevHasSplit ? number(prev['putPnl']) : 0.0;
      final pOpt = prev != null && prev.containsKey('optionsPnl')
          ? number(prev['optionsPnl'])
          : pCall + pPut;
      divSum += d;
      callSum += c;
      putSum += pt;
      optSum += o;
      divCount += number(cur?['dividendCount']).round();
      callCount += number(cur?['callCount']).round();
      putCount += number(cur?['putCount']).round();
      optCount += cur != null && cur.containsKey('optionCount')
          ? number(cur['optionCount']).round()
          : (number(cur?['callCount']).round() +
                number(cur?['putCount']).round());
      monthly12.add({
        'month': ym,
        'covered': cur != null,
        'dividends': d,
        'callPnl': c,
        'putPnl': pt,
        'optionsPnl': o,
        'expiredCalls': o,
        'total': d + o,
        'dividendCount': number(cur?['dividendCount']).round(),
        'callCount': number(cur?['callCount']).round(),
        'putCount': number(cur?['putCount']).round(),
        'optionCount': cur != null && cur.containsKey('optionCount')
            ? number(cur['optionCount']).round()
            : (number(cur?['callCount']).round() +
                  number(cur?['putCount']).round()),
        'priorYearMonth': priorYm,
        'priorYearCovered': prev != null,
        'priorYearDividends': number(prev?['dividends']),
        'priorYearCallPnl': pCall,
        'priorYearPutPnl': pPut,
        'priorYearOptions': pOpt,
        'priorYearCalls': pOpt,
        'priorYearTotal': number(prev?['total']),
      });
    }
    final overlapMonths = monthly12
        .where((m) => m['covered'] == true && m['priorYearCovered'] == true)
        .toList();
    Map<String, dynamic> yoy;
    if (overlapMonths.isNotEmpty) {
      final currComp = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['total']),
      );
      final priorComp = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['priorYearTotal']),
      );
      final currOpts = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['optionsPnl'] ?? m['expiredCalls']),
      );
      final priorOpts = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['priorYearOptions'] ?? m['priorYearCalls']),
      );
      final currDivs = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['dividends']),
      );
      final priorDivs = overlapMonths.fold<double>(
        0,
        (s, m) => s + number(m['priorYearDividends']),
      );
      yoy = {
        'status': overlapMonths.length == yrMonths.length
            ? 'full_same_period'
            : 'overlapping_subperiod',
        'priorYear': priorYear,
        'currentFrom': '${overlapMonths.first['month']}-01',
        'currentTo': '${overlapMonths.last['month']}-28',
        'priorFrom': '${overlapMonths.first['priorYearMonth']}-01',
        'priorTo': '${overlapMonths.last['priorYearMonth']}-28',
        'currentTotal': currComp,
        'priorTotal': priorComp,
        'deltaTotal': currComp - priorComp,
        'pctTotal': priorComp > 0 ? (currComp - priorComp) / priorComp : null,
        'currentOptions': currOpts,
        'priorOptions': priorOpts,
        'deltaOptions': currOpts - priorOpts,
        'pctOptions': priorOpts > 0 ? (currOpts - priorOpts) / priorOpts : null,
        'currentCalls': currOpts,
        'priorCalls': priorOpts,
        'deltaCalls': currOpts - priorOpts,
        'pctCalls': priorOpts > 0 ? (currOpts - priorOpts) / priorOpts : null,
        'currentDividends': currDivs,
        'priorDividends': priorDivs,
        'deltaDividends': currDivs - priorDivs,
        'pctDividends': priorDivs > 0 ? (currDivs - priorDivs) / priorDivs : null,
      };
    } else {
      yoy = {'status': 'prior_year_unavailable', 'priorYear': priorYear};
    }

    final events = asList(
      data['recentEvents'],
    ).where((e) => text(e['date']).startsWith('$year-')).toList();

    return {
      'year': year,
      'fromDate': yrMonths.isNotEmpty
          ? '${yrMonths.first['month']}-01'
          : '$year-01-01',
      'toDate': yrMonths.isNotEmpty
          ? text(data['toDate'], '${yrMonths.last['month']}-28')
          : '$year-12-31',
      'isFullYear': yrMonths.length == 12,
      'isYtd': yrMonths.length < 12,
      'totalConfirmed': divSum + optSum,
      'dividends': {
        'grossAmount': divSum,
        'withholdingTax': yrsSingle(data, year)
            ? asMap(data['dividends'])['withholdingTax']
            : null,
        'netAmount': yrsSingle(data, year)
            ? asMap(data['dividends'])['netAmount']
            : null,
        'eventCount': divCount,
      },
      'options': {
        'amount': optSum,
        'callAmount': callSum,
        'putAmount': putSum,
        'settlementCount': optCount,
        'callCount': callCount,
        'putCount': putCount,
        'contractCount': optCount,
      },
      'expiredCalls': {
        'amount': optSum,
        'settlementCount': optCount,
        'contractCount': optCount,
      },
      'monthly': monthly12,
      'byTicker': yrsSingle(data, year) ? asList(data['byTicker']) : const [],
      'recentEvents': events,
      'yoy': yoy,
    };
  }

  bool yrsSingle(Map<String, dynamic> data, String year) {
    final ms = asList(data['monthly']);
    return ms.isNotEmpty &&
        ms.every((m) => text(m['month']).startsWith('$year-'));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final callColor = passiveCallColor(p);
    final putColor = passivePutColor(p);
    final divColor = passiveDividendColor(p);
    final lossColor = passiveLossColor(p);
    final data = widget.passiveIncome;
    final ready = data['status'] == 'ready';
    final pending = asMap(data['pendingShortCalls']);
    final pendingRows = asList(pending['rows']);
    final pendingPuts = asMap(data['pendingShortPuts']);
    final pendingPutRows = asList(pendingPuts['rows']);
    if (!ready && pendingRows.isEmpty && pendingPutRows.isEmpty) {
      return const SizedBox.shrink();
    }

    final allMonths = asList(data['monthly']);
    final years = _resolveYears(data, allMonths);
    final validScopes = <String>{
      ...years,
      if (allMonths.length > 6) 'TTM',
      'ALL',
    };
    final defaultScope = years.isNotEmpty ? years.first : 'ALL';
    final activeScope =
        selectedScope != null && validScopes.contains(selectedScope)
        ? selectedScope!
        : defaultScope;
    final isYearScope = years.contains(activeScope);

    late final List<Map<String, dynamic>> displayMonths;
    late final double windowDivs;
    late final double windowOptions;
    late final double windowCalls;
    late final double windowPuts;
    late final int windowDivCount;
    late final int windowOptCount;
    late final double? taxAmount;
    late final double? netDividends;
    late final List<Map<String, dynamic>> scopedByTicker;
    late final List<Map<String, dynamic>> scopedEvents;
    late final Map<String, dynamic> yoyInfo;
    late final String periodLabel;

    if (isYearScope) {
      final yrData = _resolveYearData(activeScope, data, allMonths);
      final yrDivInfo = asMap(yrData['dividends']);
      final yrOptInfo = asMap(yrData['options']);
      final yrCallInfo = asMap(yrData['expiredCalls']);
      displayMonths = asList(yrData['monthly']);
      windowDivs = number(yrDivInfo['grossAmount']);
      if (yrOptInfo.isNotEmpty) {
        windowOptions = number(yrOptInfo['amount']);
        windowCalls = yrOptInfo.containsKey('callAmount')
            ? number(yrOptInfo['callAmount'])
            : windowOptions;
        windowPuts = number(yrOptInfo['putAmount']);
        windowOptCount = number(yrOptInfo['contractCount']).round();
      } else {
        windowOptions = number(yrCallInfo['amount']);
        windowCalls = windowOptions;
        windowPuts = 0.0;
        windowOptCount = number(yrCallInfo['contractCount']).round();
      }
      windowDivCount = number(yrDivInfo['eventCount']).round();
      taxAmount = nullableNumber(yrDivInfo['withholdingTax']);
      netDividends = nullableNumber(yrDivInfo['netAmount']);
      final yrTickers = asList(yrData['byTicker']);
      scopedByTicker = yrTickers.isNotEmpty
          ? yrTickers
          : asList(data['byTicker']);
      scopedEvents = asList(yrData['recentEvents']);
      yoyInfo = asMap(yrData['yoy']);
      periodLabel =
          '${text(yrData['fromDate'], '$activeScope-01-01')} → ${text(yrData['toDate'], '$activeScope-12-31')}';
    } else if (activeScope == 'TTM') {
      displayMonths = allMonths.length > 12
          ? allMonths.sublist(allMonths.length - 12)
          : allMonths;
      windowDivs = displayMonths.fold<double>(
        0,
        (s, m) => s + number(m['dividends']),
      );
      windowCalls = displayMonths.fold<double>(
        0,
        (s, m) =>
            s +
            (m.containsKey('callPnl')
                ? number(m['callPnl'])
                : number(m['expiredCalls'])),
      );
      windowPuts = displayMonths.fold<double>(
        0,
        (s, m) => s + number(m['putPnl']),
      );
      windowOptions = displayMonths.fold<double>(
        0,
        (s, m) =>
            s +
            (m.containsKey('optionsPnl')
                ? number(m['optionsPnl'])
                : number(m['expiredCalls'])),
      );
      windowDivCount = displayMonths.fold<int>(
        0,
        (s, m) => s + number(m['dividendCount']).round(),
      );
      windowOptCount = displayMonths.fold<int>(
        0,
        (s, m) =>
            s +
            (m.containsKey('optionCount')
                ? number(m['optionCount']).round()
                : number(m['callCount']).round() +
                      number(m['putCount']).round()),
      );
      taxAmount = null;
      netDividends = null;
      scopedByTicker = asList(data['byTicker']);
      final minYm = displayMonths.isNotEmpty
          ? text(displayMonths.first['month'])
          : '';
      scopedEvents = asList(
        data['recentEvents'],
      ).where((e) => text(e['date']).compareTo(minYm) >= 0).toList();
      yoyInfo = const {};
      periodLabel = displayMonths.isNotEmpty
          ? '${displayMonths.first['month']} → ${displayMonths.last['month']}'
          : '—';
    } else {
      final divInfo = asMap(data['dividends']);
      final optInfo = asMap(data['options']);
      final callInfo = asMap(data['expiredCalls']);
      displayMonths = allMonths;
      windowDivs = number(divInfo['grossAmount']);
      if (optInfo.isNotEmpty) {
        windowOptions = number(optInfo['amount']);
        windowCalls = optInfo.containsKey('callAmount')
            ? number(optInfo['callAmount'])
            : windowOptions;
        windowPuts = number(optInfo['putAmount']);
        windowOptCount = number(optInfo['contractCount']).round();
      } else {
        windowOptions = number(callInfo['amount']);
        windowCalls = windowOptions;
        windowPuts = 0.0;
        windowOptCount = number(callInfo['contractCount']).round();
      }
      windowDivCount = number(divInfo['eventCount']).round();
      taxAmount = nullableNumber(divInfo['withholdingTax']);
      netDividends = nullableNumber(divInfo['netAmount']);
      scopedByTicker = asList(data['byTicker']);
      scopedEvents = asList(data['recentEvents']);
      yoyInfo = years.isNotEmpty
          ? asMap(_resolveYearData(years.first, data, allMonths)['yoy'])
          : const {};
      periodLabel =
          '${text(data['fromDate'], '—')} → ${text(data['toDate'], '—')}';
    }

    final windowTotal = windowDivs + windowOptions;
    final allTimeTotal = number(data['totalConfirmed']);

    // Default active month on chart: latest covered month
    int? defaultChartIdx;
    for (var i = displayMonths.length - 1; i >= 0; i--) {
      if (displayMonths[i]['covered'] != false) {
        defaultChartIdx = i;
        break;
      }
    }
    final activeIdx = displayMonths.isEmpty
        ? null
        : (hoveredIndex ?? defaultChartIdx ?? (displayMonths.length - 1)).clamp(
            0,
            displayMonths.length - 1,
          );
    final activeMonth = activeIdx != null ? displayMonths[activeIdx] : null;

    final screenW = MediaQuery.sizeOf(context).width;
    final isMobile = screenW > 0 && screenW < 640;
    return Container(
      key: const ValueKey('portfolio-passive-income-card'),
      padding: EdgeInsets.all(isMobile ? 16 : 20),
      decoration: BoxDecoration(
        color: isMobile ? const Color(0xFF161B24) : p.panel,
        borderRadius: BorderRadius.circular(isMobile ? 20 : 14),
        border: Border.all(
          color: isMobile ? Colors.white.withValues(alpha: .05) : p.border,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(
              p: p,
              callColor: callColor,
              divColor: divColor,
              ready: ready,
              years: years,
              allMonthsCount: allMonths.length,
              activeScope: activeScope,
              data: data,
              allMonths: allMonths,
              periodLabel: periodLabel,
            ),
            if (ready) ...[
              const SizedBox(height: 16),
              _buildSummaryGrid(
                p: p,
                callColor: callColor,
                putColor: putColor,
                divColor: divColor,
                lossColor: lossColor,
                activeScope: activeScope,
                isYearScope: isYearScope,
                years: years,
                data: data,
                allMonths: allMonths,
                windowTotal: windowTotal,
                allTimeTotal: allTimeTotal,
                windowOptions: windowOptions,
                windowCalls: windowCalls,
                windowPuts: windowPuts,
                windowDivs: windowDivs,
                windowOptCount: windowOptCount,
                windowDivCount: windowDivCount,
                taxAmount: taxAmount,
                netDividends: netDividends,
                yoyInfo: yoyInfo,
              ),
              const SizedBox(height: 18),
              LayoutBuilder(
                builder: (_, c) {
                  final monthlyChart = _buildMonthlyChart(
                    p: p,
                    callColor: callColor,
                    putColor: putColor,
                    divColor: divColor,
                    lossColor: lossColor,
                    months: displayMonths,
                    hoveredIdx: hoveredIndex,
                    activeMonth: activeMonth,
                    isYearScope: isYearScope,
                    activeScope: activeScope,
                  );
                  final sourceBreakdown = _buildSourceBreakdown(
                    p: p,
                    callColor: callColor,
                    putColor: putColor,
                    divColor: divColor,
                    lossColor: lossColor,
                    rows: scopedByTicker,
                    scopeTotal: windowTotal > 0 ? windowTotal : allTimeTotal,
                    scopeLabel: isYearScope
                        ? w('$activeScope breakdown', '$activeScope 年贡献明细')
                        : w('Cumulative breakdown', '累计贡献明细'),
                  );
                  if (c.maxWidth >= 880 &&
                      MediaQuery.textScalerOf(context).scale(1) <= 1.25) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 6, child: monthlyChart),
                        const SizedBox(width: 22),
                        Container(width: 1, height: 258, color: p.border),
                        const SizedBox(width: 22),
                        Expanded(flex: 5, child: sourceBreakdown),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      monthlyChart,
                      const SizedBox(height: 16),
                      Divider(height: 1, color: p.border),
                      const SizedBox(height: 16),
                      sourceBreakdown,
                    ],
                  );
                },
              ),
            ],
            if (pendingRows.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildPendingShortCalls(p, callColor, pending, pendingRows),
            ],
            if (pendingPutRows.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildPendingShortPuts(p, pendingPuts, pendingPutRows),
            ],
            if (ready && scopedEvents.isNotEmpty) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('passive-income-ledger-toggle'),
                  onPressed: () => setState(() => showLedger = !showLedger),
                  icon: Icon(
                    showLedger
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 17,
                  ),
                  label: Text(
                    showLedger
                        ? w('Hide confirmed records', '收起已确认流水')
                        : w(
                            'View confirmed records (${scopedEvents.length})',
                            '查看已确认流水（${scopedEvents.length} 笔）',
                          ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              if (showLedger)
                _buildRecentLedger(
                  p,
                  callColor,
                  putColor,
                  divColor,
                  lossColor,
                  scopedEvents,
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _yearOptionLabel(
    String yr,
    Map<String, dynamic> data,
    List<Map<String, dynamic>> allMonths,
    String latestYear,
  ) {
    final info = _resolveYearData(yr, data, allMonths);
    final isYtd = info['isYtd'] == true || yr == latestYear && info['isFullYear'] != true;
    final fromD = text(info['fromDate']);
    final isPartialStart =
        fromD.length >= 10 && !fromD.endsWith('-01-01') && yr != latestYear;
    if (isYtd) {
      return w('$yr (YTD)', '$yr 年（今年迄今）');
    }
    if (isPartialStart) {
      final startMm = fromD.substring(5, 7);
      return w('$yr (from $startMm)', '$yr 年（$startMm月起）');
    }
    return w('$yr Full Year', '$yr 全年');
  }

  Widget _buildHeader({
    required Palette p,
    required Color callColor,
    required Color divColor,
    required bool ready,
    required List<String> years,
    required int allMonthsCount,
    required String activeScope,
    required Map<String, dynamic> data,
    required List<Map<String, dynamic>> allMonths,
    required String periodLabel,
  }) {
    final dropdownItems = <(String, String)>[
      for (final yr in years)
        (yr, _yearOptionLabel(yr, data, allMonths, years.first)),
      if (allMonthsCount > 6) ('TTM', w('Trailing 12M', '近 12 个月（滚动）')),
      ('ALL', w('All years combined', '全部年份累计')),
    ];

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 10,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: p.border),
              ),
              child: Icon(
                Icons.payments_outlined,
                size: 17,
                color: p.muted,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w('Confirmed passive income', '已收被动收入（已确认）'),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    w(
                      'Cash dividends + realized Call/Put P&L (expiry, TP & SL) · $periodLabel',
                      '实际到账股息 + Call/Put 期权已实现盈亏（含到期、止盈、止损） · $periodLabel',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (ready && dropdownItems.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: p.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.calendar_today_outlined, size: 14, color: p.muted),
                const SizedBox(width: 7),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    key: const ValueKey('passive-year-dropdown'),
                    value: dropdownItems.any((e) => e.$1 == activeScope)
                        ? activeScope
                        : dropdownItems.first.$1,
                    isDense: true,
                    dropdownColor: p.panel,
                    icon: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: p.text,
                    ),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                    items: [
                      for (final item in dropdownItems)
                        DropdownMenuItem<String>(
                          value: item.$1,
                          child: Text(item.$2),
                        ),
                    ],
                    onChanged: (next) {
                      if (next == null) return;
                      setState(() {
                        selectedScope = next;
                        hoveredIndex = null;
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSummaryGrid({
    required Palette p,
    required Color callColor,
    required Color putColor,
    required Color divColor,
    required Color lossColor,
    required String activeScope,
    required bool isYearScope,
    required List<String> years,
    required Map<String, dynamic> data,
    required List<Map<String, dynamic>> allMonths,
    required double windowTotal,
    required double allTimeTotal,
    required double windowOptions,
    required double windowCalls,
    required double windowPuts,
    required double windowDivs,
    required int windowOptCount,
    required int windowDivCount,
    required double? taxAmount,
    required double? netDividends,
    required Map<String, dynamic> yoyInfo,
  }) {
    final yoyStatus = text(yoyInfo['status']);
    final hasComparableYoy =
        yoyStatus == 'full_same_period' || yoyStatus == 'overlapping_subperiod';
    final optYoyPct = hasComparableYoy
        ? nullableNumber(yoyInfo['pctOptions'] ?? yoyInfo['pctCalls'])
        : null;
    final divYoyPct = hasComparableYoy
        ? nullableNumber(yoyInfo['pctDividends'])
        : null;
    final hasAnyPut = windowPuts.abs() > 0.005;
    final allNonNegative = windowOptions >= 0 && windowDivs >= 0 && windowTotal > 0;
    final optAccent = windowOptions < 0 ? lossColor : callColor;

    return LayoutBuilder(
      builder: (_, c) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final cols = c.maxWidth >= 940 && textScale <= 1.25
            ? 4
            : (c.maxWidth >= 560 && textScale <= 1.3 ? 2 : 1);
        final tileWidth = cols == 1
            ? c.maxWidth
            : (c.maxWidth - (cols - 1) * 12) / cols;

        final String totalSub;
        if (widget.hideAmounts) {
          totalSub = allNonNegative
              ? w(
                  'Options ${fmtShare(windowOptions, windowTotal)} · Dividends ${fmtShare(windowDivs, windowTotal)}',
                  '期权 ${fmtShare(windowOptions, windowTotal)} · 股息 ${fmtShare(windowDivs, windowTotal)}',
                )
              : w(
                  'Includes realized Call/Put TP & SL + dividends',
                  '已含 Call/Put 止盈止损与到账股息',
                );
        } else if (allNonNegative) {
          totalSub = isYearScope && years.length > 1
              ? w(
                  'Options ${fmtShare(windowOptions, windowTotal)} · Divs ${fmtShare(windowDivs, windowTotal)} · All-time ${fmtMoney(allTimeTotal)}',
                  '期权 ${fmtShare(windowOptions, windowTotal)} · 股息 ${fmtShare(windowDivs, windowTotal)} · 跨年累计 ${fmtMoney(allTimeTotal)}',
                )
              : w(
                  'Options ${fmtShare(windowOptions, windowTotal)} · Dividends ${fmtShare(windowDivs, windowTotal)}',
                  '期权占 ${fmtShare(windowOptions, windowTotal)} · 股息占 ${fmtShare(windowDivs, windowTotal)}',
                );
        } else {
          totalSub = isYearScope && years.length > 1
              ? w(
                  'Options ${fmtMoney(windowOptions, signed: true)} · Divs ${fmtMoney(windowDivs)} · All-time ${fmtMoney(allTimeTotal)}',
                  '期权 ${fmtMoney(windowOptions, signed: true)} · 股息 ${fmtMoney(windowDivs)} · 跨年累计 ${fmtMoney(allTimeTotal)}',
                )
              : w(
                  'Options ${fmtMoney(windowOptions, signed: true)} · Dividends ${fmtMoney(windowDivs)}',
                  '期权 ${fmtMoney(windowOptions, signed: true)} · 股息 ${fmtMoney(windowDivs)}',
                );
        }

        final String optSubtitle;
        if (widget.hideAmounts) {
          optSubtitle = allNonNegative
              ? w('Share of confirmed income', '占当期已确认收入比例')
              : w('Realized Call & Put expiry, TP & SL', '含 Call/Put 到期与止盈止损');
        } else if (hasAnyPut) {
          optSubtitle = w(
            'Call ${fmtMoney(windowCalls, signed: true)} · Put ${fmtMoney(windowPuts, signed: true)} · $windowOptCount contracts',
            'Call ${fmtMoney(windowCalls, signed: true)} · Put ${fmtMoney(windowPuts, signed: true)} · $windowOptCount 张（已扣佣金）',
          );
        } else {
          optSubtitle = w(
            'Call ${fmtMoney(windowCalls, signed: true)} · $windowOptCount contracts · net of fees',
            'Call ${fmtMoney(windowCalls, signed: true)} · $windowOptCount 张期权平仓/到期 · 已扣佣金',
          );
        }

        final tiles = <Widget>[
          _summaryTile(
            p: p,
            accentColor: windowTotal < 0 ? lossColor : p.text,
            title: isYearScope
                ? w('$activeScope confirmed total', '$activeScope 年已确认合计')
                : w('Total confirmed', '已确认被动收入合计'),
            value: widget.hideAmounts
                ? (windowTotal > 0 ? '100.0%' : '—')
                : fmtMoney(windowTotal),
            valueColor: windowTotal < 0 ? lossColor : null,
            badge: null,
            subtitle: totalSub,
            highlight: true,
          ),
          _summaryTile(
            p: p,
            accentColor: optAccent,
            title: w('Realized options (Call & Put)', '期权已实现净盈亏（Call/Put）'),
            value: widget.hideAmounts
                ? (allNonNegative
                      ? fmtShare(windowOptions, windowTotal)
                      : (windowOptions >= 0 ? '≥0' : '<0'))
                : fmtMoney(windowOptions),
            valueColor: windowOptions < 0 ? lossColor : null,
            badge: optYoyPct != null
                ? '${w('YoY', '同比')} ${fmtPct(optYoyPct)}'
                : null,
            badgePositive: optYoyPct == null ? null : optYoyPct >= 0,
            subtitle: optSubtitle,
          ),
          _summaryTile(
            p: p,
            accentColor: divColor,
            title: w('Cash dividends', '已到账现金股息'),
            value: widget.hideAmounts
                ? (allNonNegative ? fmtShare(windowDivs, windowTotal) : '••••')
                : fmtMoney(windowDivs),
            badge: divYoyPct != null
                ? '${w('YoY', '同比')} ${fmtPct(divYoyPct)}'
                : null,
            badgePositive: divYoyPct == null ? null : divYoyPct >= 0,
            subtitle: widget.hideAmounts
                ? w('Share of confirmed income', '占当期已确认收入比例')
                : (taxAmount != null && taxAmount < 0 && netDividends != null
                      ? w(
                          'Net ${fmtMoney(netDividends)} after ${fmtMoney(taxAmount)} tax',
                          '税后净额 ${fmtMoney(netDividends)}（预扣税 ${fmtMoney(taxAmount)}）',
                        )
                      : w(
                          '$windowDivCount broker cash payouts received',
                          '$windowDivCount 笔券商现金分红入账',
                        )),
          ),
          _buildYoySummaryTile(
            p: p,
            activeScope: activeScope,
            isYearScope: isYearScope,
            years: years,
            data: data,
            allMonths: allMonths,
            yoyInfo: yoyInfo,
          ),
        ];

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final tile in tiles) SizedBox(width: tileWidth, child: tile),
          ],
        );
      },
    );
  }

  Widget _buildYoySummaryTile({
    required Palette p,
    required String activeScope,
    required bool isYearScope,
    required List<String> years,
    required Map<String, dynamic> data,
    required List<Map<String, dynamic>> allMonths,
    required Map<String, dynamic> yoyInfo,
  }) {
    final status = text(yoyInfo['status']);
    final priorYear = text(
      yoyInfo['priorYear'],
      isYearScope
          ? '${(int.tryParse(activeScope) ?? 2026) - 1}'
          : (years.length > 1 ? years[1] : ''),
    );

    if (!isYearScope && activeScope == 'ALL' && years.length >= 2) {
      final y0 = _resolveYearData(years[0], data, allMonths);
      final y1 = _resolveYearData(years[1], data, allMonths);
      final t0 = number(y0['totalConfirmed']);
      final t1 = number(y1['totalConfirmed']);
      return Container(
        key: const ValueKey('passive-yoy-card'),
        child: _summaryTile(
          p: p,
          accentColor: p.accent,
          title: w('Annual history overview', '历年被动收入对比'),
          value: w('${years.length} years', '共 ${years.length} 个年度'),
          subtitle: widget.hideAmounts
              ? w(
                  'Select any year in dropdown for YoY view',
                  '右上角下拉可按年份回看及对比同期',
                )
              : '${years[0]}: ${fmtMoney(t0)} · ${years[1]}: ${fmtMoney(t1)}',
        ),
      );
    }

    if (status == 'full_same_period' || status == 'overlapping_subperiod') {
      final deltaTotal = number(yoyInfo['deltaTotal']);
      final pctTotal = nullableNumber(yoyInfo['pctTotal']);
      final priorTotal = number(yoyInfo['priorTotal']);
      final deltaOpts = number(yoyInfo['deltaOptions'] ?? yoyInfo['deltaCalls']);
      final deltaDivs = number(yoyInfo['deltaDividends']);
      final priorFrom = text(yoyInfo['priorFrom']);
      final priorTo = text(yoyInfo['priorTo']);
      final windowSpan = priorFrom.length >= 10 && priorTo.length >= 10
          ? '${priorFrom.substring(5)}~${priorTo.substring(5)}'
          : priorYear;
      final up = deltaTotal >= 0;
      final tone = up ? p.positive : p.negative;

      return Container(
        key: const ValueKey('passive-yoy-card'),
        child: _summaryTile(
          p: p,
          accentColor: tone,
          title: status == 'full_same_period'
              ? w('vs $priorYear same period (YoY)', '对比 $priorYear 去年同期')
              : w('vs $priorYear matched window', '对比 $priorYear 可比同期 ($windowSpan)'),
          value: widget.hideAmounts
              ? (pctTotal != null ? fmtPct(pctTotal) : (up ? '↑' : '↓'))
              : fmtMoney(deltaTotal, signed: true),
          badge: !widget.hideAmounts && pctTotal != null
              ? fmtPct(pctTotal)
              : null,
          badgePositive: up,
          valueColor: tone,
          subtitle: widget.hideAmounts
              ? w(
                  'Same-period comparison ($windowSpan)',
                  '严格同日历区间对比 ($windowSpan)',
                )
              : w(
                  '$priorYear ($windowSpan): ${fmtMoney(priorTotal)} · Opt ${fmtMoney(deltaOpts, signed: true)} · Div ${fmtMoney(deltaDivs, signed: true)}',
                  '$priorYear 同期 ${fmtMoney(priorTotal)} · 期权 ${fmtMoney(deltaOpts, signed: true)} · 股息 ${fmtMoney(deltaDivs, signed: true)}',
                ),
        ),
      );
    }

    return Container(
      key: const ValueKey('passive-yoy-card'),
      child: _summaryTile(
        p: p,
        accentColor: p.faint,
        title: priorYear.isNotEmpty
            ? w('vs $priorYear same period (YoY)', '对比 $priorYear 去年同期')
            : w('Year-over-year comparison', '与去年同期对比'),
        value: w('Baseline year', '基准记录年'),
        subtitle: priorYear.isNotEmpty
            ? w(
                'No $priorYear same-period broker history yet; YoY unlocks automatically as annual history accumulates.',
                '暂无 $priorYear 同日历区间券商流水，跨满周年后将自动展示同期增减对比。',
              )
            : w(
                'YoY comparison activates automatically across years.',
                '跨年度流水积累后自动展示同期同比增减。',
              ),
      ),
    );
  }

  Widget _summaryTile({
    required Palette p,
    required Color accentColor,
    required String title,
    required String value,
    required String subtitle,
    String? badge,
    bool? badgePositive,
    Color? valueColor,
    bool highlight = false,
  }) {
    final badgeTint = badgePositive == null
        ? p.muted
        : (badgePositive ? p.positive : p.negative);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: p.card.withValues(alpha: highlight ? .62 : .42),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: highlight ? p.text.withValues(alpha: .16) : p.border,
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
                  color: accentColor.withValues(alpha: .88),
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (badge != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: badgeTint.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(
                      color: badgeTint,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 9),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: valueColor ?? p.text,
              fontSize: 21,
              fontWeight: FontWeight.w700,
              letterSpacing: -.3,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.muted, fontSize: 11, height: 1.35),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthlyChart({
    required Palette p,
    required Color callColor,
    required Color putColor,
    required Color divColor,
    required Color lossColor,
    required List<Map<String, dynamic>> months,
    required int? hoveredIdx,
    required Map<String, dynamic>? activeMonth,
    required bool isYearScope,
    required String activeScope,
  }) {
    if (months.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Text(
          w('No monthly observations in this range.', '所选区间暂无月度确认收入。'),
          style: TextStyle(color: p.muted, fontSize: 12),
        ),
      );
    }
    double monthCall(Map<String, dynamic>? m) => m == null
        ? 0.0
        : (m.containsKey('callPnl')
              ? number(m['callPnl'])
              : number(m['expiredCalls']));
    double monthPut(Map<String, dynamic>? m) =>
        m == null ? 0.0 : number(m['putPnl']);

    final hasAnyPriorOverlay =
        isYearScope &&
        months.any(
          (m) =>
              m['priorYearCovered'] == true &&
              number(m['priorYearTotal']).abs() > 0.005,
        );
    final hasAnyPut = months.any((m) => monthPut(m).abs() > 0.005);
    final hasAnyLoss = months.any(
      (m) =>
          monthCall(m) < -0.005 ||
          monthPut(m) < -0.005 ||
          number(m['total']) < -0.005,
    );

    double maxPos = 0.0;
    double minNeg = 0.0;
    for (final r in months) {
      final d = number(r['dividends']);
      final c = monthCall(r);
      final pt = monthPut(r);
      final posStack =
          (d > 0 ? d : 0.0) + (c > 0 ? c : 0.0) + (pt > 0 ? pt : 0.0);
      final negStack =
          (d < 0 ? d : 0.0) + (c < 0 ? c : 0.0) + (pt < 0 ? pt : 0.0);
      if (posStack > maxPos) maxPos = posStack;
      if (negStack < minNeg) minNeg = negStack;
      if (isYearScope && r['priorYearCovered'] == true) {
        final prev = number(r['priorYearTotal']);
        if (prev > maxPos) maxPos = prev;
        if (prev < minNeg) minNeg = prev;
      }
    }

    final activeCovered = activeMonth?['covered'] != false;
    final activeTotal = number(activeMonth?['total']);
    final activeCalls = monthCall(activeMonth);
    final activePuts = monthPut(activeMonth);
    final activeDivs = number(activeMonth?['dividends']);
    final activePriorCovered =
        isYearScope && activeMonth?['priorYearCovered'] == true;
    final activePriorTotal = number(activeMonth?['priorYearTotal']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 6,
          children: [
            Text(
              isYearScope
                  ? w(
                      '$activeScope monthly cashflow (Jan–Dec)',
                      '$activeScope 年月度确认净收入（1–12月）',
                    )
                  : w('Monthly confirmed cashflow', '月度已确认净收入'),
              style: TextStyle(
                color: p.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _legendDot(p, callColor, w('Call P&L', 'Call 净盈亏')),
                if (hasAnyPut)
                  _legendDot(p, putColor, w('Put P&L', 'Put 净盈亏')),
                _legendDot(p, divColor, w('Cash Dividend', '现金股息')),
                if (hasAnyLoss)
                  _legendDot(p, lossColor, w('Option Loss', '期权止损')),
                if (hasAnyPriorOverlay)
                  _legendTick(p, w('Prior yr month', '去年同月')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (activeMonth != null)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                !activeCovered
                    ? '${text(activeMonth['month'])} · ${w('Not yet reached / outside report window', '尚未进入该月份或不在报表区间')}'
                    : widget.hideAmounts
                    ? '${text(activeMonth['month'])} · ${activeTotal > 0 && activeCalls >= 0 && activePuts >= 0 ? '${w('Options', '期权')} ${fmtShare(activeCalls + activePuts, activeTotal)} · ${w('Div', '股息')} ${fmtShare(activeDivs, activeTotal)}' : (activeTotal.abs() > 0.005 ? w('Confirmed activity recorded', '有已确认记录') : w('No confirmed income', '无确认记录'))}'
                    : '${text(activeMonth['month'])} · ${fmtMoney(activeTotal)}',
                style: TextStyle(
                  color: !activeCovered
                      ? p.muted
                      : (activeTotal < 0
                            ? lossColor
                            : (activeTotal > 0 ? p.text : p.muted)),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (activeCovered && !widget.hideAmounts) ...[
                Text(
                  'Call ${fmtMoney(activeCalls, signed: true)}',
                  style: TextStyle(
                    color: activeCalls < 0 ? lossColor : callColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (hasAnyPut || activePuts.abs() > 0.005)
                  Text(
                    'Put ${fmtMoney(activePuts, signed: true)}',
                    style: TextStyle(
                      color: activePuts < 0 ? lossColor : putColor,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                Text(
                  '${w('Div', '股息')} ${fmtMoney(activeDivs)}',
                  style: TextStyle(
                    color: divColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (activeCovered && activePriorCovered && !widget.hideAmounts)
                Text(
                  '· ${w('Prior yr', '去年同月')} ${fmtMoney(activePriorTotal)}${activePriorTotal > 0 ? ' (${fmtPct((activeTotal - activePriorTotal) / activePriorTotal)})' : ''}',
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
            ],
          ),
        const SizedBox(height: 12),
        SizedBox(
          key: const ValueKey('passive-income-monthly-chart'),
          height: 188,
          child: LayoutBuilder(
            builder: (_, c) {
              void selectAt(double dx) {
                if (months.isEmpty) return;
                const leftPad = 48.0;
                final plotW = math.max(1.0, c.maxWidth - leftPad - 8);
                final frac = ((dx - leftPad) / plotW).clamp(0.0, 0.9999);
                final idx = (frac * months.length).floor().clamp(
                  0,
                  months.length - 1,
                );
                if (hoveredIndex != idx) setState(() => hoveredIndex = idx);
              }

              return MouseRegion(
                onHover: (e) => selectAt(e.localPosition.dx),
                onExit: (_) => setState(() => hoveredIndex = null),
                child: GestureDetector(
                  onTapDown: (e) => selectAt(e.localPosition.dx),
                  child: CustomPaint(
                    painter: _PassiveIncomeBarPainter(
                      months: months,
                      maxPos: maxPos,
                      minNeg: minNeg,
                      palette: p,
                      callColor: callColor,
                      putColor: putColor,
                      divColor: divColor,
                      lossColor: lossColor,
                      activeIndex: hoveredIdx,
                      hideAmounts: widget.hideAmounts,
                      isYearScope: isYearScope,
                    ),
                    size: Size.infinite,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _legendDot(Palette p, Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2.5),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: p.text, fontSize: 11)),
    ],
  );

  Widget _legendTick(Palette p, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 11,
        height: 2,
        decoration: BoxDecoration(
          color: p.text.withValues(alpha: .65),
          borderRadius: BorderRadius.circular(1),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: TextStyle(color: p.muted, fontSize: 11)),
    ],
  );

  Widget _buildSourceBreakdown({
    required Palette p,
    required Color callColor,
    required Color putColor,
    required Color divColor,
    required Color lossColor,
    required List<Map<String, dynamic>> rows,
    required double scopeTotal,
    required String scopeLabel,
  }) {
    final top = rows
        .where((r) => number(r['total']).abs() > 0.005)
        .take(6)
        .toList();
    final maxRow = top.fold<double>(
      0,
      (m, r) => math.max(m, number(r['total']).abs()),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(
              w('By underlying source', '按标的来源贡献'),
              style: TextStyle(
                color: p.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(scopeLabel, style: TextStyle(color: p.muted, fontSize: 11)),
          ],
        ),
        const SizedBox(height: 12),
        if (top.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              w('No confirmed passive income in this period.', '该区间暂无已确认被动收入记录。'),
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
          ),
        for (final r in top)
          Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: widget.onCompany != null && text(r['ticker']) != 'CASH'
                  ? () => widget.onCompany!(text(r['ticker']), 'evidence')
                  : null,
              child: Builder(
                builder: (_) {
                  final hasSplit =
                      r.containsKey('callPnl') || r.containsKey('putPnl');
                  final callAmt = hasSplit
                      ? number(r['callPnl'])
                      : number(r['expiredCalls']);
                  final putAmt = hasSplit ? number(r['putPnl']) : 0.0;
                  final divAmt = number(r['dividends']);
                  final totAmt = number(r['total']);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          StockLogo(
                            ticker: text(r['ticker']),
                            palette: p,
                            size: 24,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Wrap(
                              spacing: 5,
                              runSpacing: 3,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  text(r['ticker']),
                                  style: TextStyle(
                                    color: p.text,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (callAmt.abs() > 0.005)
                                  _miniTag(
                                    callAmt < 0 ? lossColor : callColor,
                                    widget.hideAmounts
                                        ? 'Call'
                                        : 'Call ${fmtMoney(callAmt, signed: callAmt < 0 || putAmt.abs() > 0.005)}',
                                  ),
                                if (putAmt.abs() > 0.005)
                                  _miniTag(
                                    putAmt < 0 ? lossColor : putColor,
                                    widget.hideAmounts
                                        ? 'Put'
                                        : 'Put ${fmtMoney(putAmt, signed: true)}',
                                  ),
                                if (divAmt > 0.005)
                                  _miniTag(
                                    divColor,
                                    widget.hideAmounts
                                        ? w('Div', '股息')
                                        : '${w('Div', '股息')} ${fmtMoney(divAmt)}',
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            widget.hideAmounts
                                ? (totAmt >= 0 && scopeTotal > 0
                                      ? fmtShare(totAmt, scopeTotal)
                                      : (totAmt < 0 ? '<0' : '—'))
                                : fmtMoney(totAmt),
                            style: TextStyle(
                              color: totAmt < 0 ? lossColor : p.text,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      LayoutBuilder(
                        builder: (_, barConstraints) {
                          final fullW = barConstraints.maxWidth;
                          if (totAmt < 0) {
                            final lossW = maxRow > 0
                                ? (totAmt.abs() / maxRow * fullW)
                                      .clamp(2.0, fullW)
                                      .toDouble()
                                : 0.0;
                            return Container(
                              height: 5.5,
                              decoration: BoxDecoration(
                                color: p.border.withValues(alpha: .42),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Row(
                                children: [
                                  if (lossW > 0)
                                    Container(
                                      width: lossW,
                                      height: 5.5,
                                      decoration: BoxDecoration(
                                        color: lossColor.withValues(alpha: .85),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          }
                          final posCall = callAmt > 0 ? callAmt : 0.0;
                          final posPut = putAmt > 0 ? putAmt : 0.0;
                          final posDiv = divAmt > 0 ? divAmt : 0.0;
                          final posSum = posCall + posPut + posDiv;
                          final segs = <(double, Color)>[
                            if (posCall > 0) (posCall, callColor),
                            if (posPut > 0) (posPut, putColor),
                            if (posDiv > 0) (posDiv, divColor),
                          ];
                          final barScale = maxRow > 0 && posSum > 0
                              ? (totAmt / maxRow).clamp(0.0, 1.0)
                              : 0.0;
                          final totalBarW = fullW * barScale;
                          final gaps = segs.length > 1
                              ? (segs.length - 1) * 1.8
                              : 0.0;
                          final usableW = math.max(0.0, totalBarW - gaps);
                          return Container(
                            height: 5.5,
                            decoration: BoxDecoration(
                              color: p.border.withValues(alpha: .42),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Row(
                              children: [
                                for (var idx = 0; idx < segs.length; idx++) ...[
                                  if (idx > 0) const SizedBox(width: 1.8),
                                  Container(
                                    width: posSum > 0
                                        ? (segs[idx].$1 / posSum * usableW)
                                              .clamp(0.0, usableW)
                                              .toDouble()
                                        : 0.0,
                                    height: 5.5,
                                    decoration: BoxDecoration(
                                      color: segs[idx].$2.withValues(
                                        alpha: .82,
                                      ),
                                      borderRadius: BorderRadius.horizontal(
                                        left: idx == 0
                                            ? const Radius.circular(3)
                                            : const Radius.circular(1),
                                        right: idx == segs.length - 1
                                            ? const Radius.circular(3)
                                            : const Radius.circular(1),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  Widget _miniTag(Color tint, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
    decoration: BoxDecoration(
      color: tint.withValues(alpha: .11),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: tint.withValues(alpha: .22), width: 0.6),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: tint.withValues(alpha: .92),
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _buildPendingShortCalls(
    Palette p,
    Color callColor,
    Map<String, dynamic> pending,
    List<Map<String, dynamic>> pendingRows,
  ) => Container(
    key: const ValueKey('passive-pending-short-calls'),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    decoration: BoxDecoration(
      color: p.card.withValues(alpha: .38),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: p.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 6,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.schedule_rounded,
                  size: 15,
                  color: callColor.withValues(alpha: .85),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    w(
                      'Pending short calls · confirmed only after expiration',
                      '待到期卖 Call · 未到期暂不计入确认收入',
                    ),
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (!widget.hideAmounts &&
                nullableNumber(pending['collectedPremium']) != null)
              Text(
                w(
                  'Collected premium: ${fmtMoney(pending['collectedPremium'])}',
                  '待确认权利金：${fmtMoney(pending['collectedPremium'])}',
                ),
                style: TextStyle(
                  color: p.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final r in pendingRows)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: p.panel,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: p.border),
                ),
                child: Text(
                  widget.hideAmounts
                      ? '${text(r['ticker'])} · ${text(r['expiry'], '—')}'
                      : context.isChinese
                      ? '${text(r['ticker'])} ${nullableNumber(r['strike']) != null ? '\$${formatNumber(number(r['strike']))} ' : ''}看涨(Call) · ${text(r['expiry'], '—')} · ${number(r['contracts']).round()}张'
                      : '${text(r['ticker'])} ${nullableNumber(r['strike']) != null ? formatNumber(number(r['strike'])) : ''}C · ${text(r['expiry'], '—')} ×${number(r['contracts']).round()}',
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _buildPendingShortPuts(
    Palette p,
    Map<String, dynamic> pendingPuts,
    List<Map<String, dynamic>> putRows,
  ) {
    const putColor = Color(0xFF8E8CD8);
    return Container(
      key: const ValueKey('passive-pending-short-puts'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: p.card.withValues(alpha: .38),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.shield_outlined, size: 15, color: putColor),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      w(
                        'Open short puts · collateral & unconfirmed premium',
                        '在途卖 Put · 接盘备付金与待确认权利金',
                      ),
                      style: TextStyle(
                        color: p.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              if (!widget.hideAmounts)
                Text(
                  [
                    if (nullableNumber(pendingPuts['collectedPremium']) != null)
                      w(
                        'Premium: ${fmtMoney(pendingPuts['collectedPremium'])}',
                        '权利金：${fmtMoney(pendingPuts['collectedPremium'])}',
                      ),
                    if (nullableNumber(pendingPuts['collateralExposure']) !=
                        null)
                      w(
                        'Assignment notional: ${fmtMoney(pendingPuts['collateralExposure'])}',
                        '行权接盘敞口：${fmtMoney(pendingPuts['collateralExposure'])}',
                      ),
                  ].join(' · '),
                  style: TextStyle(
                    color: p.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final r in putRows)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: p.panel,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: p.border),
                  ),
                  child: Text(
                    widget.hideAmounts
                        ? '${text(r['ticker'])} · ${text(r['expiry'], '—')}'
                        : context.isChinese
                        ? '${text(r['ticker'])} ${nullableNumber(r['strike']) != null ? '\$${formatNumber(number(r['strike']))} ' : ''}看跌(Put) · ${text(r['expiry'], '—')} · ${number(r['contracts']).round()}张'
                        : '${text(r['ticker'])} ${nullableNumber(r['strike']) != null ? formatNumber(number(r['strike'])) : ''}P · ${text(r['expiry'], '—')} ×${number(r['contracts']).round()}',
                    style: TextStyle(color: p.muted, fontSize: 11.5),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecentLedger(
    Palette p,
    Color callColor,
    Color putColor,
    Color divColor,
    Color lossColor,
    List<Map<String, dynamic>> events,
  ) => Container(
    margin: const EdgeInsets.only(top: 6),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: p.card.withValues(alpha: .36),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: p.border),
    ),
    child: Column(
      children: [
        for (var i = 0; i < events.take(30).length; i++) ...[
          if (i > 0) Divider(height: 1, color: p.border),
          Builder(
            builder: (_) {
              final ev = events[i];
              final kind = text(ev['kind']);
              final amt = number(ev['amount']);
              final isDiv = kind == 'dividend';
              final isPut =
                  kind.startsWith('put_') ||
                  text(ev['right']).toUpperCase() == 'P';
              final isLoss = !isDiv && amt < 0;
              final badgeColor = isDiv
                  ? divColor
                  : (isLoss ? lossColor : (isPut ? putColor : callColor));
              final badgeText = switch (kind) {
                'dividend' => w('Div', '股息'),
                'expired_call' || 'call_expired' => w('Call Exp', 'Call 到期'),
                'call_tp' => w('Call TP', 'Call 止盈'),
                'call_sl' => w('Call SL', 'Call 止损'),
                'call_expired_loss' => w('Call Exp', 'Call 过期亏'),
                'put_expired' => w('Put Exp', 'Put 到期'),
                'put_tp' => w('Put TP', 'Put 止盈'),
                'put_sl' => w('Put SL', 'Put 止损'),
                'put_expired_loss' => w('Put Exp', 'Put 过期亏'),
                _ => isPut ? 'Put' : 'Call',
              };
              final strikeSuffix =
                  !widget.hideAmounts && nullableNumber(ev['strike']) != null
                  ? ' (${formatNumber(number(ev['strike']))}${isPut ? 'P' : 'C'})'
                  : '';
              final detailLabel = switch (kind) {
                'dividend' =>
                  ev['category'] == 'substitute_dividends' || ev['pil'] == true
                      ? '${text(ev['ticker'])} · ${w('PIL dividend', '代付股息 (PIL)')}'
                      : '${text(ev['ticker'])} · ${w('Cash Dividend', '现金股息')}',
                'expired_call' || 'call_expired' =>
                  '${text(ev['ticker'])} · ${w('Expired Short Call', '卖 Call 虚值到期归零')}$strikeSuffix',
                'call_tp' =>
                  '${text(ev['ticker'])} · ${w('Call Take-Profit Close', 'Call 平仓止盈')}$strikeSuffix',
                'call_sl' =>
                  '${text(ev['ticker'])} · ${w('Call Stop-Loss Close', 'Call 平仓止损')}$strikeSuffix',
                'call_expired_loss' =>
                  '${text(ev['ticker'])} · ${w('Long Call Expired Loss', '买 Call 到期作废')}$strikeSuffix',
                'put_expired' =>
                  '${text(ev['ticker'])} · ${w('Expired Short Put', '卖 Put 虚值到期归零')}$strikeSuffix',
                'put_tp' =>
                  '${text(ev['ticker'])} · ${w('Put Take-Profit Close', 'Put 平仓止盈')}$strikeSuffix',
                'put_sl' =>
                  '${text(ev['ticker'])} · ${w('Put Stop-Loss Close', 'Put 平仓止损')}$strikeSuffix',
                'put_expired_loss' =>
                  '${text(ev['ticker'])} · ${w('Long Put Expired Loss', '买 Put 到期作废')}$strikeSuffix',
                _ => '${text(ev['ticker'])} · ${text(ev['label'])}',
              };
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: .15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        badgeText,
                        style: TextStyle(
                          color: badgeColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 78,
                      child: Text(
                        text(ev['date']),
                        style: TextStyle(color: p.muted, fontSize: 11.5),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        detailLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.text, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.hideAmounts
                          ? '••••'
                          : fmtMoney(amt, signed: true),
                      style: TextStyle(
                        color: badgeColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    ),
  );
}

class _PassiveIncomeBarPainter extends CustomPainter {
  _PassiveIncomeBarPainter({
    required this.months,
    required this.maxPos,
    required this.minNeg,
    required this.palette,
    required this.callColor,
    required this.putColor,
    required this.divColor,
    required this.lossColor,
    required this.activeIndex,
    required this.hideAmounts,
    required this.isYearScope,
  });

  final List<Map<String, dynamic>> months;
  final double maxPos;
  final double minNeg;
  final Palette palette;
  final Color callColor;
  final Color putColor;
  final Color divColor;
  final Color lossColor;
  final int? activeIndex;
  final bool hideAmounts;
  final bool isYearScope;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 48.0;
    const bottomPad = 24.0;
    const topPad = 8.0;
    final rect = Rect.fromLTRB(
      leftPad,
      topPad,
      size.width - 8,
      size.height - bottomPad,
    );
    if (rect.width <= 0 || rect.height <= 0 || months.isEmpty) return;

    final hasNeg = minNeg < -0.005;
    final topVal = maxPos > 0 ? maxPos * 1.14 : (hasNeg ? 0.0 : 100.0);
    final botVal = hasNeg ? minNeg * 1.14 : 0.0;
    final span = math.max(1e-6, topVal - botVal);
    double yOf(double v) => rect.bottom - ((v - botVal) / span) * rect.height;
    final zeroY = yOf(0.0);

    for (var g = 0; g <= 3; g++) {
      final frac = g / 3;
      final val = botVal + span * frac;
      final y = rect.bottom - frac * rect.height;
      canvas.drawLine(
        Offset(rect.left, y),
        Offset(rect.right, y),
        Paint()
          ..color = palette.border.withValues(alpha: .55)
          ..strokeWidth = 1,
      );
      final absVal = val.abs();
      final sign = val < -0.5 ? '-' : '';
      final labelText = hideAmounts
          ? (maxPos > 0 ? '${(frac * 100).round()}%' : '—')
          : absVal >= 1000
          ? '$sign${(absVal / 1000).toStringAsFixed(1)}K'
          : '$sign${absVal.toStringAsFixed(0)}';
      final tp = TextPainter(
        text: TextSpan(
          text: labelText,
          style: TextStyle(color: palette.muted, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: leftPad - 6);
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }

    if (hasNeg) {
      canvas.drawLine(
        Offset(rect.left, zeroY),
        Offset(rect.right, zeroY),
        Paint()
          ..color = palette.muted.withValues(alpha: .65)
          ..strokeWidth = 1.1,
      );
    }

    final slotW = rect.width / months.length;
    final barW = (slotW * 0.58).clamp(6.0, 26.0);
    final labelStep = months.length > 12 ? 2 : 1;

    for (var i = 0; i < months.length; i++) {
      final m = months[i];
      final covered = m['covered'] != false;
      final hasSplit = m.containsKey('callPnl') || m.containsKey('putPnl');
      final calls = hasSplit ? number(m['callPnl']) : number(m['expiredCalls']);
      final puts = hasSplit ? number(m['putPnl']) : 0.0;
      final divs = number(m['dividends']);
      final cx = rect.left + (i + 0.5) * slotW;
      final isFocused = activeIndex == null || activeIndex == i;

      if (activeIndex == i) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - slotW * 0.46,
              rect.top,
              cx + slotW * 0.46,
              rect.bottom,
            ),
            const Radius.circular(6),
          ),
          Paint()..color = palette.text.withValues(alpha: .06),
        );
      }

      if (!covered) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(cx, zeroY - 1.5),
              width: barW * 0.7,
              height: 2,
            ),
            const Radius.circular(1),
          ),
          Paint()..color = palette.border.withValues(alpha: .45),
        );
      } else {
        final barAlpha = activeIndex == null
            ? 0.82
            : (isFocused ? 0.95 : 0.36);

        // Positive stacked segments (upward from zeroY): Dividends -> Put -> Call
        final posSegs = <(double, Color)>[
          if (divs > 0.005) (divs, divColor),
          if (puts > 0.005) (puts, putColor),
          if (calls > 0.005) (calls, callColor),
        ];
        var posCursor = zeroY;
        for (var s = 0; s < posSegs.length; s++) {
          final hPx = (posSegs[s].$1 / span) * rect.height;
          if (hPx <= 0.2) continue;
          final gap = posSegs.length > 1 && s > 0 ? 1.5 : 0.0;
          final segH = math.max(1.5, hPx - gap);
          final segTop = posCursor - gap - segH;
          final isTop = s == posSegs.length - 1;
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              Rect.fromLTWH(cx - barW / 2, segTop, barW, segH),
              topLeft: isTop
                  ? const Radius.circular(3.5)
                  : const Radius.circular(1.5),
              topRight: isTop
                  ? const Radius.circular(3.5)
                  : const Radius.circular(1.5),
              bottomLeft: s == 0 ? Radius.zero : const Radius.circular(1.5),
              bottomRight: s == 0 ? Radius.zero : const Radius.circular(1.5),
            ),
            Paint()..color = posSegs[s].$2.withValues(alpha: barAlpha),
          );
          posCursor = segTop;
        }

        // Negative stacked segments (downward from zeroY): Call/Put realized losses
        final negAmt = (calls < -0.005 ? -calls : 0.0) +
            (puts < -0.005 ? -puts : 0.0) +
            (divs < -0.005 ? -divs : 0.0);
        if (negAmt > 0.005) {
          final negH = math.max(2.0, (negAmt / span) * rect.height);
          canvas.drawRRect(
            RRect.fromRectAndCorners(
              Rect.fromLTWH(cx - barW / 2, zeroY, barW, negH),
              bottomLeft: const Radius.circular(3.5),
              bottomRight: const Radius.circular(3.5),
            ),
            Paint()..color = lossColor.withValues(alpha: barAlpha),
          );
        }
      }

      // Draw prior-year same-month reference tick when viewing a specific year
      if (isYearScope &&
          m['priorYearCovered'] == true &&
          number(m['priorYearTotal']).abs() > 0.005) {
        final py = yOf(number(m['priorYearTotal']));
        canvas.drawLine(
          Offset(cx - barW * 0.58, py),
          Offset(cx + barW * 0.58, py),
          Paint()
            ..color = palette.text.withValues(alpha: isFocused ? 0.72 : 0.35)
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      }

      if (i % labelStep == 0 || i == months.length - 1) {
        final rawM = text(m['month']);
        final shortM = isYearScope && rawM.length >= 7
            ? rawM.substring(5)
            : (rawM.length >= 7 ? rawM.substring(2) : rawM);
        final mtp = TextPainter(
          text: TextSpan(
            text: shortM,
            style: TextStyle(
              color: activeIndex == i
                  ? palette.text
                  : (covered ? palette.muted : palette.faint),
              fontSize: 9.5,
              fontWeight: activeIndex == i
                  ? FontWeight.w600
                  : FontWeight.normal,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        mtp.paint(canvas, Offset(cx - mtp.width / 2, rect.bottom + 6));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PassiveIncomeBarPainter old) =>
      old.months != months ||
      old.maxPos != maxPos ||
      old.minNeg != minNeg ||
      old.palette != palette ||
      old.callColor != callColor ||
      old.putColor != putColor ||
      old.divColor != divColor ||
      old.lossColor != lossColor ||
      old.activeIndex != activeIndex ||
      old.hideAmounts != hideAmounts ||
      old.isYearScope != isYearScope;
}
