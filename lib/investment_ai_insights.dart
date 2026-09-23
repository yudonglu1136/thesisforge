part of 'main.dart';

/// Sorting only changes the displayed rows. Server peer ranks and scores remain
/// attached to their original, unfiltered comparison universe.
List<Map<String, dynamic>> filterAiInsightsCompanies(
  List<Map<String, dynamic>> rows, {
  String group = 'all',
  String sector = '',
  String query = '',
  String sort = 'growth',
}) {
  final term = query.trim().toLowerCase();
  final metric = switch (sort) {
    'growth' => 'growthScore',
    'quality' => 'qualityScore',
    'composite' => 'compositeScore',
    _ => sort,
  };
  final visible = rows.where((row) {
    return (group == 'all' || row['group'] == group) &&
        (sector.isEmpty || row['sector'] == sector) &&
        (term.isEmpty ||
            '${row['ticker']} ${row['name']}'.toLowerCase().contains(term));
  }).toList();
  visible.sort((a, b) {
    final x = nullableNumber(a[metric]), y = nullableNumber(b[metric]);
    if (x == null && y != null) return 1;
    if (y == null && x != null) return -1;
    final result = (y ?? 0).compareTo(x ?? 0);
    return result != 0
        ? result
        : text(a['ticker']).compareTo(text(b['ticker']));
  });
  return visible;
}

String aiInsightsPercent(dynamic value, {bool signed = false}) {
  final n = nullableNumber(value);
  return n == null
      ? '—'
      : '${signed && n > 0 ? '+' : ''}${(n * 100).toStringAsFixed(1)}%';
}

String aiInsightsAmount(dynamic value) {
  final n = nullableNumber(value);
  if (n == null) return '—';
  final absolute = n.abs();
  final (divisor, suffix) = absolute >= 1e12
      ? (1e12, 'T')
      : absolute >= 1e9
      ? (1e9, 'B')
      : absolute >= 1e6
      ? (1e6, 'M')
      : absolute >= 1e3
      ? (1e3, 'K')
      : (1.0, '');
  return '${n < 0 ? '−' : ''}\$${(absolute / divisor).toStringAsFixed(absolute / divisor >= 100 ? 0 : 1)}$suffix';
}

class AiInsightsPanel extends StatefulWidget {
  const AiInsightsPanel({
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
  State<AiInsightsPanel> createState() => _AiInsightsPanelState();
}

class _AiInsightsPanelState extends State<AiInsightsPanel> {
  Map<String, dynamic>? data, comparison;
  String quarter = '', tab = 'overview', metric = 'yoy';
  String group = 'all', sector = '', sort = 'growth';
  String selectedTicker = '';
  int window = 8, requestSerial = 0, comparisonSerial = 0;
  bool loading = true,
      failed = false,
      comparing = false,
      comparisonFailed = false;
  List<String> tickers = ['CRDO', 'ALAB'];
  final search = TextEditingController();
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  Map<String, dynamic> get snapshot => asMap(data?['context']);
  String get snapshotId =>
      text(snapshot['snapshotId'], text(data?['snapshotId']));
  List<Map<String, dynamic>> get companies => asList(data?['companies']);
  List<Map<String, dynamic>> get series => asList(data?['series']);
  List<Map<String, dynamic>> get matches => filterAiInsightsCompanies(
    companies,
    group: group,
    sector: sector,
    query: search.text,
    sort: sort,
  );
  Color seriesColor(String id) => switch (id) {
    'capex' => p.accent,
    'hardware' => const Color(0xFF7FAAFF),
    _ => p.secondary,
  };
  String seriesLabel(String id) => switch (id) {
    'capex' => w('Capital investment', '资本投入'),
    'hardware' => w('Hardware basket revenue', '硬件组公司收入'),
    _ => w('Software basket revenue', '软件组公司收入'),
  };
  String localized(dynamic value, [String fallback = '']) {
    final label = value is String
        ? value
        : text(asMap(value)[context.isEnglish ? 'en' : 'zh'], fallback);
    return switch (label) {
      'compute_semiconductors' => w('Compute & semiconductors', '计算与芯片'),
      'memory_storage' => w('Memory & storage', '存储'),
      'foundry_equipment' => w('Foundry & equipment', '代工与设备'),
      'network_optical_interconnect' => w('Networks & interconnect', '网络与光互连'),
      'servers_manufacturing' => w('Servers & manufacturing', '服务器与制造'),
      'power_cooling' => w('Power & cooling', '电力与散热'),
      'data_ai_platforms' => w('Data & AI platforms', '数据与 AI 平台'),
      'enterprise_workflow' => w('Enterprise workflow', '企业工作流'),
      'cloud_observability' => w('Cloud & observability', '云工具与可观测'),
      'mixed_cloud_software' => w('Cloud & software mix', '云与软件混合业务'),
      'security' => w('Security', '安全'),
      'applications' => w('Applications', '应用'),
      'eda_design_tools' => w('EDA & design tools', 'EDA 与设计工具'),
      'gpu_cloud' => w('GPU cloud', 'GPU 云'),
      'datacenter_hosting' => w('Data center hosting', '数据中心托管'),
      'data_center_hosting' => w('Data center hosting', '数据中心托管'),
      'mining_to_ai_transition' => w('Mining / AI transition', '矿业 / AI 转型'),
      _ => label,
    };
  }

  TextStyle style([double size = 14, bool bold = false, Color? color]) =>
      TextStyle(
        fontSize: size,
        height: 1.4,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        color: color ?? p.text,
      );

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSelection;
    quarter = text(initial['quarter']);
    tab = const {'overview', 'companies', 'compare'}.contains(initial['tab'])
        ? text(initial['tab'])
        : 'overview';
    metric = initial['metric'] == 'qoq' ? 'qoq' : 'yoy';
    final requestedWindow = int.tryParse(text(initial['window']));
    if (const {8, 12, 20}.contains(requestedWindow)) window = requestedWindow!;
    group = const {'all', 'hardware', 'software'}.contains(initial['group'])
        ? text(initial['group'])
        : 'all';
    sector = text(initial['sector']);
    sort =
        const {
          'growth',
          'quality',
          'composite',
          'revenueYoY',
          'revenueQoQ',
          'yoyAcceleration',
          'revenue',
        }.contains(initial['sort'])
        ? text(initial['sort'])
        : 'growth';
    search.text = text(initial['query']);
    selectedTicker = text(initial['selected']);
    final incomingTickers = initial['tickers'];
    if (incomingTickers is List && incomingTickers.isNotEmpty) {
      tickers = incomingTickers.map((v) => text(v)).toSet().take(4).toList();
    }
    unawaited(load(pinnedSnapshot: text(initial['snapshotId'])));
  }

  @override
  void didUpdateWidget(covariant AiInsightsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOf != widget.asOf || oldWidget.api != widget.api) {
      final cutoff = DateTime.tryParse(widget.asOf);
      if (cutoff != null) {
        final latestQuarter = '${cutoff.year}Q${((cutoff.month - 1) ~/ 3) + 1}';
        // Keep valid incomplete quarters, but drop a future-dated selection
        // when the user moves the global cutoff into an earlier year.
        if (quarter.replaceAll('-', '').compareTo(latestQuarter) > 0) {
          quarter = '';
        }
      }
      unawaited(load());
    }
  }

  @override
  void dispose() {
    requestSerial++;
    comparisonSerial++;
    search.dispose();
    super.dispose();
  }

  void remember() => widget.onSelection?.call({
    'quarter': quarter,
    'window': window,
    'tab': tab,
    'metric': metric,
    'group': group,
    'sector': sector,
    'sort': sort,
    'query': search.text,
    'selected': selectedTicker,
    'tickers': [...tickers],
    'snapshotId': snapshotId,
  });

  String endpoint(
    String suffix, {
    bool pinned = true,
    Map<String, String>? extra,
  }) {
    final parameters = <String, String>{
      'asOf': widget.asOf,
      if (quarter.isNotEmpty) 'quarter': quarter,
      'window': '$window',
      if (pinned && snapshotId.isNotEmpty) 'snapshotId': snapshotId,
      ...?extra,
    };
    return Uri(
      path: '/api/investment/ai-insights$suffix',
      queryParameters: parameters,
    ).toString();
  }

  Future<void> load({String? pinnedSnapshot}) async {
    final serial = ++requestSerial, date = widget.asOf;
    comparisonSerial++;
    setState(() {
      loading = true;
      failed = false;
      data = null;
      comparison = null;
      comparing = false;
    });
    try {
      final response = await widget.api.getJson(
        endpoint(
          '',
          pinned: false,
          extra: pinnedSnapshot != null && pinnedSnapshot.isNotEmpty
              ? {'snapshotId': pinnedSnapshot}
              : null,
        ),
      );
      final ctx = asMap(response['context']);
      if (text(ctx['asOf'], text(response['asOf'])) != date ||
          text(ctx['snapshotId'], text(response['snapshotId'])).isEmpty ||
          (pinnedSnapshot != null &&
              pinnedSnapshot.isNotEmpty &&
              text(ctx['snapshotId'], text(response['snapshotId'])) !=
                  pinnedSnapshot)) {
        throw StateError('Mismatched analysis snapshot');
      }
      if (!mounted || serial != requestSerial) return;
      setState(() {
        data = response;
        quarter = text(ctx['quarter'], text(response['selectedQuarter']));
        if (!asList(
          response['companies'],
        ).any((row) => row['ticker'] == selectedTicker)) {
          selectedTicker = text(
            asList(
              response['rankings'] is Map
                  ? asMap(response['rankings'])['composite']
                  : null,
            ).firstOrNull?['ticker'],
            text(asList(response['companies']).firstOrNull?['ticker']),
          );
        }
        loading = false;
      });
      remember();
      if (tab == 'compare') unawaited(loadComparison());
    } catch (_) {
      if (!mounted || serial != requestSerial) return;
      setState(() {
        failed = true;
        loading = false;
      });
    }
  }

