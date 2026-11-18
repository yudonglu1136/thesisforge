part of 'main.dart';

// Hedge belongs to step four of StrategyLab; it is not a navigation destination.
class StrategyHedgeCard extends StatefulWidget {
  const StrategyHedgeCard({
    super.key,
    required this.api,
    required this.palette,
    required this.config,
    required this.ctaWeight,
    required this.onChanged,
  });
  final ApiClient api;
  final Palette palette;
  final Map<String, dynamic> config;
  final double ctaWeight;
  final ValueChanged<Map<String, dynamic>> onChanged;
  @override
  State<StrategyHedgeCard> createState() => _StrategyHedgeCardState();
}

class _StrategyHedgeCardState extends State<StrategyHedgeCard> {
  Map<String, dynamic>? data;
  bool loading = false;
  String error = '';
  int serial = 0;
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  TextStyle s([double size = 13, bool bold = false]) => TextStyle(
    fontSize: size,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: bold ? p.text : p.muted,
    height: 1.4,
  );
  bool get enabled => widget.config['type'] != 'none';
  String label(String t) => switch (t) {
    'none' => w('No hedge', '不对冲'),
    'put_spread' => w('Put Spread', '熊市看跌价差'),
    'protective_put' => w('Protective Put', '保护性看跌期权'),
    _ => w('Collar', '领口期权对冲'),
  };
  @override
  void initState() {
    super.initState();
    if (enabled) unawaited(load());
  }

  @override
  void didUpdateWidget(covariant StrategyHedgeCard old) {
    super.didUpdateWidget(old);
    if (enabled && data == null && !loading && error.isEmpty) unawaited(load());
  }

  @override
  void dispose() {
    serial++;
    super.dispose();
  }

