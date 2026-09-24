part of 'main.dart';

/// Independent, cutoff-scoped research layer. Never blocks financial statements.
class ResearchInsidersPanel extends StatefulWidget {
  const ResearchInsidersPanel({
    super.key,
    required this.api,
    required this.palette,
    required this.ticker,
    required this.asOf,
  });
  final ApiClient api;
  final Palette palette;
  final String ticker, asOf;
  @override
  State<ResearchInsidersPanel> createState() => _ResearchInsidersState();
}

class _ResearchInsidersState extends State<ResearchInsidersPanel> {
  Map<String, dynamic>? data;
  bool loading = true, failed = false;
  int months = 6, offset = 0, epoch = 0;
  String kind = 'all';
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  TextStyle s([double size = 13, bool bold = false, Color? color]) => TextStyle(
    fontSize: size,
    height: 1.4,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? p.text,
  );
  Map<String, dynamic> map(dynamic x) =>
      x is Map ? Map<String, dynamic>.from(x) : {};
  List<Map<String, dynamic>> list(dynamic x) =>
      x is List ? x.map(map).toList() : [];
  String amount(dynamic x, {bool money = false}) {
    if (x is! num || !x.isFinite) return '—';
    final a = x.abs();
    final suffix = a >= 1e9
        ? 'B'
        : a >= 1e6
        ? 'M'
        : a >= 1e3
        ? 'K'
        : '';
    final scale = a >= 1e9
        ? 1e9
        : a >= 1e6
        ? 1e6
        : a >= 1e3
        ? 1e3
        : 1;
    return '${x < 0 ? '−' : ''}${money ? '\$' : ''}${(a / scale).toStringAsFixed(scale == 1 && !money ? 0 : 2)}$suffix';
  }

