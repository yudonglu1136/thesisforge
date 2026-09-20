part of 'main.dart';

// Transparent screens over the dated disclosure universe, not investment scores.
// Nulls never satisfy a numerical screen and unknown models remain discoverable.
List<Map<String, dynamic>> filterDiscoverCandidates(
  List<Map<String, dynamic>> rows, {
  String collection = 'all',
  String manager = '',
  String coverage = 'all',
  String query = '',
  String sort = 'managers',
  GrowthQualityRules qualityRules = const GrowthQualityRules(),
}) {
  double? value(Map<String, dynamic> row, String key) => nullableNumber(
    key == 'growth'
        ? asMap(row['valuation'])['revenueGrowth']
        : key == 'revision'
        ? asMap(row['valuation'])['change']
        : key == 'gap'
        ? row['modelGap']
        : key == 'managers'
        ? row['managerCount']
        : row[key],
  );
  final actionForCollection = const {
    'new': 'new',
    'increased': 'increased',
    'reduced': 'reduced',
    'exited': 'sold_out',
  }[collection];
  final result = rows.where((r) {
    final included = switch (collection) {
      'new' => (value(r, 'newPositions') ?? -1) > 0,
      'increased' => (value(r, 'increases') ?? -1) > 0,
      'reduced' => (value(r, 'reductions') ?? -1) > 0,
      'exited' => (value(r, 'exits') ?? -1) > 0,
      'adds' => (value(r, 'adds') ?? -1) >= 2,
      'growth' =>
        const {
              'operating_company',
              'multi_method_growth',
              'revenue_stage',
            }.contains(asMap(r['valuation'])['modelRoute']) &&
            (value(r, 'growth') ?? -1) >= qualityRules.growth &&
            (!qualityRules.enabled ||
                assessGrowthQuality(r, qualityRules).passes),
      'revision' => asMap(asMap(r['valuation'])['trend'])['eligible'] == true,
      'debate' =>
        (value(r, 'adds') ?? -1) >= 2 && (value(r, 'trims') ?? -1) >= 2,
      _ => true,
    };
    if (!included) return false;
    if (manager.isNotEmpty &&
        !asList(r['managers']).any(
          (m) =>
              m['guruId'] == manager &&
              (actionForCollection == null ||
                  m['action'] == actionForCollection),
        )) {
      return false;
    }
    final modelled = r['valuationStatus'] == 'available';
    if (coverage == 'modelled' && !modelled) return false;
    if (coverage == 'missing' && modelled) return false;
    return '${r['ticker']} ${r['name']}'.toLowerCase().contains(
      query.trim().toLowerCase(),
    );
  }).toList();
  result.sort((a, b) {
    if (sort == 'quality') {
      final av = assessGrowthQuality(a, qualityRules);
      final bv = assessGrowthQuality(b, qualityRules);
      final floorA = av.complete ? av.worst : null;
      final floorB = bv.complete ? bv.worst : null;
      if (floorA == null && floorB != null) return 1;
      if (floorB == null && floorA != null) return -1;
      final order = floorA == null ? 0 : floorB!.compareTo(floorA);
      return order != 0
          ? order
          : text(a['ticker']).compareTo(text(b['ticker']));
    }
    if (sort == 'revision') {
      final at = asMap(asMap(a['valuation'])['trend']);
      final bt = asMap(asMap(b['valuation'])['trend']);
      // Lexicographic, not an opaque score: more rises, less drawdown,
      // then less quarter-to-quarter variation. Missing metrics sort last.
      for (final key in ['upCount', 'maxDrawdown', 'stepVolatility']) {
        final av = nullableNumber(at[key]), bv = nullableNumber(bt[key]);
        if (av == null && bv != null) return 1;
        if (bv == null && av != null) return -1;
        final order = av == null
            ? 0
            : key == 'upCount'
            ? bv!.compareTo(av)
            : av.compareTo(bv!);
        if (order != 0) return order;
      }
      return text(a['ticker']).compareTo(text(b['ticker']));
    }
    final av = value(a, sort), bv = value(b, sort);
    if (av == null && bv != null) return 1;
    if (bv == null && av != null) return -1;
    final c = av == null ? 0 : bv!.compareTo(av);
    return c != 0 ? c : text(a['ticker']).compareTo(text(b['ticker']));
  });
  return result;
}

