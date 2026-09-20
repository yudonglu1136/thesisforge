part of 'main.dart';

// Four research lenses over the same dated observations. No new score, trade
// inference, cash-flow assumption or model write is created by switching lenses.
List<Map<String, dynamic>> discoverManagerSide(
  List<Map<String, dynamic>> managers, {
  required bool additions,
}) {
  final actions = additions ? {'new', 'increased'} : {'reduced', 'sold_out'};
  final rows = managers.where((m) => actions.contains(m['action'])).toList();
  rows.sort((a, b) {
    final aw = nullableNumber(a['weight']), bw = nullableNumber(b['weight']);
    if (aw == null && bw != null) return 1;
    if (bw == null && aw != null) return -1;
    final order = aw == null ? 0 : bw!.compareTo(aw);
    return order != 0 ? order : text(a['name']).compareTo(text(b['name']));
  });
  return rows;
}

double? discoverShareChange(Map<String, dynamic> m) {
  final previous = nullableNumber(m['previousShares']);
  final delta = nullableNumber(m['changeShares']);
  // A new position has no meaningful percentage denominator. Never substitute
  // zero for missing shares or infer corporate-action-adjusted transactions.
  return previous != null && previous > 0 && delta != null
      ? delta / previous
      : null;
}

extension _InvestmentDiscoverLenses on _InvestmentWorkspaceState {
  Color discoverLensColor(String id) =>
      {'reduced', 'exited', 'debate'}.contains(id)
      ? p.secondary
      : id == 'growth'
      ? const Color(0xFF76BCEB)
      : p.accent;

  String discoverLensAction(String id) => switch (id) {
    'new' => w('Inspect new positions', '查看新建仓机构'),
    'increased' => w('Inspect increases', '查看加仓机构'),
    'reduced' => w('Inspect reductions', '查看减仓机构'),
    'exited' => w('Inspect exits', '查看清仓机构'),
    'adds' => w('Compare manager additions', '对比经理增持'),
    'growth' => w('Inspect growth quality', '检验增长质量'),
    'revision' => w('Inspect the value trend', '检验估值趋势'),
    'debate' => w('Explore both sides', '研究分歧双方'),
    _ => w('Explore evidence', '研究证据'),
  };

  String discoverLensQuestion(String id) => switch (id) {
    'new' => w(
      'Which institutions reported starting this position?',
      '哪些机构本季度申报了新建仓？',
    ),
    'increased' => w(
      'Which institutions reported adding to this position?',
      '哪些机构本季度申报了加仓？',
    ),
    'reduced' => w(
      'Which institutions reported reducing this position?',
      '哪些机构本季度申报了减仓？',
    ),
    'exited' => w(
      'Which institutions reported exiting this position?',
      '哪些机构本季度申报了清仓？',
    ),
    'adds' => w(
      'Who is building a position — and how meaningful is it?',
      '谁在增加持仓？这笔仓位有多重要？',
    ),
    'growth' => w(
      'Is revenue growth translating into profit and cash?',
      '收入增长，有没有转化成利润和现金？',
    ),
    'revision' => w('Steady progress, not a one-quarter leap.', '持续改善，而非单季跳涨。'),
    'debate' => w('Who is adding — and who is stepping back?', '谁在增加持仓，谁在减少？'),
    _ => discoverRule(id),
  };

