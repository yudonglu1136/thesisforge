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
    updateUI(() {
      insightAction = action;
      insightSearch = '';
      insightSearchInput.clear();
    });
    _persist13FInsights();
    unawaited(load13FInsights());
  }

  void _select13FMarketSegment(String segment) {
    updateUI(() {
      insightMarketSegment = segment;
      insightSearch = '';
      insightSearchInput.clear();
    });
    _persist13FInsights();
    unawaited(load13FInsights());
  }

  void _persist13FInsights() => replaceBrowserQuery({
    'insightQuarter': insightQuarter,
    'insightAction': insightAction == 'increased' ? null : insightAction,
    'insightView': null,
    'insightRank': insightStockRanking == 'amount' ? null : insightStockRanking,
    'insightSegment': insightMarketSegment == 'all'
        ? null
        : insightMarketSegment,
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
      final query = <String, String>{
        'asOf': cutoff,
        if (selected.isNotEmpty) 'quarter': selected,
        'action': insightAction,
        'rank': insightStockRanking,
        'segment': insightMarketSegment,
        'limit': '100',
        if (insightSearch.trim().isNotEmpty) 'search': insightSearch.trim(),
        if (insightTicker.isNotEmpty) 'ticker': insightTicker,
      };
      final data = await widget.api.getJson(
        Uri(
          path: '/api/investment/13f-insights',
          queryParameters: query,
        ).toString(),
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
      if (insightMarketSegment != 'all' &&
          !(row['segments'] as List? ?? const []).contains(
            insightMarketSegment,
          )) {
        return false;
      }
      return query.isEmpty ||
          '${row['ticker']} ${row['name']}'.toLowerCase().contains(query);
    }).toList();
    rows.sort((a, b) {
      final primary = switch (insightStockRanking) {
        'shareChange' => number(
          b['netChangePctOutstanding'],
        ).abs().compareTo(number(a['netChangePctOutstanding']).abs()),
        'institutions' => number(b['holders']).compareTo(number(a['holders'])),
        'sharesHeldPct' => number(
          b['institutionalOwnershipPct'],
        ).compareTo(number(a['institutionalOwnershipPct'])),
        _ => number(
          b['netChangeValueM'],
        ).abs().compareTo(number(a['netChangeValueM']).abs()),
      };
      if (primary != 0) return primary;
      final count = number(b[key]).compareTo(number(a[key]));
      if (count != 0) return count;
      return text(a['ticker']).compareTo(text(b['ticker']));
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
        _insightMarketPulse(),
        const SizedBox(height: 22),
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
                'Common-stock positions only. The market pulse divides aggregate reported value by the sum of unique covered securities’ quarter-end Sharadar market capitalizations. New and exited positions compare adjacent quarter-end books; increases and reductions compare split-adjusted reported units. Net change is valued at the current quarter implied price. Percentage rankings divide net reported value change or aggregate institutional value by quarter-end Sharadar market capitalization; at the same implied price this is equivalent to using total shares outstanding, not free float. Counts use the full SF3 filer universe, while detail rows are bounded. 13F disclosures are delayed and do not reveal trade dates or execution prices.',
                '仅统计普通股持仓。宏观脉搏用机构申报持股总市值除以覆盖股票的 Sharadar 季末总市值。新建仓与清仓比较相邻季末组合；加仓与减仓按拆股调整后的申报股数比较；净变化按本季度隐含价格折算。比例排名以机构净变化市值或机构持股市值除以 Sharadar 季末总市值；在相同隐含价格下等价于使用总股本，而非自由流通股。计数覆盖完整 SF3 机构范围，明细行做有界展示。13F 存在披露延迟，不提供实际交易日期或成交价。',
                size: 12,
              ),
            ),
          ],
        ),
      ],
    ];
  }

  String _percentagePoints(dynamic value, {int digits = 2}) {
    final parsed = nullableNumber(value);
    return parsed == null ? '—' : '${parsed.toStringAsFixed(digits)}%';
  }

  String _insightSegmentName(String id) => switch (id) {
    'sp500' => w('S&P 500 · SPY universe', '标普 500 · SPY 范围'),
    'nasdaq100Proxy' => w('Nasdaq-100 proxy', '纳斯达克 100 代理篮子'),
    'smallCap' => w('US small cap', '美国小盘股'),
    _ => w('All covered equities', '全市场覆盖股票'),
  };

  Widget _insightMarketPulse() {
    final overview = asMap(
      asMap(institutional13f?['marketOverview'])[insightMarketSegment],
    );
    final history = asList(institutional13f?['marketHistory'])
        .map((item) {
          final segment = asMap(asMap(item['segments'])[insightMarketSegment]);
          return _InsightHistoryPoint(
            reportDate: text(item['reportDate']),
            holders: nullableNumber(segment['institutionalOwnershipPct']),
            sharesK: nullableNumber(segment['institutionalValueM']),
            ownershipPct: nullableNumber(segment['netChangePctMarketCap']),
          );
        })
        .where((point) => point.holders != null)
        .toList();
    final prior = history.length > 1
        ? history[history.length - 2].holders
        : null;
    final latest = nullableNumber(overview['institutionalOwnershipPct']);
    final change = latest == null || prior == null ? null : latest - prior;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: p.accent.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.public, color: p.accent, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w('Institutional ownership pulse', '机构持股宏观脉搏'),
                      style: TextStyle(
                        color: p.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    label(
                      'Aggregate reported common-stock value as a share of covered market capitalization',
                      '机构申报普通股总市值占覆盖股票总市值的比例',
                      size: 11,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _percentagePoints(latest),
                    style: TextStyle(
                      color: p.accent,
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (change != null)
                    Text(
                      '${change >= 0 ? '+' : ''}${change.toStringAsFixed(2)} ${w('pp QoQ', '个百分点 环比')}',
                      style: TextStyle(
                        color: change >= 0 ? p.accent : p.secondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final segment in const [
                'all',
                'sp500',
                'nasdaq100Proxy',
                'smallCap',
              ])
                ChoiceChip(
                  key: ValueKey('13f-segment-$segment'),
                  label: Text(_insightSegmentName(segment)),
                  selected: insightMarketSegment == segment,
                  onSelected: (_) => _select13FMarketSegment(segment),
                ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (_, constraints) {
              final chart = SizedBox(
                height: 190,
                child: _InsightHistoryInteractiveChart(
                  points: history,
                  series: _InsightHistorySeries.holders,
                  primaryScale: _InsightAxisScale.percent,
                  accent: p.accent,
                  secondary: p.secondary,
                  grid: p.border,
                  panel: p.card,
                  textColor: p.text,
                  muted: p.muted,
                  quarterLabel: reportQuarterLabel,
                  tooltipLines: (point) => [
                    '${w('Institutional ownership', '机构持股占比')} ${_percentagePoints(point.holders)}',
                    '${w('Reported value', '申报持股市值')} ${_usdMillions(point.sharesK)}',
                  ],
                ),
              );
              final facts = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _insightPulseFact(
                    w('Reported institutional value', '机构申报持股市值'),
                    _usdMillions(overview['institutionalValueM']),
                  ),
                  _insightPulseFact(
                    w('Covered market cap', '覆盖股票总市值'),
                    _usdMillions(overview['marketCapM']),
                  ),
                  _insightPulseFact(
                    w('Quarterly net change', '本季净增减'),
                    _usdMillions(overview['netChangeValueM']),
                    color: number(overview['netChangeValueM']) >= 0
                        ? p.accent
                        : p.secondary,
                  ),
                  _insightPulseFact(
                    w('Coverage', '覆盖范围'),
                    '${_integer(overview['coveredSecurities'])} / ${_integer(overview['securities'])}',
                  ),
                ],
              );
              if (constraints.maxWidth < 760) {
                return Column(
                  children: [chart, const SizedBox(height: 12), facts],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 7, child: chart),
                  const SizedBox(width: 20),
                  Expanded(flex: 3, child: facts),
                ],
              );
            },
          ),
          const SizedBox(height: 9),
          label(
            insightMarketSegment == 'nasdaq100Proxy'
                ? 'Proxy basket: the 100 largest non-financial Nasdaq listings by quarter-end market cap; not official QQQ holdings.'
                : 'Uses quarter-end Sharadar market capitalization. Ratios use shares outstanding, not free float.',
            insightMarketSegment == 'nasdaq100Proxy'
                ? '代理篮子：按季末市值选取纳斯达克最大的 100 家非金融公司，并非 QQQ 官方成分。'
                : '使用 Sharadar 季末市值；比例分母为总股本，不是自由流通股。',
            size: 10,
          ),
        ],
      ),
    );
  }

  Widget _insightPulseFact(String title, String value, {Color? color}) =>
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: p.card.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: TextStyle(color: p.muted, fontSize: 10),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                color: color ?? p.text,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );

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
    final rows = asList(asMap(institutional13f?['actionLeaders'])[action]);
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
            key: const ValueKey('13f-rank-amount'),
            avatar: const Icon(Icons.attach_money, size: 16),
            label: Text(w('By amount', '按变动金额')),
            selected: insightStockRanking == 'amount',
            onSelected: (_) {
              updateUI(() => insightStockRanking = 'amount');
              _persist13FInsights();
              unawaited(load13FInsights());
            },
          ),
          ChoiceChip(
            key: const ValueKey('13f-rank-share-change'),
            avatar: const Icon(Icons.swap_vert, size: 16),
            label: Text(w('By share change', '按市值占比变化')),
            selected: insightStockRanking == 'shareChange',
            onSelected: (_) {
              updateUI(() => insightStockRanking = 'shareChange');
              _persist13FInsights();
              unawaited(load13FInsights());
            },
          ),
          ChoiceChip(
            key: const ValueKey('13f-rank-institutions'),
            avatar: const Icon(Icons.account_balance_outlined, size: 16),
            label: Text(w('By institutions', '按机构数量')),
            selected: insightStockRanking == 'institutions',
            onSelected: (_) {
              updateUI(() => insightStockRanking = 'institutions');
              _persist13FInsights();
              unawaited(load13FInsights());
            },
          ),
          ChoiceChip(
            key: const ValueKey('13f-rank-shares-held-pct'),
            avatar: const Icon(Icons.percent, size: 16),
            label: Text(w('By shares held %', '按机构持股占比')),
            selected: insightStockRanking == 'sharesHeldPct',
            onSelected: (_) {
              updateUI(() => insightStockRanking = 'sharesHeldPct');
              _persist13FInsights();
              unawaited(load13FInsights());
            },
          ),
          SizedBox(
            width: 330,
            child: TextField(
              key: const ValueKey('13f-search'),
              controller: insightSearchInput,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 19),
                hintText: w('Search company or ticker', '搜索公司或代码'),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) {
                updateUI(() => insightSearch = value);
                insightSearchTimer?.cancel();
                insightSearchTimer = Timer(
                  const Duration(milliseconds: 250),
                  () {
                    _persist13FInsights();
                    unawaited(load13FInsights());
                  },
                );
              },
            ),
          ),
          label(
            switch (insightStockRanking) {
              'shareChange' => w(
                'Ranked by net reported value change as % of company market cap',
                '按机构申报净变化市值占公司总市值比例排名',
              ),
              'institutions' => w(
                'Ranked by reporting institution count',
                '按持有机构数量排名',
              ),
              'sharesHeldPct' => w(
                'Ranked by reported institutional value as % of company market cap',
                '按 13F 机构持股市值占公司总市值比例排名',
              ),
              _ => w(
                'Ranked by absolute quarterly net reported value change',
                '按季度机构申报净变化市值绝对额排名',
              ),
            },
            switch (insightStockRanking) {
              'shareChange' => '按机构申报净变化市值占公司总市值比例排名',
              'institutions' => '按持有机构数量排名',
              'sharesHeldPct' => '按 13F 机构持股市值占公司总市值比例排名',
              _ => '按季度机构申报净变化市值绝对额排名',
            },
            size: 11,
          ),
        ],
      ),
      const SizedBox(height: 13),
      LayoutBuilder(
        builder: (_, constraints) {
          final wide = constraints.maxWidth >= 1040;
          final list = _insightStockList();
          final detail = _insightStockDetail();
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
    final rows = _insightStocks(), color = _insightColor(insightAction);
    final compact = MediaQuery.sizeOf(context).width < 620;
    final amountWidth = compact ? 64.0 : 88.0;
    final changeWidth = compact ? 54.0 : 78.0;
    final holdersWidth = compact ? 48.0 : 70.0;
    final heldWidth = compact ? 52.0 : 72.0;
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
                  width: amountWidth,
                  child: label('Amount', '变动金额', size: 11),
                ),
                SizedBox(
                  width: changeWidth,
                  child: label('Share change', '市值占比变化', size: 11),
                ),
                SizedBox(
                  width: holdersWidth,
                  child: label('Institutions', '机构数', size: 11),
                ),
                SizedBox(
                  width: heldWidth,
                  child: label('Shares held %', '机构持股占比', size: 11),
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
                        width: amountWidth,
                        child: Text(
                          _usdMillions(row['netChangeValueM']),
                          style: TextStyle(
                            color: insightStockRanking == 'amount'
                                ? color
                                : p.text,
                            fontWeight: insightStockRanking == 'amount'
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: changeWidth,
                        child: Text(
                          _percentagePoints(row['netChangePctOutstanding']),
                          style: TextStyle(
                            color: insightStockRanking == 'shareChange'
                                ? color
                                : p.text,
                            fontWeight: insightStockRanking == 'shareChange'
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
                            color: insightStockRanking == 'institutions'
                                ? p.accent
                                : p.text,
                            fontWeight: insightStockRanking == 'institutions'
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: heldWidth,
                        child: Text(
                          _percentagePoints(row['institutionalOwnershipPct']),
                          style: TextStyle(
                            color: insightStockRanking == 'sharesHeldPct'
                                ? p.accent
                                : p.text,
                            fontWeight: insightStockRanking == 'sharesHeldPct'
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
          if (number(institutional13f?['totalMatches']) > rows.length)
            Padding(
              padding: const EdgeInsets.all(12),
              child: label(
                'Showing the first ${_integer(rows.length)} of ${_integer(institutional13f?['totalMatches'])} server-ranked matches.',
                '显示服务端排名的前 ${_integer(rows.length)} 个，共 ${_integer(institutional13f?['totalMatches'])} 个匹配结果。',
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
                primaryScale: series == _InsightHistorySeries.holders
                    ? _InsightAxisScale.count
                    : _InsightAxisScale.shares,
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
                        '${w('% market cap', '占总市值')} ${point.ownershipPct == null ? '—' : '${point.ownershipPct!.toStringAsFixed(2)}%'}',
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
                    label('% market cap', '占总市值', size: 9),
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
          titleZh: '机构持股与占总市值变化',
          subtitleEn: 'Aggregate reported shares · % of company market cap',
          subtitleZh: '机构申报持股总数 · 机构持股市值占公司总市值',
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

enum _InsightAxisScale { count, percent, shares }

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
    required this.primaryScale,
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
  final _InsightAxisScale primaryScale;
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
    const leftAxis = 42.0;
    final rightAxis = widget.series == _InsightHistorySeries.shares
        ? 40.0
        : 8.0;
    final plotWidth = math.max(1.0, width - leftAxis - rightAxis);
    final ratio = ((dx - leftAxis) / plotWidth).clamp(0.0, 1.0);
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
                    primaryScale: widget.primaryScale,
                    accent: widget.accent,
                    secondary: widget.secondary,
                    grid: widget.grid,
                    muted: widget.muted,
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
    required this.primaryScale,
    required this.accent,
    required this.secondary,
    required this.grid,
    required this.muted,
    required this.hoverIndex,
  });

  final List<_InsightHistoryPoint> points;
  final _InsightHistorySeries series;
  final _InsightAxisScale primaryScale;
  final Color accent;
  final Color secondary;
  final Color grid;
  final Color muted;
  final int? hoverIndex;

  @override
  void paint(Canvas canvas, Size size) {
    const leftAxis = 42.0;
    final rightAxis = series == _InsightHistorySeries.shares ? 40.0 : 8.0;
    final chart = Rect.fromLTWH(
      leftAxis,
      7,
      math.max(1.0, size.width - leftAxis - rightAxis),
      math.max(1.0, size.height - 14),
    );
    final double? Function(_InsightHistoryPoint) primaryRead =
        series == _InsightHistorySeries.holders
        ? (point) => point.holders
        : (point) => point.sharesK;
    final primaryBounds = _bounds(primaryRead, primaryScale);
    final gridPaint = Paint()
      ..color = grid.withValues(alpha: .72)
      ..strokeWidth = 1;
    for (var index = 0; index <= 4; index++) {
      final ratio = index / 4;
      final y = chart.bottom - chart.height * ratio;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
      _drawAxisLabel(
        canvas,
        _formatAxis(
          primaryBounds.min + (primaryBounds.max - primaryBounds.min) * ratio,
          primaryScale,
        ),
        Offset(chart.left - 5, y),
        alignRight: true,
      );
      if (series == _InsightHistorySeries.shares) {
        _drawAxisLabel(
          canvas,
          '${(ratio * 100).round()}%',
          Offset(chart.right + 5, y),
        );
      }
    }
    if (series == _InsightHistorySeries.holders) {
      _drawSeries(
        canvas,
        chart,
        (point) => point.holders,
        primaryBounds,
        accent,
        fill: true,
      );
    } else {
      _drawBars(canvas, chart, (point) => point.sharesK, primaryBounds, accent);
      _drawSeries(canvas, chart, (point) => point.ownershipPct, (
        min: 0,
        max: 100,
      ), secondary);
    }
    _drawHover(canvas, chart, primaryBounds);
  }

  ({double min, double max}) _bounds(
    double? Function(_InsightHistoryPoint) read,
    _InsightAxisScale scale,
  ) {
    if (scale == _InsightAxisScale.percent) return (min: 0, max: 100);
    final values = points
        .map(read)
        .whereType<double>()
        .where((value) => value.isFinite && value >= 0)
        .toList();
    if (values.isEmpty) return (min: 0, max: 1);
    return (min: 0, max: _niceCeiling(values.reduce(math.max) * 1.06));
  }

  double _niceCeiling(double value) {
    if (!value.isFinite || value <= 0) return 1;
    final roughStep = value / 4;
    final magnitude = math
        .pow(10, (math.log(roughStep) / math.ln10).floor())
        .toDouble();
    final normalized = roughStep / magnitude;
    final niceStep = normalized <= 1
        ? 1
        : normalized <= 2
        ? 2
        : normalized <= 2.5
        ? 2.5
        : normalized <= 5
        ? 5
        : 10;
    return niceStep * magnitude * 4;
  }

  String _formatAxis(double value, _InsightAxisScale scale) {
    if (scale == _InsightAxisScale.percent) return '${value.round()}%';
    final display = scale == _InsightAxisScale.shares ? value * 1000 : value;
    if (display.abs() >= 1000000000) {
      return '${(display / 1000000000).toStringAsFixed(display % 1000000000 == 0 ? 0 : 1)}B';
    }
    if (display.abs() >= 1000000) {
      return '${(display / 1000000).toStringAsFixed(display % 1000000 == 0 ? 0 : 1)}M';
    }
    if (display.abs() >= 1000) {
      return '${(display / 1000).toStringAsFixed(display % 1000 == 0 ? 0 : 1)}K';
    }
    return display.round().toString();
  }

  void _drawAxisLabel(
    Canvas canvas,
    String value,
    Offset anchor, {
    bool alignRight = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: muted,
          fontSize: 8,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    painter.paint(
      canvas,
      Offset(
        alignRight ? anchor.dx - painter.width : anchor.dx,
        anchor.dy - painter.height / 2,
      ),
    );
  }

  void _drawHover(
    Canvas canvas,
    Rect chart,
    ({double min, double max}) primaryBounds,
  ) {
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
        ? <
            (
              double? Function(_InsightHistoryPoint),
              ({double min, double max}),
              Color,
            )
          >[((point) => point.holders, primaryBounds, accent)]
        : <
            (
              double? Function(_InsightHistoryPoint),
              ({double min, double max}),
              Color,
            )
          >[
            ((point) => point.sharesK, primaryBounds, accent),
            ((point) => point.ownershipPct, (min: 0, max: 100), secondary),
          ];
    for (final entry in reads) {
      final offset = _seriesOffset(chart, index, entry.$1, entry.$2);
      if (offset == null) continue;
      canvas.drawCircle(offset, 5.2, Paint()..color = grid);
      canvas.drawCircle(offset, 3.1, Paint()..color = entry.$3);
    }
  }

  Offset? _seriesOffset(
    Rect chart,
    int index,
    double? Function(_InsightHistoryPoint) read,
    ({double min, double max}) bounds,
  ) {
    final value = read(points[index]);
    if (value == null || !value.isFinite) return null;
    final x = points.length == 1
        ? chart.center.dx
        : chart.left + chart.width * index / (points.length - 1);
    final ratio = ((value - bounds.min) / (bounds.max - bounds.min)).clamp(
      0.0,
      1.0,
    );
    return Offset(x, chart.bottom - ratio * chart.height);
  }

  void _drawBars(
    Canvas canvas,
    Rect chart,
    double? Function(_InsightHistoryPoint) read,
    ({double min, double max}) bounds,
    Color color,
  ) {
    final values = <(int, double)>[];
    for (var index = 0; index < points.length; index++) {
      final value = read(points[index]);
      if (value != null && value.isFinite) values.add((index, value));
    }
    if (values.isEmpty) return;
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
      final ratio = ((item.$2 - bounds.min) / (bounds.max - bounds.min)).clamp(
        0.0,
        1.0,
      );
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
    ({double min, double max}) bounds,
    Color color, {
    bool fill = false,
  }) {
    final values = <(int, double)>[];
    for (var index = 0; index < points.length; index++) {
      final value = read(points[index]);
      if (value != null && value.isFinite) values.add((index, value));
    }
    if (values.isEmpty) return;
    Offset offset((int, double) item) {
      final x = points.length == 1
          ? chart.center.dx
          : chart.left + chart.width * item.$1 / (points.length - 1);
      final ratio = ((item.$2 - bounds.min) / (bounds.max - bounds.min)).clamp(
        0.0,
        1.0,
      );
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
      oldDelegate.primaryScale != primaryScale ||
      oldDelegate.accent != accent ||
      oldDelegate.secondary != secondary ||
      oldDelegate.grid != grid ||
      oldDelegate.muted != muted ||
      oldDelegate.hoverIndex != hoverIndex;
}
