part of 'main.dart';

// Route fallback is exact, never a substitute company. An explicit research
// ticker wins over the candidate retained by the discovery workspace.
String researchEntryTicker(String page, String explicit, String? candidate) =>
    (explicit.trim().isNotEmpty
            ? explicit
            : page == 'research'
            ? candidate ?? ''
            : '')
        .trim()
        .toUpperCase();

String researchReportKey(Map<String, dynamic> row) =>
    '${text(row['period'])}|${text(row['availableAt'])}';

List<Map<String, dynamic>> researchDatedRows(
  List<Map<String, dynamic>> rows,
  String dateKey,
  String asOf, {
  String from = '',
}) => rows.where((r) {
  final date = text(r[dateKey]);
  return DateTime.tryParse(date) != null &&
      date.compareTo(asOf) <= 0 &&
      (from.isEmpty || date.compareTo(from) >= 0);
}).toList()..sort((a, b) => text(a[dateKey]).compareTo(text(b[dateKey])));

// A displayed model change requires a common methodology and version. It is a
// change between model nodes, not an attribution of causality to one input.
double? researchValueChange(
  Map<String, dynamic> now,
  Map<String, dynamic>? prior,
) {
  if (prior == null ||
      text(now['publishedFormula']).isEmpty ||
      now['publishedFormula'] != prior['publishedFormula'] ||
      text(asMap(now['source'])['modelVersion']).isEmpty ||
      asMap(now['source'])['modelVersion'] !=
          asMap(prior['source'])['modelVersion']) {
    return null;
  }
  final a = nullableNumber(now['publishedFairValue']);
  final b = nullableNumber(prior['publishedFairValue']);
  return a != null && b != null && b > 0 ? a / b - 1 : null;
}

