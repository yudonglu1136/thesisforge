part of 'main.dart';

class HedgeLabPanel extends StatefulWidget {
  const HedgeLabPanel({super.key, required this.api, required this.palette});
  final ApiClient api;
  final Palette palette;
  @override
  State<HedgeLabPanel> createState() => _HedgeLabPanelState();
}

class _HedgeLabPanelState extends State<HedgeLabPanel> {
  Map<String, dynamic>? data, result;
  String expiry = '',
      put = '',
      lowerPut = '',
      call = '',
      error = '',
      notice = '';
  String active = 'collar';
  bool loading = true, running = false, saving = false, dirty = false;
  int serial = 0;
  double coverage = 1, fee = .65, slippage = .05, stress = -.2;
  final shares = TextEditingController(text: '100');
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  String money(dynamic v) =>
      nullableNumber(v) == null ? '—' : '\$${number(v).toStringAsFixed(2)}';
  TextStyle s([double size = 14, bool bold = false, Color? color]) => TextStyle(
    fontSize: size,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? p.text,
    height: 1.4,
  );
  List<Map<String, dynamic>> get chain => asList(
    data?['chain'],
  ).map(asMap).where((c) => c['expiry'] == expiry).toList();
  List<Map<String, dynamic>> get results =>
      asList(result?['results']).map(asMap).toList();
  Map<String, dynamic> get rules => {
    'date': data?['date'],
    'expiry': expiry,
    'shares': int.tryParse(shares.text),
    'coverage': coverage,
    'fee': fee,
    'slippage': slippage,
    'putTicker': put,
    'shortPutTicker': lowerPut,
    'callTicker': call,
  };
  String name(String id) => switch (id) {
    'unhedged' => w('QQQ · no hedge', 'QQQ · 不对冲'),
    'protective_put' => w('Protective Put', '保护性看跌期权'),
    'collar' => w('Collar', '领口期权对冲'),
    'put_spread' => w('Long Put Spread', '熊市看跌价差'),
    _ => id,
  };
  Color color(String id) => switch (id) {
    'collar' => p.accent,
    'protective_put' => const Color(0xFF6CBDF3),
    'put_spread' => const Color(0xFFE5B859),
    _ => p.muted,
  };
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    serial++;
    shares.dispose();
    super.dispose();
  }

  void change(VoidCallback f) {
    setState(() {
      f();
      dirty = true;
      error = '';
      notice = '';
    });
  }

  Future<void> load([String? date]) async {
    final n = ++serial;
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final d = await widget.api.getJson(
        '/api/investment/hedge${date == null ? '' : '?date=$date'}',
      );
      if (!mounted || n != serial) return;
      setState(() {
        data = d;
        result = null;
        dirty = false;
        final dates = asList(d['expiries'])
            .map(asMap)
            .where((x) => number(x['puts']) >= 2 && number(x['calls']) >= 1)
            .map((x) => text(x['expiry']))
            .toList();
        final base = DateTime.tryParse(text(d['date']));
        dates.sort(
          (a, b) =>
              ((DateTime.parse(a).difference(base ?? DateTime.now()).inDays -
                          35)
                      .abs())
                  .compareTo(
                    (DateTime.parse(
                              b,
                            ).difference(base ?? DateTime.now()).inDays -
                            35)
                        .abs(),
                  ),
        );
        expiry = dates.isEmpty ? '' : dates.first;
        selectDefaults();
        loading = false;
      });
    } catch (_) {
      if (mounted && n == serial) {
        setState(() {
          loading = false;
          error = w(
            'Hedge data could not be loaded. Check the local data connection and retry.',
            '对冲数据未能载入，请检查本地数据连接并重试。',
          );
        });
      }
    }
  }

  void selectDefaults() {
    String near(String type, double target) {
      final rows = chain.where((c) => c['type'] == type).toList()
        ..sort(
          (a, b) => (number(a['strike']) - target).abs().compareTo(
            (number(b['strike']) - target).abs(),
          ),
        );
      return rows.isEmpty ? '' : text(rows.first['ticker']);
    }

    final spot = number(data?['spot']);
    put = near('put', spot * .95);
    lowerPut = near('put', spot * .85);
    call = near('call', spot * 1.05);
  }

  bool get canRun =>
      !loading &&
      !running &&
      expiry.isNotEmpty &&
      [put, lowerPut, call].every((x) => x.isNotEmpty) &&
      (int.tryParse(shares.text) ?? 0) * coverage >= 100;
  Future<void> run() async {
    final request = Map<String, dynamic>.from(rules), n = ++serial;
    setState(() {
      running = true;
      error = '';
      notice = '';
    });
    try {
      final r = await widget.api.postJson(
        '/api/investment/hedge/calculate',
        request,
      );
      if (!mounted || n != serial) return;
      final current = rules;
      setState(() {
        result = r;
        dirty = request.entries.any((e) => current[e.key] != e.value);
        running = false;
      });
    } catch (_) {
      if (mounted && n == serial) {
        setState(() {
          running = false;
          error = w(
            'These legs cannot form a verified comparison. Use the same expiry, a lower short-put strike and positive-volume daily marks; try another strike.',
            '这些合约无法形成有效比较。请使用相同到期日、较低的卖出 Put 行权价及有成交量的收盘价，或换一个行权价。',
          );
        });
      }
    }
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = '';
    });
    try {
      await widget.api.postJson('/api/investment/hedge/save', {
        ...rules,
        'name': 'QQQ · $expiry',
        'operationId': 'hedge_${DateTime.now().microsecondsSinceEpoch}',
      });
      if (mounted) {
        setState(() {
          saving = false;
          notice = w(
            'Saved privately to your account. This is an experiment, not an order.',
            '已私密保存到你的账户。这是研究实验，不是交易指令。',
          );
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = w(
            'Could not save. Your existing experiments are unchanged.',
            '保存失败，已有实验保持不变。',
          );
        });
      }
    }
  }

  Widget box(List<Widget> children, {Color? border}) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: p.panel,
      border: Border.all(color: border ?? p.border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
  Widget note(String en, String zh, {Color? color}) =>
      Text(w(en, zh), style: s(12, false, color ?? p.muted));
  Widget heading(String en, String zh) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Text(w(en, zh), style: s(18, true)),
  );
  Widget leg(
    String en,
    String zh,
    String type,
    String selected,
    ValueChanged<String> onChange,
  ) {
    final rows = chain.where((c) => c['type'] == type).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$en-$expiry-$selected'),
        initialValue: rows.any((c) => c['ticker'] == selected)
            ? selected
            : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: w(en, zh)),
        items: rows
            .map(
              (c) => DropdownMenuItem(
                value: text(c['ticker']),
                child: Text(
                  '${money(c['strike'])}  ·  ${money(c['close'])}',
                  style: s(13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(),
        onChanged: loading
            ? null
            : (v) {
                if (v != null) change(() => onChange(v));
              },
      ),
    );
  }

  Widget controls() => box([
    heading('Build your protection', '设置你的保护方案'),
    note('1  Position size', '1  持仓规模'),
    const SizedBox(height: 10),
    TextField(
      key: const Key('hedge-shares'),
      controller: shares,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: w('QQQ shares', 'QQQ 股数')),
      onChanged: (_) => change(() {}),
    ),
    const SizedBox(height: 10),
    Text(
      w(
        'Target coverage ${(coverage * 100).round()}%',
        '目标覆盖 ${(coverage * 100).round()}%',
      ),
      style: s(13),
    ),
    Slider(
      value: coverage,
      min: .1,
      max: 1,
      divisions: 9,
      label: '${(coverage * 100).round()}%',
      onChanged: (v) => change(() => coverage = v),
    ),
    note(
      'Whole contracts only: 100 shares per contract. Uncovered shares remain exposed.',
      '仅使用整张合约：每张 100 股，未覆盖股数仍承担风险。',
    ),
    const SizedBox(height: 20),
    note('2  Expiry & strikes', '2  到期日与行权价'),
    const SizedBox(height: 10),
    DropdownButtonFormField<String>(
      key: ValueKey('expiry-$expiry'),
      initialValue: expiry.isEmpty ? null : expiry,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: w('Same expiry for all legs', '所有期权使用相同到期日'),
      ),
      items: asList(data?['expiries'])
          .map(asMap)
          .where((x) => number(x['puts']) >= 2 && number(x['calls']) >= 1)
          .map(
            (x) => DropdownMenuItem(
              value: text(x['expiry']),
              child: Text(text(x['expiry']), style: s(13)),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) {
          change(() {
            expiry = v;
            selectDefaults();
          });
        }
      },
    ),
    const SizedBox(height: 12),
    leg(
      'Buy put · protection starts',
      '买入 Put · 保护起点',
      'put',
      put,
      (v) => put = v,
    ),
    leg(
      'Sell lower put · spread limit',
      '卖出较低 Put · 价差保护终点',
      'put',
      lowerPut,
      (v) => lowerPut = v,
    ),
    leg(
      'Sell call · collar upside cap',
      '卖出 Call · 领口上涨上限',
      'call',
      call,
      (v) => call = v,
    ),
    note(
      'Strike · observed daily close per share. These are not executable bid/ask quotes.',
      '行权价 · 每股期权收盘价。不是可成交的买卖报价。',
    ),
    const SizedBox(height: 16),
    ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(w('3  Execution assumptions', '3  成本假设'), style: s(14)),
      children: [
        Text(
          w(
            'Adverse price adjustment ${(slippage * 100).round()}%',
            '不利成交价调整 ${(slippage * 100).round()}%',
          ),
          style: s(13),
        ),
        Slider(
          value: slippage,
          min: 0,
          max: .2,
          divisions: 20,
          label: '${(slippage * 100).round()}%',
          onChanged: (v) => change(() => slippage = v),
        ),
        DropdownButtonFormField<double>(
          initialValue: fee,
          decoration: InputDecoration(
            labelText: w('Opening fee / contract', '每张开仓手续费'),
          ),
          items: [0.0, .65, 1.0, 2.0]
              .map((v) => DropdownMenuItem(value: v, child: Text(money(v))))
              .toList(),
          onChanged: (v) {
            if (v != null) change(() => fee = v);
          },
        ),
        const SizedBox(height: 12),
        note(
          'Expiry payoff only. Exercise/assignment charges, tax and dividends are excluded.',
          '仅模拟到期盈亏，不含行权、指派费用、税费和分红。',
        ),
      ],
    ),
    const SizedBox(height: 16),
    FilledButton.icon(
      key: const Key('hedge-run'),
      onPressed: canRun ? run : null,
      icon: Icon(running ? Icons.hourglass_empty : Icons.compare_arrows),
      label: Text(
        w(
          running ? 'Calculating…' : 'Compare hedges',
          running ? '计算中…' : '比较对冲方案',
        ),
      ),
    ),
    if (!canRun && !running)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: note(
          'Choose available legs and cover at least 100 shares.',
          '请选择有数据的合约，且至少覆盖 100 股。',
        ),
      ),
  ]);
  Widget explanation() => box([
    heading('What are you giving up to reduce risk?', '为了降低风险，你付出了什么？'),
    for (final row in [
      ('protective_put', 'Pay a premium. Keep the upside.', '支付权利金，保留上涨空间。'),
      ('collar', 'Sell upside to help fund protection.', '卖出上涨空间，补贴保护成本。'),
      (
        'put_spread',
        'Lower cost, but protection stops below the short put.',
        '降低成本，但跌破卖出 Put 的行权价后，额外保护不再增加。',
      ),
    ])
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, color: color(row.$1), size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name(row.$1), style: s(16, true)),
                  const SizedBox(height: 4),
                  Text(w(row.$2, row.$3), style: s(13, false, p.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    const Divider(),
    note(
      'Compare hedges plots your QQQ position with each overlay at expiry. It does not simulate historical returns or hedge an unrelated portfolio.',
      '点击“比较对冲方案”，查看 QQQ 持仓加上各方案的到期盈亏。不是历史收益回测，也不代表其他组合的对冲效果。',
    ),
  ]);
  Widget output() {
    final chosen = results.firstWhere(
      (r) => r['strategy'] == active,
      orElse: () => results.first,
    );
    final scenarios = asList(chosen['scenarios']).map(asMap).toList();
    final event = scenarios.firstWhere(
      (r) => (number(r['move']) - stress).abs() < .0001,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (dirty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              w(
                'Inputs changed. Compare again to update these results.',
                '参数已修改。请重新比较，以下仍是上次结果。',
              ),
              style: s(13, true, const Color(0xFFE5B859)),
            ),
          ),
        box([
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: [
              Text(
                w('Your position, with and without protection', '对冲前后，你的持仓会怎样'),
                style: s(20, true),
              ),
              Text(
                w('AT EXPIRY · NOT A BACKTEST', '到期情景 · 非历史回测'),
                style: s(11, true, p.accent),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${result?['rules']['date']} → ${result?['rules']['expiry']}  ·  ${result?['coveredShares']} ${w('shares covered', '股已覆盖')}  ·  ${result?['uncoveredShares']} ${w('uncovered', '股未覆盖')}',
            style: s(12, false, p.muted),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: results
                .map(
                  (r) => ChoiceChip(
                    label: Text(name(text(r['strategy']))),
                    selected: active == r['strategy'],
                    onSelected: (_) =>
                        setState(() => active = text(r['strategy'])),
                    avatar: Icon(
                      Icons.circle,
                      size: 10,
                      color: color(text(r['strategy'])),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 12),
          Semantics(
            label: w(
              'Expiry profit and loss against QQQ ending price. Exact scenarios follow below.',
              '到期盈亏随 QQQ 价格变化的情景图，下方可查看具体数值。',
            ),
            child: SizedBox(
              height: 260,
              child: CustomPaint(
                painter: _HedgePayoffPainter(
                  results,
                  active,
                  p,
                  context.isChinese,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            active == 'put_spread'
                ? w(
                    'Below ${money(chosen['protectionEnds'])}, the spread payout is capped. Your QQQ losses can keep growing.',
                    '跌破 ${money(chosen['protectionEnds'])} 后，价差支付达到上限，QQQ 持仓亏损仍可能扩大。',
                  )
                : active == 'collar'
                ? w(
                    'The covered shares give up gains above the call strike. Uncovered shares do not have a floor.',
                    '被覆盖股数放弃 Call 行权价以上的收益；未覆盖股数没有保护底线。',
                  )
                : w(
                    'This is an expiry payoff, not a path-dependent risk estimate.',
                    '这是到期盈亏，不是持有期间的路径风险估计。',
                  ),
            style: s(12, false, p.muted),
          ),
        ]),
        const SizedBox(height: 18),
        box([
          heading('Stress test the ending price', '测试到期价格情景'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [-.5, -.3, -.2, -.1, 0.0, .1, .3]
                .map(
                  (v) => ChoiceChip(
                    label: Text('${v > 0 ? '+' : ''}${(v * 100).round()}%'),
                    selected: stress == v,
                    onSelected: (_) => setState(() => stress = v),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 34,
            runSpacing: 16,
            children: [
              metric(w('QQQ at expiry', 'QQQ 到期价格'), money(event['price'])),
              metric(
                w('Position P&L', '持仓盈亏'),
                money(event['pnl']),
                number(event['pnl']) < 0 ? p.negative : p.accent,
              ),
              metric(w('Net hedge debit', '对冲净支出'), money(chosen['netDebit'])),
              metric(
                w('Worst expiry loss*', '最差到期亏损*'),
                money(chosen['maxLoss']),
              ),
            ],
          ),
          const SizedBox(height: 14),
          note(
            '*Across non-negative QQQ prices; includes the QQQ holding and opening hedge costs. Negative debit means a net credit.',
            '*覆盖 QQQ 非负价格范围，包含 QQQ 持仓与开仓对冲成本。净支出为负表示净收入。',
          ),
        ]),
        const SizedBox(height: 18),
        box([
          heading('Compare the trade-offs', '比较各方案的取舍'),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 24,
              columns: [
                w('Overlay', '对冲方案'),
                w('Net debit', '净支出'),
                w('At −20%', '下跌 20%'),
                w('At +20%', '上涨 20%'),
                w('Upside cap', '最大上涨盈利'),
              ].map((x) => DataColumn(label: Text(x, style: s(12)))).toList(),
              rows: results.map((r) {
                final ss = asList(r['scenarios']).map(asMap);
                double at(double move) => number(
                  ss.firstWhere(
                    (x) => (number(x['move']) - move).abs() < .001,
                  )['pnl'],
                );
                return DataRow(
                  selected: active == r['strategy'],
                  onSelectChanged: (_) =>
                      setState(() => active = text(r['strategy'])),
                  cells: [
                    name(text(r['strategy'])),
                    money(r['netDebit']),
                    money(at(-.2)),
                    money(at(.2)),
                    r['maxGain'] == null
                        ? w('Uncapped', '无上限')
                        : money(r['maxGain']),
                  ].map((x) => DataCell(Text(x, style: s(12)))).toList(),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: dirty || saving ? null : save,
            icon: const Icon(Icons.bookmark_add_outlined),
            label: Text(
              w(
                saving ? 'Saving…' : 'Save private experiment',
                saving ? '保存中…' : '私密保存实验',
              ),
            ),
          ),
        ]),
        const SizedBox(height: 18),
        box([
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              w('Exact legs & data evidence', '具体合约与数据依据'),
              style: s(15, true),
            ),
            children: [
              for (final l in asList(chosen['legs']).map(asMap))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        context.isChinese
                            ? '${formatOccOptionContract(text(l['ticker']), language: AppLanguage.zh)}（${text(l['ticker'])}）'
                            : text(l['ticker']),
                        style: s(13, true),
                      ),
                      Text(
                        '${number(l['side']) > 0 ? w('Buy', '买入') : w('Sell', '卖出')} ${l['contracts']} × 100 · ${w('close', '收盘价')} ${money(l['mark'])} · ${w('assumed fill', '假设成交价')} ${money(l['assumedFill'])}',
                        style: s(12, false, p.muted),
                      ),
                      Text(
                        '${l['date']} · Polygon · ${w('volume', '成交量')} ${l['volume']}',
                        style: s(12, false, p.muted),
                      ),
                    ],
                  ),
                ),
              note(
                'American-style options may be assigned early, especially around distributions. Holding to expiry and simultaneous exercise are simplifying assumptions.',
                '美式期权可能提前指派，尤其在分红附近。持有至到期及同步行权均为简化假设。',
              ),
            ],
          ),
        ]),
      ],
    );
  }

  Widget metric(String title, String value, [Color? c]) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: s(12, false, p.muted)),
      const SizedBox(height: 6),
      Text(value, style: s(24, true, c)),
    ],
  );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        w('HEDGE / QQQ PROTECTION LAB', '对冲 / QQQ 保护实验室'),
        style: s(12, true, p.accent),
      ),
      const SizedBox(height: 12),
      Text(
        w('Keep the position. Shape the risk.', '保留持仓，调整风险。'),
        style: s(30, true),
      ),
      const SizedBox(height: 8),
      note(
        'Compare the cost of protection, the downside it covers and the upside you give up.',
        '比较保护成本、能够覆盖的下跌区间，以及为此放弃的上涨空间。',
      ),
      const SizedBox(height: 20),
      if (loading) const LinearProgressIndicator(),
      if (error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: box([
            Text(error, style: s(13, false, p.negative)),
            TextButton(
              onPressed: () => load(),
              child: Text(w('Reload hedge data', '重新载入对冲数据')),
            ),
          ]),
        ),
      if (notice.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(notice, style: s(13, false, p.accent)),
        ),
      if (data != null) ...[
        box([
          Wrap(
            spacing: 30,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield_outlined, color: p.accent, size: 30),
                  const SizedBox(width: 12),
                  metric('QQQ', money(data?['spot'])),
                ],
              ),
              metric(
                w('Market observations', '市场数据日期'),
                text(data?['date'], '—'),
              ),
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('date-${data?['date']}'),
                  initialValue: asList(data?['dates']).contains(data?['date'])
                      ? text(data?['date'])
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: w('Observation date', '数据观察日'),
                  ),
                  items: asList(data?['dates'])
                      .map(
                        (v) => DropdownMenuItem(
                          value: text(v),
                          child: Text(text(v), style: s(13)),
                        ),
                      )
                      .toList(),
                  onChanged: loading
                      ? null
                      : (v) {
                          if (v != null) load(v);
                        },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          note(
            'Daily-close scenario · no bid/ask entitlement · not live trading. Hedge dates are independent of the stock-research cutoff.',
            '收盘价情景实验 · 暂无买卖盘口（Bid/Ask）行情权限 · 非实时交易。对冲日期独立于股票研究截止日。',
            color: const Color(0xFFE5B859),
          ),
        ]),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (_, constraints) => constraints.maxWidth >= 1050
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 330, child: controls()),
                    const SizedBox(width: 20),
                    Expanded(child: result == null ? explanation() : output()),
                  ],
                )
              : Column(
                  children: [
                    controls(),
                    const SizedBox(height: 20),
                    result == null ? explanation() : output(),
                  ],
                ),
        ),
        const SizedBox(height: 18),
        if (asList(data?['saved']).isNotEmpty)
          box([
            heading('Your saved experiments', '你保存的实验'),
            for (final saved in asList(
              data?['saved'],
            ).reversed.take(8).map(asMap))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.bookmark_outline, color: p.accent),
                title: Text(text(saved['name']), style: s(14)),
                subtitle: Text(
                  '${saved['recordedAt']}',
                  style: s(12, false, p.muted),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => setState(() {
                  result = saved;
                  dirty = true;
                  notice = w(
                    'Viewing a saved snapshot. Current controls have not been replaced.',
                    '正在查看已保存快照，当前输入参数没有被替换。',
                  );
                }),
              ),
          ]),
        const SizedBox(height: 18),
        note(
          'Research only. A QQQ hedge is not a verified hedge for your Guru portfolio. Historical rolling backtests require separate quote, assignment and dividend validation.',
          '仅供研究。QQQ 对冲并非经过验证的 Guru 组合对冲。历史滚动回测仍需独立核验报价、指派与分红。',
        ),
      ],
    ],
  );
}

