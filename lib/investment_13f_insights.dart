part of 'main.dart';

extension _Institutional13FInsights on _InvestmentWorkspaceState {
  String _insightKey(String action) => switch (action) {
    'new' => 'newPositions',
    'reduced' => 'reductions',
    'exited' => 'exits',
    _ => 'increases',
  };

  String _insightName(String action) => switch (action) {
    'new' => w('New positions', '新建仓'),
    'reduced' => w('Reduced positions', '减仓'),
    'exited' => w('Exited positions', '清仓'),
    _ => w('Increased positions', '加仓'),
  };

  Color _insightColor(String action) =>
      {'reduced', 'exited'}.contains(action) ? p.secondary : p.accent;

  void _select13FInsightAction(String action) {
    final key = _insightKey(action);
    final ranked =
        asList(
            institutional13f?['rows'],
          ).where((row) => number(row[key]) > 0).toList()
          ..sort((a, b) => number(b[key]).compareTo(number(a[key])));
    final ticker = text(ranked.firstOrNull?['ticker']);
    updateUI(() {
      insightAction = action;
      insightSearch = '';
      insightSearchInput.clear();
    });
    if (ticker.isNotEmpty) {
      unawaited(select13FInsightStock(ticker));
    } else {
      _persist13FInsights();
    }
  }

  void _persist13FInsights() => replaceBrowserQuery({
    'insightQuarter': insightQuarter,
    'insightAction': insightAction == 'increased' ? null : insightAction,
    'insightView': insightPerspective == 'stocks' ? null : insightPerspective,
    'insightRank': insightStockRanking == 'holders'
        ? null
        : insightStockRanking,
    'insightLimit': insightInstitutionLimit == 8
        ? null
        : '$insightInstitutionLimit',
    'insightTicker': insightTicker,
    'insightInvestor': insightInvestor,
    'insightSearch': insightSearch.isEmpty ? null : insightSearch,
  }, replaceCurrent: true);

  String _insightDetailCacheKey(String ticker, [String? quarter]) =>
      '$asOf|${quarter ?? insightQuarter}|$ticker';

  void _merge13FInsightDetail(String ticker, Map<String, dynamic> detail) {
    final current = Map<String, dynamic>.from(institutional13f ?? {});
    final details = Map<String, dynamic>.from(asMap(current['details']));
    details[ticker] = detail;
    current['details'] = details;
    institutional13f = current;
  }

  Future<void> load13FInsights({String? quarter}) async {
    final serial = ++insightSerial, cutoff = asOf;
    final requestedInsightTicker = insightTicker;
    updateUI(() {
      insightLoading = true;
      insightError = '';
    });
    try {
      final selected = quarter ?? insightQuarter;
      final requestedTicker = insightTicker.isEmpty
          ? ''
          : '&ticker=$insightTicker';
      final data = await widget.api.getJson(
        '/api/investment/13f-insights?asOf=$cutoff${selected.isEmpty ? '' : '&quarter=$selected'}$requestedTicker',
      );
      if (!mounted || serial != insightSerial || cutoff != asOf) return;
      updateUI(() {
        institutional13f = data;
        insightQuarter = text(data['reportDate']);
        final rows = asList(data['rows']);
        final rowTickers = rows.map((row) => text(row['ticker'])).toSet();
        final serverTicker = text(data['selectedTicker']);
        final requestedStillCurrent = insightTicker == requestedInsightTicker;
        if (!rowTickers.contains(insightTicker) || requestedStillCurrent) {
          insightTicker = rowTickers.contains(requestedInsightTicker)
              ? requestedInsightTicker
              : rowTickers.contains(serverTicker)
              ? serverTicker
              : text(rows.firstOrNull?['ticker']);
        }
        final cacheKey = _insightDetailCacheKey(insightTicker, insightQuarter);
        final cached = insightDetailCache[cacheKey];
        if (cached != null) _merge13FInsightDetail(insightTicker, cached);
        final institutions = asList(data['institutions']);
        if (!institutions.any((row) => row['investorId'] == insightInvestor)) {
          insightInvestor = text(institutions.firstOrNull?['investorId']);
        }
      });
      _persist13FInsights();
      final loaded = asMap(asMap(institutional13f?['details'])[insightTicker]);
      if (insightTicker.isNotEmpty && loaded.isEmpty) {
        unawaited(_load13FInsightDetail(insightTicker));
      }
    } catch (_) {
      if (mounted && serial == insightSerial) {
        updateUI(
          () => insightError = w(
            'Could not load the all-institution 13F tape.',
            '暂时无法加载全机构 13F 数据。',
          ),
        );
      }
    } finally {
      if (mounted && serial == insightSerial) {
        updateUI(() => insightLoading = false);
      }
    }
  }

  Future<void> select13FInsightStock(String ticker) async {
    updateUI(() => insightTicker = ticker);
    _persist13FInsights();
    await _load13FInsightDetail(ticker);
  }