  String exact(dynamic x) => x == null ? '—' : '$x';
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant ResearchInsidersPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticker != widget.ticker || oldWidget.asOf != widget.asOf) {
      data = null;
      offset = 0;
      unawaited(load());
    }
  }

  Future<void> load({bool reset = false}) async {
    final request = ++epoch;
    if (reset) {
      offset = 0;
      data = null;
    }
    setState(() {
      loading = true;
      failed = false;
    });
    final snapshot = offset > 0 ? (data?['snapshotId']) : null;
    final uri = Uri(
      path: '/api/investment/research/${widget.ticker}/insiders',
      queryParameters: {
        'asOf': widget.asOf,
        'months': '$months',
        'kind': kind,
        'offset': '$offset',
        'limit': '5',
        if (snapshot != null) 'snapshotId': '$snapshot',
      },
    );
    try {
      final result = await widget.api.getJson(uri.toString());
      if (!mounted || request != epoch) return;
      setState(() {
        data = result;
        loading = false;
      });
    } catch (_) {
      if (!mounted || request != epoch) return;
      setState(() {
        failed = true;
        loading = false;
        data = null;
      });
    }
  }

  String action(Map<String, dynamic> r) => switch (r['kind']) {
    'purchase' => w('Purchase · P', '买入 · P'),
    'sale' => w('Sale · S', '卖出 · S'),
    'A' => w('Award / grant · A', '奖励 / 授予 · A'),
    'M' => w('Exercise / conversion · M', '行权 / 转换 · M'),
    'C' => w('Conversion · C', '转换 · C'),
    'F' => w('Tax / exercise payment · F', '税款 / 行权支付 · F'),
    'G' => w('Gift · G', '赠与 · G'),
    'holding' => w('Ownership report', '持有申报'),
    _ => w(
      'Other · ${r['transactioncode'] ?? '—'}',
      '其他 · ${r['transactioncode'] ?? '—'}',
    ),
  };
  String role(Map<String, dynamic> r) => [
    if ('${r['officertitle'] ?? ''}'.trim().isNotEmpty) '${r['officertitle']}',
    if (r['isdirector'] == 'Y') w('Director', '董事'),
    if (r['isofficer'] == 'Y' && '${r['officertitle'] ?? ''}'.trim().isEmpty)
      w('Officer', '高管'),
    if (r['istenpercentowner'] == 'Y') w('10% owner', '10% 股东'),
  ].join(' · ');
  String exclusion(dynamic x) => switch (x) {
    'amendment_unresolved' => w('Amendment not reconciled', '修订尚未对账'),
    'invalid_transaction_date' => w('Transaction date unverified', '交易日期未验证'),
    'inconsistent_direction' => w(
      'Direction conflicts with reported shares',
      '方向与申报股数冲突',
    ),
    'derivative_or_unknown_security' => w(
      'Derivative / unclassified security',
      '衍生品 / 未分类证券',
    ),
    'not_transaction_form' => w('Ownership-only form', '持有类申报'),
    _ => w('Not a P/S purchase or sale', '非 P/S 买卖'),
  };
  Widget summaryCard(String name, Map<String, dynamic> b, Color color) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: s(12, false, p.muted)),
            const SizedBox(height: 6),
            Text(amount(b['value'], money: true), style: s(25, true, color)),
            Text(
              w(
                '${b['lines'] ?? 0} reported lines',
                '${b['lines'] ?? 0} 条申报明细',
              ),
              style: s(11, false, p.muted),
            ),
            if (b['complete'] == false)
              Text(
                w(
                  '${b['unpriced']} unpriced · partial total',
                  '${b['unpriced']} 条缺少金额 · 仅部分合计',
                ),
                style: s(11, false, p.secondary),
              ),
          ],
        ),
      );
  Widget timeline() {
    final points = list(data?['months']);
    double peak = 1;
    for (final point in points) {
      for (final key in ['purchases', 'sales']) {
        final n = map(point[key])['value'];
        if (n is num) peak = math.max(peak, n.toDouble());
      }
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 10),
      decoration: BoxDecoration(
        color: p.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            w('Reported activity by filing month · USD', '按申报月份汇总 · 美元'),
            style: s(12, true),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final point in points)
                Expanded(
                  child: Tooltip(
                    message:
                        '${point['month']}\n${w('Purchases', '买入')} ${amount(map(point['purchases'])['value'], money: true)}\n${w('Sales', '卖出')} ${amount(map(point['sales'])['value'], money: true)}',
                    child: Semantics(
                      label:
                          '${point['month']} ${w('Purchases', '买入')} ${amount(map(point['purchases'])['value'], money: true)}, ${w('Sales', '卖出')} ${amount(map(point['sales'])['value'], money: true)}',
                      child: Column(
                        children: [
                          SizedBox(
                            height: 92,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (final key in ['purchases', 'sales']) ...[
                                  Container(
                                    width: months == 12 ? 6 : 12,
                                    height: map(point[key])['value'] is num
                                        ? math.max(
                                            2,
                                            90 *
                                                (map(point[key])['value']
                                                    as num) /
                                                peak,
                                          )
                                        : 2,
                                    decoration: BoxDecoration(
                                      color: map(point[key])['value'] == null
                                          ? p.border
                                          : key == 'purchases'
                                          ? p.accent
                                          : p.secondary,
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(3),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${point['month']}'.substring(5),
                            style: s(10, false, p.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            children: [
              Text('● ${w('Purchases', '买入')}', style: s(11, false, p.accent)),
              Text('● ${w('Sales', '卖出')}', style: s(11, false, p.secondary)),
              Text(
                w(
                  'Hover for amounts; tap a row for evidence.',
                  '悬停查看金额；点击明细查看证据。',
                ),
                style: s(11, false, p.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void evidence(Map<String, dynamic> r) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        title: Text('${r['ownername']}', style: s(19, true)),
        content: SizedBox(
          width: 540,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(action(r), style: s(15, true, p.accent)),
                const SizedBox(height: 12),
                for (final item in [
                  (w('Transaction date', '交易日'), r['transactiondate']),
                  (
                    w('Filing date / form', '申报日 / 表格'),
                    '${r['date']} · ${r['formtype']}',
                  ),
                  (
                    w('Security / type code', '证券 / 类型代码'),
                    '${r['securitytitle'] ?? '—'} · ${r['securityadcode'] ?? '—'}',
                  ),
                  (w('Reported shares · signed', '申报股数 · 带方向'), r['shares']),
                  (
                    w('Reported price · USD/share', '申报价 · 美元/股'),
                    r['priceUsd'],
                  ),
                  (w('Reported value · USD', '申报金额 · 美元'), r['valueUsd']),
                  (
                    w('Holdings after this line', '该明细后的持有量'),
                    r['holdingsAfter'],
                  ),
                  (w('Direct / indirect', '直接 / 间接持有'), r['directorindirect']),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('${item.$1}: ${exact(item.$2)}', style: s()),
                  ),
                if (r['exclusion'] != null)
                  Text(
                    '${w('Excluded from P/S totals', '未纳入买卖合计')}: ${exclusion(r['exclusion'])}',
                    style: s(12, false, p.secondary),
                  ),
                const Divider(),
                SelectableText(
                  'Sharadar · insiders\n${r['ticker']} / ${r['date']} / ${r['formtype']} / ${r['ownername']} / ${r['rownum']}\n${r['id']}\n${data?['methodVersion']}',
                  style: s(11, false, p.muted),
                ),
                const SizedBox(height: 10),
                Text(
                  w(
                    'No accession, filing text or 10b5-1 plan in this dataset. The link opens the issuer’s SEC filing search, not a verified transaction document.',
                    '当前数据不含申报编号、正文或 10b5-1 计划。下方打开公司 SEC 检索页，不是已核验的单笔交易原文。',
                  ),
                  style: s(12, false, p.muted),
                ),
                if (data?['sourceSearchUrl'] != null)
                  TextButton.icon(
                    onPressed: () =>
                        openBrowserPath('${data!['sourceSearchUrl']}'),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(
                      w('Find SEC ownership filings', '查找 SEC 内部人申报'),
                    ),
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
        ],
      ),
    );
  }

  Widget activityRow(Map<String, dynamic> r) {
    final color = r['kind'] == 'purchase'
        ? p.accent
        : r['kind'] == 'sale'
        ? p.secondary
        : p.muted;
    return InkWell(
      key: ValueKey('insider-row-${r['id']}'),
      onTap: () => evidence(r),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(
                      '${r['transactioncode'] ?? ''}'.trim().isEmpty
                          ? '·'
                          : '${r['transactioncode']}',
                      style: s(15, true, color),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${r['ownername']}', style: s(13, true)),
                      if (role(r).isNotEmpty)
                        Text(role(r), style: s(11, false, p.muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      amount(r['valueUsd'], money: true),
                      style: s(16, true, color),
                    ),
                    Text(action(r), style: s(10, false, color)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                Text(
                  w(
                    'Traded ${r['transactiondate'] ?? '—'}',
                    '交易 ${r['transactiondate'] ?? '—'}',
                  ),
                  style: s(11, false, p.muted),
                ),
                Text(
                  w('Filed ${r['date']}', '申报 ${r['date']}'),
                  style: s(11, false, p.muted),
                ),
                Text(
                  '${amount(r['shares'])} ${w('shares', '股')} · ${r['securitytitle'] ?? '—'}',
                  style: s(11, false, p.muted),
                ),
                if (r['exclusion'] != null &&
                    r['exclusion'] != 'not_purchase_sale')
                  Text(
                    exclusion(r['exclusion']),
                    style: s(11, false, p.secondary),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = map(data?['summary']), rows = list(data?['rows']);
    final total = (data?['total'] as num?)?.toInt() ?? 0;
    return Container(
      key: const ValueKey('research-insiders'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              runSpacing: 12,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w('INSIDE THE COMPANY', '公司内部人'),
                      style: s(10, true, p.accent),
                    ),
                    Text(w('Insider trades', '内部人交易'), style: s(23, true)),
                    Text(
                      w(
                        'Reported activity · Current vendor snapshot · Not a trading signal.',
                        '申报变动 · 供应商当前快照 · 不是买卖信号。',
                      ),
                      style: s(12, false, p.muted),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final n in [3, 6, 12])
                      ChoiceChip(
                        key: ValueKey('insider-window-$n'),
                        selected: months == n,
                        label: Text(n == 12 ? '1Y' : '${n}M'),
                        onSelected: (_) {
                          months = n;
                          unawaited(load(reset: true));
                        },
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (loading) const LinearProgressIndicator(),
            if (failed) ...[
              Text(
                w(
                  'Insider filings could not be loaded. Financial research is still available.',
                  '内部人申报暂时无法读取，其他财务研究仍可使用。',
                ),
                style: s(13, false, p.secondary),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => load(reset: true),
                  icon: const Icon(Icons.refresh),
                  label: Text(w('Retry filings', '重试申报数据')),
                ),
              ),
            ],
            if (data != null) ...[
              Text(
                '${data!['start']} → ${widget.asOf} · ${w('Filing-date window', '按申报日筛选')} · ${w('USD', '美元')}',
                style: s(11, false, p.muted),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, c) {
                  final cards = [
                    summaryCard(
                      w('Purchases · P', '买入 · P'),
                      map(summary['purchases']),
                      p.accent,
                    ),
                    summaryCard(
                      w('Sales · S', '卖出 · S'),
                      map(summary['sales']),
                      p.secondary,
                    ),
                  ];
                  return Column(
                    children: [
                      Row(
                        children: [
                          for (var i = 0; i < cards.length; i++) ...[
                            if (i > 0) const SizedBox(width: 10),
                            Expanded(child: cards[i]),
                          ],
                        ],
                      ),
                      const SizedBox(height: 10),
                      timeline(),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final item in [
                    ('all', w('All activity', '全部变动')),
                    ('purchase', w('Purchases', '买入')),
                    ('sale', w('Sales', '卖出')),
                    ('other', w('Awards & other', '奖励与其他')),
                  ])
                    ChoiceChip(
                      key: ValueKey('insider-filter-${item.$1}'),
                      selected: kind == item.$1,
                      label: Text(item.$2),
                      onSelected: (_) {
                        kind = item.$1;
                        offset = 0;
                        unawaited(load());
                      },
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    w(
                      'No matching filing lines in this window. This does not establish that no transactions occurred.',
                      '该范围暂无匹配的申报明细，不代表实际没有发生交易。',
                    ),
                    style: s(13, false, p.muted),
                  ),
                ),
              if (!loading)
                for (final row in rows) ...[
                  activityRow(row),
                  Divider(height: 1, color: p.border),
                ],
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      '$total ${w('filing lines', '条明细')} · ${total == 0 ? 0 : offset + 1}–${math.min(offset + rows.length, total)}',
                      style: s(11, false, p.muted),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('insider-prev'),
                    tooltip: w('Previous', '上一页'),
                    onPressed: loading || offset == 0
                        ? null
                        : () {
                            offset = math.max(0, offset - 5);
                            unawaited(load());
                          },
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    key: const ValueKey('insider-next'),
                    tooltip: w('Next', '下一页'),
                    onPressed: loading || offset + rows.length >= total
                        ? null
                        : () {
                            offset += 5;
                            unawaited(load());
                          },
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  w('Coverage & calculation', '覆盖与计算口径'),
                  style: s(12, true),
                ),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      w(
                        'Totals sum reported USD values for non-derivative P/S lines only. P/S includes open-market or private trades. Awards, exercises, gifts and tax withholding are separate. Lines are not unique economic trades; joint reporting may overlap. Missing amounts are excluded, not zero.\nFiling date controls availability and monthly buckets; transaction dates are shown separately. Shares are as reported, not split-adjusted. Owners with unresolved amendments are excluded from totals.\nThis is the current vendor snapshot filtered by filing date, not a strict historical vintage. No filing text, amendment links or 10b5-1 plan flags are available.',
                        '仅汇总非衍生证券 P/S 明细的申报美元金额；P/S 包含公开市场或私下买卖。奖励、行权、赠与和代扣税款单独列示。明细不等于独立经济交易，共同申报可能重复。缺失金额不补零。\n可用性和月度分组按申报日；交易日单独显示。股数为申报原值，未经拆股调整。存在未对账修订的申报人不计入合计。\n这是按申报日筛选的供应商当前快照，不是严格历史版本。当前不含原文、修订关联或 10b5-1 计划标记。',
                      ),
                      style: s(11, false, p.muted),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${w('Excluded lines', '排除明细')} ${summary['excludedLines']} · ${w('Source through', '来源截至')} ${data!['sourceAsOf'] ?? '—'}\n${data!['methodVersion']}',
                      style: s(11, false, p.muted),
                    ),
                  ),
                  ExpansionTile(
                    title: Text(w('Monthly data', '月度数据'), style: s(12)),
                    children: [
                      for (final m in list(data!['months']))
                        ListTile(
                          dense: true,
                          title: Text('${m['month']}', style: s(12)),
                          subtitle: Text(
                            '${w('Purchases', '买入')} ${amount(map(m['purchases'])['value'], money: true)} · ${w('Sales', '卖出')} ${amount(map(m['sales'])['value'], money: true)}',
                            style: s(12),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