  String discoverLeadLabel() => switch (discoverCollection) {
    'new' => w('New positions', '新建仓机构'),
    'increased' => w('Increased', '加仓机构'),
    'reduced' => w('Reduced', '减仓机构'),
    'exited' => w('Exited', '清仓机构'),
    'adds' => w('Adding', '增持经理'),
    'debate' => w('Adds / trims', '增 / 减持'),
    'revision' => w('Rising quarters', '上升次数'),
    _ => w('Revenue YoY', '收入同比'),
  };
  String discoverLeadValue(Map<String, dynamic> r) =>
      switch (discoverCollection) {
        'new' => text(r['newPositions']),
        'increased' => text(r['increases']),
        'reduced' => text(r['reductions']),
        'exited' => text(r['exits']),
        'adds' => text(r['adds']),
        'debate' => '${r['adds']} / ${r['trims']}',
        'revision' =>
          '${asMap(asMap(r['valuation'])['trend'])['upCount'] ?? '—'} / 7',
        _ => pct(asMap(r['valuation'])['revenueGrowth']),
      };
  String discoverTailLabel() =>
      {
        'new',
        'increased',
        'reduced',
        'exited',
        'adds',
        'debate',
      }.contains(discoverCollection)
      ? w('Median wt.', '仓位中位数')
      : discoverCollection == 'revision'
      ? w('Max drawdown', '最大回撤')
      : discoverCollection == 'growth' && growthQuality.enabled
      ? w('ROIC floor', 'ROIC 最低值')
      : w('Value Δ', '估值变化');
  String discoverTailValue(Map<String, dynamic> r) =>
      {
        'new',
        'increased',
        'reduced',
        'exited',
        'adds',
        'debate',
      }.contains(discoverCollection)
      ? pct(r['medianWeight'])
      : discoverCollection == 'revision'
      ? pct(asMap(asMap(r['valuation'])['trend'])['maxDrawdown'])
      : discoverCollection == 'growth' && growthQuality.enabled
      ? pct(assessGrowthQuality(r, growthQuality).worst)
      : pct(asMap(r['valuation'])['change']);

