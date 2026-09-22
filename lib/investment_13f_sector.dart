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
  final expandedRows = <String>{};
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
      expandedRows.clear();
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
          fontSize: 25,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );

  String count(dynamic value) =>
      nullableNumber(value) == null ? '—' : formatNumber(number(value));

  Widget tag(String label, {Color? color, IconData? icon}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: (color ?? p.muted).withValues(alpha: .08),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: color ?? p.muted),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              color: color ?? p.muted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );

  Widget summaryPanel(Map<String, dynamic> summary) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: p.accent.withValues(alpha: .035),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: p.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              w('Reported sector weight', '申报行业权重'),
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
            Text(
              '${percent(widget.sectorSummary['previousWeight'])} → ${percent(widget.sectorSummary['currentWeight'])}',
              style: TextStyle(
                color: p.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        if (summary.isNotEmpty) ...[
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final items = [
                metric(
                  w('Net change · estimated', '净变动 · 估算'),
                  amount(summary['netProxyM'], signed: true),
                  p.text,
                ),
                metric(
                  w('Added · estimated', '增持 · 估算'),
                  amount(summary['addProxyM']),
                  p.accent,
                ),
                metric(
                  w('Reduced · estimated', '减持 · 估算'),
                  amount(summary['trimProxyM']),
                  p.secondary,
                ),
              ];
              return Wrap(
                spacing: 18,
                runSpacing: 18,
                children: [
                  for (var i = 0; i < items.length; i++)
                    SizedBox(
                      width: constraints.maxWidth < 540
                          ? (i == 0
                                ? constraints.maxWidth
                                : (constraints.maxWidth - 18) / 2)
                          : (constraints.maxWidth - 36) / 3,
                      child: items[i],
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              tag('${count(summary['stocks'])} ${w('stocks', '只股票')}'),
              tag('${count(summary['managers'])} ${w('managers', '家机构')}'),
              if (number(summary['unpricedPositions']) > 0)
                tag(
                  w('Partial estimate · exclusions apply', '部分估算 · 已排除缺失项'),
                  color: p.secondary,
                  icon: Icons.info_outline,
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        note(
          w(
            'Split-adjusted share changes at a common quarter-end price. Not real-time cash flows.',
            '按拆股调整后股数变化及统一季末价格估算，不是实时资金流。',
          ),
        ),
      ],
    ),
  );

  Widget methodology(Map<String, dynamic> summary) => ExpansionTile(
    key: const ValueKey('sector-methodology'),
    tilePadding: const EdgeInsets.symmetric(horizontal: 2),
    childrenPadding: const EdgeInsets.only(bottom: 16),
    shape: const Border(),
    collapsedShape: const Border(),
    iconColor: p.muted,
    collapsedIconColor: p.muted,
    title: Text(
      w('Coverage & calculation details', '覆盖与计算口径'),
      style: TextStyle(
        color: p.muted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (summary.isNotEmpty) ...[
              note(
                '${w('Priced / comparable positions', '已估价 / 可比持仓')} ${count(summary['pricedPositions'])} / ${count(summary['positions'])} · '
                '${w('Prior-price fallback', '使用前期价格')} ${count(summary['priorPricePositions'])}',
              ),
              note(
                '${w('Share/value inconsistencies excluded', '已排除股数与金额不一致的持仓')} ${count(summary['inconsistentPositions'])} · '
                '${w('Missing inputs', '输入缺失')} ${count(summary['missingInputPositions'])}',
              ),
              if (number(summary['unpricedPositions']) > 0)
                Text(
                  w(
                    'Missing or inconsistent inputs are excluded, not zero.',
                    '缺失或不一致的数据未计入，不代表零。',
                  ),
                  style: TextStyle(color: p.secondary, fontSize: 12),
                ),
              const SizedBox(height: 10),
              note(
                '${w('Reported value', '申报市值')} ${amount(summary['previousValueM'])} → ${amount(summary['currentValueM'])}\n'
                '${w('Reported value change', '申报市值净变化')} ${amount(summary['reportedValueChangeM'], signed: true)}\n'
                '${w('Quantity effect', '股数变化等价金额')} ${amount(summary['netProxyM'], signed: true)}\n'
                '${w('Valuation / other residual', '估值及其他残差')} ${amount(summary['valuationResidualM'], signed: true)}',
              ),
              const SizedBox(height: 8),
            ],
            note(
              w(
                'Residual is only available with complete coverage; it includes price, composition and data effects, not causal attribution.',
                '覆盖完整时才计算残差；包含价格、组合结构及数据效应，不作因果归因。',
              ),
            ),
            note(
              w(
                'Price reference: median implied price of the same stock in each quarter. Share/value mismatches beyond 5% or USD 0.1m (whichever is larger) are excluded.',
                '价格参照：同股同季申报隐含价格的中位数。股数与金额差异超出 5% 或 10 万美元（取较大值）时不计入估算。',
              ),
            ),
            const SizedBox(height: 8),
            note(
              w(
                'Method active-sector-v1 · Complete comparable filings only. Conservative manager classification is not a verified fund mandate. Current sector taxonomy is applied to both periods. Quarter-end +45 days is a visibility proxy, not an actual filing date.',
                '方法 active-sector-v1 · 仅纳入前后两期完整可比申报。保守主动机构分类并非已核实基金策略。两期使用当前行业分类。季末 +45 天为可见日期代理，不是真实申报时间。',
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget chip(String key, String label, bool selected, VoidCallback select) =>
      ChoiceChip(
        key: ValueKey(key),
        showCheckmark: false,
        selected: selected,
        selectedColor: p.accent.withValues(alpha: .15),
        backgroundColor: p.panel,
        side: BorderSide(
          color: selected ? p.accent.withValues(alpha: .4) : p.border,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        label: Text(
          label,
          style: TextStyle(
            color: selected ? p.accent : p.muted,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
        onSelected: (_) => change(select),
      );

  Widget controls() => LayoutBuilder(
    builder: (context, constraints) {
      final tabs = Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final tab in [
            ('stocks', w('Stocks', '股票')),
            ('industries', w('Industries', '细分行业')),
            ('managers', w('Managers', '机构')),
          ])
            chip('sector-tab-${tab.$1}', tab.$2, view == tab.$1, () {
              view = tab.$1;
              industry = '';
            }),
        ],
      );
      final field = TextField(
        key: const ValueKey('sector-search'),
        controller: search,
        style: TextStyle(color: p.text, fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: p.muted.withValues(alpha: .04),
          prefixIcon: const Icon(Icons.search, size: 19),
          hintText: w('Find within this sector', '在本行业内搜索'),
          hintStyle: TextStyle(color: p.muted, fontSize: 13),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: p.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: p.border),
          ),
        ),
        onChanged: (value) {
          debounce?.cancel();
          ++serial;
          debounce = Timer(
            const Duration(milliseconds: 300),
            () => change(() => query = value),
          );
        },
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (constraints.maxWidth >= 680)
            Row(
              children: [
                Expanded(child: tabs),
                const SizedBox(width: 16),
                SizedBox(width: 280, child: field),
              ],
            )
          else ...[
            tabs,
            const SizedBox(height: 10),
            field,
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final option in [
                ('all', w('All changes', '全部变动')),
                ('adding', w('Net additions', '净增持')),
                ('reducing', w('Net reductions', '净减持')),
              ])
                chip(
                  'sector-direction-${option.$1}',
                  option.$2,
                  direction == option.$1,
                  () => direction = option.$1,
                ),
              if (industry.isNotEmpty)
                ActionChip(
                  avatar: const Icon(Icons.close, size: 15),
                  label: Text('${context.ui(industry)} · ${w('Clear', '清除')}'),
                  onPressed: () => change(() => industry = ''),
                ),
            ],
          ),
          const SizedBox(height: 8),
          note(
            w(
              'Ranked by absolute net quantity effect. Sector-wide ranks stay fixed when filtered.',
              '按净股数变化等价金额的绝对值排序；筛选不改变全行业排名。',
            ),
          ),
        ],
      );
    },
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
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
                          context.ui(widget.sector),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 5),
                        note(
                          '${w('Active-manager rotation', '主动机构调仓')} · ${widget.quarter}\n${w('Research cutoff', '研究截止日')} ${widget.asOf}',
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
                    summaryPanel(summary),
                    methodology(summary),
                    controls(),
                    const SizedBox(height: 16),
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
    final id = text(
      row[view == 'stocks'
          ? 'ticker'
          : view == 'managers'
          ? 'investorId'
          : 'industry'],
    );
    final expanded = expandedRows.contains('$view:$id');
    final partial = number(row['unpricedPositions']) > 0;
    final tone = net == null || net == 0
        ? p.muted
        : net > 0
        ? p.accent
        : p.secondary;
    final heading = view == 'stocks'
        ? text(row['ticker'])
        : view == 'industries'
        ? context.ui(text(row['name']))
        : text(row['name']);
    Widget detailMetric(String label, String value, Color color) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        note(label),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
    return Container(
      key: ValueKey('sector-row-$id'),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: p.muted.withValues(alpha: .035),
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < 520;
                  final identity = Row(
                    children: [
                      if (!narrow) ...[
                        SizedBox(
                          width: 30,
                          child: Text(
                            '#${row['rank']}',
                            style: TextStyle(color: p.muted, fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (view == 'stocks')
                        StockLogo(
                          ticker: text(row['ticker']),
                          palette: p,
                          size: 38,
                        )
                      else
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: p.accent.withValues(alpha: .08),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Icon(
                            view == 'industries'
                                ? Icons.category_outlined
                                : Icons.account_balance_outlined,
                            color: p.accent,
                            size: 20,
                          ),
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${narrow ? '#${row['rank']}  ' : ''}$heading',
                              style: TextStyle(
                                color: p.text,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            if (view == 'stocks') ...[
                              const SizedBox(height: 3),
                              Text(
                                text(row['name']),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.muted,
                                  fontSize: 11,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                  final change = Column(
                    crossAxisAlignment: narrow
                        ? CrossAxisAlignment.start
                        : CrossAxisAlignment.end,
                    children: [
                      Text(
                        amount(net, signed: true),
                        style: TextStyle(
                          color: tone,
                          fontWeight: FontWeight.w700,
                          fontSize: 22,
                        ),
                      ),
                      note(w('Net change · estimated', '净变动 · 估算')),
                    ],
                  );
                  return narrow
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            identity,
                            const SizedBox(height: 14),
                            change,
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(child: identity),
                            const SizedBox(width: 20),
                            change,
                          ],
                        );
                },
              ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, constraints) => Wrap(
                  spacing: 16,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width:
                          (constraints.maxWidth - 16) /
                              (constraints.maxWidth < 520 ? 2 : 3) -
                          6,
                      child: detailMetric(
                        w('Added', '增持'),
                        amount(adds),
                        p.accent,
                      ),
                    ),
                    SizedBox(
                      width:
                          (constraints.maxWidth - 16) /
                              (constraints.maxWidth < 520 ? 2 : 3) -
                          6,
                      child: detailMetric(
                        w('Reduced', '减持'),
                        amount(trims),
                        p.secondary,
                      ),
                    ),
                    detailMetric(
                      view == 'managers'
                          ? w('Sector / manager book', '行业占该机构组合')
                          : w('Within-sector weight', '行业内占比'),
                      '${percent(row['previousWeight'])} → ${percent(row['currentWeight'])}',
                      p.text,
                    ),
                  ],
                ),
              ),
              if (gross > 0 && adds != null && trims != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  label:
                      '${w('Added / reduced mix', '增持与减持构成')} ${amount(adds)} / ${amount(trims)}',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Row(
                      children: [
                        if (adds > 0)
                          Expanded(
                            flex: math.max(1, (adds / gross * 1000).round()),
                            child: Container(height: 3, color: p.accent),
                          ),
                        if (trims > 0)
                          Expanded(
                            flex: math.max(1, (trims / gross * 1000).round()),
                            child: Container(height: 3, color: p.secondary),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 6,
                children: [
                  TextButton.icon(
                    key: ValueKey('sector-detail-$id'),
                    style: TextButton.styleFrom(
                      foregroundColor: partial ? p.secondary : p.muted,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    onPressed: () => setState(() {
                      expanded
                          ? expandedRows.remove('$view:$id')
                          : expandedRows.add('$view:$id');
                    }),
                    icon: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 17,
                    ),
                    label: Text(
                      partial
                          ? w('Positions · partial coverage', '持仓明细 · 覆盖不完整')
                          : w('Position details', '持仓明细'),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  if (view != 'managers')
                    TextButton.icon(
                      key: ValueKey('sector-open-$id'),
                      onPressed: () {
                        if (view == 'stocks') {
                          Navigator.pop(context, text(row['ticker']));
                        } else {
                          change(() {
                            industry = text(row['industry']);
                            view = 'stocks';
                          });
                        }
                      },
                      style: TextButton.styleFrom(foregroundColor: p.accent),
                      icon: const Icon(Icons.arrow_forward, size: 16),
                      label: Text(
                        view == 'stocks'
                            ? w('Research', '公司研究')
                            : w('Inspect stocks', '查看内部股票'),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
              if (expanded) ...[
                Divider(color: p.border, height: 18),
                note(
                  '${w('Reported value', '申报市值')} ${amount(row['currentValueM'])}',
                ),
                note(
                  '${w('Adding / reducing positions', '增持 / 减持持仓')} ${count(row['addingPositions'])} / ${count(row['reducingPositions'])} · '
                  '${w('New / exited', '新建 / 清仓')} ${count(row['newPositions'])} / ${count(row['exitedPositions'])}',
                ),
                if (partial) ...[
                  note(
                    '${w('Priced / comparable positions', '已估价 / 可比持仓')} ${count(row['pricedPositions'])} / ${count(row['positions'])}',
                  ),
                  note(
                    '${w('Inconsistent inputs excluded', '不一致输入已排除')} ${count(row['inconsistentPositions'])}',
                  ),
                  note(
                    w(
                      'Missing inputs are excluded, not zero.',
                      '缺失输入未计入，不代表零。',
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