class _HedgePayoffPainter extends CustomPainter {
  _HedgePayoffPainter(this.results, this.active, this.p, this.chinese);
  final List<Map<String, dynamic>> results;
  final String active;
  final Palette p;
  final bool chinese;
  @override
  void paint(Canvas canvas, Size size) {
    final points = results
        .expand((r) => asList(r['curve']).map(asMap))
        .toList();
    if (points.isEmpty) return;
    final left = 64.0,
        right = size.width - 10,
        top = 12.0,
        bottom = size.height - 40;
    final maxX = points.map((x) => number(x['price'])).reduce(math.max);
    final minY = points.map((x) => number(x['pnl'])).reduce(math.min);
    final maxY = points.map((x) => number(x['pnl'])).reduce(math.max);
    Offset pos(double x, double y) => Offset(
      left + x / maxX * (right - left),
      bottom - (y - minY) / math.max(1, maxY - minY) * (bottom - top),
    );
    void txt(String text, Offset at) {
      final t = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: p.muted, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      t.paint(canvas, at);
    }

    for (var i = 0; i <= 4; i++) {
      final y = minY + (maxY - minY) * i / 4;
      canvas.drawLine(
        pos(0, y),
        pos(maxX, y),
        Paint()
          ..color = p.border
          ..strokeWidth = 1,
      );
      txt('\$${(y / 1000).toStringAsFixed(1)}k', Offset(0, pos(0, y).dy - 6));
      final x = maxX * i / 4;
      txt('\$${x.round()}', Offset(pos(x, minY).dx - 16, bottom + 8));
    }
    canvas.drawLine(
      pos(0, 0),
      pos(maxX, 0),
      Paint()
        ..color = p.muted
        ..strokeWidth = 1,
    );
    for (final r in [
      ...results.where((r) => r['strategy'] != active),
      ...results.where((r) => r['strategy'] == active),
    ]) {
      final id = text(r['strategy']);
      final c = id == 'collar'
          ? p.accent
          : id == 'protective_put'
          ? const Color(0xFF6CBDF3)
          : id == 'put_spread'
          ? const Color(0xFFE5B859)
          : p.muted;
      final path = Path();
      var first = true;
      for (final pt in asList(r['curve']).map(asMap)) {
        final o = pos(number(pt['price']), number(pt['pnl']));
        if (first) {
          path.moveTo(o.dx, o.dy);
          first = false;
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = c.withValues(alpha: id == active ? 1 : .45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = id == active ? 3 : 1.4,
      );
    }
    txt(
      chinese ? 'QQQ 到期价格 →' : 'QQQ price at expiry →',
      Offset(left, size.height - 10),
    );
  }

  @override
  bool shouldRepaint(covariant _HedgePayoffPainter old) =>
      old.results != results || old.active != active || old.chinese != chinese;
}