  Widget lensNote(String en, String zh, {bool caution = false}) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(
      w(en, zh),
      style: TextStyle(
        color: caution ? p.secondary : p.muted,
        fontSize: 12,
        height: 1.5,
      ),
    ),
  );

  Widget lensStat(String title, String value, {Color? color, String? detail}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: p.muted, fontSize: 11)),
          const SizedBox(height: 5),
          Text(
            value,
            style: TextStyle(
              color: color ?? p.text,
              fontSize: 23,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (detail != null)
            Text(
              detail,
              style: TextStyle(color: p.muted, fontSize: 11, height: 1.5),
            ),
        ],
      );

  Widget discoverLensEvidence() {
    final id = discoverCollection;
    final c = opportunityCompany;
    return Container(
      key: ValueKey('discover-lens-$id'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: discoverLensColor(id).withValues(alpha: .4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(discoverLensQuestion(id), style: deskHeading(18)),
          const SizedBox(height: 14),
          if (opportunityCutoff != asOf) ...[
            lensNote(
              'This screen is selected at $asOf. Return to that date to compare its evidence; the historical timeline below remains separate.',
              '本筛选以 $asOf 为截止日。返回该日期后可比较筛选证据；下方历史时间线独立保留。',
            ),
            TextButton(
              onPressed: () =>
                  unawaited(selectOpportunity(opportunityTicker, at: asOf)),
              child: Text(w('Return to screen date', '返回筛选截止日')),
            ),
          ] else ...[
            if ({
              'new',
              'increased',
              'reduced',
              'exited',
              'adds',
              'debate',
            }.contains(id))
              discoverPositioningEvidence(
                debate: id == 'debate',
                action: const {
                  'new': 'new',
                  'increased': 'increased',
                  'reduced': 'reduced',
                  'exited': 'sold_out',
                }[id],
              )
            else if (opportunityDetailLoading)
              label('Loading dated evidence…', '正在加载带日期的证据…')
            else if (c == null)
              lensNote(
                'Detailed model evidence is unavailable. The screen observation is not a substitute for a reviewed company model.',
                '详细模型证据暂不可用；筛选记录不能替代完整公司模型。',
                caution: true,
              )
            else if (id == 'growth')
              discoverGrowthEvidence(c)
            else if (id == 'revision')
              discoverRevisionEvidence(c),
            const SizedBox(height: 14),
            if (c != null && !opportunityDetailLoading)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: ValueKey('lens-$id-research'),
                    onPressed: () => unawaited(
                      openOpportunityValuation(
                        section: id == 'revision' ? 'value' : 'financials',
                      ),
                    ),
                    icon: Icon(
                      id == 'revision' ? Icons.tune : Icons.manage_search,
                      size: 16,
                    ),
                    label: Text(switch (id) {
                      'growth' => w('Read quarterly evidence', '阅读季度财报证据'),
                      'revision' =>
                        asMap(c['templates']).isNotEmpty
                            ? w('Stress-test this valuation', '压力测试这份估值')
                            : w('Inspect valuation method', '检查估值方法'),
                      'debate' => w(
                        'Investigate the disagreement',
                        '检验分歧背后的证据',
                      ),
                      _ => w('Check the business case', '检验公司的基本面'),
                    }),
                  ),
                  if (id != 'revision')
                    TextButton(
                      key: ValueKey('lens-$id-value'),
                      onPressed: () => unawaited(openOpportunityValuation()),
                      child: Text(w('Then test the price', '再检验当前价格')),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget discoverPositioningEvidence({required bool debate, String? action}) {
    final managers = asList(opportunityRow['managers']);
    final adds = discoverManagerSide(managers, additions: true);
    final trims = discoverManagerSide(managers, additions: false);
    final exact = action == null
        ? const <Map<String, dynamic>>[]
        : managers.where((m) => m['action'] == action).toList();
    final newCount = adds.where((m) => m['action'] == 'new').length;
    final unknown = managers
        .where((m) => m['comparisonStatus'] != 'adjusted')
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 24,
          runSpacing: 12,
          children: [
            lensStat(
              action == null
                  ? w('Adding / new', '增持 / 新建')
                  : opportunityAction(action),
              '${action == null ? adds.length : exact.length}',
              color: {'reduced', 'sold_out'}.contains(action)
                  ? p.secondary
                  : p.accent,
            ),
            lensStat(
              action != null
                  ? w('Current holders', '当前持有机构')
                  : debate
                  ? w('Reducing / exited', '减持 / 退出')
                  : w('New positions', '首次持仓'),
              '${action != null
                  ? opportunityRow['managerCount']
                  : debate
                  ? trims.length
                  : newCount}',
              color: debate ? p.secondary : p.text,
            ),
            lensStat(
              w('Median held weight', '持有者仓位中位数'),
              pct(opportunityRow['medianWeight']),
            ),
          ],
        ),
        lensNote(
          'Held ${reportQuarterLabel(opportunityQuarter)} · weights are within each disclosed common-long book, not fund AUM.',
          '持仓季度 ${reportQuarterLabel(opportunityQuarter)} · 仓位为各经理披露普通股多头组合内的占比，不是基金总资产占比。',
        ),
        const SizedBox(height: 14),
        if (action != null)
          discoverManagerGroup(
            exact,
            additions: !{'reduced', 'sold_out'}.contains(action),
            title: opportunityAction(action),
          )
        else if (debate)
          LayoutBuilder(
            builder: (_, constraints) {
              final left = discoverManagerGroup(
                adds,
                additions: true,
                visibleCount: 2,
              );
              final right = discoverManagerGroup(
                trims,
                additions: false,
                visibleCount: 2,
              );
              return constraints.maxWidth >= 460
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: left),
                        const SizedBox(width: 12),
                        Expanded(child: right),
                      ],
                    )
                  : Column(children: [left, const SizedBox(height: 12), right]);
            },
          )
        else
          discoverManagerGroup(adds, additions: true),
        lensNote(
          action != null
              ? 'This is a delayed 13F share-count observation. It does not reveal execution price, timing within the quarter or the manager’s motive.'
              : debate
              ? 'Position changes do not tell us why managers disagree. Check business durability, price paid and portfolio constraints; none of those motives is inferred here.'
              : 'A large percentage increase can start from a tiny holding. Compare the reported share change with the ending portfolio weight before calling it conviction.',
          action != null
              ? '这是有披露延迟的 13F 股数观察，无法得知真实成交价、季度内交易时间或机构动机。'
              : debate
              ? '仓位变化不能证明经理的观点或动机。请分别检验经营持续性、买入价格和组合约束；这里不推断他们为何分歧。'
              : '增持百分比可能来自很小的初始仓位。结合期末组合占比，再判断这笔持仓是否重要。',
        ),
        lensNote(
          unknown > 0
              ? 'Raw reported shares · corporate-action adjustments are unverified for $unknown observations. Delayed 13F disclosures, not confirmed trades.'
              : 'Corporate-action adjustment is recorded in the source. 13F disclosures remain delayed and do not reveal execution prices.',
          unknown > 0
              ? '原始申报股数 · $unknown 条记录的公司行动调整未经核实。13F 存在披露延迟，不是已确认成交。'
              : '来源记录了公司行动调整；13F 仍有披露延迟，无法获知真实成交价。',
          caution: true,
        ),
      ],
    );
  }

  Widget discoverManagerGroup(
    List<Map<String, dynamic>> rows, {
    required bool additions,
    int visibleCount = 3,
    String? title,
  }) {
    final tint = additions ? p.accent : p.secondary;
    return Container(
      key: ValueKey(
        additions ? 'lens-adding-managers' : 'lens-reducing-managers',
      ),
      decoration: BoxDecoration(
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                additions ? Icons.north_east : Icons.south_east,
                color: tint,
                size: 17,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title ??
                      (additions
                          ? w('Added or started', '增持或新建')
                          : w('Reduced or exited', '减持或退出')),
                  style: TextStyle(
                    color: tint,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text('${rows.length}', style: TextStyle(color: tint)),
            ],
          ),
          if (rows.isEmpty)
            lensNote('No matching disclosure in this extract.', '本摘录中没有相应披露。'),
          for (final m in rows.take(visibleCount))
            discoverManagerObservation(m, tint),
          if (rows.length > visibleCount)
            ExpansionTile(
              key: ValueKey(
                'lens-managers-more-${additions ? 'adds' : 'trims'}',
              ),
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                w(
                  'Show all ${rows.length} managers',
                  '查看全部 ${rows.length} 位经理',
                ),
                style: TextStyle(color: tint, fontSize: 12),
              ),
              children: [
                for (final m in rows.skip(visibleCount))
                  discoverManagerObservation(m, tint),
              ],
            ),
        ],
      ),
    );
  }

  Widget discoverManagerObservation(Map<String, dynamic> m, Color tint) {
    String shares(dynamic value) =>
        nullableNumber(value) == null ? '—' : formatNumber(number(value));
    final delta = discoverShareChange(m);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('lens-manager-${m['guruId']}'),
            borderRadius: BorderRadius.circular(6),
            onTap: () {
              updateUI(() {
                managerDesk = true;
                selectedGuru = null;
                discoveryTab = 'gurus';
              });
              navigate('discover');
              unawaited(
                loadGuru(
                  text(m['guruId']),
                  filingId: text(m['accession']),
                  holdingTicker: opportunityTicker,
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  GuruAvatar(
                    guru: {
                      'id': m['guruId'],
                      'name': m['name'],
                      'avatarUrl':
                          m['avatar'] ?? '/guru-avatars/${m['guruId']}.png',
                    },
                    palette: p,
                    size: 34,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          text(m['name']),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          opportunityAction(text(m['action'])),
                          style: TextStyle(color: p.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: p.muted, size: 16),
                ],
              ),
            ),
          ),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              Text(
                '${delta == null ? '—' : '${delta > 0 ? '+' : ''}${pct(delta)}'} ${w('shares', '股数')}',
                style: TextStyle(
                  color: tint,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${pct(m['weight'])} ${w('weight', '仓位')}',
                style: TextStyle(color: p.muted, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            '${w('Reported shares', '申报股数')}: ${shares(m['previousShares'])} → ${shares(m['shares'])}',
            style: TextStyle(color: p.muted, fontSize: 11),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${w('Filed', '披露')} ${text(m['availableAt'], '—')}',
                  style: TextStyle(color: p.faint, fontSize: 11),
                ),
              ),
              if (Uri.tryParse(text(m['sourceUrl']))?.scheme == 'https')
                TextButton(
                  onPressed: () => openBrowserPath(text(m['sourceUrl'])),
                  child: Text(
                    w('Filing', '申报原文'),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget discoverMetricComparison(Map<String, dynamic> c) {
    final metrics = asList(c['metrics']);
    final history = asList(c['history']);
    final latest = history.lastOrNull;
    final previous = history.length >= 2 ? history[history.length - 2] : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          w('Reported inputs · latest vs prior node', '披露指标 · 最新与前一节点'),
          style: TextStyle(
            color: p.text,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        lensNote(
          '${text(previous?['period'], '—')} / ${text(previous?['availableAt'], '—')} → ${text(latest?['period'], '—')} / ${text(latest?['availableAt'], '—')}',
          '${text(previous?['period'], '—')} / ${text(previous?['availableAt'], '—')} → ${text(latest?['period'], '—')} / ${text(latest?['availableAt'], '—')}',
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: label('Metric', '指标', size: 11)),
            SizedBox(width: 61, child: label('Prior', '前值', size: 11)),
            SizedBox(width: 66, child: label('Latest', '最新', size: 11)),
            SizedBox(width: 67, child: label('Δ pp', 'Δ 百分点', size: 11)),
          ],
        ),
        for (final key in [
          'revenueGrowth',
          'operatingMargin',
          'fcfMargin',
          'capexIntensity',
        ])
          Builder(
            builder: (_) {
              final m = metrics.where((m) => m['key'] == key).firstOrNull ?? {};
              final now = nullableNumber(m['value']),
                  prior = nullableNumber(m['previous']);
              final delta = now != null && prior != null ? now - prior : null;
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: p.border)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        metricName(key),
                        style: TextStyle(color: p.text, fontSize: 12),
                      ),
                    ),
                    SizedBox(
                      width: 61,
                      child: Text(
                        pct(prior),
                        style: TextStyle(color: p.muted, fontSize: 11),
                      ),
                    ),
                    SizedBox(
                      width: 66,
                      child: Text(
                        pct(now),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 67,
                      child: Text(
                        delta == null
                            ? '—'
                            : '${delta > 0 ? '+' : ''}${(delta * 100).toStringAsFixed(2)}',
                        style: TextStyle(
                          color: delta == null
                              ? p.muted
                              : key == 'capexIntensity'
                              ? p.text
                              : delta < 0
                              ? p.secondary
                              : p.accent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        lensNote(
          'Revenue growth is quarterly YoY; margins and capex use TTM. These are adjacent reporting nodes, not necessarily different fiscal quarters. Missing is not zero.',
          '收入增速为季度同比；利润率、现金流率和资本开支占比使用 TTM。对比相邻披露节点，不一定是不同财季。缺失不是零。',
        ),
      ],
    );
  }

  Widget discoverGrowthEvidence(Map<String, dynamic> c) {
    final metrics = asList(c['metrics']);
    final fcf = metrics.where((m) => m['key'] == 'fcfMargin').firstOrNull ?? {};
    final now = nullableNumber(fcf['value']),
        prior = nullableNumber(fcf['previous']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        growthQualityEvidence(opportunityRow),
        discoverMetricComparison(c),
        const SizedBox(height: 14),
        Text(
          w('The next diligence question', '下一步要核实的问题'),
          style: TextStyle(
            color: const Color(0xFF76BCEB),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        lensNote(
          now == null || prior == null
              ? 'Cash conversion cannot yet be compared. Check the cash-flow statement before extrapolating the revenue growth.'
              : now < prior
              ? 'FCF margin fell despite this company passing the growth screen. Is this working-capital timing, investment spending, or weaker cash conversion?'
              : 'FCF margin did not decline at the latest node. Check whether growth is organic, recurring and sustainable before extending it into your forecast.',
          now == null || prior == null
              ? '现金流率尚无法比较。先检查现金流量表，再外推收入增速。'
              : now < prior
              ? '公司通过了增长筛选，但自由现金流率下降。原因是营运资本时点、投资支出，还是现金转化变弱？'
              : '最新节点的自由现金流率没有下降。仍需核实增长是否内生、可重复、可持续，再写入预测。',
        ),
        lensNote(
          'Acquisition and base effects are not separated in this screen. Read management guidance and quarterly Q&A before setting your revenue and margin path.',
          '本筛选尚未拆分并购与基数效应。阅读管理层指引和季度问答，再设定收入与利润率路径。',
          caution: true,
        ),
      ],
    );
  }

  Widget discoverRevisionEvidence(Map<String, dynamic> c) {
    final v = asMap(opportunityRow['valuation']);
    final trend = asMap(v['trend']);
    final points = asList(trend['points']);
    final policy = asMap(trend['policy']);
    if (trend['status'] != 'evaluated' || points.length != 8) {
      return lensNote(
        'Eight comparable quarters are not available. Missing history is not a steady trend.',
        '尚无完整的 8 个同口径季度。历史缺失不等于估值稳定。',
        caution: true,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (_, box) {
            final stats = [
              lensStat(
                w('Rising quarters', '上升次数'),
                '${trend['upCount']} / ${trend['transitions']}',
                color: p.accent,
              ),
              lensStat(
                w('Total value growth', '区间估值提升'),
                pct(trend['totalChange']),
                color: p.accent,
              ),
              lensStat(w('Max drawdown', '最大回撤'), pct(trend['maxDrawdown'])),
              lensStat(
                w('Largest quarterly move', '最大单季变动'),
                pct(trend['maxAbsStep']),
              ),
            ];
            return Wrap(
              spacing: 24,
              runSpacing: 14,
              children: [
                for (final stat in stats)
                  SizedBox(
                    width: box.maxWidth < 420 ? (box.maxWidth - 24) / 2 : null,
                    child: stat,
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        SteadyValueChart(
          key: ValueKey('steady-value-$opportunityTicker'),
          points: points,
          palette: p,
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          key: const ValueKey('steady-value-rules'),
          tilePadding: EdgeInsets.zero,
          title: Text(
            w('Why it qualifies · screening rules', '为什么入选 · 筛选规则'),
            style: TextStyle(color: p.accent, fontSize: 13),
          ),
          children: [
            lensNote(
              'Latest 8 consecutive fiscal quarters; at least 6 of 7 changes exceed ${pct(policy['upTolerance'])}. Total value growth ≥ ${pct(policy['minTotalChange'])}; peak-to-trough drawdown ≤ ${pct(policy['maxDrawdown'])}; any quarterly move ≤ ${pct(policy['maxAbsStep'])}.',
              '最近连续 8 个财季，7 次变化中至少 6 次上升超过 ${pct(policy['upTolerance'])}。区间累计提升 ≥ ${pct(policy['minTotalChange'])}；峰谷最大回撤 ≤ ${pct(policy['maxDrawdown'])}；任何单季变动幅度 ≤ ${pct(policy['maxAbsStep'])}。',
            ),
            lensNote(
              'No single quarter supplies more than ${pct(policy['maxGainConcentration'])} of positive log changes (observed: ${pct(trend['gainConcentration'])}). Sort: more rises, then smaller drawdown, then lower variation. These are screening defaults, not validated return predictors.',
              '单季不得贡献超过 ${pct(policy['maxGainConcentration'])} 的正向对数变化（本公司：${pct(trend['gainConcentration'])}）。排序依次看上升次数、较小回撤、较低波动。这是初始筛选规则，不是经过验证的收益预测指标。',
            ),
            lensNote(
              'One latest available observation per fiscal quarter at $asOf. Method, currency, model version and economic route must match; latest observation ≤ ${policy['maxAgeDays']} days old. Gaps or basis changes do not qualify.',
              '以 $asOf 为截止日，每财季只取当时可见的最后一个节点。方法、币种、模型版本与经济口径一致；最新节点距截止日不超过 ${policy['maxAgeDays']} 天。缺季或口径切换不入选。',
            ),
          ],
        ),
        lensNote(
          'Stored model replay, not stock returns. A smooth model does not prove a safe business or an attractive price. Corporate actions are not independently adjusted by this screen.',
          '这是存储模型的历史重演，不是股价收益。曲线稳定不等于公司安全或价格便宜；本筛选不独立调整公司行动。',
        ),
        ExpansionTile(
          key: const ValueKey('latest-value-revision'),
          tilePadding: EdgeInsets.zero,
          title: Text(
            w('Latest revision & financial context', '最新修订与财务背景'),
            style: TextStyle(fontSize: 13, color: p.muted),
          ),
          children: [discoverLatestRevision(c)],
        ),
      ],
    );
  }

  Widget discoverLatestRevision(Map<String, dynamic> c) {
    final v = asMap(opportunityRow['valuation']);
    final before = nullableNumber(v['previousFairValue']),
        after = nullableNumber(v['fairValue']);
    final comparable =
        v['comparable'] == true &&
        before != null &&
        before > 0 &&
        after != null;
    String amount(double? n) => n == null || text(v['currency']).isEmpty
        ? '—'
        : '${currencySymbol(text(v['currency']))}${n.toStringAsFixed(2)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 24,
          runSpacing: 12,
          children: [
            lensStat(
              w('Prior published value', '前次公布估值'),
              comparable ? amount(before) : '—',
              detail: text(v['previousDate'], '—'),
            ),
            lensStat(
              w('Revised published value', '本次公布估值'),
              amount(after),
              color: p.accent,
              detail: text(v['date'], '—'),
            ),
            lensStat(
              w('Revision', '估值变化'),
              comparable ? pct(after / before - 1) : '—',
              color: p.accent,
            ),
          ],
        ),
        lensNote(
          comparable
              ? 'Same method, currency and model version. This is a model revision, not a stock return or a standalone DCF claim.'
              : 'The comparison is incomplete or not on the same basis. No revision percentage is claimed.',
          comparable
              ? '方法、币种和模型版本相同。这是模型估值变化，不是股票收益，也不等同于独立 DCF。'
              : '对比数据不完整或口径不同，不显示修订百分比。',
          caution: !comparable,
        ),
        const SizedBox(height: 16),
        // The two independently bounded reads must refer to the same dates.
        if (asMap(c['snapshot'])['availableAt'] == v['date'] &&
            asList(c['history']).length >= 2 &&
            asList(c['history'])[asList(c['history']).length -
                    2]['availableAt'] ==
                v['previousDate'])
          discoverMetricComparison(c)
        else
          lensNote(
            'Financial comparison is not aligned to these two model dates. Inspect the dated model in Research before attributing the revision.',
            '财务对比尚未对齐这两个模型日期。请在研究页核实对应节点后再解释估值变化。',
          ),
        lensNote(
          'These inputs changed at the same time; they are not a per-share contribution bridge. A causal attribution requires rerunning the model one input at a time. Test whether the new cash-flow assumptions survive your downside case.',
          '这些指标是同期变化，不是逐项金额归因。因果归因需要逐一替换输入重新运行模型。请检验新现金流假设能否经受悲观情景。',
          caution: true,
        ),
      ],
    );
  }
}