  Future<Map<String, dynamic>> getPinned(
    String suffix, {
    Map<String, String>? extra,
  }) async {
    final expected = snapshotId;
    final result = await widget.api.getJson(endpoint(suffix, extra: extra));
    if (expected.isEmpty ||
        expected != snapshotId ||
        text(
              asMap(result['context'])['snapshotId'],
              text(result['snapshotId']),
            ) !=
            expected) {
      throw StateError('Analysis changed; reload the full snapshot');
    }
    return result;
  }

  Future<void> loadComparison() async {
    final serial = ++comparisonSerial;
    if (tickers.length < 2 || data == null) {
      setState(() {
        comparison = null;
        comparing = false;
      });
      return;
    }
    setState(() {
      comparing = true;
      comparisonFailed = false;
      comparison = null;
    });
    try {
      final result = await getPinned(
        '/compare',
        extra: {'tickers': tickers.join(',')},
      );
      if (mounted && serial == comparisonSerial) {
        setState(() => comparison = result);
      }
    } catch (_) {
      if (mounted && serial == comparisonSerial) {
        setState(() => comparisonFailed = true);
      }
    } finally {
      if (mounted && serial == comparisonSerial) {
        setState(() => comparing = false);
      }
    }
  }

  void setTab(String next) {
    setState(() => tab = next);
    remember();
    if (next == 'compare' && comparison == null && !comparing) {
      unawaited(loadComparison());
    }
  }

  void setMetric(String next) {
    setState(() {
      metric = next;
      if (sort == 'revenueYoY' || sort == 'revenueQoQ') {
        sort = next == 'yoy' ? 'revenueYoY' : 'revenueQoQ';
      }
    });
    remember();
  }

  void setQuarter(String next) {
    if (next == quarter) return;
    quarter = next;
    unawaited(load());
  }