  void change(String key, dynamic value) =>
      widget.onChanged({...widget.config, key: value});
  Future<void> load() async {
    final n = ++serial;
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final d = await widget.api.getJson('/api/investment/hedge');
      if (!mounted || n != serial) return;
      setState(() {
        data = d;
        loading = false;
      });
      final expiries = asList(d['expiries'])
          .map(asMap)
          .where((x) => number(x['puts']) >= 2 && number(x['calls']) >= 1)
          .toList();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            n == serial &&
            enabled &&
            text(widget.config['date']).isEmpty) {
          widget.onChanged({
            ...widget.config,
            'date': text(d['date']),
            'expiry': expiries.isEmpty ? '' : text(expiries.first['expiry']),
          });
        }
      });
    } catch (_) {
      if (mounted && n == serial) {
        setState(() {
          loading = false;
          error = w(
            'Local options could not be loaded. Retry.',
            '本地期权未能加载，请重试。',
          );
        });
      }
    }
  }

  void choose(String type) {
    if (type == 'none') {
      widget.onChanged({'type': 'none'});
      return;
    }
    final expiries = asList(data?['expiries'])
        .map(asMap)
        .where((x) => number(x['puts']) >= 2 && number(x['calls']) >= 1)
        .toList();
    widget.onChanged({
      'type': type,
      'coverage': widget.config['coverage'] ?? 1.0,
      'capital': widget.config['capital'] ?? 250000.0,
      'beta': widget.config['beta'] ?? 1.0,
      'ctaReturn': widget.config['ctaReturn'] ?? 0.0,
      'date': text(data?['date']),
      'expiry':
          widget.config['expiry'] ??
          (expiries.isEmpty ? '' : text(expiries.first['expiry'])),
    });
    if (data == null && !loading) unawaited(load());
  }

  Widget textNote(String en, String zh) => Text(w(en, zh), style: s(12));
  Widget getCard() => Container(
    key: const Key('strategy-hedge-step'),
    decoration: BoxDecoration(
      color: p.panel,
      border: Border.all(color: enabled ? p.accent : p.border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: p.accent.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '4',
                    style: s(16, true).copyWith(color: p.accent),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(w('Add a hedge', '加入对冲'), style: s(17, true)),
                ),
                Icon(Icons.shield_outlined, color: p.muted, size: 21),
              ],
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final type in [
                  'none',
                  'put_spread',
                  'protective_put',
                  'collar',
                ])
                  ChoiceChip(
                    key: ValueKey('strategy-hedge-$type'),
                    label: Text(label(type)),
                    selected: widget.config['type'] == type,
                    onSelected: (_) => choose(type),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            if (!enabled) ...[
              textNote(
                'Use QQQ options to test protection for your stock sleeve. CTA remains a separate allocation.',
                '用 QQQ 期权测试股票部分的保护，CTA 维持独立配置。',
              ),
              const SizedBox(height: 12),
              textNote(
                'Optional · leave off to run the original strategy.',
                '可选步骤 · 关闭时保持原策略回测。',
              ),
            ] else ...[
              if (loading) const LinearProgressIndicator(),
              if (error.isNotEmpty)
                TextButton(onPressed: load, child: Text(error)),
              Text(
                w(
                  'Stock-sleeve coverage ${(number(widget.config['coverage']) * 100).round()}%',
                  '股票部分覆盖 ${(number(widget.config['coverage']) * 100).round()}%',
                ),
                style: s(13, true),
              ),
              Slider(
                value: number(widget.config['coverage']).clamp(.25, 1),
                min: .25,
                max: 1,
                divisions: 3,
                onChanged: (v) => change('coverage', v),
              ),
              DropdownButtonFormField<String>(
                key: ValueKey(
                  'strategy-hedge-expiry-${widget.config['expiry']}',
                ),
                isExpanded: true,
                initialValue:
                    asList(
                      data?['expiries'],
                    ).any((x) => x['expiry'] == widget.config['expiry'])
                    ? text(widget.config['expiry'])
                    : null,
                decoration: InputDecoration(
                  labelText: w('Available duration', '可用期限'),
                ),
                items: asList(data?['expiries'])
                    .map(asMap)
                    .where(
                      (x) => number(x['puts']) >= 2 && number(x['calls']) >= 1,
                    )
                    .map((x) {
                      final duration = DateTime.parse(
                        text(x['expiry']),
                      ).difference(DateTime.parse(text(data?['date']))).inDays;
                      return DropdownMenuItem(
                        value: text(x['expiry']),
                        child: Text(
                          '${w('$duration days', '$duration 天')} · ${x['expiry']}',
                          style: s(12, true),
                        ),
                      );
                    })
                    .toList(),
                onChanged: (v) {
                  if (v != null) change('expiry', v);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<double>(
                key: ValueKey('hedge-capital-${widget.config['capital']}'),
                initialValue: number(widget.config['capital']),
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: w('Portfolio size · USD', '组合规模 · USD'),
                ),
                items: [100000.0, 250000.0, 500000.0, 1000000.0]
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(
                          '\$${(v / 1000).round()}k',
                          style: s(13, true),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) change('capital', v);
                },
              ),
              const SizedBox(height: 12),
              textNote(
                '${((1 - widget.ctaWeight) * 100).round()}% stock target · ${(widget.ctaWeight * 100).round()}% CTA · 100 shares / option contract.',
                '股票目标 ${((1 - widget.ctaWeight) * 100).round()}% · CTA ${(widget.ctaWeight * 100).round()}% · 每张期权对应 100 股。',
              ),
              const SizedBox(height: 10),
              if (data != null)
                textNote(
                  'Local closes: ${data!['date']} · offline experiment.',
                  '本地收盘价：${data!['date']} · 离线实验。',
                ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  w('Stress assumptions', '压力测试假设'),
                  style: s(12, true),
                ),
                children: [
                  Text(
                    w(
                      'Stock beta to QQQ: ${number(widget.config['beta']).toStringAsFixed(1)} (assumed)',
                      '股票对 QQQ 的 Beta：${number(widget.config['beta']).toStringAsFixed(1)}（假设）',
                    ),
                    style: s(12),
                  ),
                  Slider(
                    value: number(widget.config['beta']),
                    min: 0,
                    max: 3,
                    divisions: 12,
                    onChanged: (v) => change('beta', v),
                  ),
                  Text(
                    w(
                      'CTA return: ${(number(widget.config['ctaReturn']) * 100).round()}% (assumed)',
                      'CTA 收益：${(number(widget.config['ctaReturn']) * 100).round()}%（假设）',
                    ),
                    style: s(12),
                  ),
                  Slider(
                    value: number(widget.config['ctaReturn']),
                    min: -.5,
                    max: .5,
                    divisions: 20,
                    onChanged: (v) => change('ctaReturn', v),
                  ),
                  textNote(
                    'Put ≈95%, lower put ≈85%, call ≈105% of QQQ, using the nearest available strikes. 5% adverse fill adjustment + \$0.65 per contract per leg.',
                    '选最接近 QQQ 95% / 85% / 105% 的 Put / 较低 Put / Call。每腿含 5% 不利价格调整与每张 \$0.65 手续费。',
                  ),
                ],
              ),
              Text(
                w(
                  'Allocation stress test, not a hedged historical return.',
                  '配置压力测试，并非加对冲后的历史回报。',
                ),
                style: s(12, true).copyWith(color: p.secondary),
              ),
              if (widget.config['type'] == 'collar')
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    w(
                      'Proxy collar: Guru stocks do not cover a short QQQ call. Losses may be unlimited; no guaranteed portfolio floor.',
                      '代理领口：Guru 股票不能覆盖卖出的 QQQ Call，可能无限亏损，不保证组合底线。',
                    ),
                    style: s(12).copyWith(color: p.negative),
                  ),
                ),
            ],
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => getCard();
}