  Future<void> _load13FInsightDetail(String ticker) async {
    final detail = asMap(asMap(institutional13f?['details'])[ticker]);
    if (detail.isNotEmpty) return;
    final serial = insightSerial, cutoff = asOf, quarter = insightQuarter;
    if (quarter.isEmpty) return;
    final cacheKey = _insightDetailCacheKey(ticker, quarter);
    final cached = insightDetailCache[cacheKey];
    if (cached != null) {
      if (mounted && serial == insightSerial && cutoff == asOf) {
        updateUI(() => _merge13FInsightDetail(ticker, cached));
      }
      return;
    }
    if (insightDetailLoading.contains(cacheKey)) return;
    updateUI(() => insightDetailLoading.add(cacheKey));
    try {
      final data = await widget.api.getJson(
        '/api/investment/13f-insights/${Uri.encodeComponent(ticker)}?asOf=$cutoff&quarter=$quarter',
      );
      if (!mounted || serial != insightSerial || cutoff != asOf) return;
      final nextDetail = asMap(data['details']);
      updateUI(() {
        insightDetailCache[cacheKey] = nextDetail;
        _merge13FInsightDetail(ticker, nextDetail);
      });
    } catch (_) {
      // Aggregate ranking remains usable when a bounded detail request fails.
    } finally {
      if (mounted) {
        updateUI(() => insightDetailLoading.remove(cacheKey));
      }
    }
  }

  String _integer(dynamic value) {
    final n = nullableNumber(value)?.round();
    if (n == null) return '—';
    return n.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
  }

  String _usdMillions(dynamic value) {
    final n = nullableNumber(value);
    if (n == null) return '—';
    if (n.abs() >= 1000000) return '\$${(n / 1000000).toStringAsFixed(1)}T';
    if (n.abs() >= 1000) return '\$${(n / 1000).toStringAsFixed(1)}B';
    return '\$${n.toStringAsFixed(1)}M';
  }

  String _reportedShares(dynamic value) {
    final thousands = nullableNumber(value);
    if (thousands == null) return '—';
    final shares = thousands * 1000;
    if (shares.abs() >= 1000000000) {
      return '${(shares / 1000000000).toStringAsFixed(2)}B';
    }
    if (shares.abs() >= 1000000) {
      return '${(shares / 1000000).toStringAsFixed(1)}M';
    }
    if (shares.abs() >= 1000) return '${(shares / 1000).toStringAsFixed(0)}K';
    return _integer(shares);
  }

  List<Map<String, dynamic>> _insightStocks() {
    final key = _insightKey(insightAction);
    final query = insightSearch.trim().toLowerCase();
    final rows = asList(institutional13f?['rows']).where((row) {
      if (number(row[key]) <= 0) return false;
      return query.isEmpty ||
          '${row['ticker']} ${row['name']}'.toLowerCase().contains(query);
    }).toList();
    rows.sort((a, b) {
      final primary = insightStockRanking == 'shares'
          ? number(b['currentUnitsK']).compareTo(number(a['currentUnitsK']))
          : number(b['holders']).compareTo(number(a['holders']));
      if (primary != 0) return primary;
      final count = number(b[key]).compareTo(number(a[key]));
      if (count != 0) return count;
      return text(a['ticker']).compareTo(text(b['ticker']));
    });
    return rows;
  }

  List<Map<String, dynamic>> _insightInstitutions() {
    final key = _insightKey(insightAction);
    final query = insightSearch.trim().toLowerCase();
    final rows = asList(institutional13f?['institutions']).where((row) {
      if (number(row[key]) <= 0) return false;
      return query.isEmpty ||
          '${row['name']} ${row['investorId']}'.toLowerCase().contains(query);
    }).toList();
    rows.sort((a, b) {
      final count = number(b[key]).compareTo(number(a[key]));
      if (count != 0) return count;
      return number(b['currentValueM']).compareTo(number(a['currentValueM']));
    });
    return rows;
  }

