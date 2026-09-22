part of 'main.dart';

/// A lazy, quarter/generation-pinned drill-down. It never downloads the full
/// population in the first-screen request or silently mixes two generations.
class ActiveSectorDialog extends StatefulWidget {
  const ActiveSectorDialog({
    super.key,
    required this.api,
    required this.palette,
    required this.sector,
    required this.asOf,
    required this.quarter,
    required this.generation,
    required this.sectorSummary,
  });
  final ApiClient api;
  final Palette palette;
  final String sector, asOf, quarter, generation;
  final Map<String, dynamic> sectorSummary;
  @override
  State<ActiveSectorDialog> createState() => _ActiveSectorDialogState();
}

class _ActiveSectorDialogState extends State<ActiveSectorDialog> {
  Map<String, dynamic>? data;
  String view = 'stocks', direction = 'all', query = '', industry = '';
  bool loading = true;
  String? error;
  int serial = 0, offset = 0;
  Timer? debounce;
  final search = TextEditingController();
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  String amount(dynamic value, {bool signed = false}) {
    final n = nullableNumber(value);
    if (n == null) return '—';
    final abs = n.abs();
    final formatted = abs >= 1000000
        ? '${(abs / 1000000).toStringAsFixed(2)}T'
        : abs >= 1000
        ? '${(abs / 1000).toStringAsFixed(2)}B'
        : '${abs.toStringAsFixed(1)}M';
    return '${n < 0
        ? '−'
        : signed && n > 0
        ? '+'
        : ''}\$$formatted';
  }

  String percent(dynamic v) => nullableNumber(v) == null
      ? '—'
      : '${(number(v) * 100).toStringAsFixed(2)}%';
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final request = ++serial;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final params = Uri(
        queryParameters: {
          'asOf': widget.asOf,
          'quarter': widget.quarter,
          if (widget.generation.isNotEmpty) 'generation': widget.generation,
          'view': view,
          'direction': direction,
          'offset': '$offset',
          'limit': '20',
          'search': query,
          if (industry.isNotEmpty) 'industry': industry,
        },
      ).query;
      final result = await widget.api.getJson(
        '/api/investment/13f-sectors/${Uri.encodeComponent(widget.sector)}?$params',
      );
      if (!mounted || request != serial) return;
      setState(() {
        data = result;
        offset = number(result['offset']).toInt();
        loading = false;
      });
    } catch (e) {
      if (!mounted || request != serial) return;
      setState(() {
        error = '$e';
        loading = false;
        data = null;
      });
    }
  }

  void change(VoidCallback action) {
    debounce?.cancel();
    setState(() {
      action();
      offset = 0;
      data = null;
    });
    unawaited(load());
  }

  Widget note(String text) =>
      Text(text, style: TextStyle(color: p.muted, fontSize: 12, height: 1.5));
  Widget metric(String title, String value, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      note(title),
      const SizedBox(height: 5),
      Text(
        value,
        style: TextStyle(
          color: color,
          fontSize: 23,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final summary = asMap(data?['summary']);
    final rows = asList(data?['rows']);
    final total = number(data?['total']).toInt();
    return Dialog(
      backgroundColor: p.panel,
      insetPadding: EdgeInsets.all(size.width < 600 ? 8 : 28),
      child: SizedBox(
        width: 1120,
        height: size.height * .91,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${context.ui(widget.sector)} · ${w('Inside the sector', '行业内部动向')}',
                          style: TextStyle(
                            color: p.text,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 5),
                        note(
                          '${widget.quarter} · ${w('Cutoff', '截止日')} ${widget.asOf}',
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('sector-close'),
                    tooltip: w('Close', '关闭'),
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close, color: p.muted),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${w('Reported sector weight', '申报行业权重')}  ${percent(widget.sectorSummary['previousWeight'])} → ${percent(widget.sectorSummary['currentWeight'])}',
                      style: TextStyle(
                        color: p.accent,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    note(
                      w(
                        'Comparable active-manager holdings, not real-time cash flows. Amounts value split-adjusted share changes at a common quarter-end price.',
                        '可比主动机构申报持仓，不是实时资金流。金额按拆股调整后的股数变化，以统一季末价格估算。',
                      ),
                    ),
                    if (summary.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 36,
                        runSpacing: 14,
                        children: [
                          metric(
                            w('Added · estimated', '增持等价金额'),
                            amount(summary['addProxyM']),
                            p.accent,
                          ),
                          metric(
                            w('Reduced · estimated', '减持等价金额'),
                            amount(summary['trimProxyM']),
                            p.secondary,
                          ),
                          metric(
                            w('Net quantity effect', '净股数变化等价金额'),
                            amount(summary['netProxyM'], signed: true),
                            p.text,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      note(
                        '${w('Stocks / managers / comparable positions', '股票 / 机构 / 可比持仓')}  ${summary['stocks']} / ${summary['managers']} / ${summary['positions']}',
                      ),
                      note(
                        '${w('Priced positions', '已估价持仓')} ${summary['pricedPositions']} / ${summary['positions']} · ${w('Prior-price fallback', '使用前期价格')} ${summary['priorPricePositions']}',
                      ),
                      if (number(summary['unpricedPositions']) > 0)
                        Text(
                          w(
                            'Partial estimate: missing or inconsistent inputs are excluded, not zero.',
                            '仅为部分估算：缺失或不一致的数据未计入，不代表零。',
                          ),
                          style: TextStyle(color: p.secondary),
                        ),
                      if (number(summary['inconsistentPositions']) > 0)
                        note(
                          '${w('Share/value inconsistencies excluded', '已排除股数与金额不一致的持仓')} ${summary['inconsistentPositions']} · '
                          '${w('Missing inputs', '输入缺失')} ${summary['missingInputPositions'] ?? 0}',
                        ),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(
                          w('Reconcile reported value change', '对账：申报市值变化'),
                          style: TextStyle(color: p.text, fontSize: 13),
                        ),
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: note(
                              '${amount(summary['previousValueM'])} → ${amount(summary['currentValueM'])}\n'
                              '${w('Reported value change', '申报市值净变化')} ${amount(summary['reportedValueChangeM'], signed: true)}\n'
                              '${w('Quantity effect', '股数变化等价金额')} ${amount(summary['netProxyM'], signed: true)}\n'
                              '${w('Valuation / other residual', '估值及其他残差')} ${amount(summary['valuationResidualM'], signed: true)}\n'
                              '${w('Residual is only available with complete coverage; it includes price, composition and data effects, not causal attribution.', '覆盖完整时才计算残差；包含价格、组合结构及数据效应，不作因果归因。')}\n'
                              '${w('Price reference: median implied price of the same stock in each quarter. Share/value mismatches beyond 5% or USD 0.1m (whichever is larger) are excluded.', '价格参照：同股同季申报隐含价格的中位数。股数与金额差异超出 5% 或 10 万美元（取较大值）时不计入估算。')}',
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final tab in [
                          ('stocks', w('Stocks', '股票')),
                          ('industries', w('Industries', '细分行业')),
                          ('managers', w('Managers', '机构')),
                        ])
                          ChoiceChip(
                            key: ValueKey('sector-tab-${tab.$1}'),
                            selected: view == tab.$1,
                            label: Text(tab.$2),
                            onSelected: (_) => change(() {
                              view = tab.$1;
                              industry = '';
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final item in [
                          ('all', w('All changes', '全部变动')),
                          ('adding', w('Net additions', '净增持')),
                          ('reducing', w('Net reductions', '净减持')),
                        ])
                          ChoiceChip(
                            key: ValueKey('sector-direction-${item.$1}'),
                            selected: direction == item.$1,
                            label: Text(item.$2),
                            onSelected: (_) =>
                                change(() => direction = item.$1),
                          ),
                        if (industry.isNotEmpty)
                          ActionChip(
                            avatar: const Icon(Icons.close, size: 16),
                            label: Text(
                              '${context.ui(industry)} · ${w('Clear', '清除')}',
                            ),
                            onPressed: () => change(() => industry = ''),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('sector-search'),
                      controller: search,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: w('Find within this sector', '在本行业内搜索'),
                      ),
                      onChanged: (value) {
                        debounce?.cancel();
                        ++serial;
                        debounce = Timer(
                          const Duration(milliseconds: 300),
                          () => change(() => query = value),
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    note(
                      w(
                        'Ranked by absolute net quantity effect in the complete sector. Search and filters do not change ranks.',
                        '按全行业净股数变化等价金额的绝对值排序；搜索与筛选不改变原始排名。',
                      ),
                    ),
                    if (loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: LinearProgressIndicator(),
                      ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Column(
                          children: [
                            note(
                              error!.contains('generation_changed')
                                  ? w(
                                      'Data version changed. Close this panel and refresh the 13F page.',
                                      '数据版本已更新，请关闭后刷新 13F 页面再试。',
                                    )
                                  : w(
                                      'Sector detail is unavailable for this quarter. No substitute sample is shown.',
                                      '本季行业明细暂不可用，不以部分样本替代。',
                                    ),
                            ),
                            TextButton(
                              onPressed: load,
                              child: Text(w('Retry', '重试')),
                            ),
                          ],
                        ),
                      ),
                    if (!loading && error == null) ...[
                      if (rows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: note(w('No matching changes.', '没有符合条件的变动。')),
                        ),
                      for (final row in rows) _row(row),
                      Row(
                        children: [
                          Expanded(
                            child: note(
                              total == 0
                                  ? '0'
                                  : '${offset + 1}–${offset + rows.length} / $total',
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('sector-prev'),
                            tooltip: w('Previous page', '上一页'),
                            onPressed: offset == 0
                                ? null
                                : () {
                                    offset -= 20;
                                    unawaited(load());
                                  },
                            icon: const Icon(Icons.chevron_left),
                          ),
                          IconButton(
                            key: const ValueKey('sector-next'),
                            tooltip: w('Next page', '下一页'),
                            onPressed: offset + rows.length >= total
                                ? null
                                : () {
                                    offset += 20;
                                    unawaited(load());
                                  },
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    note(
                      w(
                        'Method active-sector-v1 · Complete comparable filings only. Conservative manager classification is not a verified fund mandate. Current sector taxonomy is applied to both periods. Quarter-end +45 days is a visibility proxy, not an actual filing date.',
                        '方法 active-sector-v1 · 仅纳入前后两期完整可比申报。保守主动机构分类并非已核实基金策略。两期使用当前行业分类。季末 +45 天为可见日期代理，不是真实申报时间。',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> row) {
    final net = nullableNumber(row['netProxyM']);
    final adds = nullableNumber(row['addProxyM']),
        trims = nullableNumber(row['trimProxyM']);
    final gross = (adds ?? 0) + (trims ?? 0);
    final title = view == 'stocks'
        ? '${row['ticker']} · ${row['name']}'
        : view == 'industries'
        ? context.ui(text(row['name']))
        : text(row['name']);
    return Container(
      key: ValueKey(
        'sector-row-${row['ticker'] ?? row['investorId'] ?? row['industry']}',
      ),
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '#${row['rank']}  $title',
                  style: TextStyle(
                    color: p.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                amount(net, signed: true),
                style: TextStyle(
                  color: net == null || net >= 0 ? p.accent : p.secondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 22,
            runSpacing: 5,
            children: [
              note(
                '${w('Added', '增持')} ${amount(adds)} · ${w('Reduced', '减持')} ${amount(trims)}',
              ),
              note(
                '${w('Reported value', '申报市值')} ${amount(row['currentValueM'])}',
              ),
              note(
                '${view == 'managers' ? w('Sector / manager book', '行业占该机构组合') : w('Within-sector weight', '行业内占比')} ${percent(row['previousWeight'])} → ${percent(row['currentWeight'])}',
              ),
            ],
          ),
          if (gross > 0 && adds != null && trims != null) ...[
            const SizedBox(height: 8),
            Semantics(
              label:
                  '${w('Added / reduced mix', '增持与减持构成')} ${amount(adds)} / ${amount(trims)}',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: Row(
                  children: [
                    if (adds > 0)
                      Expanded(
                        flex: math.max(1, (adds / gross * 1000).round()),
                        child: Container(height: 4, color: p.accent),
                      ),
                    if (trims > 0)
                      Expanded(
                        flex: math.max(1, (trims / gross * 1000).round()),
                        child: Container(height: 4, color: p.secondary),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          note(
            '${w('Adding / reducing positions', '增持 / 减持持仓')} ${row['addingPositions']} / ${row['reducingPositions']} · ${w('New / exited', '新建 / 清仓')} ${row['newPositions']} / ${row['exitedPositions']}',
          ),
          if (number(row['unpricedPositions']) > 0)
            note(
              '${w('Partial amount coverage', '金额覆盖不完整')}: '
              '${row['pricedPositions']} / ${row['positions']} · '
              '${w('Inconsistent inputs excluded', '不一致输入已排除')} ${row['inconsistentPositions'] ?? 0}',
            ),
          if (view == 'stocks')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => Navigator.pop(context, text(row['ticker'])),
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: Text(w('Research this stock', '研究这只股票')),
              ),
            ),
          if (view == 'industries')
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => change(() {
                  industry = text(row['industry']);
                  view = 'stocks';
                }),
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: Text(w('Inspect stocks', '查看内部股票')),
              ),
            ),
        ],
      ),
    );
  }
}