  void toggleCompare(String ticker) {
    if (!tickers.contains(ticker) && tickers.length == 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            w(
              'Compare up to four companies. Remove one first.',
              '最多比较四家公司，请先移除一家。',
            ),
          ),
        ),
      );
      return;
    }
    setState(() {
      tickers = tickers.contains(ticker)
          ? tickers.where((t) => t != ticker).toList()
          : [...tickers, ticker];
      comparison = null;
    });
    remember();
    if (tab == 'compare') unawaited(loadComparison());
  }

  Widget panel(List<Widget> children, {Color? border}) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: p.panel,
      border: Border.all(color: border ?? p.border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget caption(String en, String zh) =>
      Text(w(en, zh), style: style(12, false, p.muted));

  Widget title(String en, String zh, {String? hintEn, String? hintZh}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(w(en, zh), style: style(18, true)),
            if (hintEn != null) ...[
              const SizedBox(height: 4),
              caption(hintEn, hintZh ?? hintEn),
            ],
          ],
        ),
      );

  Widget dropdown(
    String label,
    String value,
    Map<String, String> options,
    ValueChanged<String> onChanged, {
    double width = 185,
  }) => SizedBox(
    width: width,
    child: DropdownButtonFormField<String>(
      key: ValueKey('$label:$value'),
      initialValue: options.containsKey(value) ? value : options.keys.first,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        isDense: true,
      ),
      dropdownColor: p.panel,
      style: style(13),
      items: [
        for (final item in options.entries)
          DropdownMenuItem(
            value: item.key,
            child: Text(item.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    ),
  );

  Widget basisToggle() => Wrap(
    spacing: 6,
    children: [
      for (final id in ['yoy', 'qoq'])
        ChoiceChip(
          label: Text(id == 'yoy' ? 'YoY' : w('QoQ · unadjusted', 'QoQ · 未季调')),
          selected: metric == id,
          onSelected: (_) => setMetric(id),
        ),
    ],
  );

  Widget toolbar() {
    final rawQuarters =
        snapshot['availableQuarters'] ?? data?['availableQuarters'];
    final quarters = <String>{
      if (quarter.isNotEmpty) quarter,
      if (rawQuarters is List) ...rawQuarters.map((v) => text(v)),
    }.where((v) => v.isNotEmpty).toList()..sort((a, b) => b.compareTo(a));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 12,
          spacing: 20,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI Insights', style: style(28, true)),
                const SizedBox(height: 4),
                caption(
                  'Follow capital investment, revenue and earnings quality.',
                  '追踪资本投入、营收增长与盈利质量。',
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: showMethodology,
                  icon: const Icon(Icons.info_outline, size: 17),
                  label: Text(w('Methodology & coverage', '口径与覆盖')),
                ),
                if (!loading && data != null)
                  PopupMenuButton<String>(
                    tooltip: w('Export analysis', '导出分析'),
                    onSelected: (value) {
                      if (value == 'png') {
                        showExport();
                      } else {
                        unawaited(exportCsv());
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'png',
                        child: Text(w('English report · PNG', '英文长图 · PNG')),
                      ),
                      PopupMenuItem(
                        value: 'csv',
                        child: Text(w('Company metrics · CSV', '公司指标 · CSV')),
                      ),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: p.border),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.download_outlined,
                            size: 17,
                            color: p.text,
                          ),
                          const SizedBox(width: 8),
                          Text(w('Export', '导出'), style: style(13)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (quarters.isNotEmpty)
              dropdown(
                w('Research quarter', '研究季度'),
                quarter,
                {for (final q in quarters) q: q.replaceAll('-', ' ')},
                setQuarter,
                width: 175,
              ),
            dropdown(
              w('History', '历史区间'),
              '$window',
              {
                '8': w('8 quarters', '8 个季度'),
                '12': w('12 quarters', '12 个季度'),
                '20': w('20 quarters', '20 个季度'),
              },
              (value) {
                window = int.parse(value);
                unawaited(load());
              },
              width: 145,
            ),
            basisToggle(),
            IconButton(
              tooltip: w('Refresh analysis', '刷新分析'),
              onPressed: loading ? null : load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 12),
        caption(
          'Fiscal-quarter aligned · fixed current basket · disclosure-date PIT',
          '按财季对齐 · 当前固定篮子历史研究 · 披露日粒度 PIT',
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final item in [
              ('overview', w('Overview', '总览')),
              ('companies', w('Company rankings', '公司排名')),
              ('compare', w('Compare', '公司对比')),
            ])
              ChoiceChip(
                label: Text(item.$2),
                selected: tab == item.$1,
                onSelected: (_) => setTab(item.$1),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          toolbar(),
          const SizedBox(height: 20),
          if (loading)
            panel([
              LinearProgressIndicator(
                color: p.accent,
                backgroundColor: p.border,
              ),
              const SizedBox(height: 18),
              caption(
                'Loading one consistent analysis snapshot…',
                '正在载入同一版本的分析快照…',
              ),
            ])
          else if (failed)
            panel([
              title('AI Insights is unavailable', 'AI Insights 暂不可用'),
              caption(
                'The current snapshot could not be loaded. Retry after the data sync finishes.',
                '无法载入当前快照，请在数据同步完成后重试。',
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: load,
                  icon: const Icon(Icons.refresh),
                  label: Text(w('Retry', '重试')),
                ),
              ),
            ])
          else if (data != null) ...[
            if (tab == 'overview') overview(constraints.maxWidth),
            if (tab == 'companies') companyRankings(),
            if (tab == 'compare') compareView(),
            const SizedBox(height: 18),
            snapshotFooter(),
          ],
        ],
      );
    },
  );

  Widget summaryCards(double width) {
    final columns = width >= 850
        ? 3
        : width >= 570
        ? 2
        : 1;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final id in ['capex', 'hardware', 'software'])
          SizedBox(
            width: (width - 12 * (columns - 1)) / columns,
            child: summaryCard(id, asMap(asMap(data?['summary'])[id])),
          ),
      ],
    );
  }

  Widget summaryCard(String id, Map<String, dynamic> summary) {
    final coverage = asMap(summary['coverage']);
    final known = '${coverage['disclosed'] ?? 0}/${coverage['expected'] ?? 0}';
    return panel([
      Row(
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              color: seriesColor(id),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(seriesLabel(id), style: style(13, true, p.muted)),
          ),
        ],
      ),
      const SizedBox(height: 15),
      Text(aiInsightsAmount(summary['amount']), style: style(30, true)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 18,
        runSpacing: 7,
        children: [
          for (final basis in ['yoy', 'qoq'])
            Text(
              '${basis == 'yoy' ? 'YoY' : 'QoQ'}  ${aiInsightsPercent(summary[basis], signed: true)}',
              style: style(13, true, seriesColor(id)),
            ),
        ],
      ),
      const SizedBox(height: 14),
      caption(
        '$known reported · paired YoY ${coverage['yoyComparable'] ?? 0} / QoQ ${coverage['qoqComparable'] ?? 0}',
        '$known 家已披露 · 同比可比 ${coverage['yoyComparable'] ?? 0} / 环比可比 ${coverage['qoqComparable'] ?? 0}',
      ),
      const SizedBox(height: 4),
      caption(
        id == 'capex'
            ? 'Net cash investment proxy · USD'
            : 'Company revenue proxy · USD',
        id == 'capex' ? '净现金投入代理 · 美元' : '集团总收入代理 · 美元',
      ),
    ]);
  }

  Widget overview(double width) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      summaryCards(width),
      const SizedBox(height: 16),
      // Keep the original chart-led overview visible. Company rankings retain
      // their full dedicated tab; the economic context is not an optional panel.
      marketContextContent(width),
    ],
  );

  Widget marketContextContent(double width) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        panel([
          title(
            'How much capital is being deployed?',
            '资本投入有多大？',
            hintEn:
                'Big four + covered neocloud · click a bar to inspect that quarter',
            hintZh: '四大科技 + 已覆盖 neocloud · 点击柱状图研究该季',
          ),
          legend([
            ('Big four', '四大科技', p.accent),
            ('Neocloud', 'Neocloud', const Color(0xFF648F96)),
          ]),
          const SizedBox(height: 8),
          _AiInsightsChart(
            palette: p,
            labels: [for (final row in series) text(row['quarter'])],
            series: [
              _AiChartSeries(w('Big four', '四大科技'), p.accent, [
                for (final row in series)
                  nullableNumber(
                    asMap(asMap(row['capex'])['breakdown'])['big4'],
                  ),
              ]),
              _AiChartSeries('Neocloud', const Color(0xFF648F96), [
                for (final row in series)
                  nullableNumber(
                    asMap(asMap(row['capex'])['breakdown'])['neocloud'],
                  ),
              ]),
            ],
            stacked: true,
            percent: false,
            selectedQuarter: quarter,
            onQuarter: setQuarter,
            emptyLabel: w(
              'No disclosed capital investment in this window',
              '该区间暂无已披露资本投入',
            ),
          ),
          accessibleQuarterTable('capex'),
          Material(
            color: Colors.transparent,
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                w('Company contributions · $quarter', '逐公司投入 · $quarter'),
                style: style(13, true),
              ),
              children: [capexTable()],
            ),
          ),
        ]),
        const SizedBox(height: 16),
        panel([
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: 6,
            spacing: 12,
            children: [
              title(
                'Are growth rates moving together?',
                '三条增速是否同频？',
                hintEn: metric == 'yoy'
                    ? 'YoY · growth on matched company pairs'
                    : 'QoQ · unadjusted for seasonality · matched company pairs',
                hintZh: metric == 'yoy'
                    ? 'YoY · 本期与基期成员配对'
                    : 'QoQ · 未季调 · 本期与基期成员配对',
              ),
              basisToggle(),
            ],
          ),
          legend([
            for (final id in ['capex', 'hardware', 'software'])
              (seriesLabel(id), seriesLabel(id), seriesColor(id)),
          ]),
          _AiInsightsChart(
            palette: p,
            labels: [for (final row in series) text(row['quarter'])],
            series: [
              for (final id in ['capex', 'hardware', 'software'])
                _AiChartSeries(seriesLabel(id), seriesColor(id), [
                  for (final row in series)
                    nullableNumber(asMap(row[id])[metric]),
                ]),
            ],
            emptyLabel: w(
              'Not enough comparable reports for growth rates',
              '可比披露不足，暂无法计算增速',
            ),
          ),
          accessibleQuarterTable('growth'),
          const SizedBox(height: 8),
          caption(
            'Each line is a separate basket. Their amounts cannot be added or interpreted as AI return on investment.',
            '三条线是独立样本，金额不可相加，也不能据此计算 AI 投资回报率。',
          ),
        ]),
        const SizedBox(height: 16),
        if (width >= 1080)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: sectorHeatmap()),
              const SizedBox(width: 16),
              Expanded(child: contributions()),
            ],
          )
        else ...[
          sectorHeatmap(),
          const SizedBox(height: 16),
          contributions(),
        ],
        const SizedBox(height: 16),
        observations(),
        const SizedBox(height: 16),
        panel([
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            children: [
              title('Growth meets earnings quality', '增长能否兑现为盈利？'),
              TextButton(
                onPressed: () => setTab('companies'),
                child: Text(w('View all rankings →', '查看全部排名 →')),
              ),
            ],
          ),
          caption(
            'Scores are relative to hardware or software peers; missing inputs never become zero.',
            '分数在硬件或软件同组内比较；缺失输入不计为零。',
          ),
          const SizedBox(height: 12),
          rankingTable(
            filterAiInsightsCompanies(
              companies,
              sort: 'composite',
            ).take(6).toList(),
            compact: true,
          ),
        ]),
      ],
    );
  }

  Widget legend(List<(String, String, Color)> items) => Wrap(
    spacing: 18,
    runSpacing: 6,
    children: [
      for (final item in items)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 14, height: 3, color: item.$3),
            const SizedBox(width: 6),
            Text(w(item.$1, item.$2), style: style(12, false, p.muted)),
          ],
        ),
    ],
  );

  Widget accessibleQuarterTable(String kind) => Material(
    color: Colors.transparent,
    child: ExpansionTile(
      key: ValueKey('ai-quarterly-data-$kind'),
      tilePadding: EdgeInsets.zero,
      title: Text(w('Quarterly data table', '季度数据表'), style: style(12, true)),
      subtitle: Text(
        w('Accessible alternative to the chart', '图表的可访问数据入口'),
        style: style(10, false, p.muted),
      ),
      children: [
        Semantics(
          label: kind == 'capex'
              ? w('Capital investment quarterly values', '资本投入季度数据')
              : w('Quarterly growth values', '季度增速数据'),
          child: scrollTable(
            DataTable(
              horizontalMargin: 0,
              columnSpacing: 22,
              headingTextStyle: style(11, true, p.muted),
              dataTextStyle: style(11),
              columns: [
                DataColumn(label: Text(w('Quarter', '季度'))),
                if (kind == 'capex') ...[
                  DataColumn(label: Text(w('Big four', '四大科技')), numeric: true),
                  const DataColumn(label: Text('Neocloud'), numeric: true),
                  DataColumn(label: Text(w('Total', '合计')), numeric: true),
                ] else ...[
                  DataColumn(
                    label: Text(w('Capital investment', '资本投入')),
                    numeric: true,
                  ),
                  DataColumn(label: Text(w('Hardware', '硬件')), numeric: true),
                  DataColumn(label: Text(w('Software', '软件')), numeric: true),
                ],
              ],
              rows: [
                for (final row in series)
                  DataRow(
                    cells: [
                      DataCell(Text(text(row['quarter']))),
                      if (kind == 'capex') ...[
                        DataCell(
                          Text(
                            aiInsightsAmount(
                              asMap(asMap(row['capex'])['breakdown'])['big4'],
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            aiInsightsAmount(
                              asMap(
                                asMap(row['capex'])['breakdown'],
                              )['neocloud'],
                            ),
                          ),
                        ),
                        DataCell(
                          Text(aiInsightsAmount(asMap(row['capex'])['amount'])),
                        ),
                      ] else ...[
                        for (final id in ['capex', 'hardware', 'software'])
                          DataCell(
                            Text(
                              aiInsightsPercent(
                                asMap(row[id])[metric],
                                signed: true,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget capexTable() => scrollTable(
    DataTable(
      headingTextStyle: style(12, true, p.muted),
      dataTextStyle: style(12),
      horizontalMargin: 0,
      columnSpacing: 22,
      columns: [
        for (final label in [
          w('Company', '公司'),
          w('Group', '分组'),
          w('Net investment', '净投入'),
          'YoY',
          'QoQ',
          w('Period end', '报告期末'),
          w('Disclosed', '披露日'),
          w('Data status', '数据状态'),
        ])
          DataColumn(label: Text(label)),
      ],
      rows: [
        for (final row in asList(data?['capexComposition']))
          DataRow(
            cells: [
              DataCell(Text(text(row['ticker']), style: style(12, true))),
              DataCell(
                Text(
                  row['capexGroup'] == 'big4'
                      ? w('Big four', '四大科技')
                      : localized(row['sector'], 'Neocloud'),
                ),
              ),
              DataCell(Text(aiInsightsAmount(row['amount']))),
              DataCell(Text(aiInsightsPercent(row['yoy'], signed: true))),
              DataCell(Text(aiInsightsPercent(row['qoq'], signed: true))),
              DataCell(Text(text(row['reportperiod'], '—'))),
              DataCell(Text(text(row['datekey'], '—'))),
              DataCell(Text(statusLabel(row['status']))),
            ],
          ),
      ],
    ),
  );

  Widget scrollTable(Widget table) =>
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: table);

  Widget sectorHeatmap() {
    final sectors = asList(data?['sectors']);
    return panel([
      title(
        'Where is growth accelerating?',
        '哪些环节增长更快？',
        hintEn:
            '${metric == 'yoy' ? 'YoY' : 'QoQ'} revenue growth · select a cell to open company rankings',
        hintZh: '${metric == 'yoy' ? 'YoY' : 'QoQ'} 营收增速 · 点选单元格查看公司榜单',
      ),
      if (sectors.isEmpty)
        caption('No comparable sector data for this cutoff.', '该截止日暂无可比环节数据。')
      else
        scrollTable(
          DataTable(
            horizontalMargin: 0,
            columnSpacing: 10,
            headingTextStyle: style(10, false, p.muted),
            dataRowMinHeight: 38,
            dataRowMaxHeight: 46,
            columns: [
              DataColumn(label: Text(w('Sector', '环节'))),
              for (final row in series)
                DataColumn(
                  label: Text(text(row['quarter']).replaceFirst('20', '')),
                ),
            ],
            rows: [
              for (final row in sectors)
                DataRow(
                  cells: [
                    DataCell(
                      SizedBox(
                        width: 120,
                        child: Text(
                          localized(row['label'], text(row['id'])),
                          style: style(11),
                        ),
                      ),
                    ),
                    for (final period in series)
                      DataCell(
                        Builder(
                          builder: (_) {
                            final point = asList(row['series'])
                                .where((v) => v['quarter'] == period['quarter'])
                                .firstOrNull;
                            final value = nullableNumber(point?[metric]);
                            return InkWell(
                              onTap: () {
                                group = text(row['group'], 'all');
                                sector = text(row['id']);
                                tab = 'companies';
                                sort = metric == 'yoy'
                                    ? 'revenueYoY'
                                    : 'revenueQoQ';
                                if (period['quarter'] != quarter) {
                                  setQuarter(text(period['quarter']));
                                } else {
                                  setState(() {});
                                  remember();
                                }
                              },
                              child: Container(
                                width: 58,
                                height: 30,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: value == null
                                      ? p.card
                                      : (value >= 0 ? p.accent : p.secondary)
                                            .withValues(
                                              alpha:
                                                  .08 +
                                                  math.min(value.abs(), 1) *
                                                      .32,
                                            ),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  aiInsightsPercent(value),
                                  style: style(10, true),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
    ]);
  }

  List<Map<String, dynamic>> contributionRows(String id) {
    final summary = asMap(asMap(data?['summary'])[id]);
    final rows = [
      ...asList(asMap(summary['${metric}Comparison'])['contributions']),
    ];
    rows.sort(
      (a, b) => (nullableNumber(b['delta']) ?? 0).abs().compareTo(
        (nullableNumber(a['delta']) ?? 0).abs(),
      ),
    );
    return rows;
  }

  Widget contributions() => panel([
    title(
      'Who added the most revenue?',
      '谁贡献了最多收入增量？',
      hintEn:
          '${metric == 'yoy' ? 'YoY' : 'QoQ'} dollar changes on comparable company pairs',
      hintZh: '${metric == 'yoy' ? 'YoY' : 'QoQ'} 可比公司美元收入增量',
    ),
    for (final id in ['hardware', 'software']) ...[
      Text(seriesLabel(id), style: style(12, true, seriesColor(id))),
      const SizedBox(height: 8),
      if (contributionRows(id).isEmpty)
        caption('No comparable pairs available.', '暂无可比公司对。'),
      for (final row in contributionRows(id).take(4))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              SizedBox(
                width: 60,
                child: Text(text(row['ticker']), style: style(12, true)),
              ),
              Expanded(
                child: Text(
                  aiInsightsAmount(row['delta']),
                  style: style(13, true),
                ),
              ),
              Text(
                pp(row['contribution'] ?? row['growthContribution']),
                style: style(12, false, p.muted),
              ),
            ],
          ),
        ),
      const SizedBox(height: 10),
    ],
    caption(
      'Percentage-point contributions sum to the basket growth rate. Negative contributors are retained.',
      '增速贡献以百分点显示，合计等于样本增速；保留负贡献。',
    ),
  ]);

  Widget observations() {
    final sums = asMap(data?['summary']);
    final capex = nullableNumber(asMap(sums['capex'])[metric]);
    final hw = nullableNumber(asMap(sums['hardware'])[metric]);
    final sw = nullableNumber(asMap(sums['software'])[metric]);
    final comparable = companies
        .where(
          (r) =>
              nullableNumber(r['yoyAcceleration']) != null &&
              asMap(r['comparability'])['growth'] != 'scope_bridge_required' &&
              r['historicalEligibility'] != 'before_first_price_proxy',
        )
        .toList();
    final accelerating = comparable
        .where((r) => number(r['yoyAcceleration']) > 0)
        .length;
    String gap(double a, double b) =>
        '${((a - b) * 100).toStringAsFixed(1)} pp';
    return panel([
      title('This quarter, in context', '本季观察'),
      if (capex != null && hw != null)
        observation(
          Icons.compare_arrows,
          w(
            'Capital investment minus hardware growth: ${gap(capex, hw)}.',
            '资本投入与硬件收入增速差：${gap(capex, hw)}。',
          ),
        ),
      if (hw != null && sw != null)
        observation(
          Icons.stacked_line_chart,
          w(
            'Hardware minus software growth: ${gap(hw, sw)}.',
            '硬件与软件收入增速差：${gap(hw, sw)}。',
          ),
        ),
      if (comparable.isNotEmpty)
        observation(
          Icons.hub_outlined,
          w(
            '$accelerating/${comparable.length} comparable companies have faster revenue YoY than last quarter.',
            '${comparable.length} 家可比公司中，$accelerating 家营收同比增速高于上季。',
          ),
        ),
      if (capex == null && hw == null && sw == null)
        caption(
          'More disclosed comparison periods are needed.',
          '需要更多已披露可比期间。',
        ),
      const SizedBox(height: 6),
      caption(
        'Observed growth gaps describe this sample. They do not establish a lead–lag relationship or causality.',
        '以上是样本的已观察增速差，不能据此认定领先期数或因果关系。',
      ),
    ]);
  }

  Widget observation(IconData icon, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: p.accent),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: style(14))),
      ],
    ),
  );

  String statusLabel(dynamic status) => switch (text(status)) {
    'ready' => w('Available', '已披露'),
    'partial' => w('Partial history', '历史不完整'),
    'missing' => w('Not disclosed', '未披露'),
    'provider_zero_unverified' => w('Zero not verified', '零值未核验'),
    'missing_capex' => w('Missing investment data', '缺少投入数据'),
    'missing_usd_conversion' => w('Missing USD conversion', '缺少美元换算'),
    'net_disposal_inflow' => w('Net disposal inflow', '资产处置净流入'),
    'non_comparable' => w('Not comparable', '不可比'),
    _ => w('Review coverage', '查看覆盖'),
  };

  Widget companyRankings() {
    final sectorRows = asList(
      data?['sectors'],
    ).where((r) => group == 'all' || r['group'] == group);
    final options = {
      '': w('All sectors', '全部环节'),
      for (final s in sectorRows)
        text(s['id']): localized(s['label'], text(s['id'])),
    };
    final rows = matches;
    return panel([
      title(
        'Rank the businesses behind the AI buildout',
        '比较 AI 建设背后的公司',
        hintEn:
            'Revenue growth, GAAP profitability and cash conversion · scores relative to sector peers',
        hintZh: '营收增长、GAAP 盈利与现金兑现 · 分数相对于硬件或软件同组',
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in [
            ('growth', w('Growth', '增长')),
            ('quality', w('Earnings quality', '盈利质量')),
            ('composite', w('Operating composite', '经营综合')),
          ])
            ChoiceChip(
              label: Text(item.$2),
              selected: sort == item.$1,
              onSelected: (_) {
                setState(() => sort = item.$1);
                remember();
              },
            ),
        ],
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 10,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 230,
            child: TextField(
              controller: search,
              onChanged: (_) {
                setState(() {});
                remember();
              },
              decoration: InputDecoration(
                hintText: w('Search company or ticker', '搜索公司或股票代码'),
                prefixIcon: const Icon(Icons.search, size: 18),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          dropdown(
            w('Business group', '业务分组'),
            group,
            {
              'all': w('All companies', '全部公司'),
              'hardware': w('Hardware', '硬件'),
              'software': w('Software', '软件'),
            },
            (value) {
              setState(() {
                group = value;
                sector = '';
              });
              remember();
            },
          ),
          dropdown(w('Sector', '环节'), sector, options, (value) {
            setState(() => sector = value);
            remember();
          }),
          dropdown(
            w('Sort by', '排序'),
            sort,
            {
              'growth': w('Growth score', '增长分'),
              'quality': w('Quality score', '质量分'),
              'composite': w('Composite score', '综合分'),
              'revenueYoY': w('Revenue YoY', '收入 YoY'),
              'revenueQoQ': w('Revenue QoQ', '收入 QoQ'),
              'yoyAcceleration': w('YoY acceleration', 'YoY 增速变化'),
              'revenue': w('Revenue size', '收入规模'),
            },
            (value) {
              setState(() => sort = value);
              remember();
            },
          ),
        ],
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            w(
              '${rows.length} companies · peer ranks stay fixed when filtering',
              '${rows.length} 家公司 · 筛选不改变同组排名',
            ),
            style: style(12, false, p.muted),
          ),
          OutlinedButton.icon(
            onPressed: () => setTab('compare'),
            icon: const Icon(Icons.compare_arrows, size: 17),
            label: Text(
              w('Compare (${tickers.length}/4)', '对比 (${tickers.length}/4)'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: caption(
            'No companies match these filters. Try clearing search or choosing another sector.',
            '没有匹配的公司，请清空搜索或更换环节。',
          ),
        )
      else
        rankingTable(rows),
      const SizedBox(height: 12),
      caption(
        'Raw growth is as reported, not verified organic growth. Missing values stay visible. Scores require complete inputs and eight eligible peers; known scope changes suspend affected scores. QoQ is unadjusted.',
        '原始增速按披露口径，不代表已核实的内生增长。保留缺失数据；评分要求输入齐全且同组至少八家，已知业务范围变化会暂停相关评分。QoQ 未季调。',
      ),
    ]);
  }

  String score(dynamic value) =>
      nullableNumber(value)?.toStringAsFixed(1) ?? '—';
  String pp(dynamic value) => nullableNumber(value) == null
      ? '—'
      : '${number(value) > 0 ? '+' : ''}${(number(value) * 100).toStringAsFixed(1)} pp';
  String peerLabel(Map<String, dynamic> row) =>
      row['group'] == 'software' ? w('Software', '软件') : w('Hardware', '硬件');

  Widget rankingTable(
    List<Map<String, dynamic>> rows, {
    bool compact = false,
  }) => scrollTable(
    DataTable(
      headingTextStyle: style(11, true, p.muted),
      dataTextStyle: style(12),
      horizontalMargin: 0,
      columnSpacing: 22,
      dataRowMinHeight: 60,
      dataRowMaxHeight: 68,
      columns: [
        DataColumn(label: Text(w('Compare', '对比'))),
        DataColumn(label: Text(w('Peer rank', '同组排名')), numeric: true),
        DataColumn(label: Text(w('Company / peer', '公司 / 同组'))),
        DataColumn(label: Text(w('Revenue', '收入')), numeric: true),
        const DataColumn(label: Text('YoY'), numeric: true),
        const DataColumn(label: Text('QoQ'), numeric: true),
        if (!compact)
          DataColumn(label: Text(w('Δ YoY', 'YoY 变化')), numeric: true),
        DataColumn(
          label: Text(w('Op. margin · TTM', '经营利润率 · TTM')),
          numeric: true,
        ),
        DataColumn(
          label: Text(w('FCF margin · TTM', 'FCF 率 · TTM')),
          numeric: true,
        ),
        if (!compact)
          DataColumn(
            label: Text(w('SBC / revenue', 'SBC / 收入')),
            numeric: true,
          ),
        for (final l in [
          w('Growth', '增长分'),
          w('Quality', '质量分'),
          w('Composite', '综合分'),
        ])
          DataColumn(label: Text(l), numeric: true),
        if (!compact) ...[
          DataColumn(label: Text(w('Period end / disclosed', '期末 / 披露日'))),
          DataColumn(label: Text(w('Data status', '数据状态'))),
        ],
      ],
      rows: [
        for (final row in rows)
          DataRow(
            cells: [
              DataCell(
                Checkbox(
                  value: tickers.contains(row['ticker']),
                  semanticLabel: w(
                    'Compare ${row['ticker']}',
                    '比较 ${row['ticker']}',
                  ),
                  onChanged: (_) => toggleCompare(text(row['ticker'])),
                ),
              ),
              DataCell(
                Text(
                  text(
                    asMap(row['rank'])[compact
                        ? 'composite'
                        : const {
                            'growth',
                            'quality',
                            'composite',
                          }.contains(sort)
                        ? sort
                        : 'growth'],
                    '—',
                  ),
                  style: style(12, true, p.muted),
                ),
              ),
              DataCell(
                InkWell(
                  onTap: () => showCompany(row),
                  child: SizedBox(
                    width: 170,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          text(row['ticker']),
                          style: style(13, true, p.accent),
                        ),
                        Text(
                          '${peerLabel(row)} · ${localized(row['sectorLabel'], text(row['sector']))}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style(10, false, p.muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              DataCell(Text(aiInsightsAmount(row['revenue']))),
              DataCell(
                Text(aiInsightsPercent(row['revenueYoY'], signed: true)),
              ),
              DataCell(
                Text(aiInsightsPercent(row['revenueQoQ'], signed: true)),
              ),
              if (!compact) DataCell(Text(pp(row['yoyAcceleration']))),
              DataCell(Text(aiInsightsPercent(row['ttmOperatingMargin']))),
              DataCell(Text(aiInsightsPercent(row['ttmFcfMargin']))),
              if (!compact) DataCell(Text(aiInsightsPercent(row['sbcRatio']))),
              for (final id in ['growth', 'quality', 'composite'])
                DataCell(
                  Tooltip(
                    message: w(
                      'Peer rank ${asMap(row['rank'])[id] ?? '—'} · tap company for score inputs',
                      '同组排名 ${asMap(row['rank'])[id] ?? '—'} · 点击公司查看评分输入',
                    ),
                    child: Text(
                      score(row['${id}Score']),
                      style: style(
                        13,
                        true,
                        id == 'composite' ? p.accent : p.text,
                      ),
                    ),
                  ),
                ),
              if (!compact) ...[
                DataCell(
                  Text(
                    '${text(row['reportperiod'], '—')}\n${text(row['datekey'], '—')}',
                    style: style(10, false, p.muted),
                  ),
                ),
                DataCell(
                  Text(
                    scopeReview(row)
                        ? w('Scope review', '口径待核')
                        : statusLabel(row['status']),
                    style: style(11, false, p.muted),
                  ),
                ),
              ],
            ],
          ),
      ],
    ),
  );

  Widget compareView() {
    final details = asList(comparison?['companies']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        panel([
          title(
            'Compare growth with its cash outcome',
            '把收入增长与现金兑现放在一起看',
            hintEn:
                'Choose two to four companies · every panel uses the same quarter and information cutoff',
            hintZh: '选择 2–4 家公司 · 所有指标使用同一研究季度与信息截止日',
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final symbol in tickers)
                InputChip(
                  label: Text(symbol),
                  onDeleted: () => toggleCompare(symbol),
                ),
              PopupMenuButton<String>(
                tooltip: w('Add company', '添加公司'),
                onSelected: toggleCompare,
                itemBuilder: (_) => [
                  for (final row in companies.where(
                    (r) => !tickers.contains(r['ticker']),
                  ))
                    PopupMenuItem(
                      value: text(row['ticker']),
                      child: Text('${row['ticker']} · ${row['name']}'),
                    ),
                ],
                child: Chip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text(w('Add company', '添加公司')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              for (final preset in [
                ['CRDO', 'ALAB'],
                ['AVGO', 'MRVL'],
                ['LITE', 'COHR'],
                ['MU', 'STX'],
              ])
                TextButton(
                  onPressed: () {
                    setState(() => tickers = [...preset]);
                    remember();
                    unawaited(loadComparison());
                  },
                  child: Text(preset.join(' / ')),
                ),
            ],
          ),
        ]),
        const SizedBox(height: 16),
        if (tickers.length < 2)
          panel([
            caption(
              'Add another company to start comparing.',
              '再添加一家公司即可开始比较。',
            ),
          ])
        else if (comparing)
          panel([
            LinearProgressIndicator(color: p.accent),
            const SizedBox(height: 12),
            caption(
              'Loading the selected companies from this snapshot…',
              '从当前快照载入所选公司…',
            ),
          ])
        else if (comparisonFailed)
          panel([
            caption(
              'The comparison snapshot could not be verified. Reload the full analysis to keep all values consistent.',
              '对比快照无法验证。请刷新整个分析，确保所有数据来自同一版本。',
            ),
            TextButton(
              onPressed: load,
              child: Text(w('Reload analysis', '刷新分析')),
            ),
          ])
        else if (details.isNotEmpty) ...[
          panel([
            title('Revenue momentum', '收入增长动能'),
            basisToggle(),
            const SizedBox(height: 8),
            legend([
              for (var i = 0; i < details.length; i++)
                (
                  text(asMap(details[i]['company'])['ticker']),
                  text(asMap(details[i]['company'])['ticker']),
                  compareColor(i),
                ),
            ]),
            _AiInsightsChart(
              palette: p,
              labels: [for (final row in series) text(row['quarter'])],
              series: [
                for (var i = 0; i < details.length; i++)
                  _AiChartSeries(
                    text(asMap(details[i]['company'])['ticker']),
                    compareColor(i),
                    [
                      for (final period in series)
                        nullableNumber(
                          asList(details[i]['history'])
                              .where(
                                (row) => row['quarter'] == period['quarter'],
                              )
                              .firstOrNull?[metric == 'yoy'
                              ? 'revenueYoY'
                              : 'revenueQoQ'],
                        ),
                    ],
                  ),
              ],
              emptyLabel: w(
                'Comparable history is not yet available.',
                '暂无可比历史。',
              ),
            ),
          ]),
          const SizedBox(height: 16),
          panel([
            title('Growth, profitability and cash generation', '增长、盈利与现金产生'),
            compareMetrics(details),
            const SizedBox(height: 10),
            caption(
              'A higher growth rate alone does not establish better earnings quality. Open a company to inspect the inputs.',
              '更高增速不等于更好盈利质量。点击公司可检查评分输入。',
            ),
          ]),
        ],
      ],
    );
  }

  Color compareColor(int index) => [
    p.accent,
    const Color(0xFF7FAAFF),
    p.secondary,
    const Color(0xFFC79AF5),
  ][index % 4];

  Widget compareMetrics(List<Map<String, dynamic>> details) {
    final rows = [for (final detail in details) asMap(detail['company'])];
    final metrics = <(String, String, String)>[
      ('revenue', w('Quarterly revenue', '当季收入'), 'money'),
      ('revenueYoY', w('Revenue YoY', '收入 YoY'), 'pct'),
      ('revenueQoQ', w('Revenue QoQ · unadjusted', '收入 QoQ · 未季调'), 'pct'),
      ('yoyAcceleration', w('YoY acceleration', 'YoY 增速变化'), 'pp'),
      (
        'ttmOperatingMargin',
        w('GAAP operating margin · TTM', 'GAAP 经营利润率 · TTM'),
        'pct',
      ),
      ('ttmFcfMargin', w('FCF margin · TTM', 'FCF 率 · TTM'), 'pct'),
      ('sbcRatio', w('SBC / revenue · TTM', 'SBC / 收入 · TTM'), 'pct'),
      ('growthScore', w('Growth score', '增长分'), 'score'),
      ('qualityScore', w('Quality score', '质量分'), 'score'),
      ('compositeScore', w('Operating composite score', '经营综合分'), 'score'),
      ('reportperiod', w('Actual report period end', '实际报告期末'), 'text'),
      ('datekey', w('Disclosed by', '披露日'), 'text'),
    ];
    return scrollTable(
      DataTable(
        horizontalMargin: 0,
        columnSpacing: 34,
        headingTextStyle: style(13, true),
        dataTextStyle: style(12),
        columns: [
          DataColumn(label: Text(w('Metric', '指标'))),
          for (final row in rows)
            DataColumn(
              label: TextButton(
                onPressed: () => showCompany(row),
                child: Text(text(row['ticker'])),
              ),
            ),
        ],
        rows: [
          for (final item in metrics)
            DataRow(
              cells: [
                DataCell(Text(item.$2, style: style(12, false, p.muted))),
                for (final row in rows)
                  DataCell(
                    Text(switch (item.$3) {
                      'money' => aiInsightsAmount(row[item.$1]),
                      'pct' => aiInsightsPercent(row[item.$1]),
                      'pp' => pp(row[item.$1]),
                      'score' => score(row[item.$1]),
                      _ => text(row[item.$1], '—'),
                    }),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  void showCompany(Map<String, dynamic> row) {
    // The full rankings table is the company entry point in the restored layout.
    // Preserve its selection when opening Research, just as the former desk did.
    setState(() => selectedTicker = text(row['ticker']));
    remember();
    final future = getPinned(
      '/companies/${Uri.encodeComponent(text(row['ticker']))}',
    );
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: p.panel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980, maxHeight: 800),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${row['ticker']} · ${row['name']}',
                            style: style(20, true),
                          ),
                          Text(
                            '$quarter · ${widget.asOf}',
                            style: style(12, false, p.muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: w('Close details', '关闭详情'),
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: FutureBuilder<Map<String, dynamic>>(
                    future: future,
                    builder: (_, result) {
                      if (result.hasError) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            caption(
                              'These details could not be verified against the current snapshot. Reload the analysis and try again.',
                              '无法验证详情与当前快照一致。请刷新分析后重试。',
                            ),
                          ],
                        );
                      }
                      if (!result.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final detail = result.data!,
                          company = asMap(detail['company']);
                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            compareMetrics([detail]),
                            if (text(company['scopeWarning']).isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                scopeWarning(text(company['scopeWarning'])),
                                style: style(12, false, p.secondary),
                              ),
                            ],
                            if (scopeReview(company)) ...[
                              const SizedBox(height: 8),
                              caption(
                                'Reported growth includes a business-scope change. Comparable growth and affected scores require a documented bridge.',
                                '报告增速涉及业务范围变化，可比增速与相关评分需先建立已披露的口径桥接。',
                              ),
                            ],
                            const SizedBox(height: 20),
                            title('How the scores are built', '评分如何计算'),
                            scoreBreakdown(company),
                            const SizedBox(height: 20),
                            title('Reported facts and provenance', '已披露事实与来源'),
                            evidenceTable(asList(detail['evidence'])),
                            const SizedBox(height: 14),
                            for (final period in asList(
                              detail['comparisonEvidence'],
                            ).where((period) => period['role'] != 'current'))
                              ExpansionTile(
                                tilePadding: EdgeInsets.zero,
                                title: Text(
                                  w(
                                    '${period['quarter']} · comparison / TTM source facts',
                                    '${period['quarter']} · 基期 / TTM 来源事实',
                                  ),
                                  style: style(12, true),
                                ),
                                children: [
                                  evidenceTable(asList(period['facts'])),
                                ],
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () {
                        toggleCompare(text(row['ticker']));
                        Navigator.of(dialogContext).pop();
                      },
                      child: Text(
                        tickers.contains(row['ticker'])
                            ? w('Remove from compare', '移出对比')
                            : w('Add to compare', '加入对比'),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: () {
                        remember();
                        Navigator.of(dialogContext).pop();
                        widget.onCompany(text(row['ticker']), 'evidence');
                      },
                      icon: const Icon(Icons.north_east, size: 16),
                      label: Text(w('Open Research', '打开 Research')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget scoreBreakdown(Map<String, dynamic> company) {
    final breakdown = asMap(company['scoreBreakdown']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final type in ['growth', 'quality']) ...[
          Text(
            '${type == 'growth' ? w('Growth', '增长') : w('Earnings quality', '盈利质量')} · ${score(company['${type}Score'])}/100',
            style: style(14, true),
          ),
          const SizedBox(height: 6),
          if (asMap(asMap(company['scoreStatus'])[type])['eligiblePeers'] !=
              null)
            caption(
              '${asMap(asMap(company['scoreStatus'])[type])['eligiblePeers']} eligible ${text(company['group'])} peers',
              '${asMap(asMap(company['scoreStatus'])[type])['eligiblePeers']} 家${peerLabel(company)}合格同组公司',
            ),
          if (breakdown[type] is List)
            scoreInputTable(asList(breakdown[type]))
          else if (breakdown[type] is Map)
            scoreInputTable(asList(asMap(breakdown[type])['components'])),
          if (nullableNumber(company['${type}Score']) == null)
            caption(
              'Score unavailable: incomplete inputs, insufficient peers or a comparability review.',
              '暂无评分：输入不全、可比同组不足或需检查口径。',
            ),
          for (final reason
              in (asMap(asMap(company['scoreStatus'])[type])['reasons']
                      as List? ??
                  []))
            Text(
              scoreReason(text(reason)),
              style: style(11, false, p.secondary),
            ),
          const SizedBox(height: 12),
        ],
        Text(
          w(
            'Composite = 50% × growth + 50% × earnings quality',
            '综合分 = 50% × 增长分 + 50% × 盈利质量分',
          ),
          style: style(13, true, p.accent),
        ),
        const SizedBox(height: 6),
        caption(
          'Percentile ranks use the full eligible peer group, not your current search results. Missing required inputs are not reweighted.',
          '百分位使用完整合格同组，不随搜索变化；必要输入缺失时，不对剩余权重重新分配。',
        ),
      ],
    );
  }

  Widget scoreInputTable(List<Map<String, dynamic>> rows) => scrollTable(
    DataTable(
      horizontalMargin: 0,
      columnSpacing: 24,
      dataTextStyle: style(11),
      headingTextStyle: style(11, true, p.muted),
      columns: [
        for (final name in [
          w('Input', '输入'),
          w('Raw value', '原始值'),
          w('Weight', '权重'),
          w('Percentile', '百分位'),
          w('Contribution', '得分贡献'),
        ])
          DataColumn(label: Text(name)),
      ],
      rows: [
        for (final row in rows)
          DataRow(
            cells: [
              DataCell(
                Text(
                  '${metricLabel(text(row['metric'], text(row['id'])))}${row['direction'] == 'lower' ? ' ↓' : ' ↑'}',
                ),
              ),
              DataCell(
                Text(
                  const {
                        'yoyAcceleration',
                        'ttmGrossMarginYoYChange',
                      }.contains(row['metric'])
                      ? pp(row['raw'] ?? row['value'] ?? row['rawValue'])
                      : aiInsightsPercent(
                          row['raw'] ?? row['value'] ?? row['rawValue'],
                        ),
                ),
              ),
              DataCell(Text(aiInsightsPercent(row['weight']))),
              DataCell(Text(score(row['percentile']))),
              DataCell(Text(score(row['contribution']))),
            ],
          ),
      ],
    ),
  );

  String scoreReason(String reason) {
    if (reason.startsWith('missing_')) {
      return w(
        'Missing: ${metricLabel(reason.substring(8))}',
        '缺少：${metricLabel(reason.substring(8))}',
      );
    }
    return switch (reason) {
      'insufficient_peer_cohort' => w(
        'Fewer than eight eligible peers',
        '合格同组不足八家',
      ),
      'before_first_price_proxy' => w(
        'Before the first observed public price',
        '早于首次可得公开价格',
      ),
      'net_disposal_inflow_requires_bridge' => w(
        'Net asset-disposal inflow needs a cash-flow bridge',
        '资产处置净流入需要现金流口径桥接',
      ),
      'requires_growth_and_quality_scores' => w(
        'Both growth and quality scores are required',
        '需要同时具备增长分与质量分',
      ),
      'scope_bridge_required' => w(
        'A merger / spin-off scope bridge is required',
        '需要并购 / 拆分业务范围桥接',
      ),
      _ => w('Comparability review required', '需要检查可比性'),
    };
  }

  bool scopeReview(Map<String, dynamic> row) =>
      asMap(row['comparability'])['growth'] == 'scope_bridge_required' ||
      asMap(row['comparability'])['quality'] == 'scope_bridge_required';

  String scopeWarning(String warning) => context.isEnglish
      ? warning
      : switch (warning) {
          'Whole-company revenue includes infrastructure software.' =>
            '集团总收入包含基础设施软件业务。',
          'Semiconductor IP licensing and royalties; not chip manufacturing revenue.' =>
            '收入来自半导体 IP 授权与版税，并非芯片制造销售收入。',
          'Whole-company revenue includes cloud infrastructure and hardware; not pure software or AI revenue.' =>
            '集团总收入包含云基础设施与硬件，不能视为纯软件或 AI 收入。',
          'Group history includes predecessor businesses; current AI classification is retrospective.' =>
            '历史数据包含前身业务，当前 AI 分类属于回溯分类。',
          'Group capital spending includes non-AI and mining operations.' =>
            '集团资本开支包含非 AI 与矿业业务。',
          _ => '业务范围包含混合或历史业务，需核对可比口径。',
        };

  String metricLabel(String metric) => switch (metric) {
    'revenueYoY' => w('Revenue YoY', '收入 YoY'),
    'revenueQoQ' => w('Revenue QoQ', '收入 QoQ'),
    'yoyAcceleration' => w('YoY acceleration', 'YoY 增速变化'),
    'ttmGrossProfitYoY' => w('Gross profit YoY · TTM', '毛利额 YoY · TTM'),
    'ttmOperatingMargin' => w('Operating margin · TTM', '经营利润率 · TTM'),
    'ttmFcfMargin' => w('FCF margin · TTM', 'FCF 率 · TTM'),
    'accrualRatio' => w('Accrual ratio', '应计比率'),
    'sbcRatio' => w('SBC / revenue', 'SBC / 收入'),
    'ttmGrossMarginChange' => w('Gross margin change · TTM', '毛利率变化 · TTM'),
    'ttmGrossMarginYoYChange' => w('Gross margin change · TTM', '毛利率变化 · TTM'),
    'revenue' => w('Revenue', '收入'),
    'revenueusd' => w('Revenue · USD', '收入 · 美元'),
    'capex' => w('Net capital cash flow · source sign', '净资本现金流 · 来源符号'),
    'gp' => w('Gross profit', '毛利'),
    'opinc' => w('Operating income', '经营利润'),
    'netinc' => w('Net income', '净利润'),
    'ncfo' => w('Operating cash flow', '经营现金流'),
    'sbcomp' => w('Share-based compensation', '股份支付'),
    'assets' => w('Assets', '资产'),
    _ => metric,
  };

  Widget evidenceTable(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      return caption(
        'No source detail supplied for this observation.',
        '此观察暂无逐项来源明细。',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        scrollTable(
          DataTable(
            horizontalMargin: 0,
            columnSpacing: 24,
            headingTextStyle: style(11, true, p.muted),
            dataTextStyle: style(11),
            columns: [
              for (final name in [
                w('Fact', '事实'),
                w('Value', '数值'),
                w('Period end', '报告期末'),
                w('Available date', '可得日'),
                w('Source', '来源'),
              ])
                DataColumn(label: Text(name)),
            ],
            rows: [
              for (final row in rows)
                DataRow(
                  cells: [
                    DataCell(Text(metricLabel(text(row['metric'])))),
                    DataCell(
                      Text(
                        row['unit'] == 'ratio'
                            ? aiInsightsPercent(row['value'])
                            : text(row['unit']) == 'USD'
                            ? aiInsightsAmount(row['value'])
                            : '${nullableNumber(row['value'])?.toStringAsFixed(2) ?? '—'} ${text(row['unit'])}',
                      ),
                    ),
                    DataCell(Text(text(row['reportperiod'], '—'))),
                    DataCell(Text(text(row['datekey'], '—'))),
                    DataCell(
                      Tooltip(
                        message: text(row['sourceRevisionId']),
                        child: SelectableText(
                          row['source'] is String
                              ? text(row['source'])
                              : text(
                                  asMap(row['source'])['dataset'],
                                  'Fact OS',
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        caption(
          'Availability uses the provider disclosure date at day precision. Same-day intraday timing is not asserted.',
          '可得时间使用供应商披露日，仅有日期精度，不代表日内可交易时间。',
        ),
      ],
    );
  }

  Future<void> exportCsv() async {
    final fields = [
      'ticker',
      'name',
      'group',
      'sector',
      'quarter',
      'reportperiod',
      'datekey',
      'revenue',
      'revenueYoY',
      'revenueQoQ',
      'yoyAcceleration',
      'ttmOperatingMargin',
      'ttmFcfMargin',
      'sbcRatio',
      'growthScore',
      'qualityScore',
      'compositeScore',
      'status',
      'sourceRevisionId',
    ];
    String cell(dynamic value) => '"${text(value).replaceAll('"', '""')}"';
    final csv = [
      ['asOf', 'snapshotId', ...fields].map(cell).join(','),
      for (final row in companies)
        [
          widget.asOf,
          snapshotId,
          ...fields.map((f) => row[f]),
        ].map(cell).join(','),
    ].join('\r\n');
    try {
      await downloadAiInsightsBytes(
        Uint8List.fromList(utf8.encode(csv)),
        'ai-insights-$quarter-${widget.asOf}.csv',
        'text/csv;charset=utf-8',
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              w(
                'Download could not start. Try the web application.',
                '无法开始下载，请使用网页版重试。',
              ),
            ),
          ),
        );
      }
    }
  }

  void showExport() {
    final reportData = data;
    if (reportData == null) return;
    final captureKey = GlobalKey();
    var saving = false;
    final fileQuarter = quarter, fileAsOf = widget.asOf;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          backgroundColor: p.panel,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1340, maxHeight: 860),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          w('English report · PNG', '英文长图 · PNG'),
                          style: style(18, true),
                        ),
                      ),
                      IconButton(
                        tooltip: w('Close preview', '关闭预览'),
                        onPressed: saving
                            ? null
                            : () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: SingleChildScrollView(
                      key: const ValueKey('ai-insights-export-preview'),
                      // Scale outside the capture boundary: the preview fits
                      // its dialog while PNG keeps all 1280 logical pixels.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: 1280,
                          child: RepaintBoundary(
                            key: captureKey,
                            child: LanguageScope(
                              language: AppLanguage.en,
                              child: _AiInsightsExportReport(
                                data: reportData,
                                asOf: fileAsOf,
                                quarter: fileQuarter,
                                metric: metric,
                                palette: p,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: saving
                          ? null
                          : () async {
                              setDialogState(() => saving = true);
                              try {
                                await WidgetsBinding.instance.endOfFrame;
                                final boundary =
                                    captureKey.currentContext
                                            ?.findRenderObject()
                                        as RenderRepaintBoundary?;
                                if (boundary == null) {
                                  throw StateError('Report is not ready');
                                }
                                final image = await boundary.toImage(
                                  pixelRatio: 2,
                                );
                                try {
                                  final bytes = await image.toByteData(
                                    format: ui.ImageByteFormat.png,
                                  );
                                  if (bytes == null) {
                                    throw StateError(
                                      'Report image is unavailable',
                                    );
                                  }
                                  await downloadAiInsightsBytes(
                                    bytes.buffer.asUint8List(),
                                    'ai-insights-$fileQuarter-$fileAsOf-en.png',
                                    'image/png',
                                  );
                                } finally {
                                  image.dispose();
                                }
                              } catch (_) {
                                if (mounted) {
                                  ScaffoldMessenger.of(
                                    this.context,
                                  ).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        w(
                                          'Image download could not start. Try again in the web application.',
                                          '图片下载失败，请在网页版重试。',
                                        ),
                                      ),
                                    ),
                                  );
                                }
                              } finally {
                                if (context.mounted) {
                                  setDialogState(() => saving = false);
                                }
                              }
                            },
                      icon: Icon(
                        saving
                            ? Icons.hourglass_empty
                            : Icons.download_outlined,
                        size: 17,
                      ),
                      label: Text(
                        saving
                            ? w('Rendering…', '生成中…')
                            : w('Save PNG', '保存 PNG'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void showMethodology() => showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: p.panel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 780),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      w('Methodology & coverage', '口径与覆盖'),
                      style: style(21, true),
                    ),
                  ),
                  IconButton(
                    tooltip: w('Close methodology', '关闭口径说明'),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      methodParagraph(
                        'A defined basket, not the entire AI economy',
                        '固定覆盖篮子，不等于整个 AI 产业',
                        'Capital investment covers MSFT, AMZN, Alphabet once, META and the listed neocloud roster. Hardware and software figures use company total revenue, including non-AI business. Mixed-business issuers remain in one primary group. EDA software belongs to software. Inspect the company table for the complete roster and missing periods.',
                        '资本投入涵盖 MSFT、AMZN、Alphabet（只计一次）、META 与已登记上市 neocloud。硬件和软件采用集团总收入，包含非 AI 业务。混合公司只归属一个主组，EDA 计入软件。完整成员与缺失期间见公司列表。',
                      ),
                      methodParagraph(
                        'Cash investment basis',
                        '现金投入口径',
                        'Net cash investment proxy = − reported capex. Net disposal inflows stay negative; they are never converted with an absolute value. Unverified provider zeros and missing values do not establish complete coverage. Financing leases and commitments are not added without a disclosed bridge.',
                        '净现金投入代理 = − 报告 capex。资产处置净流入保留负号，不取绝对值。未经核验的供应商零值和缺失值不能证明完整覆盖；无披露桥接时，不加融资租赁或未来承诺。',
                      ),
                      methodParagraph(
                        'Comparable growth and contributions',
                        '可比增速与贡献',
                        'Growth = sum(current matched companies) / sum(prior matched companies) − 1. Weights use prior-period amounts. Contribution = (company current − prior) / total prior. Disclosed totals may cover more companies than the YoY or QoQ pair. A non-positive denominator is unavailable, not zero growth.',
                        '增速 = 可比公司本期合计 / 同组基期合计 − 1，权重采用基期金额。单股贡献 =（本期 − 基期）/ 基期总额。已披露总额覆盖可能大于 YoY 或 QoQ 可比成员；分母非正时不计算百分比。',
                      ),
                      methodParagraph(
                        'Point-in-time research',
                        'PIT 历史研究',
                        'The research quarter is separate from the information cutoff. Only eligible reports available by that date are used; unavailable quarters are not replaced by older results. Financial quarters are provider-aligned, with actual period ends retained. This is a current fixed basket viewed historically, not a reconstructed historical investable universe.',
                        '研究季度与信息截止日分别控制。只采用截止日已可得的合格报告，不用旧季度替补未披露期间。按供应商财季对齐，并保留实际期末。当前固定篮子的回溯不等于重建当时可投资股票池。',
                      ),
                      methodParagraph(
                        'Growth score · 0–100',
                        '增长分 · 0–100',
                        '40% revenue YoY + 30% revenue QoQ + 15% change in revenue YoY + 15% TTM gross-profit YoY, each transformed into a peer percentile. QoQ is unadjusted for seasonality.',
                        '40% 收入 YoY + 30% 收入 QoQ + 15% 收入 YoY 变化 + 15% TTM 毛利额 YoY，各输入先转为同组百分位。QoQ 未季调。',
                      ),
                      methodParagraph(
                        'Earnings quality and composite',
                        '盈利质量与综合分',
                        'Quality: 25% GAAP operating margin + 25% FCF margin + 20% lower accrual ratio + 15% lower SBC/revenue + 15% change in gross margin, using TTM where appropriate. Composite is 50% growth + 50% quality. All required inputs and at least eight eligible peers are needed. Known cash-disposal distortions suspend dependent quality scores. Scores do not include price returns or valuation.',
                        '质量：25% GAAP 经营利润率 + 25% FCF 率 + 20% 较低应计比率 + 15% 较低 SBC/收入 + 15% 毛利率变化，适用项目采用 TTM。综合分 = 50% 增长 + 50% 质量。输入须齐全，同组至少八家合格公司；已知处置现金失真会暂停相关质量分。分数不含股价或估值。',
                      ),
                      Text(w('Snapshot', '快照'), style: style(14, true)),
                      const SizedBox(height: 6),
                      SelectableText(
                        snapshotId.isEmpty ? '—' : snapshotId,
                        style: style(11, false, p.muted),
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        '${text(snapshot['methodologyVersion'])}\n${text(snapshot['universeVersion'])}',
                        style: style(11, false, p.muted),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget methodParagraph(
    String titleEn,
    String titleZh,
    String bodyEn,
    String bodyZh,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(w(titleEn, titleZh), style: style(15, true)),
        const SizedBox(height: 6),
        Text(w(bodyEn, bodyZh), style: style(13, false, p.muted)),
      ],
    ),
  );

  Widget snapshotFooter() => Wrap(
    spacing: 16,
    runSpacing: 5,
    children: [
      Text(
        w(
          'Fact OS · ${widget.asOf} cutoff · ${snapshotId.length > 16 ? snapshotId.substring(0, 16) : snapshotId}',
          'Fact OS · 截止 ${widget.asOf} · ${snapshotId.length > 16 ? snapshotId.substring(0, 16) : snapshotId}',
        ),
        style: style(10, false, p.faint),
      ),
      Text(
        w('Missing data is shown as —', '缺失数据显示为 —'),
        style: style(10, false, p.faint),
      ),
    ],
  );
}

class _AiChartSeries {
  const _AiChartSeries(this.label, this.color, this.values);
  final String label;
  final Color color;
  final List<double?> values;
}

class _AiInsightsChart extends StatefulWidget {
  const _AiInsightsChart({
    required this.palette,
    required this.labels,
    required this.series,
    required this.emptyLabel,
    this.stacked = false,
    this.percent = true,
    this.selectedQuarter,
    this.onQuarter,
  });
  final Palette palette;
  final List<String> labels;
  final List<_AiChartSeries> series;
  final bool stacked, percent;
  final String emptyLabel;
  final String? selectedQuarter;
  final ValueChanged<String>? onQuarter;
  @override
  State<_AiInsightsChart> createState() => _AiInsightsChartState();
}

class _AiInsightsChartState extends State<_AiInsightsChart> {
  int? hovered;
  int nearest(double x, double width) {
    final plotWidth = math.max(1.0, width - 66);
    final fraction = ((x - 54) / plotWidth).clamp(0.0, 1.0);
    return widget.stacked
        ? (fraction * widget.labels.length).floor().clamp(
            0,
            widget.labels.length - 1,
          )
        : (fraction * (widget.labels.length - 1)).round().clamp(
            0,
            widget.labels.length - 1,
          );
  }

  @override
  Widget build(BuildContext context) {
    final hasValues = widget.series.any((s) => s.values.any((v) => v != null));
    if (!hasValues || widget.labels.isEmpty) {
      return SizedBox(
        height: 180,
        child: Center(
          child: Text(
            widget.emptyLabel,
            style: TextStyle(color: widget.palette.muted),
          ),
        ),
      );
    }
    final selected = hovered != null && hovered! < widget.labels.length
        ? hovered!
        : widget.labels.length - 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(520.0, constraints.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: MouseRegion(
                onHover: (event) => setState(
                  () => hovered = nearest(event.localPosition.dx, width),
                ),
                onExit: (_) => setState(() => hovered = null),
                child: GestureDetector(
                  onTapDown: (event) {
                    final index = nearest(event.localPosition.dx, width);
                    setState(() => hovered = index);
                    widget.onQuarter?.call(widget.labels[index]);
                  },
                  child: Semantics(
                    label: widget.percent
                        ? context.tr('季度增速折线图', 'Quarterly growth line chart')
                        : context.tr(
                            '季度资本投入堆叠柱状图',
                            'Quarterly capital investment stacked bars',
                          ),
                    child: SizedBox(
                      width: width,
                      height: 270,
                      child: CustomPaint(
                        painter: _AiInsightsChartPainter(
                          palette: widget.palette,
                          labels: widget.labels,
                          series: widget.series,
                          stacked: widget.stacked,
                          percent: widget.percent,
                          hovered: hovered,
                          selectedQuarter: widget.selectedQuarter,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 16,
              runSpacing: 5,
              children: [
                Text(
                  widget.labels[selected].replaceAll('-', ' '),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: widget.palette.text,
                  ),
                ),
                for (final series in widget.series)
                  Text(
                    '${series.label}  ${widget.percent ? aiInsightsPercent(series.values.elementAtOrNull(selected), signed: true) : aiInsightsAmount(series.values.elementAtOrNull(selected))}',
                    style: TextStyle(fontSize: 11, color: series.color),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _AiInsightsChartPainter extends CustomPainter {
  const _AiInsightsChartPainter({
    required this.palette,
    required this.labels,
    required this.series,
    required this.stacked,
    required this.percent,
    required this.hovered,
    required this.selectedQuarter,
  });
  final Palette palette;
  final List<String> labels;
  final List<_AiChartSeries> series;
  final bool stacked, percent;
  final int? hovered;
  final String? selectedQuarter;

  @override
  void paint(Canvas canvas, Size size) {
    if (labels.isEmpty || !series.any((s) => s.values.any((v) => v != null))) {
      final empty = TextPainter(
        text: TextSpan(
          text: 'No comparable observations',
          style: TextStyle(color: palette.muted, fontSize: 13),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      empty.paint(
        canvas,
        Offset((size.width - empty.width) / 2, size.height / 2),
      );
      return;
    }
    const left = 54.0, top = 14.0, bottom = 34.0;
    final width = size.width - left - 12, height = size.height - top - bottom;
    final values = <double>[0];
    if (stacked) {
      for (var i = 0; i < labels.length; i++) {
        var positive = 0.0, negative = 0.0;
        for (final s in series) {
          final value = s.values.elementAtOrNull(i) ?? 0;
          if (value >= 0) {
            positive += value;
          } else {
            negative += value;
          }
        }
        values.addAll([positive, negative]);
      }
    } else {
      for (final s in series) {
        values.addAll(s.values.whereType<double>());
      }
    }
    var min = values.reduce(math.min), max = values.reduce(math.max);
    if (max == min) {
      max = min + 1;
    }
    final padding = (max - min) * .1;
    max += padding;
    if (min < 0) min -= padding;
    double y(double value) => top + (max - value) / (max - min) * height;
    double x(int i) => stacked
        ? left + width * (i + .5) / labels.length
        : left + width * i / math.max(1, labels.length - 1);
    void label(
      String value,
      Offset offset, {
      Color? color,
      double fontSize = 10,
      bool alignRight = false,
    }) {
      final tp = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(color: color ?? palette.faint, fontSize: fontSize),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        alignRight ? Offset(offset.dx - tp.width, offset.dy) : offset,
      );
    }

    final grid = Paint()
      ..color = palette.border
      ..strokeWidth = .7;
    for (var i = 0; i <= 4; i++) {
      final value = min + (max - min) * i / 4,
          py = y(min + (max - min) * i / 4);
      canvas.drawLine(Offset(left, py), Offset(left + width, py), grid);
      label(
        percent
            ? '${(value * 100).toStringAsFixed(0)}%'
            : aiInsightsAmount(value),
        Offset(left - 8, py - 6),
        alignRight: true,
      );
    }
    if (min < 0) {
      canvas.drawLine(
        Offset(left, y(0)),
        Offset(left + width, y(0)),
        Paint()
          ..color = palette.muted
          ..strokeWidth = .7,
      );
    }
    for (var i = 0; i < labels.length; i++) {
      if (labels.length <= 12 || i.isEven || i == labels.length - 1) {
        label(
          labels[i].replaceFirst('20', '').replaceAll('-', ' '),
          Offset(x(i) - 15, top + height + 13),
          color: labels[i] == selectedQuarter ? palette.accent : palette.faint,
          fontSize: 9,
        );
      }
    }
    if (hovered != null && hovered! < labels.length) {
      canvas.drawLine(
        Offset(x(hovered!), top),
        Offset(x(hovered!), top + height),
        Paint()
          ..color = palette.muted.withValues(alpha: .35)
          ..strokeWidth = 1,
      );
    }
    if (stacked) {
      final barWidth = math.min(42.0, width / labels.length * .58);
      for (var i = 0; i < labels.length; i++) {
        var positive = 0.0, negative = 0.0;
        for (final s in series) {
          final value = s.values.elementAtOrNull(i);
          if (value == null) continue;
          final baseline = value >= 0 ? positive : negative;
          final endpoint = baseline + value;
          final a = y(baseline), b = y(endpoint);
          final rect = Rect.fromLTRB(
            x(i) - barWidth / 2,
            math.min(a, b),
            x(i) + barWidth / 2,
            math.max(a, b),
          );
          canvas.drawRect(
            rect,
            Paint()
              ..color = s.color.withValues(
                alpha: hovered == i || labels[i] == selectedQuarter ? 1 : .78,
              ),
          );
          if (value >= 0) {
            positive = endpoint;
          } else {
            negative = endpoint;
          }
        }
      }
    } else {
      for (final s in series) {
        final path = Path();
        var continuing = false;
        for (var i = 0; i < labels.length; i++) {
          final value = s.values.elementAtOrNull(i);
          if (value == null) {
            continuing = false;
            continue;
          }
          final point = Offset(x(i), y(value));
          if (continuing) {
            path.lineTo(point.dx, point.dy);
          } else {
            path.moveTo(point.dx, point.dy);
            continuing = true;
          }
          canvas.drawCircle(
            point,
            hovered == i ? 4 : 2.6,
            Paint()..color = s.color,
          );
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = s.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AiInsightsChartPainter oldDelegate) => true;
}