extension _InvestmentExplorer on _InvestmentWorkspaceState {
  Widget discoverIntro() => LayoutBuilder(
    builder: (_, c) {
      final compact = c.maxWidth < 620;
      final study = discoveryTab == 'managers' && selectedGuru == null;
      final opportunities = discoveryTab == 'gurus' && selectedGuru == null;
      final showTitle =
          !{'valueflow', 'fundamentals'}.contains(discoveryTab) &&
          (selectedGuru == null ||
              !{'gurus', 'managers'}.contains(discoveryTab));
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!compact && !study)
                      label(
                        'DISCOVER / RESEARCH STARTS HERE',
                        '发现 / 从这里开始研究',
                        size: 11,
                        color: p.accent,
                      ),
                    if (!compact && !study) const SizedBox(height: 10),
                    if (showTitle)
                      Text(
                        study
                            ? w('Guru holdings & consensus', 'Guru 共识持仓与加减仓')
                            : opportunities
                            ? w('13F Insights', '13F 洞察')
                            : compact
                            ? w('Discover', '发现')
                            : w(
                                'Find the signal. Build your case.',
                                '发现线索，形成判断。',
                              ),
                        style: deskHeading(
                          compact
                              ? 28
                              : study
                              ? 34
                              : 30,
                        ),
                      ),
                    if (study) ...[
                      const SizedBox(height: 4),
                      label(
                        'Find stocks Gurus hold in common, then see who added or reduced.',
                        '发现多位 Guru 共同持有的股票，再看谁在加仓、谁在减仓。',
                        size: compact ? 13 : 17,
                      ),
                    ],
                  ],
                ),
              ),
              if (!(compact && study)) ...[
                const SizedBox(width: 12),
                dateControl(),
              ],
            ],
          ),
          if (compact && study) ...[
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerRight, child: dateControl()),
          ],
          if (showTitle && !study && !(compact && opportunityMobileDetail)) ...[
            const SizedBox(height: 10),
            label(
              study
                  ? 'Shortlist a few managers. Compare their style, then study their holdings.'
                  : opportunities
                  ? 'See what every covered 13F institution started, added, reduced or exited — not just the Guru shortlist.'
                  : 'See what managers changed, what the business delivered, and what the price assumes.',
              study
                  ? '选几位经理，比较投资风格，再深入研究他们的持仓。'
                  : opportunities
                  ? '覆盖全部 13F 申报机构的新建仓、加仓、减仓和清仓，不再局限于 Guru 名单。'
                  : '看大佬仓位怎么变、公司交出什么业绩，再检验价格隐含的预期。',
              size: compact ? 12 : 14,
            ),
          ],
        ],
      );
    },
  );
  void persistDiscover() => replaceBrowserQuery({
    ...growthQuality.query,
    'discoverTab': discoveryTab,
    'guru': selectedGuru == null
        ? null
        : text(asMap(selectedGuru?['guru'])['id']),
    'collection': discoverCollection == 'all' ? null : discoverCollection,
    'managerFilter': discoverManager.isEmpty ? null : discoverManager,
    'coverage': discoverCoverage == 'all' ? null : discoverCoverage,
    'sort': discoverSort == 'managers' ? null : discoverSort,
    'discoverSearch': discoverSearch.isEmpty ? null : discoverSearch,
  }, replaceCurrent: true);

  List<Map<String, dynamic>> get discoverMatches => filterDiscoverCandidates(
    asList(opportunities?['rows']),
    collection: discoverCollection,
    manager: discoverManager,
    coverage: discoverCoverage,
    query: discoverSearch,
    sort: discoverSort,
    qualityRules: growthQuality,
  );

  void changeDiscover(VoidCallback change) {
    updateUI(() {
      change();
      opportunityMobileDetail = false;
    });
    persistDiscover();
    final matches = discoverMatches;
    if (matches.isNotEmpty &&
        !matches.any((r) => r['ticker'] == opportunityTicker)) {
      unawaited(
        selectOpportunity(text(matches.first['ticker']), showMobile: false),
      );
    }
  }

  void chooseCollection(String id) => changeDiscover(() {
    discoverCollection = id;
    discoverSort = switch (id) {
      'new' => 'newPositions',
      'increased' => 'increases',
      'reduced' => 'reductions',
      'exited' => 'exits',
      'adds' => 'adds',
      'growth' => growthQuality.enabled ? 'quality' : 'growth',
      'revision' => 'revision',
      _ => 'managers',
    };
    opportunityLens = {'new', 'increased', 'adds'}.contains(id)
        ? 'adds'
        : {'reduced', 'exited'}.contains(id)
        ? 'trims'
        : id == 'revision'
        ? 'value'
        : 'holdings';
    persistOpportunity();
  });

  String discoverRule(String id) => switch (id) {
    'new' => w(
      'Rank companies by managers reporting a new position this quarter.',
      '按本季度申报新建仓的机构数量排名。',
    ),
    'increased' => w(
      'Rank companies by managers reporting a higher share count this quarter.',
      '按本季度申报股数增加的机构数量排名。',
    ),
    'reduced' => w(
      'Rank companies by managers reporting a lower share count this quarter.',
      '按本季度申报股数减少的机构数量排名。',
    ),
    'exited' => w(
      'Rank companies by managers reporting a complete exit this quarter.',
      '按本季度申报清仓的机构数量排名。',
    ),
    'adds' => w(
      'At least 2 managers reported new or increased shares.',
      '至少 2 位经理申报首次持仓或股数增加。',
    ),
    'growth' => w(
      growthQuality.enabled
          ? 'Revenue growth ≥ ${pct(growthQuality.growth)} · ROIC ≥ ${pct(growthQuality.roic)} in ${growthQuality.passingYears}/${growthQuality.years} years.'
          : 'Quarterly revenue growth ≥ ${pct(growthQuality.growth)} · quality filter off.',
      growthQuality.enabled
          ? '收入增长 ≥ ${pct(growthQuality.growth)} · ${growthQuality.passingYears}/${growthQuality.years} 年税前 ROIC ≥ ${pct(growthQuality.roic)}。'
          : '季度收入同比 ≥ ${pct(growthQuality.growth)} · 质量筛选已关闭。',
    ),
    'revision' => w(
      '8 quarters · at least 6 rises · limited drawdowns and jumps.',
      '观察 8 个季度，至少上升 6 次，同时限制回撤与跳变。',
    ),
    'debate' => w(
      'At least 2 managers added and at least 2 reduced or exited.',
      '至少 2 位经理增持，且至少 2 位减持或退出。',
    ),
    _ => w(
      'All observed common-share holdings and reported exits in this quarter.',
      '该季度可见的普通股持仓及申报退出记录。',
    ),
  };

  String discoverCollectionName(String id) => switch (id) {
    'new' => w('New positions', '新建仓排名'),
    'increased' => w('Most increased', '加仓排名'),
    'reduced' => w('Most reduced', '减仓排名'),
    'exited' => w('Exited positions', '清仓排名'),
    'adds' => w('Shared additions', '多人增持'),
    'growth' => w('Growing businesses', '收入增长'),
    'revision' => w('Steadily rising value', '估值稳步提升'),
    'debate' => w('Two sides of the trade', '买卖分歧'),
    _ => w('All opportunities', '全部研究线索'),
  };

  // Retained for the Home research desk, while Discover now uses the full
  // institutional 13F surface above the curated Guru opportunity model.
  // ignore: unused_element
  List<Widget> discoverExplorerPage() {
    final coverage = asMap(opportunities?['coverage']);
    final rows = asList(opportunities?['rows']);
    return [
      Wrap(
        spacing: 18,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (opportunityQuarter.isNotEmpty)
            DropdownButton<String>(
              key: const ValueKey('discover-quarter'),
              value: opportunityQuarter,
              dropdownColor: p.card,
              underline: const SizedBox.shrink(),
              items: [
                for (final q in (opportunities?['quarters'] as List? ?? []))
                  DropdownMenuItem(
                    value: '$q',
                    child: Text(
                      reportQuarterLabel('$q'),
                      style: TextStyle(
                        color: p.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
              onChanged: (q) {
                if (q != null) unawaited(loadOpportunities(quarter: q));
              },
            ),
          label(
            '${coverage['reportedManagers'] ?? '—'} reported / ${coverage['eligibleManagers'] ?? '—'} covered managers · ${coverage['total'] ?? '—'} securities',
            '${coverage['reportedManagers'] ?? '—'} 位本季有申报 / ${coverage['eligibleManagers'] ?? '—'} 位已覆盖机构 · ${coverage['total'] ?? '—'} 只证券',
            size: 12,
          ),
          label(
            '${coverage['modelled'] ?? '—'} comparable valuations',
            '${coverage['modelled'] ?? '—'} 个可比估值',
            size: 12,
            color: p.accent,
          ),
          label('Available by $asOf', '披露截止 $asOf', size: 12),
        ],
      ),
      if (number(coverage['extractedBooks']) > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: label(
            'Historical extracts: manager counts are lower bounds, not full-market consensus.',
            '历史摘录：经理数量为可见下限，不代表全市场共识。',
            size: 12,
            color: p.secondary,
          ),
        ),
      if (opportunityLoading) const LinearProgressIndicator(minHeight: 2),
      if (opportunityError.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  opportunityError,
                  style: TextStyle(color: p.secondary),
                ),
              ),
              TextButton(
                onPressed: () => unawaited(loadOpportunities()),
                child: Text(w('Retry', '重试')),
              ),
            ],
          ),
        ),
      if (opportunities != null) ...[
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (_, c) {
            if (c.maxWidth < 1080 && opportunityMobileDetail) {
              return const SizedBox.shrink();
            }
            const ids = ['new', 'increased', 'reduced', 'exited'];
            if (c.maxWidth < 620) {
              return SizedBox(
                height: 190,
                child: ListView.separated(
                  key: const ValueKey('discover-collection-carousel'),
                  scrollDirection: Axis.horizontal,
                  itemCount: ids.length,
                  separatorBuilder: (_, i) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => SizedBox(
                    width: math.min(280, c.maxWidth - 24),
                    child: discoverCollectionCard(ids[i], rows, compact: true),
                  ),
                ),
              );
            }
            final columns = c.maxWidth >= 1080 ? 4 : 2;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final id in ids)
                  SizedBox(
                    width: (c.maxWidth - (columns - 1) * 12) / columns,
                    height: 216,
                    child: discoverCollectionCard(id, rows),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 26),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            label('Other research lenses', '其他研究视角', size: 11),
            for (final id in const ['adds', 'growth', 'revision', 'debate'])
              OutlinedButton(
                key: ValueKey('discover-collection-$id'),
                onPressed: () => chooseCollection(id),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(discoverCollectionName(id)),
              ),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (_, c) {
            final matches = discoverMatches;
            final wide = c.maxWidth >= 1080;
            final showDetail = matches.any(
              (r) => r['ticker'] == opportunityTicker,
            );
            if (!wide && opportunityMobileDetail && showDetail) {
              return Column(
                key: discoverDetailKey,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () =>
                          updateUI(() => opportunityMobileDetail = false),
                      icon: const Icon(Icons.arrow_back),
                      label: Text(w('Back to discovery', '返回发现列表')),
                    ),
                  ),
                  discoverEvidencePreview(),
                ],
              );
            }
            final list = discoverTable(matches, wide);
            if (!wide) return list;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 6, child: list),
                const SizedBox(width: 22),
                Expanded(
                  flex: 5,
                  child: Container(
                    padding: const EdgeInsets.only(left: 22),
                    decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: p.border)),
                    ),
                    child: showDetail
                        ? discoverEvidencePreview()
                        : Padding(
                            padding: const EdgeInsets.all(24),
                            child: label(
                              'Choose a matching company to inspect its evidence.',
                              '选择匹配公司，查看其证据。',
                            ),
                          ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            w('How these screens work', '筛选规则与数据边界'),
            style: TextStyle(fontSize: 13, color: p.muted),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: label(
                'Universe: common-long holdings disclosed by every covered institution for the selected quarter. Rankings count reported share changes, not verified trades or execution prices; 13F reports are delayed. Missing rows are not treated as exits. Portfolio weights are within each disclosed common-long book, not total fund AUM. Valuation remains supporting evidence, not part of the activity ranking.',
                '范围为所选季度全部覆盖机构披露的普通股多头。排名统计申报股数变化，不代表已确认交易或成交价；13F 存在披露延迟。缺失记录不会被当作清仓。仓位占比是各机构披露普通股多头组合内占比，不是基金总资产占比。估值仅作辅助证据，不参与动作排名。',
                size: 12,
              ),
            ),
          ],
        ),
      ],
    ];
  }

  Widget discoverCollectionCard(
    String id,
    List<Map<String, dynamic>> rows, {
    bool compact = false,
  }) {
    final sort = id == 'new'
        ? 'newPositions'
        : id == 'increased'
        ? 'increases'
        : id == 'reduced'
        ? 'reductions'
        : id == 'exited'
        ? 'exits'
        : id == 'growth'
        ? growthQuality.enabled
              ? 'quality'
              : 'growth'
        : id == 'revision'
        ? 'revision'
        : 'adds';
    final matches = filterDiscoverCandidates(
      rows,
      collection: id,
      sort: sort,
      qualityRules: growthQuality,
    );
    final selected = discoverCollection == id;
    final color = {'reduced', 'exited', 'debate'}.contains(id)
        ? p.secondary
        : id == 'growth'
        ? const Color(0xFF76BCEB)
        : p.accent;
    final icon = switch (id) {
      'new' => Icons.add_circle_outline,
      'increased' => Icons.trending_up,
      'reduced' => Icons.trending_down,
      'exited' => Icons.exit_to_app,
      'adds' => Icons.people_outline,
      'growth' => Icons.bar_chart,
      'revision' => Icons.trending_up,
      _ => Icons.compare_arrows,
    };
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? color.withValues(alpha: .12) : p.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: selected ? color : p.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('discover-collection-$id'),
          onTap: () => chooseCollection(id),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, color: color, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        discoverCollectionName(id),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${matches.length}',
                      style: TextStyle(
                        color: color,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                Text(
                  discoverRule(id),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.muted, fontSize: 11, height: 1.4),
                ),
                const Spacer(),
                for (final r in matches.take(compact ? 1 : 2))
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Row(
                      children: [
                        homeStockLogo(text(r['ticker']), 23),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            text(r['ticker']),
                            style: TextStyle(
                              color: p.text,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          id == 'new'
                              ? w(
                                  '${r['newPositions']} managers',
                                  '${r['newPositions']} 位机构',
                                )
                              : id == 'increased'
                              ? w(
                                  '${r['increases']} managers',
                                  '${r['increases']} 位机构',
                                )
                              : id == 'reduced'
                              ? w(
                                  '${r['reductions']} managers',
                                  '${r['reductions']} 位机构',
                                )
                              : id == 'exited'
                              ? w('${r['exits']} managers', '${r['exits']} 位机构')
                              : id == 'growth'
                              ? pct(asMap(r['valuation'])['revenueGrowth'])
                              : id == 'revision'
                              ? w(
                                  '${asMap(asMap(r['valuation'])['trend'])['upCount']}/7 rises',
                                  '${asMap(asMap(r['valuation'])['trend'])['upCount']}/7 次上升',
                                )
                              : id == 'debate'
                              ? '${r['adds']} ↑ / ${r['trims']} ↓'
                              : w('${r['adds']} managers', '${r['adds']} 位经理'),
                          style: TextStyle(color: color, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                if (matches.isEmpty)
                  label('No matches at this cutoff', '该截止日无匹配', size: 12),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        discoverLensAction(id),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      selected
                          ? Icons.check_circle_outline
                          : Icons.arrow_forward,
                      color: color,
                      size: 15,
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

  Widget discoverSelect(
    String key,
    String value,
    Map<String, String> items,
    ValueChanged<String> onChanged,
    double width,
  ) => SizedBox(
    width: width,
    child: DropdownButtonFormField<String>(
      key: ValueKey('$key-$value'),
      initialValue: items.containsKey(value) ? value : null,
      dropdownColor: p.card,
      isExpanded: true,
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        border: const OutlineInputBorder(),
      ),
      style: TextStyle(color: p.text, fontSize: 12),
      items: [
        for (final e in items.entries)
          DropdownMenuItem(
            value: e.key,
            child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    ),
  );

  Widget discoverTable(List<Map<String, dynamic>> rows, bool sideBySide) {
    final managers = <String, String>{'': w('All managers', '全部经理')};
    for (final r in asList(opportunities?['rows'])) {
      for (final m in asList(r['managers'])) {
        managers[text(m['guruId'])] = text(m['name']);
      }
    }
    if (discoverManager.isNotEmpty && !managers.containsKey(discoverManager)) {
      managers[discoverManager] = w(
        'Manager unavailable at cutoff',
        '该截止日无该经理数据',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                discoverCollectionName(discoverCollection),
                style: deskHeading(20),
              ),
            ),
            TextButton(
              key: const ValueKey('discover-reset'),
              onPressed: () => changeDiscover(() {
                discoverCollection = 'all';
                discoverSearch = '';
                discoverSearchInput.clear();
                discoverManager = '';
                discoverCoverage = 'all';
                discoverSort = 'managers';
                growthQuality = const GrowthQualityRules();
              }),
              child: Text(w('Reset filters', '重置筛选')),
            ),
          ],
        ),
        Text(
          discoverCollection == 'all'
              ? discoverRule(discoverCollection)
              : discoverLensQuestion(discoverCollection),
          style: TextStyle(color: p.muted, fontSize: 12, height: 1.5),
        ),
        if (discoverCollection == 'growth') growthQualityControls(),
        if (discoverCollection == 'revision') ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final title in [
                w('8 quarters · 6+ rises', '8 季度 · 至少 6 次上升'),
                w('Total growth ≥ 10%', '累计提升 ≥ 10%'),
                w('Drawdown ≤ 10%', '回撤 ≤ 10%'),
                w('Quarterly move ≤ 20%', '单季变动 ≤ 20%'),
              ])
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: p.border),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    title,
                    style: TextStyle(fontSize: 11, color: p.muted),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        TextFormField(
          key: const ValueKey('discover-search'),
          controller: discoverSearchInput,
          onChanged: (v) => changeDiscover(() => discoverSearch = v),
          style: TextStyle(color: p.text, fontSize: 14),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 19),
            labelText: w('Search company or ticker', '搜索公司或代码'),
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (_, c) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              discoverSelect(
                'discover-manager',
                discoverManager,
                managers,
                (v) => changeDiscover(() => discoverManager = v),
                math.min(170, c.maxWidth),
              ),
              discoverSelect(
                'discover-coverage',
                discoverCoverage,
                {
                  'all': w('Any coverage', '全部覆盖'),
                  'modelled': w('Comparable model', '有可比模型'),
                  'missing': w('Coverage gaps', '覆盖缺口'),
                },
                (v) => changeDiscover(() => discoverCoverage = v),
                154,
              ),
              discoverSelect(
                'discover-sort',
                discoverSort,
                {
                  'managers': w('Most holders', '持有经理最多'),
                  'newPositions': w('Most new positions', '新建仓机构最多'),
                  'increases': w('Most increases', '加仓机构最多'),
                  'reductions': w('Most reductions', '减仓机构最多'),
                  'exits': w('Most exits', '清仓机构最多'),
                  'adds': w('Most additions', '增持经理最多'),
                  'growth': w('Revenue growth', '收入增速'),
                  'quality': w('ROIC floor', 'ROIC 最低值'),
                  'gap': w('Model gap', '模型价差'),
                  'revision': w('Steadiest value', '估值最稳定'),
                },
                (v) => changeDiscover(() => discoverSort = v),
                146,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        label(
          '${rows.length} matches · select a company to inspect',
          '${rows.length} 个匹配 · 点击公司查看证据',
          size: 11,
        ),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            color: p.panel,
            child: Column(
              children: [
                Icon(Icons.search_off, color: p.muted, size: 28),
                const SizedBox(height: 12),
                label(
                  'No matches for this combination.',
                  '这组条件没有匹配。',
                  color: p.text,
                ),
                const SizedBox(height: 8),
                label(
                  'Try another collection, manager or coverage setting.',
                  '请切换集合、经理或覆盖条件。',
                  size: 12,
                ),
              ],
            ),
          )
        else
          LayoutBuilder(
            builder: (_, c) {
              final detailed = c.maxWidth >= 530;
              return Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 10,
                    ),
                    color: p.panel,
                    child: Row(
                      children: [
                        Expanded(
                          child: label(
                            'Company / ownership',
                            '公司 / 持仓',
                            size: 11,
                          ),
                        ),
                        if (detailed)
                          SizedBox(
                            width: 85,
                            child: Text(
                              discoverLeadLabel(),
                              style: TextStyle(color: p.muted, fontSize: 11),
                            ),
                          ),
                        SizedBox(
                          width: 85,
                          child: label('Model gap', '模型价差', size: 11),
                        ),
                        if (detailed)
                          SizedBox(
                            width: 77,
                            child: Text(
                              discoverTailLabel(),
                              style: TextStyle(color: p.muted, fontSize: 11),
                            ),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: sideBySide
                        ? 540
                        : math.min(
                            640,
                            math.max(
                              360,
                              MediaQuery.sizeOf(context).height * .65,
                            ),
                          ),
                    child: ListView.builder(
                      key: PageStorageKey(
                        'discover-$discoverCollection-$discoverManager-$discoverCoverage-$discoverSort-$opportunityQuarter-$discoverSearch',
                      ),
                      itemCount: rows.length,
                      itemBuilder: (_, i) =>
                          discoverCandidate(rows[i], detailed),
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget discoverCandidate(Map<String, dynamic> r, bool detailed) {
    final selected = r['ticker'] == opportunityTicker,
        v = asMap(r['valuation']);
    final action = const {
      'new': 'new',
      'increased': 'increased',
      'reduced': 'reduced',
      'exited': 'sold_out',
    }[discoverCollection];
    final managers = asList(r['managers'])
        .where(
          (m) =>
              action == null ? number(m['shares']) > 0 : m['action'] == action,
        )
        .take(3)
        .toList();
    final activityCount = switch (discoverCollection) {
      'new' => r['newPositions'],
      'increased' => r['increases'],
      'reduced' => r['reductions'],
      'exited' => r['exits'],
      _ => null,
    };
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? p.accent.withValues(alpha: .1) : Colors.transparent,
        child: InkWell(
          key: ValueKey('discover-candidate-${r['ticker']}'),
          onTap: () => unawaited(selectOpportunity(text(r['ticker']))),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 14),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: selected ? p.accent : Colors.transparent,
                  width: 2,
                ),
                bottom: BorderSide(color: p.border),
              ),
            ),
            child: Row(
              children: [
                homeStockLogo(text(r['ticker']), 33),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              text(r['ticker']),
                              style: TextStyle(
                                color: p.text,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          const SizedBox(width: 9),
                          Text(
                            activityCount == null
                                ? '${r['adds']} ↑  ${r['trims']} ↓'
                                : w(
                                    '$activityCount managers',
                                    '$activityCount 位机构',
                                  ),
                            style: TextStyle(color: p.muted, fontSize: 11),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        text(r['name']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.muted, fontSize: 11),
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          for (final m in managers)
                            Padding(
                              padding: const EdgeInsets.only(right: 3),
                              child: Tooltip(
                                message: text(m['name']),
                                child: GuruAvatar(
                                  guru: {
                                    'id': m['guruId'],
                                    'name': m['name'],
                                    'avatarUrl': m['avatar'],
                                  },
                                  palette: p,
                                  size: 18,
                                ),
                              ),
                            ),
                          Flexible(
                            child: Text(
                              w(
                                action == null
                                    ? '${r['managerCount']} holders'
                                    : '${managers.length == 3 && number(activityCount) > 3 ? '3+' : activityCount} reporting',
                                action == null
                                    ? '${r['managerCount']} 位持有'
                                    : '${managers.length == 3 && number(activityCount) > 3 ? '3+' : activityCount} 位申报',
                              ),
                              maxLines: 1,
                              style: TextStyle(color: p.muted, fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                      if (discoverCollection == 'growth' &&
                          growthQuality.enabled) ...[
                        const SizedBox(height: 7),
                        Text(
                          w(
                            'ROIC ≥ ${pct(growthQuality.roic)} · ${assessGrowthQuality(r, growthQuality).passingYears}/${growthQuality.years} years',
                            'ROIC ≥ ${pct(growthQuality.roic)} · ${assessGrowthQuality(r, growthQuality).passingYears}/${growthQuality.years} 年',
                          ),
                          style: TextStyle(color: p.accent, fontSize: 11),
                        ),
                      ],
                      if (!detailed && discoverCollection == 'revision') ...[
                        const SizedBox(height: 7),
                        Text(
                          w(
                            '${discoverLeadValue(r)} rises · ${discoverTailValue(r)} drawdown',
                            '${discoverLeadValue(r)} 次上升 · 回撤 ${discoverTailValue(r)}',
                          ),
                          style: TextStyle(
                            color: p.accent,
                            fontSize: 11,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (detailed)
                  SizedBox(
                    width: 85,
                    child: Text(
                      discoverLeadValue(r),
                      style: TextStyle(color: p.text, fontSize: 12),
                    ),
                  ),
                SizedBox(
                  width: 85,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pct(r['modelGap']),
                        style: TextStyle(
                          color: nullableNumber(r['modelGap']) == null
                              ? p.muted
                              : number(r['modelGap']) >= 0
                              ? p.accent
                              : p.negative,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        text(v['date'], w('No model', '无模型')),
                        style: TextStyle(color: p.faint, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                if (detailed)
                  SizedBox(
                    width: 77,
                    child: Text(
                      discoverTailValue(r),
                      style: TextStyle(
                        color: number(v['change']) < 0 ? p.negative : p.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget discoverEvidencePreview() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Icon(Icons.manage_search, size: 17, color: p.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              discoverCollection == 'all'
                  ? w('THE EVIDENCE', '研究证据')
                  : discoverLensAction(discoverCollection).toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                color: discoverLensColor(discoverCollection),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      opportunityDetail(),
    ],
  );
}