class _ResearchValueBar {
  const _ResearchValueBar({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final double value;
  final Color color;
}

class _ResearchValueComparison extends StatelessWidget {
  const _ResearchValueComparison({
    required this.items,
    required this.currency,
    required this.muted,
    required this.border,
  });
  final List<_ResearchValueBar> items;
  final String currency;
  final Color muted, border;

  @override
  Widget build(BuildContext context) {
    final maxValue = items.fold<double>(
      0,
      (largest, item) => math.max(largest, item.value.abs()),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: muted, fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${currencySymbol(currency)}${item.value.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: item.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                LayoutBuilder(
                  builder: (_, bounds) => Stack(
                    children: [
                      Container(
                        height: 8,
                        decoration: BoxDecoration(
                          color: border.withValues(alpha: .7),
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        height: 8,
                        width: maxValue <= 0
                            ? 0
                            : bounds.maxWidth * item.value.abs() / maxValue,
                        decoration: BoxDecoration(
                          color: item.color,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ResearchFinancialSeries {
  const _ResearchFinancialSeries({
    required this.keyName,
    required this.label,
    required this.color,
    required this.values,
  });
  final String keyName, label;
  final Color color;
  final List<double?> values;
}

class _ResearchFinancialBarChart extends StatefulWidget {
  const _ResearchFinancialBarChart({
    required this.periods,
    required this.series,
    required this.muted,
    required this.textColor,
    required this.grid,
  });
  final List<String> periods;
  final List<_ResearchFinancialSeries> series;
  final Color muted, textColor, grid;

  @override
  State<_ResearchFinancialBarChart> createState() =>
      _ResearchFinancialBarChartState();
}

class _ResearchFinancialBarChartState
    extends State<_ResearchFinancialBarChart> {
  int? hovered;

  void updateHover(Offset position, double width) {
    const left = 62.0, right = 10.0;
    final plot = math.max(1, width - left - right);
    final raw = ((position.dx - left) / plot * widget.periods.length).floor();
    final next = raw >= 0 && raw < widget.periods.length ? raw : null;
    if (next != hovered) setState(() => hovered = next);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.series.isEmpty || widget.periods.isEmpty) {
      return Center(
        child: Text(
          'Select a reported line item',
          style: TextStyle(color: widget.muted, fontSize: 12),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              for (final series in widget.series)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: series.color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      series.label,
                      style: TextStyle(color: widget.muted, fontSize: 10),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (_, bounds) => MouseRegion(
              onHover: (event) =>
                  updateHover(event.localPosition, bounds.maxWidth),
              onExit: (_) => setState(() => hovered = null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (event) =>
                    updateHover(event.localPosition, bounds.maxWidth),
                child: Stack(
                  children: [
                    CustomPaint(
                      size: Size.infinite,
                      painter: _ResearchFinancialBarPainter(
                        periods: widget.periods,
                        series: widget.series,
                        muted: widget.muted,
                        grid: widget.grid,
                        hovered: hovered,
                      ),
                    ),
                    if (hovered case final index?)
                      Positioned(
                        top: 4,
                        left: math.min(
                          math.max(
                            66,
                            62 +
                                (bounds.maxWidth - 72) *
                                    (index + .5) /
                                    widget.periods.length -
                                70,
                          ),
                          math.max(66, bounds.maxWidth - 154),
                        ),
                        child: IgnorePointer(
                          child: Container(
                            width: 140,
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              color: const Color(0xff0d1b23),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: widget.grid),
                              boxShadow: const [
                                BoxShadow(color: Colors.black38, blurRadius: 8),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.periods[index],
                                  style: TextStyle(
                                    color: widget.textColor,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                for (final series in widget.series)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 3),
                                    child: Text(
                                      '${series.label}: ${series.values[index] == null ? '—' : formatNumber(series.values[index]!)}',
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: series.color,
                                        fontSize: 9,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ResearchFinancialBarPainter extends CustomPainter {
  _ResearchFinancialBarPainter({
    required this.periods,
    required this.series,
    required this.muted,
    required this.grid,
    required this.hovered,
  });
  final List<String> periods;
  final List<_ResearchFinancialSeries> series;
  final Color muted, grid;
  final int? hovered;

  String axis(double value) {
    final magnitude = value.abs();
    if (magnitude >= 1e12) return '${(value / 1e12).toStringAsFixed(1)}T';
    if (magnitude >= 1e9) return '${(value / 1e9).toStringAsFixed(1)}B';
    if (magnitude >= 1e6) return '${(value / 1e6).toStringAsFixed(0)}M';
    if (magnitude >= 1e3) return '${(value / 1e3).toStringAsFixed(0)}K';
    return value.toStringAsFixed(magnitude < 10 ? 1 : 0);
  }

  void drawText(Canvas canvas, String value, Offset offset, {double size = 9}) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(color: muted, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 62.0, right = 10.0, top = 12.0, bottom = 34.0;
    final width = math.max(1.0, size.width - left - right);
    final height = math.max(1.0, size.height - top - bottom);
    final finiteValues = <double>[
      for (final item in series)
        for (final value in item.values)
          if (value != null && value.isFinite) value,
    ];
    if (finiteValues.isEmpty) return;
    var low = math.min(0.0, finiteValues.reduce(math.min));
    var high = math.max(0.0, finiteValues.reduce(math.max));
    if ((high - low).abs() < 1e-9) high = low + 1;
    final range = high - low;
    double y(double value) => top + (high - value) / range * height;
    final zero = y(0);
    final gridPaint = Paint()..color = grid.withValues(alpha: .75);
    final groupWidth = width / periods.length;
    if (hovered case final index?) {
      canvas.drawRect(
        Rect.fromLTWH(left + index * groupWidth, top, groupWidth, height),
        Paint()..color = grid.withValues(alpha: .16),
      );
    }
    for (var tick = 0; tick <= 4; tick++) {
      final value = low + range * tick / 4;
      final dy = y(value);
      canvas.drawLine(
        Offset(left, dy),
        Offset(size.width - right, dy),
        gridPaint,
      );
      final label = axis(value);
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(color: muted, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: left - 8);
      painter.paint(
        canvas,
        Offset(left - 8 - painter.width, dy - painter.height / 2),
      );
    }
    canvas.drawLine(
      Offset(left, zero),
      Offset(size.width - right, zero),
      Paint()..color = muted.withValues(alpha: .55),
    );
    final clusterWidth = groupWidth * .68;
    final barWidth = math.max(3.0, clusterWidth / math.max(1, series.length));
    for (var period = 0; period < periods.length; period++) {
      final start =
          left + period * groupWidth + (groupWidth - clusterWidth) / 2;
      for (var item = 0; item < series.length; item++) {
        final value = period < series[item].values.length
            ? series[item].values[period]
            : null;
        if (value == null || !value.isFinite) continue;
        final valueY = y(value);
        final rect = Rect.fromLTRB(
          start + item * barWidth + 1,
          math.min(zero, valueY),
          start + (item + 1) * barWidth - 1,
          math.max(zero, valueY),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(2)),
          Paint()..color = series[item].color.withValues(alpha: .92),
        );
      }
      final labelPainter = TextPainter(
        text: TextSpan(
          text: periods[period],
          style: TextStyle(color: muted, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: groupWidth);
      labelPainter.paint(
        canvas,
        Offset(
          left + period * groupWidth + (groupWidth - labelPainter.width) / 2,
          size.height - bottom + 10,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ResearchFinancialBarPainter oldDelegate) =>
      oldDelegate.periods != periods ||
      oldDelegate.series != series ||
      oldDelegate.hovered != hovered ||
      oldDelegate.grid != grid ||
      oldDelegate.muted != muted;
}

extension _InvestmentResearch on _InvestmentWorkspaceState {
  List<Map<String, dynamic>> get researchHistory =>
      researchDatedRows(asList(company?['history']), 'availableAt', asOf);

  bool get researchHasPlatformModel {
    final coverage = asMap(company?['coverage'])['platformModel'];
    if (coverage == 'available') return true;
    if (coverage != null) return false;
    // Older stored/test payloads predate explicit coverage. Preserve their
    // real model path only when model evidence is actually present.
    return assumptions.isNotEmpty ||
        nullableNumber(asMap(company?['published'])['fairValue']) != null ||
        asList(asMap(company?['publishedBreakdown'])['components']).isNotEmpty;
  }

  bool get researchNeedsFullFinancials {
    final facts = researchFundamental;
    if (facts == null) return true;
    return asList(facts['annual']).isEmpty ||
        asMap(facts['transportCoverage'])['fullFacts'] == 'on_demand';
  }

  List<Widget> refinedResearch() {
    if (company == null) return researchEntry();
    final desktop = MediaQuery.sizeOf(context).width >= 1100;
    final pad = desktop ? 28.0 : 18.0;
    final snap = asMap(company?['snapshot']);
    return [
      Padding(
        padding: EdgeInsets.fromLTRB(pad, 16, pad, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            sourceBreadcrumb(),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                homeStockLogo(ticker, 46),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(ticker, style: deskHeading(28)),
                          label(
                            text(company?['name']),
                            text(company?['name']),
                            size: 16,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      label(
                        '${snap['period']} · Filed ${snap['availableAt']} · ${text(company?['currency'])}',
                        '${snap['period']} · 披露 ${snap['availableAt']} · ${text(company?['currency'])}',
                        size: 12,
                      ),
                    ],
                  ),
                ),
                if (desktop) ...[const SizedBox(width: 14), dateControl()],
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (!desktop) dateControl(),
                OutlinedButton.icon(
                  onPressed: () => changeResearchCompany(),
                  icon: const Icon(Icons.search, size: 16),
                  label: Text(w('Switch company', '切换公司')),
                ),
                researchWatchButton(),
                researchTag(
                  asMap(company?['coverage'])['platformModel'] != 'available'
                      ? w('Fact OS · no platform model', 'Fact OS · 暂无平台模型')
                      : assumptions.isEmpty
                      ? w('Published model · read-only', '平台模型 · 只读')
                      : w('Scenario modelling available', '支持情景建模'),
                  p.muted,
                ),
              ],
            ),
          ],
        ),
      ),
      Container(
        key: const ValueKey('research-primary-nav'),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.border)),
        ),
        padding: EdgeInsets.symmetric(horizontal: pad),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tabs = [
              ('evidence', 'Research overview', '研究总览'),
              ('financials', 'Announcements & financials', '公告与财务'),
              ('institutions', 'Institutional holdings', '机构持仓'),
              ('value', 'Valuation workspace', '估值工作台'),
              ('records', 'Research records', '研究记录'),
            ];
            final buttons = [
              for (final tab in tabs)
                Semantics(
                  selected: section == tab.$1,
                  child: TextButton(
                    key: ValueKey('research-tab-${tab.$1}'),
                    style: TextButton.styleFrom(
                      foregroundColor: section == tab.$1 ? p.accent : p.muted,
                      shape: const RoundedRectangleBorder(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 16,
                      ),
                    ),
                    onPressed: () => selectResearchSection(tab.$1),
                    child: Text(
                      w(tab.$2, tab.$3),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: section == tab.$1
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
            ];
            return Wrap(spacing: 2, runSpacing: 0, children: buttons);
          },
        ),
      ),
      Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (section == 'evidence') ...researchOverview(),
            if (section == 'financials') ...[
              researchDocumentsPanel(),
              const SizedBox(height: 18),
              EarningsResearchPanel(
                api: widget.api,
                ticker: ticker,
                asOf: asOf,
                palette: p,
                history: researchHistory,
                onOpenValuation: () => selectSection('value'),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 14),
                child: label(
                  'Latest company evidence · ${snap['period']} · The quarter selector above applies only to earnings research.',
                  '最新公司证据 · ${snap['period']} · 上方季度选择只作用于财报会研究。',
                  size: 12,
                ),
              ),
              ...evidenceView(includeHistory: false),
            ],
            if (section == 'institutions') researchInstitutionPanel(),
            if (section == 'value') ...researchValuationWorkspace(),
            if (section == 'records') researchRecordsPanel(),
            const SizedBox(height: 14),
            label(
              'Research only · Model estimates are not expected returns · No orders are placed.',
              '仅供研究 · 模型估计不等于预期收益 · 不执行交易',
              size: 11,
            ),
          ],
        ),
      ),
    ];
  }

  List<Widget> researchEntry() => [
    title('Research a company', '研究一家公司'),
    label(
      'Start with a question. Follow the evidence. Put a value on your assumptions.',
      '带着问题出发，核实证据，为你的假设定价。',
    ),
    const SizedBox(height: 24),
    card([
      if (busy) const LinearProgressIndicator(),
      if (ticker.isNotEmpty && !busy && error != null) ...[
        label(
          'Research could not be loaded for $ticker. Your selection is unchanged.',
          '$ticker 研究加载失败，所选股票未改变。',
          color: p.secondary,
        ),
        const SizedBox(height: 12),
      ],
      searchBox(),
      const SizedBox(height: 18),
      label(
        'Use a ticker, or choose a company from Discover to keep its Guru and filing context.',
        '输入股票代码，或从发现页选择公司，保留经理与披露背景。',
      ),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: button(
          'Explore research candidates',
          '浏览研究候选',
          () => requestNavigate('discover'),
          icon: Icons.explore_outlined,
        ),
      ),
    ]),
    if (asList(home?['decisions']).isNotEmpty)
      card([
        title('Continue your research', '继续你的研究'),
        for (final d in asList(home?['decisions']).take(5))
          ListTile(
            leading: homeStockLogo(text(d['ticker']), 30),
            title: Text(text(d['ticker'])),
            subtitle: Text('${d['asOf']} · ${actionLabel(text(d['action']))}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => loadCompany(text(d['ticker'])),
          ),
      ]),
  ];

  Future<void> changeResearchCompany() async {
    final selected = await showDialog<String>(
      context: context,
      barrierLabel: w('Close search', '关闭搜索'),
      barrierColor: Colors.black.withValues(alpha: .55),
      builder: (ctx) => CompanySearchDialog(
        api: widget.api,
        palette: p,
        asOf: asOf,
        currentTicker: ticker,
        recentTickers: researchRecentTickers,
      ),
    );
    if (selected != null && selected != ticker && mounted) {
      await loadCompany(selected);
    }
  }

  void selectResearchSection(String next) {
    selectSection(next);
    if (next == 'evidence' && researchNeedsFullFinancials) {
      unawaited(loadResearchOverviewFinancials());
    } else if (next == 'financials' &&
        (researchDocumentsData == null || researchFundamental == null)) {
      unawaited(loadResearchPanel('financials'));
    } else if (next == 'institutions' && researchInstitution == null) {
      unawaited(loadResearchPanel('institutions'));
    } else if (next == 'records' && researchRecordsData == null) {
      unawaited(loadResearchPanel('records'));
    }
  }

  Future<void> loadResearchOverviewFinancials() async {
    if (researchFinancialsLoading || ticker.isEmpty) return;
    final symbol = ticker, cutoff = asOf, serial = requestSerial;
    updateUI(() {
      researchFinancialsLoading = true;
      researchFinancialsError = null;
    });
    try {
      final value = await widget.api.getJson(
        '/api/investment/research/${Uri.encodeComponent(symbol)}/fundamentals?asOf=$cutoff',
      );
      if (!mounted || serial != requestSerial || ticker != symbol) return;
      updateUI(() => researchFundamental = value);
    } catch (e) {
      if (mounted && serial == requestSerial && ticker == symbol) {
        updateUI(() => researchFinancialsError = e.toString());
      }
    } finally {
      if (mounted && serial == requestSerial && ticker == symbol) {
        updateUI(() => researchFinancialsLoading = false);
      }
    }
  }

  Future<void> loadResearchPanel(String panel) async {
    if (researchPanelLoading || ticker.isEmpty) return;
    final symbol = ticker, cutoff = asOf, serial = requestSerial;
    updateUI(() {
      researchPanelLoading = true;
      researchPanelError = null;
    });
    try {
      if (panel == 'financials') {
        final values = await Future.wait([
          widget.api.getJson(
            '/api/investment/research/${Uri.encodeComponent(symbol)}/documents?asOf=$cutoff',
          ),
          if (researchNeedsFullFinancials)
            widget.api.getJson(
              '/api/investment/research/${Uri.encodeComponent(symbol)}/fundamentals?asOf=$cutoff',
            )
          else
            Future.value(researchFundamental!),
        ]);
        if (!mounted || serial != requestSerial) return;
        updateUI(() {
          researchDocumentsData = values[0];
          researchFundamental = values[1];
        });
      } else if (panel == 'institutions') {
        final value = await widget.api.getJson(
          '/api/investment/research/${Uri.encodeComponent(symbol)}/institutions?asOf=$cutoff',
        );
        if (!mounted || serial != requestSerial) return;
        updateUI(() => researchInstitution = value);
      } else if (panel == 'records') {
        final value = await widget.api.getJson(
          '/api/investment/research/${Uri.encodeComponent(symbol)}/records?asOf=$cutoff',
        );
        if (!mounted || serial != requestSerial) return;
        updateUI(() => researchRecordsData = value);
      }
    } catch (e) {
      if (mounted && serial == requestSerial) {
        updateUI(() => researchPanelError = e.toString());
      }
    } finally {
      if (mounted && serial == requestSerial) {
        updateUI(() => researchPanelLoading = false);
      }
    }
  }

  Widget researchPanelState() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (researchPanelLoading) const LinearProgressIndicator(),
      if (researchPanelError != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: label(
            'This research layer could not be loaded. Existing evidence remains visible.',
            '这一研究层暂时无法载入，已有证据仍然保留显示。',
            color: p.secondary,
          ),
        ),
    ],
  );

  Future<void> loadHistoricalPublishedModel(String modelAsOf) async {
    final selectedTicker = ticker;
    try {
      final payload = await widget.api.getJson(
        '/api/investment/research/${Uri.encodeComponent(selectedTicker)}/published-model?asOf=${Uri.encodeQueryComponent(modelAsOf)}',
      );
      if (!mounted || ticker != selectedTicker || researchReport.isEmpty) {
        return;
      }
      final breakdown = asMap(payload['breakdown']);
      updateUI(() {
        company = {...?company, 'publishedBreakdown': breakdown};
      });
    } catch (e) {
      if (mounted && ticker == selectedTicker) {
        updateUI(() => researchPanelError = e.toString());
      }
    }
  }

  Widget researchEvidenceSidebar() {
    final dates = asMap(company?['researchDates']);
    final coverage = asMap(company?['coverage']);
    return card([
      label('EVIDENCE CONTEXT', '证据上下文', size: 10, color: p.accent),
      const SizedBox(height: 10),
      for (final item in [
        ('Research cutoff', '研究截止日', dates['cutoff'] ?? asOf),
        ('Financial period', '财报所属期', dates['financialPeriod']),
        ('Disclosure date', '披露日期', dates['disclosureDate']),
        ('Price date', '价格日期', dates['priceDate']),
        ('Model date', '模型日期', dates['modelDate']),
      ])
        Padding(
          padding: const EdgeInsets.only(bottom: 9),
          child: Row(
            children: [
              Expanded(child: label(item.$1, item.$2, size: 11)),
              Text(
                text(item.$3, '—'),
                style: TextStyle(color: p.text, fontSize: 11),
              ),
            ],
          ),
        ),
      Divider(color: p.border),
      label(
        coverage['platformModel'] == 'available'
            ? 'Platform model available; personal scenarios remain separate.'
            : 'No platform model. Facts, filings, holdings and notes remain researchable.',
        coverage['platformModel'] == 'available'
            ? '平台模型可用；个人情景始终单独保存。'
            : '暂无平台模型；仍可研究事实、公告、持仓并保存记录。',
        size: 11,
      ),
    ]);
  }

  Widget researchDocumentsPanel() {
    final documents = asList(researchDocumentsData?['rows']);
    final fundamental = researchFundamental;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        researchPanelState(),
        pageColumns(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title('Announcements & reported facts', '公告与已报告事实'),
              label(
                'A filing clue, a verified source link and readable source text are three different coverage states.',
                '公告分类线索、已验证原文链接、可读取正文是三种不同覆盖状态。',
              ),
              const SizedBox(height: 16),
              if (documents.isEmpty && !researchPanelLoading)
                card([
                  label(
                    'No announcement catalog is available at this cutoff.',
                    '该截止日暂无公告目录。',
                  ),
                ]),
              for (final document in documents.take(12))
                card([
                  Row(
                    children: [
                      researchTag(text(document['form'], '—'), p.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          text(document['title']),
                          style: deskHeading(15),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  label(
                    'Period ${text(document['reportPeriod'], '—')} · Published ${text(document['publishedAt'], '—')} · ${text(document['contentStatus'])}',
                    '所属期 ${text(document['reportPeriod'], '—')} · 披露 ${text(document['publishedAt'], '—')} · ${text(document['contentStatus'])}',
                    size: 11,
                  ),
                  const SizedBox(height: 6),
                  label(
                    'No stored body: no source-text summary is generated.',
                    '未存正文：不生成基于原文的摘要。',
                    size: 11,
                    color: p.secondary,
                  ),
                  if (Uri.tryParse(text(document['sourceUrl']))?.scheme ==
                      'https')
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () =>
                            openBrowserPath(text(document['sourceUrl'])),
                        icon: const Icon(Icons.open_in_new, size: 14),
                        label: Text(w('Open verified source', '打开已验证来源')),
                      ),
                    ),
                ]),
              if (fundamental != null) ...[
                const SizedBox(height: 18),
                title('Financial evidence by research question', '按研究问题组织财务证据'),
                for (final section in asList(fundamental['sections']))
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      text(
                        asMap(
                          section['title'],
                        )[context.language == AppLanguage.zh ? 'zh' : 'en'],
                      ),
                      style: deskHeading(15),
                    ),
                    children: [
                      for (final row in asList(section['rows']))
                        ListTile(
                          dense: true,
                          title: Text(
                            text(
                              asMap(row['label'])[context.language ==
                                      AppLanguage.zh
                                  ? 'zh'
                                  : 'en'],
                            ),
                          ),
                          subtitle: Text(
                            '${text(row['formula'])} · ${text(row['status'])}',
                          ),
                          trailing: Text(
                            nullableNumber(row['value']) == null
                                ? '—'
                                : formatNumber(number(row['value'])),
                          ),
                        ),
                    ],
                  ),
              ],
            ],
          ),
          researchEvidenceSidebar(),
          sideWidth: 330,
        ),
      ],
    );
  }

  Widget researchInstitutionPanel() {
    final data = researchInstitution;
    final details = asMap(data?['details']);
    final history = asList(details['history']);
    final analysis = asMap(details['analysis']);
    final evidence = asMap(analysis['evidence']);
    final breadth = asMap(evidence['breadth']);
    final shares = asMap(evidence['shares']);
    final weights = asMap(evidence['weights']);
    final importantChanges = asList(analysis['importantChanges']);
    final institutions = <Map<String, dynamic>>[
      for (final action in ['new', 'increased', 'reduced', 'exited'])
        for (final row in asList(details[action])) {...row, 'action': action},
    ];
    final historyLimit = researchRange == 'All'
        ? history.length
        : researchRange == '10Y'
        ? 40
        : 20;
    final visibleHistory = history.length > historyLimit
        ? history.sublist(history.length - historyLimit)
        : history;
    final visibleDetails = {...details, 'history': visibleHistory};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        researchPanelState(),
        title('Institutional ownership evidence', '机构持仓证据'),
        label(
          'Reported shares are split-normalized where verified. 13F is delayed disclosure, not live trading or actual fund flow.',
          '股数在可验证时按拆股统一口径。13F 是滞后披露，不是实时交易或真实资金流。',
        ),
        const SizedBox(height: 16),
        pageColumns(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (data == null && !researchPanelLoading)
                card([
                  label(
                    'No covered 13F security record is available at this cutoff.',
                    '该截止日暂无覆盖的 13F 个股记录。',
                  ),
                ]),
              if (data != null)
                card([
                  Wrap(
                    spacing: 18,
                    runSpacing: 12,
                    children: [
                      researchTag(
                        '${asMap(data['row'])['holders'] ?? '—'} ${w('holders', '家机构')}',
                        p.accent,
                      ),
                      researchTag(
                        '${text(data['reportDate'])} ${w('holdings period', '持仓所属期')}',
                        p.muted,
                      ),
                      researchTag(
                        '${text(data['availableAt'])} ${w('proxy availability', '代理可见日')}',
                        p.secondary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  label(
                    'The SF3 quarter-end + 45 day availability field is a proxy when an actual filing timestamp is unavailable.',
                    '缺少真实申报时间时，SF3 季末 +45 天仅作为可见日期代理。',
                    size: 11,
                  ),
                ]),
              if (analysis.isNotEmpty)
                card([
                  label(
                    'EVIDENCE-BASED READ',
                    '基于证据的本季判断',
                    size: 9,
                    color: p.accent,
                  ),
                  const SizedBox(height: 7),
                  Text(
                    _insightBehaviorHeadline(text(analysis['headlineKey'])),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 7),
                  label(
                    '${reportQuarterLabel(text(data?['reportDate']))} vs ${reportQuarterLabel(text(data?['previousReportDate']))} · ${w('13F filings are delayed snapshots, not live trades.', '13F 是延迟披露的持仓快照，不是实时交易。')}',
                    '${reportQuarterLabel(text(data?['reportDate']))} 对比 ${reportQuarterLabel(text(data?['previousReportDate']))} · 13F 是延迟披露的持仓快照，不是实时交易。',
                    size: 10,
                  ),
                  if (breadth.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _insightEvidenceDisclosure(
                      key: const ValueKey('research-13f-evidence-breadth'),
                      icon: Icons.groups_2_outlined,
                      title: w('Breadth of the move', '增减广度'),
                      summary:
                          '${_integer(breadth['adds'])} ${w('adding', '增加方向')} · ${_integer(breadth['trims'])} ${w('reducing', '减少方向')}',
                      details: [
                        label(
                          '${w('Net breadth', '净广度')} ${_integer(breadth['netFilers'])} · ${w('Adding share of changed filers', '增加方向占发生变化机构')} ${pct(breadth['addsPct'])}',
                          '${w('Net breadth', '净广度')} ${_integer(breadth['netFilers'])} · ${w('Adding share of changed filers', '增加方向占发生变化机构')} ${pct(breadth['addsPct'])}',
                          size: 11,
                        ),
                      ],
                    ),
                  ],
                  if (shares.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    _insightEvidenceDisclosure(
                      key: const ValueKey('research-13f-evidence-shares'),
                      icon: Icons.stacked_line_chart,
                      title: w('Net reported share change', '股数净变化'),
                      summary:
                          '${_sharesFromThousands(shares['netUnitsChangeK'])} · ${nullableNumber(shares['netChangePctPrior']) == null ? '—' : '${number(shares['netChangePctPrior']).toStringAsFixed(2)}%'} ${w('of prior reported shares', '占上季申报股数')}',
                      details: [
                        label(
                          '${w('As % of shares outstanding', '占总股本变化')} ${nullableNumber(shares['netChangePctOutstanding']) == null ? '—' : '${number(shares['netChangePctOutstanding']).toStringAsFixed(2)}%'} · ${w('split-adjusted basis', '拆股折算口径')} ${text(shares['shareBasisDate'], '—')}',
                          '${w('As % of shares outstanding', '占总股本变化')} ${nullableNumber(shares['netChangePctOutstanding']) == null ? '—' : '${number(shares['netChangePctOutstanding']).toStringAsFixed(2)}%'} · ${w('split-adjusted basis', '拆股折算口径')} ${text(shares['shareBasisDate'], '—')}',
                          size: 11,
                        ),
                      ],
                    ),
                  ],
                  if (weights.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    _insightEvidenceDisclosure(
                      key: const ValueKey('research-13f-evidence-weight'),
                      icon: Icons.balance_outlined,
                      title: w('Portfolio-weight evidence', '重要机构组合权重'),
                      summary:
                          '${_integer(weights['importantChangesEvaluated'])} ${w('important changes reviewed', '项重要变动')} · ${_integer(weights['sharesUpWeightDown'])} ${w('shares-up / weight-down divergences', '项股数增加但权重下降')}',
                      details: [
                        label(
                          'Weight is measured inside each filer’s reported common-stock portfolio; it is not total fund AUM.',
                          '权重分母是各机构申报的普通股组合，不代表其完整基金 AUM。',
                          size: 11,
                        ),
                      ],
                    ),
                  ],
                ]),
              if (history.isNotEmpty)
                card([
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          w('All-institution history', '全机构历史'),
                          style: deskHeading(17),
                        ),
                      ),
                      for (final range in ['5Y', '10Y', 'All'])
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: ChoiceChip(
                            label: Text(
                              range == 'All' ? w('All', '全部') : range,
                            ),
                            selected: researchRange == range,
                            onSelected: (_) =>
                                updateUI(() => researchRange = range),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _insightHistoryCharts(visibleDetails),
                ]),
              if (importantChanges.isNotEmpty)
                card([
                  Row(
                    key: const ValueKey(
                      'research-13f-changes-worth-researching',
                    ),
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              w('Changes worth researching', '值得研究的变动'),
                              style: deskHeading(17),
                            ),
                            const SizedBox(height: 3),
                            label(
                              'Adds and reductions are shown together. Selected from the complete comparable population by absolute reported value change.',
                              '同时展示重要增持与减持；先在完整可比机构中计算，再按申报市值绝对变化选取。',
                              size: 10,
                            ),
                          ],
                        ),
                      ),
                      label(
                        '${importantChanges.length} ${w('changes', '项')}',
                        '${importantChanges.length} ${w('changes', '项')}',
                        size: 10,
                        color: p.accent,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final change in importantChanges)
                    _insightImportantChangeRow(change),
                ]),
              if (institutions.isNotEmpty)
                card([
                  Text(
                    w('Comparable institution detail', '可比机构明细'),
                    style: deskHeading(17),
                  ),
                  label(
                    'Complete pagination is retained by the 13F v5 detail payload; missing filings are not converted to zero holdings.',
                    '13F v5 明细保留完整分页；整份申报缺失不会被当成零持仓。',
                    size: 11,
                  ),
                  for (final row in institutions.take(30))
                    ListTile(
                      dense: true,
                      title: Text(
                        text(
                          row['name'],
                          text(row['manager'], text(row['investorId'], '—')),
                        ),
                      ),
                      subtitle: Text(
                        '${text(row['action'])} · ${w('Shares', '股数')} ${nullableNumber(row['currentUnitsK']) == null ? '—' : formatNumber(number(row['currentUnitsK']))} · ${w('Portfolio weight', '组合权重')} ${pct(row['currentWeight'])}',
                      ),
                      trailing: Text(
                        row['action'] == 'exited'
                            ? money(row['activityValueM'])
                            : pct(row['weightChange']),
                      ),
                    ),
                ]),
            ],
          ),
          researchEvidenceSidebar(),
          sideWidth: 330,
        ),
      ],
    );
  }

  List<Widget> researchValuationWorkspace() {
    final breakdown = asMap(company?['publishedBreakdown']);
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final tab in [
            ('published', 'Published model', '已发布模型'),
            ('personal', 'My DCF', '我的 DCF'),
            ('reverse', 'Reverse DCF', '反向 DCF'),
          ])
            ChoiceChip(
              label: Text(w(tab.$2, tab.$3)),
              selected: valuationSection == tab.$1,
              onSelected: (_) => updateUI(() => valuationSection = tab.$1),
            ),
        ],
      ),
      const SizedBox(height: 18),
      if (valuationSection == 'published') researchPublishedLedger(breakdown),
      if (valuationSection == 'personal' && assumptions.isEmpty)
        card([
          title('No personal DCF starting point', '暂无个人 DCF 起点'),
          label(
            'The company remains fully researchable. This snapshot does not support the generic parent-FCFE worksheet.',
            '该公司仍可完整研究，但此快照不适用通用母公司 FCFE 表。',
          ),
        ]),
      if (valuationSection == 'personal' && assumptions.isNotEmpty)
        ...personalValueWorkspace(),
      if (valuationSection == 'reverse' && assumptions.isEmpty)
        card([
          label(
            'Reverse DCF requires a supported personal cash-flow model and a comparable price.',
            '反向 DCF 需要受支持的个人现金流模型及可比价格。',
          ),
        ]),
      if (valuationSection == 'reverse' && assumptions.isNotEmpty)
        researchReversePanel(),
    ];
  }

  Widget researchPublishedLedger(Map<String, dynamic> breakdown) {
    final components = asList(breakdown['components']);
    return pageColumns(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title('Published-model reconciliation', '已发布模型逐项对账'),
          label(
            'Every stored method remains visible. An unavailable method is not displayed as a zero valuation.',
            '所有已存方法均保留显示；不可用方法不会被显示为估值为零。',
          ),
          const SizedBox(height: 16),
          if (breakdown.isEmpty)
            card([
              label(
                'No published valuation exists for this company at the research cutoff.',
                '该公司在研究截止日没有已发布估值。',
              ),
            ]),
          for (final method in components)
            card([
              Row(
                children: [
                  Expanded(
                    child: Text(text(method['label']), style: deskHeading(17)),
                  ),
                  researchTag(
                    text(method['status']),
                    method['status'] == 'included' ? p.accent : p.secondary,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 24,
                runSpacing: 12,
                children: [
                  valuationSummary(
                    method['output'] == null ? 'N/A' : money(method['output']),
                    'Standalone output',
                    '独立输出',
                  ),
                  valuationSummary(
                    method['weight'] == null
                        ? 'Missing'
                        : pct(method['weight']),
                    'Actual stored weight',
                    '实际存储权重',
                  ),
                  valuationSummary(
                    method['status'] == 'included'
                        ? money(method['contribution'])
                        : w('Excluded', '未采用'),
                    'Weighted contribution',
                    '加权贡献',
                  ),
                ],
              ),
              if (method['exclusionReason'] != null) ...[
                const SizedBox(height: 10),
                label(
                  text(method['exclusionReason']),
                  text(method['exclusionReason']),
                  color: p.secondary,
                  size: 11,
                ),
              ],
              for (final step in asList(method['steps']))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(text(step['label'])),
                  subtitle: Text(text(step['formula'])),
                  trailing: Text(
                    nullableNumber(step['output']) == null
                        ? '—'
                        : formatNumber(number(step['output'])),
                  ),
                ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(w('Inputs and source periods', '输入与来源期间')),
                children: [
                  for (final input in asList(method['parameters']))
                    ListTile(
                      dense: true,
                      title: Text(text(input['label'])),
                      subtitle: Text(text(input['key'])),
                      trailing: Text(
                        nullableNumber(input['value']) == null
                            ? '—'
                            : formatNumber(number(input['value'])),
                      ),
                    ),
                ],
              ),
            ]),
          if (breakdown.isNotEmpty)
            card([
              dataTable(
                [w('Reconciliation', '对账'), w('Per share', '每股')],
                [
                  [
                    w('Weighted method value', '子模型加权值'),
                    money(breakdown['weightedValue']),
                  ],
                  [
                    w('Stored post-method adjustments', '已存后置调整'),
                    money(
                      asList(breakdown['postModelAdjustments']).fold<double>(
                        0,
                        (sum, row) => sum + number(row['amount']),
                      ),
                    ),
                  ],
                  [
                    w('Final published value', '最终已发布价值'),
                    money(breakdown['fairValue']),
                  ],
                ],
              ),
              label(
                '${text(breakdown['modelVersion'])} · ${text(breakdown['availableAt'])} · ${text(breakdown['reconciliationStatus'])}',
                '${text(breakdown['modelVersion'])} · ${text(breakdown['availableAt'])} · ${text(breakdown['reconciliationStatus'])}',
                size: 11,
              ),
            ]),
        ],
      ),
      researchEvidenceSidebar(),
      sideWidth: 330,
    );
  }

