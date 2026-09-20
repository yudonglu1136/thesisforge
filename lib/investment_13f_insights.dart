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
    'insightTicker': insightTicker,
    'insightInvestor': insightInvestor,
    'insightSearch': insightSearch.isEmpty ? null : insightSearch,
  }, replaceCurrent: true);

  Future<void> load13FInsights({String? quarter}) async {
    final serial = ++insightSerial, cutoff = asOf;
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
        if (!rows.any((row) => row['ticker'] == insightTicker)) {
          final loadedDetails = asMap(data['details']);
          insightTicker = text(
            loadedDetails.keys.firstOrNull,
            text(rows.firstOrNull?['ticker']),
          );
        }
        final institutions = asList(data['institutions']);
        if (!institutions.any((row) => row['investorId'] == insightInvestor)) {
          insightInvestor = text(institutions.firstOrNull?['investorId']);
        }
      });
      _persist13FInsights();
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
    final detail = asMap(asMap(institutional13f?['details'])[ticker]);
    if (detail.isNotEmpty) return;
    final serial = insightSerial, cutoff = asOf, quarter = insightQuarter;
    try {
      final data = await widget.api.getJson(
        '/api/investment/13f-insights/${Uri.encodeComponent(ticker)}?asOf=$cutoff&quarter=$quarter',
      );
      if (!mounted ||
          serial != insightSerial ||
          cutoff != asOf ||
          insightTicker != ticker) {
        return;
      }
      updateUI(() {
        final current = Map<String, dynamic>.from(institutional13f ?? {});
        final details = Map<String, dynamic>.from(asMap(current['details']));
        details[ticker] = asMap(data['details']);
        current['details'] = details;
        institutional13f = current;
      });
    } catch (_) {
      // Aggregate ranking remains usable when a bounded detail request fails.
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

  List<Map<String, dynamic>> _insightStocks() {
    final key = _insightKey(insightAction);
    final query = insightSearch.trim().toLowerCase();
    final rows = asList(institutional13f?['rows']).where((row) {
      if (number(row[key]) <= 0) return false;
      return query.isEmpty ||
          '${row['ticker']} ${row['name']}'.toLowerCase().contains(query);
    }).toList();
    rows.sort((a, b) {
      final count = number(b[key]).compareTo(number(a[key]));
      if (count != 0) return count;
      return number(b['holders']).compareTo(number(a['holders']));
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
                ? w('Ranked by filer count', '按机构数量排名')
                : w('Ranked by reported position changes', '按申报仓位动作数量排名'),
            insightPerspective == 'stocks' ? '按机构数量排名' : '按申报仓位动作数量排名',
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
                  width: 82,
                  child: label(
                    _insightName(insightAction),
                    _insightName(insightAction),
                    size: 11,
                  ),
                ),
                SizedBox(width: 70, child: label('Holders', '持有者', size: 11)),
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
                        width: 82,
                        child: Text(
                          _integer(row[key]),
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 70,
                        child: Text(
                          _integer(row['holders']),
                          style: TextStyle(color: p.text),
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
          Text(
            w(
              'Largest reported ${_insightName(insightAction).toLowerCase()}',
              '主要${_insightName(insightAction)}机构',
            ),
            style: TextStyle(color: p.text, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (asList(detail[insightAction]).isEmpty)
            label(
              'No bounded detail rows for this security; aggregate counts still use the full universe.',
              '该证券暂无明细样本，但汇总数量仍使用全量机构。',
              size: 12,
            ),
          for (final institution in asList(detail[insightAction]))
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