class StrategyHedgeResult extends StatelessWidget {
  const StrategyHedgeResult({
    super.key,
    required this.data,
    required this.palette,
  });
  final Map<String, dynamic> data;
  final Palette palette;
  @override
  Widget build(BuildContext context) {
    String w(String en, String zh) => context.tr(zh, en);
    String money(dynamic v) =>
        nullableNumber(v) == null ? '—' : '\$${number(v).toStringAsFixed(2)}';
    final p = palette,
        ready = data['status'] == 'scenario_only',
        rules = asMap(data['rules']);
    final results = asList(data['results']).map(asMap).toList();
    Text line(String en, String zh) => Text(
      w(en, zh),
      style: TextStyle(color: p.muted, fontSize: 12, height: 1.5),
    );
    return Container(
      key: const Key('strategy-hedge-result'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            w('4 · Hedge impact', '4 · 对冲影响'),
            style: TextStyle(
              color: p.text,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          if (!ready)
            line(
              'This hedge could not be calculated with the available contracts. No hedged curve was invented. ${data['reason']}',
              '现有合约无法计算此对冲，未编造对冲曲线。${localizeHedgeReason(text(data['reason']), AppLanguage.zh)}',
            ),
          if (ready) ...[
            line(
              '${data['date']} → ${data['expiry']} · ${data['durationDays']} days · QQQ daily-close allocation stress test.',
              '${data['date']} → ${data['expiry']} · ${data['durationDays']} 天 · 基于 QQQ 收盘价的配置压力实验。',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 28,
              runSpacing: 14,
              children: [
                for (final pair in [
                  (
                    w('Hedge cost / credit', '对冲支出 / 收入'),
                    money(data['netDebit']),
                  ),
                  (w('Whole contracts', '整张合约'), text(data['contracts'])),
                  (
                    w('Stock coverage', '股票金额覆盖'),
                    '${(number(data['actualCoverage']) * 100).toStringAsFixed(1)}%',
                  ),
                  (
                    w('Stock / CTA budget', '股票 / CTA 金额'),
                    '${money(data['equityNotional'])} / ${money(data['ctaNotional'])}',
                  ),
                ])
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pair.$1,
                        style: TextStyle(color: p.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        pair.$2,
                        style: TextStyle(
                          color: p.accent,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            line(
              'Gray: without hedge · Colored: selected hedge · X: QQQ ending price · Y: total portfolio P&L.',
              '灰色：未对冲 · 彩色：所选对冲 · 横轴：QQQ 到期价格 · 纵轴：组合总盈亏。',
            ),
            SizedBox(
              height: 250,
              child: CustomPaint(
                painter: _HedgePayoffPainter(
                  results,
                  text(rules['type']),
                  p,
                  context.isChinese,
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  w('QQQ move', 'QQQ 涨跌'),
                  w('Before hedge', '对冲前'),
                  w('After hedge', '对冲后'),
                  w('Difference', '差额'),
                ].map((s) => DataColumn(label: Text(s))).toList(),
                rows: [
                  for (final move in [-.3, -.2, -.1, 0.0, .1, .3]) ...[
                    DataRow(
                      cells: [
                        DataCell(Text('${(move * 100).round()}%')),
                        for (final r in results)
                          DataCell(
                            Text(
                              money(
                                asList(r['scenarios'])
                                    .map(asMap)
                                    .firstWhere(
                                      (s) =>
                                          (number(s['move']) - move).abs() <
                                          .001,
                                    )['pnl'],
                              ),
                            ),
                          ),
                        DataCell(
                          Text(
                            money(
                              number(
                                    asList(results.last['scenarios'])
                                        .map(asMap)
                                        .firstWhere(
                                          (s) =>
                                              (number(s['move']) - move).abs() <
                                              .001,
                                        )['pnl'],
                                  ) -
                                  number(
                                    asList(results.first['scenarios'])
                                        .map(asMap)
                                        .firstWhere(
                                          (s) =>
                                              (number(s['move']) - move).abs() <
                                              .001,
                                        )['pnl'],
                                  ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            line(
              'Assumed stock beta ${rules['beta']}; CTA return ${(number(rules['ctaReturn']) * 100).round()}%. Uses configured allocation, not realized holdings or valuation-filter cash. Net hedge debit is additional capital; no execution or margin simulation.',
              '股票 Beta 假设 ${rules['beta']}；CTA 收益假设 ${(number(rules['ctaReturn']) * 100).round()}%。采用配置目标，不是实际持仓，不计估值过滤留存现金。净支出需额外资金，不模拟成交或保证金。',
            ),
            const SizedBox(height: 8),
            for (final leg in asList(data['legs']).map(asMap))
              line(
                '${leg['ticker']} · ${number(leg['side']) > 0 ? 'Buy' : 'Sell'} ${leg['contracts']} · mark ${money(leg['mark'])}',
                '${formatOccOptionContract(text(leg['ticker']), contracts: number(leg['contracts']).toInt(), side: number(leg['side']) > 0 ? 'long' : 'short', language: AppLanguage.zh)} · 收盘价 ${money(leg['mark'])}',
              ),
            const SizedBox(height: 8),
            if (rules['type'] == 'collar')
              line(
                'Short QQQ calls are not covered by Guru stocks. Proxy mismatch can create unlimited losses; this is not a covered collar on the actual portfolio.',
                '大师持仓个股不能直接覆盖 QQQ 空头看涨期权（Call）。代理错配可能产生敞口风险，这并非实际股票组合上的备兑领口。',
              ),
            if (rules['type'] == 'put_spread')
              line(
                'Below the lower put strike, the spread payout stops increasing. Stock losses can continue.',
                '跌破较低 Put 行权价后，价差赔付不再增加，股票亏损仍可扩大。',
              ),
          ],
        ],
      ),
    );
  }
}