  Widget researchReversePanel() {
    final reverse = asMap(calculation?['reverse']);
    final scenario = asMap(reverse['scenario']);
    final diagnostics = asMap(reverse['diagnostics']);
    final solved = reverse['status'] == 'solved' && scenario.isNotEmpty;
    final solvedLabel = switch (text(reverse['variable'])) {
      'growth' => w('Revenue growth', '收入增长率'),
      'mature_ebit_margin' => w('Mature EBIT margin', '成熟 EBIT 利润率'),
      'reinvestment' => w('ΔNWC / revenue', 'ΔNWC / 收入'),
      'terminal_margin' => w('Final FCFE margin', '末期 FCFE 率'),
      _ => w('Solved variable', '待求变量'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        title('What operating path explains the price?', '什么经营路径能够解释当前价格？'),
        label(
          'One variable is solved at a time. All other assumptions remain fixed and visible; this is not analyst consensus.',
          '每次只反推一个变量，其余假设固定且可见；这不是分析师共识。',
        ),
        const SizedBox(height: 16),
        valuationCalculationState(),
        pageColumns(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (solved) ...[
                valuationForecastGrid(scenario, reverseDetails: reverse),
                const SizedBox(height: 18),
                valuationTerminalSummary(scenario),
              ] else
                card([
                  Icon(Icons.travel_explore, color: p.secondary, size: 24),
                  const SizedBox(height: 12),
                  title('No valid path in the search range', '搜索范围内没有有效路径'),
                  label(
                    reverse.isEmpty
                        ? 'Enter a comparable price and required return to calculate the implied path.'
                        : 'The selected variable cannot reproduce this price inside the supported bounds. Change one control; no arbitrary root is shown.',
                    reverse.isEmpty
                        ? '输入可比价格与要求回报后计算价格隐含路径。'
                        : '所选变量在支持边界内无法复现该价格。请修改一个控制项；系统不会展示任意根。',
                  ),
                ]),
            ],
          ),
          card([
            label('PRICE-IMPLIED PATH', '价格隐含路径', size: 10, color: p.accent),
            const SizedBox(height: 8),
            title('Solve one variable', '每次反推一个变量'),
            input(
              reversePrice,
              'Price to explain',
              '待解释价格',
              width: double.infinity,
              numeric: true,
              changed: (_) => scheduleCalculation(),
            ),
            const SizedBox(height: 12),
            input(
              targetReturn,
              'Required return %',
              '要求回报 %',
              width: double.infinity,
              numeric: true,
              changed: (_) => scheduleCalculation(),
            ),
            const SizedBox(height: 14),
            for (final variable
                in personalDcfMethod == 'operating_fcff'
                    ? [
                        ('growth', 'Revenue growth', '收入增长率'),
                        (
                          'mature_ebit_margin',
                          'Mature EBIT margin',
                          '成熟 EBIT 利润率',
                        ),
                        ('reinvestment', 'ΔNWC / revenue', 'ΔNWC / 收入'),
                      ]
                    : [
                        ('growth', 'Revenue growth', '收入增长率'),
                        ('terminal_margin', 'Final FCFE margin', '末期 FCFE 率'),
                      ])
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ChoiceChip(
                  key: ValueKey('reverse-variable-${variable.$1}'),
                  label: SizedBox(
                    width: double.infinity,
                    child: Text(w(variable.$2, variable.$3)),
                  ),
                  selected: reverseVariable == variable.$1,
                  onSelected: (_) {
                    updateUI(() => reverseVariable = variable.$1);
                    scheduleCalculation();
                  },
                ),
              ),
            Divider(height: 28, color: p.border),
            Text(
              solved ? pct(reverse['value']) : '—',
              key: const ValueKey('reverse-solved-value'),
              style: TextStyle(
                color: solved ? p.secondary : p.muted,
                fontSize: 28,
                fontWeight: FontWeight.w800,
              ),
            ),
            label(solvedLabel, solvedLabel, color: p.text, size: 12),
            const SizedBox(height: 14),
            dataTable(
              [w('Forward check', '回代检查'), w('Result', '结果')],
              [
                [w('Target price', '目标价格'), money(reverse['price'])],
                [
                  w('Recalculated value', '回代每股价值'),
                  money(diagnostics['verifiedForwardValue']),
                ],
                [
                  w('Price residual', '价格残差'),
                  nullableNumber(reverse['residual']) == null
                      ? '—'
                      : money(reverse['residual']),
                ],
                [
                  w('Solutions in bounds', '边界内解数量'),
                  text(diagnostics['rootCount'], '0'),
                ],
              ],
            ),
            const SizedBox(height: 10),
            label(
              solved
                  ? 'Forward check passed. The table uses the same engine as My DCF.'
                  : 'Status: ${text(reverse['status'], 'not_calculated')}',
              solved
                  ? '正向回代已通过；表格与“我的 DCF”使用同一计算引擎。'
                  : '状态：${text(reverse['status'], '尚未计算')}',
              color: solved ? p.accent : p.secondary,
              size: 11,
            ),
            if (text(reverse['fixed']).isNotEmpty) ...[
              const SizedBox(height: 12),
              label(text(reverse['fixed']), text(reverse['fixed']), size: 11),
            ],
          ]),
          sideWidth: 330,
        ),
      ],
    );
  }

  Widget researchRecordsPanel() {
    final rows = asList(researchRecordsData?['rows']);
    return pageColumns(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          researchPanelState(),
          title('Save a falsifiable research record', '保存可证伪的研究记录'),
          label(
            'A valuation model is optional. Save the question, both sides of the evidence, the failure condition and review date.',
            '估值模型不是前提；保存研究问题、正反证据、失效条件与复核日期。',
          ),
          const SizedBox(height: 16),
          card([
            input(
              researchQuestion,
              'Research question',
              '研究问题',
              changed: (_) => updateUI(() {}),
            ),
            input(researchSupport, 'Supporting evidence', '支持证据'),
            input(researchOpposition, 'Opposing evidence / gap', '反对证据 / 解释缺口'),
            input(researchInvalidation, 'Invalidation condition', '失效条件'),
            input(
              researchReviewDate,
              'Review date · YYYY-MM-DD',
              '复核日期 · YYYY-MM-DD',
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: button(
                'Save research record',
                '保存研究记录',
                researchQuestion.text.trim().isEmpty
                    ? null
                    : () => unawaited(saveResearchRecord()),
                primary: true,
              ),
            ),
          ]),
          for (final row in rows.reversed)
            card([
              Text(text(row['question']), style: deskHeading(16)),
              const SizedBox(height: 8),
              label(
                '${text(row['asOf'])} · ${w('Review', '复核')} ${text(row['reviewDate'], '—')}',
                '${text(row['asOf'])} · ${w('Review', '复核')} ${text(row['reviewDate'], '—')}',
                size: 11,
              ),
              if (text(row['supportingEvidence']).isNotEmpty)
                label(
                  '${w('Support', '支持')} · ${text(row['supportingEvidence'])}',
                  '${w('Support', '支持')} · ${text(row['supportingEvidence'])}',
                  size: 12,
                ),
              if (text(row['opposingEvidence']).isNotEmpty)
                label(
                  '${w('Counter', '反证')} · ${text(row['opposingEvidence'])}',
                  '${w('Counter', '反证')} · ${text(row['opposingEvidence'])}',
                  size: 12,
                  color: p.secondary,
                ),
            ]),
        ],
      ),
      researchEvidenceSidebar(),
      sideWidth: 330,
    );
  }

  Future<void> saveResearchRecord() async {
    final question = researchQuestion.text.trim();
    if (question.isEmpty) return;
    try {
      await widget.api.postJson('/api/investment/research-records', {
        'operationId': op(),
        'ticker': ticker,
        'asOf': asOf,
        'question': question,
        'supportingEvidence': researchSupport.text,
        'opposingEvidence': researchOpposition.text,
        'invalidationCondition': researchInvalidation.text,
        'reviewDate': researchReviewDate.text.trim().isEmpty
            ? null
            : researchReviewDate.text.trim(),
        'evidenceRefs': <String>[],
        'discoveryOrigin': discoveryOrigin,
        if (discoveryOrigin == 'ai_insights')
          'discoveryContext': asMap(entryEvidence?['aiInsights']),
        'personalScenarioId': scenarioId,
        'impliedScenario': asMap(calculation?['reverse']).isEmpty
            ? null
            : asMap(calculation?['reverse']),
      });
      researchQuestion.clear();
      researchSupport.clear();
      researchOpposition.clear();
      researchInvalidation.clear();
      researchReviewDate.clear();
      await loadResearchPanel('records');
    } catch (e) {
      if (mounted) updateUI(() => researchPanelError = e.toString());
    }
  }

  Widget researchTag(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );

  Widget researchWatchButton() {
    if (!researchHasPlatformModel) {
      return OutlinedButton.icon(
        onPressed: () => selectResearchSection('records'),
        icon: const Icon(Icons.note_add_outlined, size: 16),
        label: Text(w('Save research note', '保存研究记录')),
      );
    }
    final saved = asList(home?['watches']).any((r) => r['ticker'] == ticker);
    return OutlinedButton.icon(
      onPressed: busy || saved
          ? null
          : () => command(() async {
              final symbol = ticker, cutoff = asOf;
              await widget.api.postJson('/api/investment/watches', {
                'operationId': op(),
                'ticker': symbol,
                'asOf': cutoff,
                'origin': opportunityReturnDate.isNotEmpty
                    ? opportunityLens
                    : 'value',
              });
              await loadHome();
              if (mounted) {
                updateUI(
                  () => notice = w(
                    '$symbol saved to watch with its dated platform model. No investment decision was made.',
                    '$symbol 已保存带日期的平台模型至观察列表，未记录投资决策。',
                  ),
                );
              }
            }),
      icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border, size: 16),
      label: Text(
        w(saved ? 'Saved to watch' : 'Save to watch', saved ? '已保存观察' : '保存观察'),
      ),
    );
  }

  List<Widget> researchOverview() => [
    researchOverviewValuation(),
    const SizedBox(height: 18),
    researchFinancialStatements(),
  ];

  Widget researchOverviewValuation() {
    final price = asMap(asMap(company?['snapshot'])['price']);
    final breakdown = asMap(company?['publishedBreakdown']);
    final methods = asList(breakdown['components']);
    final fairValue = nullableNumber(
      breakdown['fairValue'] ?? asMap(company?['published'])['fairValue'],
    );
    final marketPrice = nullableNumber(price['value']);
    final comparable =
        marketPrice != null &&
        marketPrice > 0 &&
        fairValue != null &&
        text(price['currency'], text(company?['currency'])) ==
            text(company?['currency']);
    final gap = comparable ? fairValue / marketPrice - 1 : null;
    final comparison = <_ResearchValueBar>[
      if (marketPrice != null)
        _ResearchValueBar(
          label: w('Market price', '市场价格'),
          value: marketPrice,
          color: p.text,
        ),
      if (fairValue != null)
        _ResearchValueBar(
          label: w('Final published value', '最终已发布估值'),
          value: fairValue,
          color: p.accent,
        ),
      for (final method in methods)
        if (nullableNumber(method['output']) != null)
          _ResearchValueBar(
            label: text(method['label']),
            value: number(method['output']),
            color: method['status'] == 'included' ? p.secondary : p.muted,
          ),
    ];
    return card([
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label(
                  'PRICE & PUBLISHED MODEL',
                  '价格与已发布模型',
                  size: 10,
                  color: p.accent,
                ),
                const SizedBox(height: 6),
                Text(
                  w('What the model is worth — and why', '模型值多少，以及怎么算出来'),
                  style: deskHeading(22),
                ),
                const SizedBox(height: 5),
                label(
                  'Price is comparison-only. Every method below comes from the same stored model observation.',
                  '股价仅用于比较；下方每个方法均来自同一个已存模型节点。',
                  size: 11,
                ),
              ],
            ),
          ),
          if (gap != null)
            researchTag(
              '${gap >= 0 ? '+' : ''}${pct(gap)} ${w('value / price − 1', '估值 / 价格 − 1')}',
              gap >= 0 ? p.accent : p.secondary,
            ),
        ],
      ),
      const SizedBox(height: 20),
      if (!researchHasPlatformModel)
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: label(
            'No platform valuation is stored at this cutoff. The three financial statements below remain available.',
            '该截止日没有已存平台估值；下方三张财务报表仍可完整研究。',
            color: p.secondary,
          ),
        )
      else ...[
        LayoutBuilder(
          builder: (_, bounds) {
            final chart = _ResearchValueComparison(
              items: comparison,
              currency: text(company?['currency'], 'USD'),
              muted: p.muted,
              border: p.border,
            );
            final reconciliation = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _researchReconciliationLine(
                  w('Market price', '市场价格'),
                  money(marketPrice),
                  text(price['date']),
                ),
                _researchReconciliationLine(
                  w('Weighted method value', '子模型加权值'),
                  money(breakdown['weightedValue']),
                  w('Before stored adjustments', '已存后置调整前'),
                ),
                _researchReconciliationLine(
                  w('Final published value', '最终已发布估值'),
                  money(fairValue),
                  text(breakdown['availableAt']),
                  accent: true,
                ),
              ],
            );
            if (bounds.maxWidth < 840) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [chart, const SizedBox(height: 18), reconciliation],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 5, child: chart),
                const SizedBox(width: 30),
                Expanded(flex: 3, child: reconciliation),
              ],
            );
          },
        ),
        const SizedBox(height: 22),
        Divider(color: p.border),
        const SizedBox(height: 12),
        Text(w('Model components', '估值子模型'), style: deskHeading(17)),
        const SizedBox(height: 4),
        label(
          'Standalone output × actual stored weight = weighted contribution.',
          '子模型独立输出 × 实际存储权重 = 加权贡献。',
          size: 11,
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (_, bounds) => Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final method in methods)
                SizedBox(
                  width: bounds.maxWidth >= 900
                      ? (bounds.maxWidth - 12) / 2
                      : bounds.maxWidth,
                  child: _researchOverviewMethod(method),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: label(
                '${text(breakdown['modelVersion'], '—')} · ${text(breakdown['period'], '—')} · ${text(breakdown['reconciliationStatus'], '—')}',
                '${text(breakdown['modelVersion'], '—')} · ${text(breakdown['period'], '—')} · ${text(breakdown['reconciliationStatus'], '—')}',
                size: 10,
              ),
            ),
            TextButton.icon(
              onPressed: () {
                updateUI(() => valuationSection = 'published');
                selectSection('value');
              },
              icon: const Icon(Icons.arrow_forward, size: 15),
              label: Text(w('Open full reconciliation', '查看完整模型对账')),
            ),
          ],
        ),
      ],
    ]);
  }

  Widget _researchReconciliationLine(
    String heading,
    String value,
    String note, {
    bool accent = false,
  }) => Container(
    padding: const EdgeInsets.symmetric(vertical: 11),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: p.border)),
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(heading, style: TextStyle(color: p.text, fontSize: 12)),
              const SizedBox(height: 3),
              label(note, note, size: 9),
            ],
          ),
        ),
        Text(
          value,
          style: deskHeading(20).copyWith(color: accent ? p.accent : p.text),
        ),
      ],
    ),
  );

  Widget _researchOverviewMethod(Map<String, dynamic> method) {
    final included = method['status'] == 'included';
    final steps = asList(method['steps']);
    final parameters = asList(method['parameters']);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: included ? p.accent.withValues(alpha: .35) : p.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(text(method['label']), style: deskHeading(15)),
              ),
              researchTag(
                included ? w('Included', '已采用') : w('Not used', '未采用'),
                included ? p.accent : p.secondary,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 20,
            runSpacing: 10,
            children: [
              valuationSummary(
                method['output'] == null ? 'N/A' : money(method['output']),
                'Standalone',
                '独立输出',
              ),
              valuationSummary(
                method['weight'] == null ? '—' : pct(method['weight']),
                'Weight',
                '权重',
              ),
              valuationSummary(
                included ? money(method['contribution']) : '—',
                'Contribution',
                '贡献',
              ),
            ],
          ),
          if (text(method['exclusionReason']).isNotEmpty) ...[
            const SizedBox(height: 10),
            label(
              text(method['exclusionReason']),
              text(method['exclusionReason']),
              size: 10,
              color: p.secondary,
            ),
          ],
          if (steps.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final step in steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.calculate_outlined, size: 14, color: p.accent),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '${text(step['formula'])} = ${nullableNumber(step['output']) == null ? '—' : formatNumber(number(step['output']))}',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 10,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (parameters.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(
                w('Inputs used in this snapshot', '该快照采用的输入'),
                style: const TextStyle(fontSize: 11),
              ),
              children: [
                for (final input in parameters)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Row(
                      children: [
                        Expanded(
                          child: label(
                            text(input['label']),
                            text(input['label']),
                            size: 10,
                          ),
                        ),
                        Text(
                          nullableNumber(input['value']) == null
                              ? '—'
                              : formatNumber(number(input['value'])),
                          style: TextStyle(color: p.text, fontSize: 11),
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

  List<({String key, String en, String zh, String unit})>
  get _researchStatementRows => switch (researchStatement) {
    'balance' => [
      (
        key: 'cashneq',
        en: 'Cash & equivalents',
        zh: '现金及等价物',
        unit: 'currency',
      ),
      (key: 'receivables', en: 'Receivables', zh: '应收款项', unit: 'currency'),
      (key: 'inventory', en: 'Inventory', zh: '存货', unit: 'currency'),
      (key: 'assetsc', en: 'Current assets', zh: '流动资产', unit: 'currency'),
      (
        key: 'ppnenet',
        en: 'Net property, plant & equipment',
        zh: '物业厂房设备净额',
        unit: 'currency',
      ),
      (
        key: 'intangibles',
        en: 'Intangible assets',
        zh: '无形资产',
        unit: 'currency',
      ),
      (key: 'assets', en: 'Total assets', zh: '总资产', unit: 'currency'),
      (key: 'payables', en: 'Payables', zh: '应付款项', unit: 'currency'),
      (
        key: 'liabilitiesc',
        en: 'Current liabilities',
        zh: '流动负债',
        unit: 'currency',
      ),
      (key: 'debt', en: 'Total debt', zh: '总债务', unit: 'currency'),
      (
        key: 'liabilities',
        en: 'Total liabilities',
        zh: '总负债',
        unit: 'currency',
      ),
      (key: 'equity', en: 'Shareholders’ equity', zh: '股东权益', unit: 'currency'),
      (
        key: 'workingcapital',
        en: 'Working capital',
        zh: '营运资本',
        unit: 'currency',
      ),
      (key: 'invcap', en: 'Invested capital', zh: '投入资本', unit: 'currency'),
      (key: 'deposits', en: 'Deposits', zh: '存款', unit: 'currency'),
    ],
    'cash' => [
      (
        key: 'ncfo',
        en: 'Cash from operations',
        zh: '经营活动现金流',
        unit: 'currency',
      ),
      (key: 'capex', en: 'Capital expenditure', zh: '资本支出', unit: 'currency'),
      (key: 'fcf', en: 'Free cash flow', zh: '自由现金流', unit: 'currency'),
      (key: 'ncfi', en: 'Cash from investing', zh: '投资活动现金流', unit: 'currency'),
      (key: 'ncff', en: 'Cash from financing', zh: '融资活动现金流', unit: 'currency'),
      (
        key: 'sbcomp',
        en: 'Stock-based compensation',
        zh: '股权激励',
        unit: 'currency',
      ),
      (
        key: 'ncfcommon',
        en: 'Net common stock financing',
        zh: '普通股净融资',
        unit: 'currency',
      ),
      (key: 'ncfdebt', en: 'Net debt financing', zh: '债务净融资', unit: 'currency'),
      (key: 'ncfdiv', en: 'Cash dividends', zh: '现金股息', unit: 'currency'),
      (
        key: 'depamor',
        en: 'Depreciation & amortization',
        zh: '折旧与摊销',
        unit: 'currency',
      ),
      (key: 'ncf', en: 'Net change in cash', zh: '现金净变动', unit: 'currency'),
    ],
    _ => [
      (key: 'revenue', en: 'Revenue', zh: '营业收入', unit: 'currency'),
      (key: 'cor', en: 'Cost of revenue', zh: '营业成本', unit: 'currency'),
      (key: 'gp', en: 'Gross profit', zh: '毛利润', unit: 'currency'),
      (key: 'rnd', en: 'Research & development', zh: '研发费用', unit: 'currency'),
      (
        key: 'sgna',
        en: 'Selling, general & administrative',
        zh: '销售及管理费用',
        unit: 'currency',
      ),
      (key: 'opex', en: 'Operating expenses', zh: '经营费用', unit: 'currency'),
      (key: 'opinc', en: 'Operating income', zh: '营业利润', unit: 'currency'),
      (key: 'ebit', en: 'EBIT', zh: '息税前利润', unit: 'currency'),
      (key: 'intexp', en: 'Interest expense', zh: '利息费用', unit: 'currency'),
      (key: 'taxexp', en: 'Income tax expense', zh: '所得税费用', unit: 'currency'),
      (key: 'netinc', en: 'Net income', zh: '净利润', unit: 'currency'),
      (
        key: 'netinccmn',
        en: 'Net income to common',
        zh: '归属普通股净利润',
        unit: 'currency',
      ),
      (
        key: 'shareswadil',
        en: 'Diluted weighted-average shares',
        zh: '摊薄加权平均股数',
        unit: 'shares',
      ),
      (key: 'dps', en: 'Dividends per share', zh: '每股股息', unit: 'per_share'),
    ],
  };

  List<Map<String, dynamic>> _researchFinancialPeriods() {
    final annual = asList(
      researchFundamental?['annual'],
    ).take(8).toList().reversed;
    final periods = <Map<String, dynamic>>[
      for (final row in annual)
        {
          'label': text(
            row['reportperiod'],
            text(row['period_end']),
          ).split('-').first,
          'kind': 'annual',
          'row': row,
        },
    ];
    final quarters = asList(researchFundamental?['quarterly']).take(4).toList();
    if (quarters.isNotEmpty) {
      periods.add({
        'label': researchStatement == 'balance' ? w('Latest', '最新') : 'TTM',
        'kind': researchStatement == 'balance' ? 'latest' : 'ttm',
        'row': quarters.first,
        'rows': quarters,
      });
    }
    return periods;
  }

  double? _researchFinancialValue(Map<String, dynamic> period, String key) {
    if (period['kind'] != 'ttm') {
      return nullableNumber(asMap(period['row'])[key]);
    }
    final values = [
      for (final row in asList(period['rows'])) nullableNumber(row[key]),
    ];
    if (values.length != 4 || values.any((value) => value == null)) return null;
    if (const {'sharesbas', 'shareswa', 'shareswadil', 'dps'}.contains(key)) {
      return values.first;
    }
    return values.fold<double>(0, (sum, value) => sum + value!);
  }

  void _selectResearchStatement(String statement) {
    final defaults = switch (statement) {
      'balance' => ['cashneq', 'debt', 'equity'],
      'cash' => ['ncfo', 'capex', 'fcf'],
      _ => ['revenue', 'opinc', 'netinccmn'],
    };
    updateUI(() {
      researchStatement = statement;
      researchFinancialMetrics = defaults;
    });
  }

  void _toggleResearchFinancialMetric(String key, String unit) {
    updateUI(() {
      final selected = [...researchFinancialMetrics];
      if (selected.contains(key)) {
        if (selected.length > 1) selected.remove(key);
      } else {
        final definitions = {
          for (final row in _researchStatementRows) row.key: row,
        };
        final currentUnit = selected.isEmpty
            ? unit
            : definitions[selected.first]?.unit;
        if (currentUnit != unit) selected.clear();
        if (selected.length >= 3) selected.removeAt(0);
        selected.add(key);
      }
      researchFinancialMetrics = selected;
    });
  }

  Widget researchFinancialStatements() {
    final periods = _researchFinancialPeriods();
    final definitions = _researchStatementRows;
    final definitionByKey = {for (final row in definitions) row.key: row};
    final colors = [p.accent, p.secondary, const Color(0xff73a7ff)];
    final selected = [
      for (var index = 0; index < researchFinancialMetrics.length; index++)
        if (definitionByKey[researchFinancialMetrics[index]] case final row?)
          _ResearchFinancialSeries(
            keyName: row.key,
            label: w(row.en, row.zh),
            color: colors[index % colors.length],
            values: [
              for (final period in periods)
                _researchFinancialValue(period, row.key),
            ],
          ),
    ];
    return card([
      LayoutBuilder(
        builder: (_, bounds) {
          final heading = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              label(
                'FINANCIAL STATEMENTS',
                '基本财务信息',
                size: 10,
                color: p.accent,
              ),
              const SizedBox(height: 6),
              Text(
                w('Three statements. One comparison chart.', '三张报表，一张可交互比较图'),
                style: deskHeading(22),
              ),
              const SizedBox(height: 5),
              label(
                'Select up to three rows. The chart updates immediately; missing facts stay missing.',
                '最多选择三行，上方柱状图会立即更新；缺失事实继续显示为空。',
                size: 11,
              ),
            ],
          );
          final basis = researchTag(
            '${text(researchFundamental?['reportedBasis'], 'ARQ / ARY')} · ${text(company?['currency'], '—')}',
            p.muted,
          );
          if (bounds.maxWidth < 650) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [heading, const SizedBox(height: 10), basis],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: heading),
              const SizedBox(width: 12),
              basis,
            ],
          );
        },
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final statement in [
            ('income', 'Income statement', '利润表'),
            ('balance', 'Balance sheet', '资产负债表'),
            ('cash', 'Cash flow', '现金流量表'),
          ])
            ChoiceChip(
              key: ValueKey('research-statement-${statement.$1}'),
              label: Text(w(statement.$2, statement.$3)),
              selected: researchStatement == statement.$1,
              onSelected: (_) => _selectResearchStatement(statement.$1),
            ),
        ],
      ),
      const SizedBox(height: 14),
      if (researchFinancialsLoading) ...[
        const LinearProgressIndicator(),
        const SizedBox(height: 10),
        label('Loading reported statements…', '正在载入已报告财务报表…', size: 11),
      ] else if (researchFinancialsError != null)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: label(
            'The statement history could not be loaded. No values are substituted.',
            '财务报表历史暂时无法载入；系统不会填入替代数值。',
            color: p.secondary,
          ),
        )
      else if (periods.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: label(
            'No comparable annual statement history is available at this cutoff.',
            '该截止日没有可比的年度财务报表历史。',
          ),
        )
      else ...[
        Container(
          key: const ValueKey('research-financial-chart'),
          height: MediaQuery.sizeOf(context).width < 600 ? 270 : 320,
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: _ResearchFinancialBarChart(
            periods: [for (final period in periods) text(period['label'])],
            series: selected,
            muted: p.muted,
            textColor: p.text,
            grid: p.border,
          ),
        ),
        const SizedBox(height: 12),
        label(
          researchStatement == 'balance'
              ? 'Annual as-reported balances plus the latest reported quarter. Click any row to redraw the chart.'
              : 'Annual as-reported values plus TTM from four available as-reported quarters. Click any row to redraw the chart.',
          researchStatement == 'balance'
              ? '年度原始报告余额加最新已报告季度；点击任一行即可重绘图表。'
              : '年度原始报告数值加最近四个可用原始季度合计；点击任一行即可重绘图表。',
          size: 10,
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            key: ValueKey('research-financial-table-$researchStatement'),
            headingRowHeight: 42,
            dataRowMinHeight: 48,
            dataRowMaxHeight: 52,
            columns: [
              DataColumn(label: Text(w('Reported line item', '报表项目'))),
              for (final period in periods)
                DataColumn(label: Text(text(period['label'])), numeric: true),
            ],
            rows: [
              for (final row in definitions)
                DataRow(
                  selected: researchFinancialMetrics.contains(row.key),
                  onSelectChanged: (_) =>
                      _toggleResearchFinancialMetric(row.key, row.unit),
                  cells: [
                    DataCell(
                      Row(
                        key: ValueKey('research-financial-row-${row.key}'),
                        children: [
                          Container(
                            width: 4,
                            height: 30,
                            decoration: BoxDecoration(
                              color: researchFinancialMetrics.contains(row.key)
                                  ? selected
                                            .where(
                                              (series) =>
                                                  series.keyName == row.key,
                                            )
                                            .map((series) => series.color)
                                            .firstOrNull ??
                                        p.accent
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 9),
                          SizedBox(width: 210, child: Text(w(row.en, row.zh))),
                        ],
                      ),
                    ),
                    for (final period in periods)
                      DataCell(
                        Text(
                          _researchFinancialValue(period, row.key) == null
                              ? '—'
                              : formatNumber(
                                  _researchFinancialValue(period, row.key)!,
                                ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        label(
          'Source: Fact OS · Sharadar SF1 as-reported ARY/ARQ · values use the issuer reporting currency and are not zero-filled.',
          '来源：Fact OS · Sharadar SF1 原始报告 ARY/ARQ · 数值使用发行人报告币种，且不补零。',
          size: 10,
        ),
      ],
    ]);
  }

  // Retained for replaying older research layouts without showing it in the
  // current overview.
  // ignore: unused_element
  Widget researchFactInsight() {
    final fact = researchFundamental;
    final judgment = asMap(fact?['judgment']);
    final counter = asMap(fact?['counterEvidence']);
    final changes = asList(fact?['importantChanges']);
    if (judgment.isEmpty) return researchLatestChange();
    final language = context.language == AppLanguage.zh ? 'zh' : 'en';
    String translated(dynamic value) =>
        text(asMap(value)[language], text(value));
    return card([
      label(
        'EVIDENCE-BASED OBSERVATION',
        '基于证据的核心观察',
        size: 10,
        color: p.accent,
      ),
      const SizedBox(height: 10),
      Text(translated(judgment['summary']), style: deskHeading(20)),
      const SizedBox(height: 16),
      for (final change in changes.take(3))
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.trending_up, size: 17, color: p.accent),
          title: Text(translated(change['summary'])),
          subtitle: Text(asList(change['evidence']).map(text).join(' · ')),
        ),
      Divider(color: p.border),
      label(
        'Counter-evidence / explanation gap',
        '反证 / 解释缺口',
        size: 10,
        color: p.secondary,
      ),
      const SizedBox(height: 6),
      label(
        translated(counter['statement']),
        translated(counter['statement']),
        color: p.secondary,
      ),
      const SizedBox(height: 12),
      label('Next question', '下一步研究问题', size: 10, color: p.accent),
      const SizedBox(height: 6),
      label(translated(judgment['question']), translated(judgment['question'])),
    ]);
  }

  // ignore: unused_element
  Widget researchChart() {
    final all = researchHistory;
    final prices = researchDatedRows(
      asList(company?['priceHistory']),
      'date',
      asOf,
    );
    final allDates = [
      ...all.map((h) => text(h['availableAt'])),
      ...prices.map((h) => text(h['date'])),
    ]..sort();
    final end = DateTime.parse(asOf);
    final start = researchWindow != null
        ? DateTime.fromMillisecondsSinceEpoch(
            researchWindow!.start.round(),
          ).toIso8601String().substring(0, 10)
        : researchRange == 'All'
        ? ''
        : DateTime(
            end.year - (int.tryParse(researchRange.replaceAll('Y', '')) ?? 5),
            end.month,
            end.day,
          ).toIso8601String().substring(0, 10);
    final until = researchWindow != null
        ? DateTime.fromMillisecondsSinceEpoch(
            researchWindow!.end.round(),
          ).toIso8601String().substring(0, 10)
        : asOf;
    final visible = researchDatedRows(all, 'availableAt', until, from: start);
    final shownPrices = researchDatedRows(prices, 'date', until, from: start);
    final node =
        all.where((h) => researchReportKey(h) == researchReport).firstOrNull ??
        all.lastOrNull;
    final index = node == null ? -1 : all.indexOf(node);
    final prev = index > 0 ? all[index - 1] : null;
    final change = node == null ? null : researchValueChange(node, prev);
    final price = asMap(asMap(company?['snapshot'])['price']);
    final published = asMap(company?['published']);
    final hasPlatformModel = researchHasPlatformModel;
    final px = nullableNumber(price['value']),
        fv = nullableNumber(published['fairValue']);
    final matchedCurrency =
        text(price['currency']).isNotEmpty &&
        price['currency'] == company?['currency'];
    final gap = matchedCurrency && px != null && px > 0 && fv != null
        ? fv / px - 1
        : null;
    return card([
      Row(
        children: [
          Expanded(
            child: Text(
              hasPlatformModel
                  ? w('Price & value', '价格与价值')
                  : w('Price context', '价格背景'),
              style: deskHeading(18),
            ),
          ),
          researchTag(
            hasPlatformModel
                ? w('Published model', '平台模型')
                : w('Fact OS · model unavailable', 'Fact OS · 暂无模型'),
            hasPlatformModel ? p.accent : p.muted,
          ),
        ],
      ),
      const SizedBox(height: 18),
      LayoutBuilder(
        builder: (_, c) {
          final summaries = [
            (
              money(price['value']),
              w('Market price', '市场价格'),
              text(price['date']),
              p.text,
            ),
            if (hasPlatformModel) ...[
              (
                money(published['fairValue']),
                w('Published blended value', '已发布综合估值'),
                text(asMap(company?['snapshot'])['availableAt']),
                p.accent,
              ),
              (
                gap == null ? '—' : '${gap >= 0 ? '+' : ''}${pct(gap)}',
                w('Model gap', '模型价差'),
                w('Value / price − 1', '估值 / 价格 − 1'),
                p.muted,
              ),
            ],
          ];
          return Wrap(
            spacing: 12,
            runSpacing: 14,
            children: [
              for (final m in summaries)
                SizedBox(
                  width: hasPlatformModel ? (c.maxWidth - 24) / 3 : c.maxWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: c.maxWidth < 480 ? 30 : 16,
                        child: label(m.$2, m.$2, size: 11),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        m.$1,
                        style: deskHeading(
                          c.maxWidth < 480 ? 22 : 29,
                        ).copyWith(color: m.$4),
                      ),
                      const SizedBox(height: 4),
                      label(m.$3, m.$3, size: 10),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final range in ['1Y', '3Y', '5Y', 'All'])
            ChoiceChip(
              label: Text(range == 'All' ? w('All', '全部') : range),
              selected: researchRange == range && researchWindow == null,
              onSelected: (_) => updateUI(() {
                researchRange = range;
                researchWindow = null;
              }),
            ),
          const SizedBox(width: 8),
          homeChartLegend(p.muted, 'Price', '股价'),
          if (hasPlatformModel) homeChartLegend(p.accent, 'Fair value', '公允价值'),
        ],
      ),
      const SizedBox(height: 10),
      if (visible.length >= 2 || shownPrices.length >= 2)
        SizedBox(
          height: MediaQuery.sizeOf(context).width < 600 ? 225 : 240,
          child: ValuationTrendChart(
            history: [
              for (final h in hasPlatformModel ? visible : const [])
                {
                  'asOfDate': h['availableAt'],
                  'fairValue': h['publishedFairValue'],
                },
            ],
            priceHistory: shownPrices,
            currency: text(company?['currency']),
            palette: p,
            selectedQuarterKey: researchReport.isEmpty
                ? ''
                : '-${text(node?['availableAt'])}',
            labelFontSize: 11,
          ),
        )
      else
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 36),
          child: label(
            'Not enough observations in this range. Try All.',
            '此区间观测不足，请尝试全部。',
          ),
        ),
      if (allDates.length >= 2 && allDates.first != allDates.last) ...[
        Builder(
          builder: (_) {
            final min = DateTime.parse(
              allDates.first,
            ).millisecondsSinceEpoch.toDouble();
            final max = DateTime.parse(
              allDates.last,
            ).millisecondsSinceEpoch.toDouble();
            final current = RangeValues(
              DateTime.tryParse(
                    start,
                  )?.millisecondsSinceEpoch.toDouble().clamp(min, max) ??
                  min,
              DateTime.parse(
                until,
              ).millisecondsSinceEpoch.toDouble().clamp(min, max),
            );
            return Semantics(
              label: w('Chart date range', '曲线日期区间'),
              child: RangeSlider(
                values: RangeValues(
                  (current.start - min) / (max - min),
                  (current.end - min) / (max - min),
                ),
                semanticFormatterCallback: (value) =>
                    DateTime.fromMillisecondsSinceEpoch(
                      (min + value * (max - min)).round(),
                    ).toIso8601String().substring(0, 10),
                labels: RangeLabels(
                  DateTime.fromMillisecondsSinceEpoch(
                    current.start.round(),
                  ).toIso8601String().substring(0, 10),
                  DateTime.fromMillisecondsSinceEpoch(
                    current.end.round(),
                  ).toIso8601String().substring(0, 10),
                ),
                onChanged: (v) => updateUI(
                  () => researchWindow = RangeValues(
                    min + v.start * (max - min),
                    min + v.end * (max - min),
                  ),
                ),
              ),
            );
          },
        ),
      ],
      label(
        '${hasPlatformModel ? 'Model history: ${all.isEmpty ? '—' : all.first['availableAt']} · ' : ''}${prices.length} price samples: ${prices.isEmpty ? '—' : prices.first['date']} – ${prices.isEmpty ? '—' : prices.last['date']}',
        '${hasPlatformModel ? '模型历史：${all.isEmpty ? '—' : all.first['availableAt']} · ' : ''}${prices.length} 个股价样本：${prices.isEmpty ? '—' : prices.first['date']} – ${prices.isEmpty ? '—' : prices.last['date']}',
        size: 10,
      ),
      if (node != null) ...[
        const SizedBox(height: 18),
        Divider(color: p.border),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          key: ValueKey('report-$ticker-${researchReportKey(node)}'),
          initialValue: researchReportKey(node),
          isExpanded: true,
          decoration: InputDecoration(
            labelText: w('Inspect report', '检查报告期'),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final h in all.reversed)
              DropdownMenuItem(
                value: researchReportKey(h),
                child: Text(
                  '${h['period']} · ${h['availableAt']}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
          onChanged: (v) {
            final selected = v ?? '';
            updateUI(() {
              researchReport = selected;
              researchRange = 'All';
              researchWindow = null;
            });
            final selectedNode = all
                .where((h) => researchReportKey(h) == selected)
                .firstOrNull;
            final selectedDate = text(selectedNode?['availableAt']);
            if (hasPlatformModel && selectedDate.isNotEmpty) {
              unawaited(loadHistoricalPublishedModel(selectedDate));
            }
          },
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            if (hasPlatformModel) ...[
              label(
                'Value ${money(node['publishedFairValue'])}',
                '估值 ${money(node['publishedFairValue'])}',
                size: 12,
                color: p.accent,
              ),
              label(
                change == null
                    ? 'Prior model not comparable'
                    : '${change >= 0 ? '+' : ''}${pct(change)} vs prior node',
                change == null
                    ? '前期模型不可比较'
                    : '较前期模型 ${change >= 0 ? '+' : ''}${pct(change)}',
                size: 12,
              ),
            ],
          ],
        ),
        label(
          'Revenue YoY ${pct(asMap(node['metrics'])['revenueGrowth'])} · TTM FCF margin ${pct(asMap(node['metrics'])['fcfMargin'])}',
          '收入同比 ${pct(asMap(node['metrics'])['revenueGrowth'])} · TTM 自由现金流率 ${pct(asMap(node['metrics'])['fcfMargin'])}',
          size: 11,
        ),
        label(
          'Report inspection does not change the workspace cutoff or saved scenario.',
          '检查报告不改变工作区截止日或已保存情景。',
          size: 10,
        ),
      ],
    ]);
  }

  Widget researchLatestChange() {
    final history = researchHistory;
    final last = history.lastOrNull;
    final delta = last == null
        ? null
        : researchValueChange(
            last,
            history.length > 1 ? history[history.length - 2] : null,
          );
    return card([
      label('LATEST REPORT', '最新报告', size: 10, color: p.accent),
      const SizedBox(height: 10),
      Text(w('What changed?', '什么变了？'), style: deskHeading(20)),
      const SizedBox(height: 10),
      label(
        '${asMap(company?['snapshot'])['period']} · ${asMap(company?['snapshot'])['availableAt']}',
        '${asMap(company?['snapshot'])['period']} · ${asMap(company?['snapshot'])['availableAt']}',
        size: 11,
      ),
      const SizedBox(height: 16),
      for (final m in asList(company?['metrics']).take(3))
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: label(
                      metricName(text(m['key'])),
                      metricName(text(m['key'])),
                      size: 12,
                    ),
                  ),
                  Text(pct(m['value']), style: deskHeading(18)),
                ],
              ),
              const SizedBox(height: 4),
              label(
                nullableNumber(m['change']) == null
                    ? 'Prior observation unavailable'
                    : '${number(m['change']) >= 0 ? '+' : ''}${(number(m['change']) * 100).toStringAsFixed(2)} pp vs prior report',
                nullableNumber(m['change']) == null
                    ? '前期观测不可用'
                    : '较前期 ${number(m['change']) >= 0 ? '+' : ''}${(number(m['change']) * 100).toStringAsFixed(2)} 个百分点',
                size: 11,
                color:
                    nullableNumber(m['change']) != null &&
                        number(m['change']) < 0
                    ? p.secondary
                    : p.muted,
              ),
            ],
          ),
        ),
      Divider(color: p.border),
      const SizedBox(height: 8),
      label(
        delta == null
            ? 'Comparable model change unavailable'
            : 'Published value ${delta >= 0 ? '+' : ''}${pct(delta)}',
        delta == null
            ? '可比模型变化不可用'
            : '平台估值 ${delta >= 0 ? '+' : ''}${pct(delta)}',
        size: 14,
        color: p.accent,
      ),
      const SizedBox(height: 8),
      label(
        'Observed changes, not a causal valuation attribution.',
        '以上是同期变化，不是估值变化的因果归因。',
        size: 11,
      ),
    ]);
  }

  // ignore: unused_element
  Widget researchNextStep() {
    final hasPlatformModel = researchHasPlatformModel;
    return card([
      label('YOUR NEXT STEP', '下一步研究', size: 10, color: p.accent),
      const SizedBox(height: 10),
      Text(
        hasPlatformModel
            ? w('Does the price make sense?', '这个价格合理吗？')
            : w('What evidence closes the gap?', '还缺什么证据？'),
        style: deskHeading(18),
      ),
      const SizedBox(height: 10),
      label(
        hasPlatformModel
            ? assumptions.isEmpty
                  ? 'Read the published method, inspect the evidence, then save a dated watch.'
                  : 'Test growth and cash-flow assumptions, then save your own scenario.'
            : 'Review the reported facts and source coverage, then save a dated research question. No valuation is inferred.',
        hasPlatformModel
            ? assumptions.isEmpty
                  ? '查看平台方法，核对证据，再保存带日期的观察。'
                  : '检验增长与现金流假设，再保存你自己的情景。'
            : '检查已报告事实和来源覆盖，再保存带日期的研究问题；系统不会推断不存在的估值。',
        size: 12,
      ),
      const SizedBox(height: 14),
      button(
        hasPlatformModel
            ? assumptions.isEmpty
                  ? 'Inspect published model'
                  : 'Set my assumptions'
            : 'Review financial evidence',
        hasPlatformModel
            ? assumptions.isEmpty
                  ? '检查平台模型'
                  : '设定我的假设'
            : '检查财务证据',
        () => selectSection(hasPlatformModel ? 'value' : 'financials'),
        primary: true,
      ),
      const SizedBox(height: 8),
      button(
        hasPlatformModel ? 'Review financial evidence' : 'Save research note',
        hasPlatformModel ? '检查财务证据' : '保存研究记录',
        () => selectSection(hasPlatformModel ? 'financials' : 'records'),
      ),
    ]);
  }

  // ignore: unused_element
  Widget researchMetricStrip() => LayoutBuilder(
    builder: (_, bounds) => Wrap(
      spacing: 12,
      runSpacing: 0,
      children: [
        for (final m in asList(company?['metrics']))
          SizedBox(
            width: bounds.maxWidth >= 900
                ? (bounds.maxWidth - 36) / 4
                : bounds.maxWidth >= 560
                ? (bounds.maxWidth - 12) / 2
                : bounds.maxWidth,
            child: card([
              label(
                '${metricName(text(m['key']))}${m['key'] == 'revenueGrowth' ? '' : ' · TTM'}',
                '${metricName(text(m['key']))}${m['key'] == 'revenueGrowth' ? '' : ' · TTM'}',
                size: 12,
              ),
              const SizedBox(height: 10),
              Text(pct(m['value']), style: deskHeading(28)),
              const SizedBox(height: 8),
              label(
                'Prior ${pct(m['previous'])} · ${text(m['period'])}',
                '前期 ${pct(m['previous'])} · ${text(m['period'])}',
                size: 11,
              ),
              const SizedBox(height: 10),
              label(
                m['historicalPercentile'] == null
                    ? 'History percentile unavailable'
                    : 'History percentile ${pct(m['historicalPercentile'])} · n=${m['sampleCount']}',
                m['historicalPercentile'] == null
                    ? '历史分位不可用'
                    : '历史分位 ${pct(m['historicalPercentile'])} · 样本 ${m['sampleCount']}',
                size: 10,
              ),
            ]),
          ),
      ],
    ),
  );

  // ignore: unused_element
  Widget researchGuidance() {
    final evidence = asList(asMap(company?['guidance'])['evidence']);
    final audit = asMap(asMap(company?['guidance'])['audit']);
    return card([
      Row(
        children: [
          const Icon(Icons.format_quote, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              w('What management said', '管理层说了什么'),
              style: deskHeading(18),
            ),
          ),
          researchTag('${evidence.length}', p.muted),
        ],
      ),
      const SizedBox(height: 10),
      label(
        'Stored excerpts · Evidence is not automatically an accepted model input.',
        '已存原文摘录 · 引文不自动等于模型采纳的输入。',
        size: 11,
      ),
      if (audit.isNotEmpty) ...[
        const SizedBox(height: 8),
        label(
          '${audit['quantifiedCount']} quantified excerpts · ${audit['researchOnlyCount']} context-only excerpts · stored-source checks',
          '${audit['quantifiedCount']} 条量化证据 · ${audit['researchOnlyCount']} 条仅供研究 · 已存原文检查',
          size: 11,
        ),
        if (audit['status'] == 'review_required')
          label(
            'Source or model-reference issues remain. These excerpts do not certify the published valuation.',
            '仍有来源或模型引用问题；这些摘录不代表平台估值已通过审计。',
            color: p.secondary,
            size: 12,
          ),
      ],
      TextButton.icon(
        onPressed: () => selectSection('financials'),
        icon: const Icon(Icons.history, size: 16),
        label: Text(w('Quarterly earnings calls & analysis', '按季度查看财报会与分析')),
      ),
      if (evidence.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: label(
            'No guidance evidence attached to this model node. This does not prove management issued no guidance.',
            '此模型节点未附指引证据，不代表管理层未发布指引。',
            size: 12,
          ),
        ),
      for (final e in evidence.take(2)) researchQuote(e),
      if (evidence.length > 2)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            w('All ${evidence.length} excerpts', '全部 ${evidence.length} 条摘录'),
            style: const TextStyle(fontSize: 12),
          ),
          children: [for (final e in evidence.skip(2)) researchQuote(e)],
        ),
    ]);
  }

  Widget researchQuote(Map<String, dynamic> e) => Container(
    margin: const EdgeInsets.only(top: 16),
    padding: const EdgeInsets.only(left: 14),
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: p.accent.withValues(alpha: .5), width: 2),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (e['disposition'] != null)
          label(
            e['disposition'] == 'quantified_evidence'
                ? 'Quantified evidence · ${e['targetYear'] == null ? 'target year unresolved' : 'target ${e['targetYear']}'} · not automatically a forecast input'
                : 'Research context only · not an approved company forecast',
            e['disposition'] == 'quantified_evidence'
                ? '量化证据 · ${e['targetYear'] == null ? '目标年份未明确' : '目标 ${e['targetYear']} 年'} · 不自动作为预测输入'
                : '仅供研究参考 · 不是已采纳的公司预测',
            color: e['disposition'] == 'quantified_evidence'
                ? p.accent
                : p.secondary,
            size: 11,
          ),
        SelectableText(
          text(e['excerpt'], text(e['quote'])),
          style: TextStyle(color: p.text, fontSize: 14, height: 1.55),
        ),
        const SizedBox(height: 8),
        label(
          '${text(e['speaker'])} · ${text(e['observedAt'])}',
          '${text(e['speaker'])} · ${text(e['observedAt'])}',
          size: 11,
        ),
        if (Uri.tryParse(text(e['url']))?.scheme == 'https')
          TextButton.icon(
            onPressed: () => openBrowserPath(text(e['url'])),
            icon: const Icon(Icons.open_in_new, size: 13),
            label: Text(w('Open evidence', '打开证据来源')),
          ),
      ],
    ),
  );

  // ignore: unused_element
  Widget researchHolders() {
    final holders = orderedDisclosedHolders(asList(company?['provenance']), '');
    return card([
      Text(w('Who else is here?', '还有谁持有？'), style: deskHeading(18)),
      const SizedBox(height: 10),
      label(
        'Bounded 13F extracts · Delayed disclosures, not confirmed trades. Not a complete ownership register.',
        '有限 13F 摘录 · 滞后披露，不是确认交易；并非完整持有人名册。',
        size: 11,
      ),
      for (final g in holders.take(4))
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: holderAvatar(g, 36),
          title: Text(text(g['name']), style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            '${w('Held', '持仓截至')} ${g['reportDate']} · ${w('Filed', '披露')} ${g['availableAt']}',
            style: TextStyle(color: p.muted, fontSize: 11),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => unawaited(openHolderGuru(g)),
        ),
      if (holders.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: label(
            'No matching holder in this extract. This does not mean no Guru owns it.',
            '摘录中没有匹配持有人，不代表没有大佬持有。',
            size: 12,
          ),
        ),
      button('All holders & disclosure details', '全部持有人与披露详情', () {
        selectSection('financials');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = researchHoldersKey.currentContext;
          if (mounted && section == 'financials' && target != null) {
            Scrollable.ensureVisible(
              target,
              alignment: .05,
              duration: const Duration(milliseconds: 220),
            );
          }
        });
      }),
    ]);
  }

  // ignore: unused_element
  Widget researchCountercase() {
    final m = asList(
      company?['metrics'],
    ).where((m) => m['key'] == 'fcfMargin').firstOrNull;
    final declining =
        nullableNumber(m?['change']) != null && number(m?['change']) < 0;
    return card([
      Row(
        children: [
          Icon(Icons.rule_outlined, color: p.secondary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              w('Challenge the case', '检验反例'),
              style: deskHeading(18),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      label(
        declining ? 'Cash conversion weakened' : 'Can cash conversion hold?',
        declining ? '现金转化率下降' : '现金转化率能维持吗？',
        color: p.secondary,
        size: 14,
      ),
      const SizedBox(height: 8),
      label(
        declining
            ? 'TTM FCF margin moved from ${pct(m?['previous'])} to ${pct(m?['value'])}. Check timing, working capital and capex before extrapolating growth.'
            : 'Compare cash generation with reported growth. A rising valuation is not evidence that cash conversion will persist.',
        declining
            ? 'TTM 自由现金流率由 ${pct(m?['previous'])} 降至 ${pct(m?['value'])}。外推增长前，核查时点、营运资本与资本支出。'
            : '对比现金创造与报告增长，估值上升不能证明现金转化能力持续。',
        size: 12,
      ),
      const SizedBox(height: 16),
      label('What is not verified here', '这里尚未验证的内容', size: 13, color: p.text),
      const SizedBox(height: 8),
      label(
        'Peer cohort, ROIC and operating KPIs. Do not mistake missing coverage for a clean risk assessment.',
        '同行样本、ROIC 与运营 KPI 尚未验证。数据缺失不代表风险已排除。',
        size: 12,
      ),
      const SizedBox(height: 12),
      button(
        'Inspect the cash-flow evidence',
        '检查现金流证据',
        () => selectSection('financials'),
      ),
    ]);
  }

  // ignore: unused_element
  Widget researchModelCard() {
    final published = asMap(company?['published']);
    if (!researchHasPlatformModel) {
      return card([
        Text(w('Model coverage', '模型覆盖'), style: deskHeading(18)),
        const SizedBox(height: 12),
        label(
          'No platform valuation is stored for this company at the research cutoff. Financial facts, filings, holdings and research records remain available; no value or model gap is inferred.',
          '研究截止日暂无该公司的平台估值。财务事实、公告、持仓和研究记录仍可使用；系统不会推断估值或模型价差。',
          size: 12,
          color: p.secondary,
        ),
        const SizedBox(height: 12),
        button(
          'Save a research question',
          '保存研究问题',
          () => selectSection('records'),
        ),
      ]);
    }
    return card([
      Text(w('Know what the model says', '理解模型口径'), style: deskHeading(18)),
      const SizedBox(height: 14),
      label(
        text(published['formula'], w('Formula unavailable', '公式不可用')),
        text(published['formula'], w('Formula unavailable', '公式不可用')),
        size: 12,
      ),
      const SizedBox(height: 16),
      label('Standalone DCF component', '独立 DCF 部分', size: 11),
      const SizedBox(height: 6),
      Text(money(published['dcf']), style: deskHeading(26)),
      const SizedBox(height: 10),
      label(
        'The DCF component is not the published blended value. Market price is comparison-only.',
        '独立 DCF 部分不等于已发布综合估值。市场价格仅作比较。',
        size: 11,
      ),
      const SizedBox(height: 12),
      label(
        'Historical PIT replay · Reconstructed with the stored model version, not a contemporaneous recommendation.',
        '历史 PIT 回放 · 使用已存模型版本重建，并非当时发布的投资建议。',
        size: 11,
      ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          w('Model version', '模型版本'),
          style: const TextStyle(fontSize: 12),
        ),
        children: [
          SelectableText(
            text(published['modelVersion'], '—'),
            style: TextStyle(color: p.muted, fontSize: 11),
          ),
        ],
      ),
      if (assumptions.isEmpty) ...[
        const SizedBox(height: 12),
        label(
          'An editable parent FCFE scenario is not enabled for this snapshot. You can inspect the released model and save a watch.',
          '此快照未启用可编辑的母公司 FCFE 情景，可检查已发布模型并保存观察。',
          size: 12,
          color: p.secondary,
        ),
      ],
      const SizedBox(height: 8),
      TextButton.icon(
        onPressed: showMethodology,
        icon: const Icon(Icons.info_outline, size: 15),
        label: Text(w('Sources & methodology', '来源与方法')),
      ),
    ]);
  }

  // Retained for replaying legacy read-only decision records.
  // ignore: unused_element
  Widget researchReadOnlyDecision() => card([
    title('Keep the idea. Do not force a decision.', '保留线索，不强行决策。'),
    label(
      'A saved investment decision requires a supported, saved scenario. This snapshot is read-only; save its dated evidence to watch and revisit it later.',
      '保存投资决策需要受支持且已保存的情景。当前快照只读，可先保存带日期的观察，之后复核。',
    ),
    const SizedBox(height: 18),
    Align(alignment: Alignment.centerLeft, child: researchWatchButton()),
    const SizedBox(height: 12),
    Align(
      alignment: Alignment.centerLeft,
      child: button(
        'Inspect published model',
        '检查平台模型',
        () => selectSection('value'),
      ),
    ),
  ]);
}