  List<Widget> institutional13fInsightsPage() {
    final data = institutional13f;
    final coverage = asMap(data?['coverage']);
    return [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: p.accent.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.accent.withValues(alpha: .35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.account_balance_outlined, color: p.accent, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: label(
                'Full 13F universe · Rankings use every covered institutional filer. Guru selections do not change this page.',
                '全量 13F 机构口径 · 排名使用全部已覆盖申报机构，Guru 的选择不会影响本页。',
                size: 13,
                color: p.text,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 18,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (insightQuarter.isNotEmpty)
            DropdownButton<String>(
              key: const ValueKey('13f-quarter'),
              value: insightQuarter,
              dropdownColor: p.card,
              underline: const SizedBox.shrink(),
              items: [
                for (final q in (data?['quarters'] as List? ?? []))
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
              onChanged: (value) {
                if (value != null) unawaited(load13FInsights(quarter: value));
              },
            ),
          label(
            '${_integer(coverage['currentFilers'])} filers · ${_integer(coverage['securities'])} securities · ${_integer(coverage['comparablePositions'])} comparable positions',
            '${_integer(coverage['currentFilers'])} 家申报机构 · ${_integer(coverage['securities'])} 只证券 · ${_integer(coverage['comparablePositions'])} 个可比仓位',
            size: 12,
          ),
          label(
            'Available after ${text(data?['availableAt'])}',
            '统一可用日 ${text(data?['availableAt'])}',
            size: 12,
            color: p.accent,
          ),
        ],
      ),
      if (insightLoading)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: LinearProgressIndicator(minHeight: 2),
        ),
      if (insightError.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(insightError, style: TextStyle(color: p.secondary)),
              ),
              TextButton(
                onPressed: () => unawaited(load13FInsights()),
                child: Text(w('Retry', '重试')),
              ),
            ],
          ),
        ),
      if (data != null) ...[
        const SizedBox(height: 14),
        _insightActionCards(),
        const SizedBox(height: 22),
        _insightWorkbench(),
        const SizedBox(height: 18),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            w('Methodology & limits', '方法与数据边界'),
            style: TextStyle(color: p.muted, fontSize: 13),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: label(
                'Common-stock positions only. New and exited positions compare adjacent quarter-end books; increases and reductions compare split-adjusted reported units. Counts use the full SF3 filer universe, while the detail panel shows the largest reporting institutions. 13F disclosures are delayed and do not reveal trade dates or execution prices.',
                '仅统计普通股持仓。新建仓与清仓比较相邻季末组合；加仓与减仓按拆股调整后的申报股数比较。排名计数覆盖完整 SF3 机构范围，右侧明细展示动作规模最大的申报机构。13F 存在披露延迟，不提供实际交易日期或成交价。',
                size: 12,
              ),
            ),
          ],
        ),
      ],
    ];
  }

  Widget _insightActionCards() => LayoutBuilder(
    builder: (_, constraints) {
      const actions = ['new', 'increased', 'reduced', 'exited'];
      if (constraints.maxWidth < 700) {
        return SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: actions.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, index) => SizedBox(
              width: math.min(286, constraints.maxWidth - 24),
              child: _insightActionCard(actions[index]),
            ),
          ),
        );
      }
      final columns = constraints.maxWidth >= 1120 ? 4 : 2;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final action in actions)
            SizedBox(
              width: (constraints.maxWidth - (columns - 1) * 12) / columns,
              height: 202,
              child: _insightActionCard(action),
            ),
        ],
      );
    },
  );

  Widget _insightActionCard(String action) {
    final key = _insightKey(action), color = _insightColor(action);
    final rows = asList(institutional13f?['rows'])
      ..sort((a, b) => number(b[key]).compareTo(number(a[key])));
    final total = asMap(institutional13f?['activity'])[key];
    final selected = insightAction == action;
    return Material(
      color: selected ? color.withValues(alpha: .12) : p.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: selected ? color : p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('13f-action-$action'),
        onTap: () => _select13FInsightAction(action),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    switch (action) {
                      'new' => Icons.add_circle_outline,
                      'reduced' => Icons.trending_down,
                      'exited' => Icons.exit_to_app,
                      _ => Icons.trending_up,
                    },
                    color: color,
                    size: 19,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _insightName(action),
                      style: TextStyle(
                        color: p.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    _integer(total),
                    style: TextStyle(
                      color: color,
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              label(
                action == 'new'
                    ? 'First reported position vs prior quarter.'
                    : action == 'exited'
                    ? 'Position no longer reported this quarter.'
                    : 'Split-adjusted reported shares moved quarter over quarter.',
                action == 'new'
                    ? '相对上季度首次申报持仓。'
                    : action == 'exited'
                    ? '本季度不再申报该持仓。'
                    : '经拆股调整后的申报股数环比变化。',
                size: 11,
              ),
              const Spacer(),
              for (final row in rows.where((r) => number(r[key]) > 0).take(2))
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Row(
                    children: [
                      homeStockLogo(text(row['ticker']), 22),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          text(row['ticker']),
                          style: TextStyle(
                            color: p.text,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Text(
                        '${_integer(row[key])} ${w('filers', '家')}',
                        style: TextStyle(color: color, fontSize: 11),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _insightWorkbench() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ChoiceChip(
            key: const ValueKey('13f-view-stocks'),
            label: Text(w('Stocks', '按股票')),
            selected: insightPerspective == 'stocks',
            onSelected: (_) => updateUI(() {
              insightPerspective = 'stocks';
              insightSearch = '';
              insightSearchInput.clear();
              _persist13FInsights();
            }),
          ),
          ChoiceChip(
            key: const ValueKey('13f-view-institutions'),
            label: Text(w('Institutions', '按机构')),
            selected: insightPerspective == 'institutions',
            onSelected: (_) => updateUI(() {
              insightPerspective = 'institutions';
              insightSearch = '';
              insightSearchInput.clear();
              _persist13FInsights();
            }),
          ),
          if (insightPerspective == 'stocks') ...[
            ChoiceChip(
              key: const ValueKey('13f-rank-holders'),
              avatar: const Icon(Icons.account_balance_outlined, size: 16),
              label: Text(w('By institutions', '按机构数量')),
              selected: insightStockRanking == 'holders',
              onSelected: (_) => updateUI(() {
                insightStockRanking = 'holders';
                _persist13FInsights();
              }),
            ),
            ChoiceChip(
              key: const ValueKey('13f-rank-shares'),
              avatar: const Icon(Icons.stacked_line_chart, size: 16),
              label: Text(w('By shares held', '按机构持股数')),
              selected: insightStockRanking == 'shares',
              onSelected: (_) => updateUI(() {
                insightStockRanking = 'shares';
                _persist13FInsights();
              }),
            ),
          ],
          SizedBox(
            width: 330,
            child: TextField(
              key: const ValueKey('13f-search'),
              controller: insightSearchInput,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 19),
                hintText: insightPerspective == 'stocks'
                    ? w('Search company or ticker', '搜索公司或代码')
                    : w('Search institution', '搜索机构'),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => updateUI(() {
                insightSearch = value;
                _persist13FInsights();
              }),
            ),
          ),
          label(
            insightPerspective == 'stocks'
                ? insightStockRanking == 'shares'
                      ? w('Ranked by aggregate reported shares', '按机构申报持股总数排名')
                      : w('Ranked by holder count', '按持有机构数量排名')
                : w('Ranked by reported position changes', '按申报仓位动作数量排名'),
            insightPerspective == 'stocks'
                ? insightStockRanking == 'shares'
                      ? '按机构申报持股总数排名'
                      : '按持有机构数量排名'
                : '按申报仓位动作数量排名',
            size: 11,
          ),
        ],
      ),
      const SizedBox(height: 13),
      LayoutBuilder(
        builder: (_, constraints) {
          final wide = constraints.maxWidth >= 1040;
          final list = insightPerspective == 'stocks'
              ? _insightStockList()
              : _insightInstitutionList();
          final detail = insightPerspective == 'stocks'
              ? _insightStockDetail()
              : _insightInstitutionDetail();
          if (!wide) {
            return Column(children: [list, const SizedBox(height: 16), detail]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 6, child: list),
              const SizedBox(width: 20),
              Expanded(flex: 5, child: detail),
            ],
          );
        },
      ),
    ],
  );

  Widget _insightStockList() {
    final rows = _insightStocks(),
        key = _insightKey(insightAction),
        color = _insightColor(insightAction);
    final compact = MediaQuery.sizeOf(context).width < 620;
    final actionWidth = compact ? 50.0 : 94.0;
    final sharesWidth = compact ? 60.0 : 82.0;
    final holdersWidth = compact ? 48.0 : 72.0;
    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: p.card,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Row(
              children: [
                Expanded(child: label('Company', '公司', size: 11)),
                SizedBox(
                  width: actionWidth,
                  child: label(
                    _insightName(insightAction),
                    _insightName(insightAction),
                    size: 11,
                  ),
                ),
                SizedBox(
                  width: sharesWidth,
                  child: label('Shares held', '机构持股', size: 11),
                ),
                SizedBox(
                  width: holdersWidth,
                  child: label('Institutions', '机构数', size: 11),
                ),
              ],
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: label('No matching 13F records.', '没有匹配的 13F 记录。'),
            ),
          for (final row in rows.take(100))
            Material(
              color: row['ticker'] == insightTicker
                  ? p.accent.withValues(alpha: .11)
                  : Colors.transparent,
              child: InkWell(
                key: ValueKey('13f-stock-${row['ticker']}'),
                onTap: () =>
                    unawaited(select13FInsightStock(text(row['ticker']))),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: p.border)),
                  ),
                  child: Row(
                    children: [
                      homeStockLogo(text(row['ticker']), 30),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              text(row['ticker']),
                              style: TextStyle(
                                color: p.text,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              text(row['name'], text(row['ticker'])),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: p.muted, fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: actionWidth,
                        child: Text(
                          _integer(row[key]),
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: sharesWidth,
                        child: Text(
                          _reportedShares(row['currentUnitsK']),
                          style: TextStyle(
                            color: insightStockRanking == 'shares'
                                ? p.accent
                                : p.text,
                            fontWeight: insightStockRanking == 'shares'
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: holdersWidth,
                        child: Text(
                          _integer(row['holders']),
                          style: TextStyle(
                            color: insightStockRanking == 'holders'
                                ? p.accent
                                : p.text,
                            fontWeight: insightStockRanking == 'holders'
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (rows.length > 100)
            Padding(
              padding: const EdgeInsets.all(12),
              child: label(
                'Showing top 100 of ${_integer(rows.length)} matches.',
                '显示 ${_integer(rows.length)} 个匹配中的前 100 个。',
                size: 11,
              ),
            ),
        ],
      ),
    );
  }

  Widget _insightInstitutionList() {
    final rows = _insightInstitutions(),
        key = _insightKey(insightAction),
        color = _insightColor(insightAction);
    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final row in rows.take(100))
            Material(
              color: row['investorId'] == insightInvestor
                  ? p.accent.withValues(alpha: .11)
                  : Colors.transparent,
              child: ListTile(
                key: ValueKey('13f-institution-${row['investorId']}'),
                onTap: () => updateUI(() {
                  insightInvestor = text(row['investorId']);
                  _persist13FInsights();
                }),
                title: Text(
                  text(row['name']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${_integer(row['holdings'])} ${w('reported stocks', '只申报股票')} · ${_usdMillions(row['currentValueM'])}',
                  style: TextStyle(color: p.muted, fontSize: 11),
                ),
                trailing: Text(
                  _integer(row[key]),
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          if (rows.length > 100)
            Padding(
              padding: const EdgeInsets.all(12),
              child: label(
                'Showing top 100 of ${_integer(rows.length)} matches.',
                '显示 ${_integer(rows.length)} 个匹配中的前 100 个。',
                size: 11,
              ),
            ),
        ],
      ),
    );
  }

  List<_InsightHistoryPoint> _insightHistory(Map<String, dynamic> detail) =>
      asList(detail['history'])
          .map(
            (item) => _InsightHistoryPoint(
              reportDate: text(item['reportDate']),
              holders: nullableNumber(item['holders']),
              sharesK: nullableNumber(item['institutionalSharesK']),
              ownershipPct: nullableNumber(item['institutionalOwnershipPct']),
            ),
          )
          .where((point) => point.reportDate.isNotEmpty)
          .toList();

  Widget _insightHistoryCard({
    required Key key,
    required String titleEn,
    required String titleZh,
    required String subtitleEn,
    required String subtitleZh,
    required List<_InsightHistoryPoint> points,
    required _InsightHistorySeries series,
  }) {
    final available = points.where(
      (point) => series == _InsightHistorySeries.holders
          ? point.holders != null
          : point.sharesK != null,
    );
    final latest = available.lastOrNull;
    final start = points.firstOrNull?.reportDate ?? '';
    final end = points.lastOrNull?.reportDate ?? '';
    return Container(
      key: key,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.card.withValues(alpha: .64),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w(titleEn, titleZh),
                      style: TextStyle(
                        color: p.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 3),
                    label(subtitleEn, subtitleZh, size: 10),
                  ],
                ),
              ),
              if (latest != null)
                Text(
                  series == _InsightHistorySeries.holders
                      ? '${_integer(latest.holders)} ${w('filers', '家')}'
                      : '${_reportedShares(latest.sharesK)}${latest.ownershipPct == null ? '' : ' · ${latest.ownershipPct!.toStringAsFixed(1)}%'}',
                  style: TextStyle(
                    color: p.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (points.length < 2)
            SizedBox(
              height: 128,
              child: Center(
                child: label(
                  'More quarterly snapshots are needed for a trend.',
                  '至少需要两个季度快照才能显示趋势。',
                  size: 11,
                ),
              ),
            )
          else
            SizedBox(
              height: 128,
              child: _InsightHistoryInteractiveChart(
                points: points,
                series: series,
                accent: p.accent,
                secondary: p.secondary,
                grid: p.border,
                panel: p.panel,
                textColor: p.text,
                muted: p.muted,
                quarterLabel: reportQuarterLabel,
                tooltipLines: (point) => series == _InsightHistorySeries.holders
                    ? ['${_integer(point.holders)} ${w('filers', '家机构')}']
                    : [
                        '${w('Shares', '持股数')} ${_reportedShares(point.sharesK)}',
                        '${w('% outstanding', '占总股本')} ${point.ownershipPct == null ? '—' : '${point.ownershipPct!.toStringAsFixed(2)}%'}',
                      ],
              ),
            ),
          const SizedBox(height: 7),
          if (series == _InsightHistorySeries.shares) ...[
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 9,
              runSpacing: 4,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 12, height: 2, color: p.accent),
                    const SizedBox(width: 4),
                    label('Shares', '持股数', size: 9),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 12, height: 2, color: p.secondary),
                    const SizedBox(width: 4),
                    label('% outstanding', '占总股本', size: 9),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 5),
          ],
          Row(
            children: [
              Text(
                start.isEmpty ? '—' : reportQuarterLabel(start),
                style: TextStyle(color: p.muted, fontSize: 9),
              ),
              const Spacer(),
              Text(
                end.isEmpty ? '—' : reportQuarterLabel(end),
                style: TextStyle(color: p.muted, fontSize: 9),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _insightHistoryCharts(Map<String, dynamic> detail) {
    final points = _insightHistory(detail);
    return LayoutBuilder(
      builder: (_, constraints) {
        final holders = _insightHistoryCard(
          key: const ValueKey('13f-holders-history-chart'),
          titleEn: 'Institution count history',
          titleZh: '持有机构数量变化',
          subtitleEn: 'Distinct 13F filers reporting the stock',
          subtitleZh: '申报持有该股票的 13F 机构数量',
          points: points,
          series: _InsightHistorySeries.holders,
        );
        final shares = _insightHistoryCard(
          key: const ValueKey('13f-ownership-history-chart'),
          titleEn: 'Institutional ownership history',
          titleZh: '机构持股与占总股本变化',
          subtitleEn: 'Aggregate reported shares · % of shares outstanding',
          subtitleZh: '机构申报持股总数 · 占当时总股本比例',
          points: points,
          series: _InsightHistorySeries.shares,
        );
        if (constraints.maxWidth < 520) {
          return Column(
            children: [holders, const SizedBox(height: 12), shares],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: holders),
            const SizedBox(width: 12),
            Expanded(child: shares),
          ],
        );
      },
    );
  }

  Widget _insightStockDetail() {
    final row = asList(
      institutional13f?['rows'],
    ).where((item) => item['ticker'] == insightTicker).firstOrNull;
    if (row == null) {
      return card([
        label(
          'Select a stock to inspect the reporting institutions.',
          '选择一只股票查看申报机构。',
        ),
      ]);
    }
    final detail = asMap(asMap(institutional13f?['details'])[insightTicker]);
    final detailIsLoading = insightDetailLoading.contains(
      _insightDetailCacheKey(insightTicker),
    );
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              homeStockLogo(insightTicker, 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(insightTicker, style: deskHeading(24)),
                    label(
                      text(row['name'], insightTicker),
                      text(row['name'], insightTicker),
                      size: 12,
                    ),
                  ],
                ),
              ),
              Text(
                '${_integer(row['holders'])} ${w('holders', '家持有')}',
                style: TextStyle(color: p.accent, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _insightMetric('New', '新建', row['newPositions'], p.accent),
              _insightMetric('Added', '加仓', row['increases'], p.accent),
              _insightMetric('Reduced', '减仓', row['reductions'], p.secondary),
              _insightMetric('Exited', '清仓', row['exits'], p.secondary),
            ],
          ),
          const SizedBox(height: 18),
          if (detail.isEmpty && detailIsLoading)
            Container(
              height: 170,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.card.withValues(alpha: .5),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: p.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: p.accent,
                    ),
                  ),
                  const SizedBox(height: 10),
                  label('Loading quarterly history…', '正在加载季度历史…', size: 11),
                ],
              ),
            )
          else
            _insightHistoryCharts(detail),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w(
                        'Institution ranking · ${_insightName(insightAction).toLowerCase()}',
                        '机构排名 · ${_insightName(insightAction)}',
                      ),
                      style: TextStyle(
                        color: p.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    label(
                      'Largest reported positions first',
                      '按申报仓位规模由大到小',
                      size: 10,
                    ),
                  ],
                ),
              ),
              DropdownButton<int>(
                key: const ValueKey('13f-institution-limit'),
                value: insightInstitutionLimit,
                dropdownColor: p.card,
                underline: const SizedBox.shrink(),
                items: [
                  for (final count in const [8, 20, 50])
                    DropdownMenuItem(
                      value: count,
                      child: Text(
                        w('Top $count', '前 $count 家'),
                        style: TextStyle(color: p.text, fontSize: 12),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  updateUI(() {
                    insightInstitutionLimit = value;
                    _persist13FInsights();
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (asList(detail[insightAction]).isEmpty)
            label(
              'No bounded detail rows for this security; aggregate counts still use the full universe.',
              '该证券暂无明细样本，但汇总数量仍使用全量机构。',
              size: 12,
            ),
          for (final institution in asList(
            detail[insightAction],
          ).take(insightInstitutionLimit))
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p.border)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          text(institution['name']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${_usdMillions(institution['currentValueM'] ?? institution['previousValueM'])} ${w('reported value', '申报市值')}',
                          style: TextStyle(color: p.muted, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  if (nullableNumber(institution['changePct']) != null)
                    Text(
                      pct(institution['changePct']),
                      style: TextStyle(
                        color: _insightColor(insightAction),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          if (number(row['splitAdjustedFilers']) > 0) ...[
            const SizedBox(height: 12),
            label(
              'Split adjustment applied for ${_integer(row['splitAdjustedFilers'])} comparable filer rows.',
              '有 ${_integer(row['splitAdjustedFilers'])} 个机构仓位已做拆股调整。',
              size: 11,
              color: p.secondary,
            ),
          ],
        ],
      ),
    );
  }

  Widget _insightInstitutionDetail() {
    final row = asList(
      institutional13f?['institutions'],
    ).where((item) => item['investorId'] == insightInvestor).firstOrNull;
    if (row == null) {
      return card([
        label(
          'Select an institution to inspect its quarterly activity.',
          '选择一家机构查看季度动作。',
        ),
      ]);
    }
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.account_balance_outlined, color: p.accent, size: 32),
          const SizedBox(height: 10),
          Text(text(row['name']), style: deskHeading(21)),
          const SizedBox(height: 4),
          label(
            '${text(row['investorId'])} · ${_usdMillions(row['currentValueM'])} ${w('reported common-stock value', '普通股申报市值')}',
            '${text(row['investorId'])} · ${_usdMillions(row['currentValueM'])} 普通股申报市值',
            size: 12,
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _insightMetric('Holdings', '持仓', row['holdings'], p.text),
              _insightMetric('New', '新建', row['newPositions'], p.accent),
              _insightMetric('Added', '加仓', row['increases'], p.accent),
              _insightMetric('Reduced', '减仓', row['reductions'], p.secondary),
              _insightMetric('Exited', '清仓', row['exits'], p.secondary),
            ],
          ),
          const SizedBox(height: 16),
          label(
            'Institution rankings use its complete common-stock quarter comparison. Select Stocks to inspect company-level filer examples.',
            '机构排名使用其完整普通股季度对比；切换到“按股票”可查看单只股票的机构明细。',
            size: 12,
          ),
        ],
      ),
    );
  }

  Widget _insightMetric(String en, String zh, dynamic value, Color color) =>
      Container(
        width: 112,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: .25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _integer(value),
              style: TextStyle(
                color: color,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            label(en, zh, size: 10),
          ],
        ),
      );
}

enum _InsightHistorySeries { holders, shares }

class _InsightHistoryPoint {
  const _InsightHistoryPoint({
    required this.reportDate,
    required this.holders,
    required this.sharesK,
    required this.ownershipPct,
  });

  final String reportDate;
  final double? holders;
  final double? sharesK;
  final double? ownershipPct;
}

class _InsightHistoryInteractiveChart extends StatefulWidget {
  const _InsightHistoryInteractiveChart({
    required this.points,
    required this.series,
    required this.accent,
    required this.secondary,
    required this.grid,
    required this.panel,
    required this.textColor,
    required this.muted,
    required this.quarterLabel,
    required this.tooltipLines,
  });

  final List<_InsightHistoryPoint> points;
  final _InsightHistorySeries series;
  final Color accent;
  final Color secondary;
  final Color grid;
  final Color panel;
  final Color textColor;
  final Color muted;
  final String Function(String) quarterLabel;
  final List<String> Function(_InsightHistoryPoint) tooltipLines;

  @override
  State<_InsightHistoryInteractiveChart> createState() =>
      _InsightHistoryInteractiveChartState();
}

class _InsightHistoryInteractiveChartState
    extends State<_InsightHistoryInteractiveChart> {
  int? hoveredIndex;
  double pointerX = 0;

  void _selectAt(double dx, double width) {
    if (widget.points.isEmpty || width <= 10) return;
    final ratio = ((dx - 5) / (width - 10)).clamp(0.0, 1.0);
    final index = (ratio * (widget.points.length - 1)).round();
    if (hoveredIndex == index && pointerX == dx) return;
    setState(() {
      hoveredIndex = index;
      pointerX = dx;
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final index = hoveredIndex;
      final tooltipWidth = math
          .min(164.0, math.max(118.0, width * .56))
          .toDouble();
      final tooltipLeft = (pointerX - tooltipWidth / 2)
          .clamp(0.0, math.max(0.0, width - tooltipWidth))
          .toDouble();
      return MouseRegion(
        cursor: SystemMouseCursors.precise,
        onHover: (event) => _selectAt(event.localPosition.dx, width),
        onExit: (_) => setState(() => hoveredIndex = null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (event) => _selectAt(event.localPosition.dx, width),
          onPanStart: (event) => _selectAt(event.localPosition.dx, width),
          onPanUpdate: (event) => _selectAt(event.localPosition.dx, width),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _InsightHistoryPainter(
                    points: widget.points,
                    series: widget.series,
                    accent: widget.accent,
                    secondary: widget.secondary,
                    grid: widget.grid,
                    hoverIndex: index,
                  ),
                ),
              ),
              if (index != null && index < widget.points.length)
                Positioned(
                  top: 4,
                  left: tooltipLeft,
                  width: tooltipWidth,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: widget.panel.withValues(alpha: .96),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: widget.grid),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x33000000),
                            blurRadius: 10,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 7,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.quarterLabel(
                                widget.points[index].reportDate,
                              ),
                              style: TextStyle(
                                color: widget.muted,
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            for (final line in widget.tooltipLines(
                              widget.points[index],
                            ))
                              Text(
                                line,
                                style: TextStyle(
                                  color: widget.textColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  height: 1.35,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _InsightHistoryPainter extends CustomPainter {
  const _InsightHistoryPainter({
    required this.points,
    required this.series,
    required this.accent,
    required this.secondary,
    required this.grid,
    required this.hoverIndex,
  });

  final List<_InsightHistoryPoint> points;
  final _InsightHistorySeries series;
  final Color accent;
  final Color secondary;
  final Color grid;
  final int? hoverIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final chart = Rect.fromLTWH(5, 5, size.width - 10, size.height - 10);
    final gridPaint = Paint()
      ..color = grid.withValues(alpha: .72)
      ..strokeWidth = 1;
    for (var index = 0; index < 4; index++) {
      final y = chart.top + chart.height * index / 3;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
    }
    if (series == _InsightHistorySeries.holders) {
      _drawSeries(canvas, chart, (point) => point.holders, accent, fill: true);
    } else {
      _drawBars(canvas, chart, (point) => point.sharesK, accent);
      _drawSeries(canvas, chart, (point) => point.ownershipPct, secondary);
    }
    _drawHover(canvas, chart);
  }

  void _drawHover(Canvas canvas, Rect chart) {
    final index = hoverIndex;
    if (index == null || index < 0 || index >= points.length) return;
    final x = points.length == 1
        ? chart.center.dx
        : chart.left + chart.width * index / (points.length - 1);
    canvas.drawLine(
      Offset(x, chart.top),
      Offset(x, chart.bottom),
      Paint()
        ..color = grid.withValues(alpha: .95)
        ..strokeWidth = 1,
    );
    final reads = series == _InsightHistorySeries.holders
        ? <(double? Function(_InsightHistoryPoint), Color)>[
            ((point) => point.holders, accent),
          ]
        : <(double? Function(_InsightHistoryPoint), Color)>[
            ((point) => point.sharesK, accent),
            ((point) => point.ownershipPct, secondary),
          ];
    for (final entry in reads) {
      final offset = _seriesOffset(chart, index, entry.$1);
      if (offset == null) continue;
      canvas.drawCircle(offset, 5.2, Paint()..color = grid);
      canvas.drawCircle(offset, 3.1, Paint()..color = entry.$2);
    }
  }

  Offset? _seriesOffset(
    Rect chart,
    int index,
    double? Function(_InsightHistoryPoint) read,
  ) {
    final values = <(int, double)>[];
    for (var itemIndex = 0; itemIndex < points.length; itemIndex++) {
      final value = read(points[itemIndex]);
      if (value != null && value.isFinite) values.add((itemIndex, value));
    }
    final value = read(points[index]);
    if (value == null || !value.isFinite || values.isEmpty) return null;
    final rawMin = values.map((item) => item.$2).reduce(math.min);
    final rawMax = values.map((item) => item.$2).reduce(math.max);
    final spread = rawMax - rawMin;
    final padding = spread == 0
        ? math.max(rawMax.abs() * .08, 1)
        : spread * .12;
    final minValue = rawMin - padding;
    final maxValue = rawMax + padding;
    final x = points.length == 1
        ? chart.center.dx
        : chart.left + chart.width * index / (points.length - 1);
    final ratio = (value - minValue) / (maxValue - minValue);
    return Offset(x, chart.bottom - ratio * chart.height);
  }

  void _drawBars(
    Canvas canvas,
    Rect chart,
    double? Function(_InsightHistoryPoint) read,
    Color color,
  ) {
    final values = <(int, double)>[];
    for (var index = 0; index < points.length; index++) {
      final value = read(points[index]);
      if (value != null && value.isFinite) values.add((index, value));
    }
    if (values.isEmpty) return;
    final rawMin = values.map((item) => item.$2).reduce(math.min);
    final rawMax = values.map((item) => item.$2).reduce(math.max);
    final spread = rawMax - rawMin;
    final padding = spread == 0
        ? math.max(rawMax.abs() * .08, 1)
        : spread * .12;
    final minValue = rawMin - padding;
    final maxValue = rawMax + padding;
    final barWidth = math.min(
      24.0,
      chart.width / math.max(points.length * 1.8, 1),
    );
    final fillPaint = Paint()..color = color.withValues(alpha: .36);
    final edgePaint = Paint()
      ..color = color.withValues(alpha: .88)
      ..strokeWidth = 1.4;
    for (final item in values) {
      final x = points.length == 1
          ? chart.center.dx
          : chart.left + chart.width * item.$1 / (points.length - 1);
      final ratio = (item.$2 - minValue) / (maxValue - minValue);
      final y = chart.bottom - ratio * chart.height;
      final bar = RRect.fromRectAndRadius(
        Rect.fromLTRB(x - barWidth / 2, y, x + barWidth / 2, chart.bottom),
        const Radius.circular(2),
      );
      canvas.drawRRect(bar, fillPaint);
      canvas.drawLine(
        Offset(x - barWidth / 2, y),
        Offset(x + barWidth / 2, y),
        edgePaint,
      );
    }
  }

  void _drawSeries(
    Canvas canvas,
    Rect chart,
    double? Function(_InsightHistoryPoint) read,
    Color color, {
    bool fill = false,
  }) {
    final values = <(int, double)>[];
    for (var index = 0; index < points.length; index++) {
      final value = read(points[index]);
      if (value != null && value.isFinite) values.add((index, value));
    }
    if (values.isEmpty) return;
    final rawMin = values.map((item) => item.$2).reduce(math.min);
    final rawMax = values.map((item) => item.$2).reduce(math.max);
    final spread = rawMax - rawMin;
    final padding = spread == 0
        ? math.max(rawMax.abs() * .08, 1)
        : spread * .12;
    final minValue = rawMin - padding;
    final maxValue = rawMax + padding;
    Offset offset((int, double) item) {
      final x = points.length == 1
          ? chart.center.dx
          : chart.left + chart.width * item.$1 / (points.length - 1);
      final ratio = (item.$2 - minValue) / (maxValue - minValue);
      return Offset(x, chart.bottom - ratio * chart.height);
    }

    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final point = offset(values[index]);
      if (index == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    if (fill && values.length > 1) {
      final area = Path.from(path)
        ..lineTo(offset(values.last).dx, chart.bottom)
        ..lineTo(offset(values.first).dx, chart.bottom)
        ..close();
      canvas.drawPath(area, Paint()..color = color.withValues(alpha: .08));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    for (final item in values) {
      canvas.drawCircle(offset(item), 2.7, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _InsightHistoryPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.series != series ||
      oldDelegate.accent != accent ||
      oldDelegate.secondary != secondary ||
      oldDelegate.grid != grid ||
      oldDelegate.hoverIndex != hoverIndex;
}
