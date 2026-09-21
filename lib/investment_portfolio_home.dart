part of 'main.dart';

extension _PersonalPortfolioHome on _PortfolioResearchPanelState {
  Widget personalHome(
    List<Map<String, dynamic>> groups,
    Map<String, dynamic> g,
  ) {
    final h = asMap(g['home']), daily = asMap(h['daily']);
    final history = asMap(h['history']);
    final realized = asMap(history['realized']);
    final estimates = asList(asMap(history['cashAdjusted'])['rows']);
    final latestEstimate = estimates.length > 1 ? estimates.last : null;
    final navRows = portfolioDatedNav(asList(asMap(h['nav'])['rows']));
    final navRatio = navRows.length < 2
        ? null
        : portfolioRatio(navRows.last['nav'], navRows.first['nav']);
    final sessionBasis = daily['status'] == 'ready'
        ? portfolioNavBasis(navRows, text(daily['date']), strictlyBefore: true)
        : portfolioNavBasis(
            navRows,
            text(latestEstimate?['previousDate']),
            exact: true,
          );
    final realizedBasis = portfolioNavBasis(
      navRows,
      text(realized['fromDate']),
    );
    final stocks = asList(
      g['positions'],
    ).where((r) => r['kind'] == 'equity').toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (_, c) {
            final heading = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                copy(
                  'HOME / MY PORTFOLIO',
                  '首页 / 我的组合',
                  color: p.accent,
                  size: 11,
                ),
                const SizedBox(height: 8),
                title('My portfolio', '我的组合', 30),
                const SizedBox(height: 6),
                copy(
                  'Value, performance, allocation and what moved your money.',
                  '净值、表现、资产结构与盈亏贡献，一页看清。',
                ),
              ],
            );
            final actions = Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (groups.isNotEmpty)
                  tag(
                    'Synced · ${text(h['reportDate'], w('Different dates', '日期不一致'))}',
                    '已同步 · ${text(h['reportDate'], '日期不一致')}',
                  ),
                OutlinedButton.icon(
                  key: const ValueKey('home-full-analysis'),
                  onPressed: widget.onDetails,
                  icon: const Icon(Icons.analytics_outlined, size: 17),
                  label: Text(w('Full analysis', '完整分析')),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('home-manage-ibkr'),
                  onPressed:
                      data?['status'] == 'preview_account' ||
                          data?['source'] == 'local_owner_broker_snapshot'
                      ? null
                      : managePortfolioConnection,
                  icon: const Icon(Icons.settings_outlined, size: 17),
                  label: Text(w('Manage IBKR', '管理 IBKR')),
                ),
                FilledButton.icon(
                  key: const ValueKey('home-sync-now'),
                  onPressed:
                      loading ||
                          portfolioSyncing ||
                          data?['status'] == 'preview_account' ||
                          data?['source'] == 'local_owner_broker_snapshot'
                      ? null
                      : syncConnectedPortfolio,
                  icon: portfolioSyncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_sync_rounded, size: 17),
                  label: Text(
                    portfolioSyncing
                        ? w('Syncing…', '同步中…')
                        : w('Sync now', '立即同步'),
                  ),
                ),
                IconButton(
                  key: const ValueKey('home-reload-portfolio'),
                  tooltip: w('Reload portfolio', '重新读取组合'),
                  onPressed: loading ? null : load,
                  icon: Icon(Icons.refresh_rounded, color: p.accent),
                ),
                privacyToggle(),
              ],
            );
            if (c.maxWidth >= 820 &&
                MediaQuery.textScalerOf(context).scale(1) <= 1.2) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: 24),
                  actions,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [heading, const SizedBox(height: 14), actions],
            );
          },
        ),
        if (data?['source'] == 'local_owner_broker_snapshot') ...[
          const SizedBox(height: 8),
          copy(
            'Local read-only copy · not live quotes',
            '本地只读副本 · 非实时行情',
            size: 11,
          ),
        ],
        const SizedBox(height: 22),
        if (isSavedPortfolioReport(data)) ...[
          PortfolioDataNotice(
            icon: Icons.history_rounded,
            text: savedPortfolioReportNotice(data, context.language),
            palette: p,
          ),
          const SizedBox(height: 14),
        ],
        if (portfolioActionError != null || portfolioActionMessage != null) ...[
          portfolioSyncNotice(),
          const SizedBox(height: 14),
        ],
        if (loading)
          panel([
            const LinearProgressIndicator(),
            const SizedBox(height: 16),
            copy('Reading your connected portfolio…', '正在读取你的真实组合…'),
          ])
        else if (failed)
          panel([
            title('Could not read your portfolio', '暂时无法读取你的组合'),
            const SizedBox(height: 10),
            copy(
              'Your holdings are unchanged. No sample portfolio has been substituted.',
              '原始持仓没有改变，也没有使用示例数据替代。',
            ),
            TextButton(onPressed: load, child: Text(w('Try again', '重试'))),
          ])
        else if (groups.isEmpty)
          emptyState()
        else ...[
          if (data?['status'] == 'partial_accounts') ...[
            tag(
              'Partial account coverage · not your complete portfolio',
              '部分账户读取失败 · 不是完整组合',
              color: p.secondary,
            ),
            const SizedBox(height: 12),
          ],
          if (groups.length > 1) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final currency in groups)
                  ChoiceChip(
                    label: Text(text(currency['currency'], '—')),
                    selected: identical(currency, g),
                    onSelected: (_) => homeUpdate(
                      () => selectedCurrency = text(currency['currency']),
                    ),
                  ),
              ],
            ),
            copy(
              'Base currencies are shown separately, without assumed FX.',
              '基础币种分别展示，不使用假定汇率。',
              size: 12,
            ),
            const SizedBox(height: 16),
          ],
          LayoutBuilder(
            builder: (_, c) {
              final width = c.maxWidth > 950
                  ? (c.maxWidth - 42) / 4
                  : c.maxWidth > 480
                  ? (c.maxWidth - 14) / 2
                  : c.maxWidth;
              return Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  SizedBox(
                    width: width,
                    child: homeMetric(
                      hideAmounts ? 'Account value change' : 'Account value',
                      hideAmounts ? '账户净值变化' : '账户净值',
                      hideAmounts
                          ? portfolioRateLabel(
                              navRatio == null ? null : navRatio - 1,
                            )
                          : amount(h['accountValue']),
                      hideAmounts
                          ? w(
                              '${text(navRows.firstOrNull?['date'], '—')} → ${text(navRows.lastOrNull?['date'], '—')} · includes transfers; not investment return',
                              '${text(navRows.firstOrNull?['date'], '—')} → ${text(navRows.lastOrNull?['date'], '—')} · 含转入转出，不是投资收益率',
                            )
                          : '${g['accountCount']} ${w('connected accounts', '个已连接账户')}',
                      icon: Icons.account_balance_wallet_rounded,
                      accent: true,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: homeMetric(
                      daily['status'] == 'ready'
                          ? 'Session P&L'
                          : 'Latest P&L estimate',
                      daily['status'] == 'ready' ? '当日持仓盈亏' : '最近一期盈亏估算',
                      hideAmounts
                          ? portfolioRateLabel(
                              portfolioRatio(
                                daily['status'] == 'ready'
                                    ? daily['pnl']
                                    : latestEstimate?['pnl'],
                                sessionBasis,
                              ),
                            )
                          : amount(
                              daily['status'] == 'ready'
                                  ? daily['pnl']
                                  : latestEstimate?['pnl'],
                            ),
                      (hideAmounts
                              ? w('% of previous reported NAV · ', '占上期报告净值 · ')
                              : '') +
                          (daily['status'] == 'ready'
                              ? w(
                                  'Reported instruments · ${daily['date']}',
                                  '报告证券 · ${daily['date']}',
                                )
                              : latestEstimate != null
                              ? w(
                                  '${latestEstimate['previousDate']} → ${latestEstimate['date']} · cash transfers deducted',
                                  '${latestEstimate['previousDate']} → ${latestEstimate['date']} · 已扣报告现金转入转出',
                                )
                              : w('Daily MTM report needed', '需要每日 MTM 盈亏报告')),
                      icon: Icons.trending_up_rounded,
                      color:
                          nullableNumber(
                                daily['pnl'] ?? latestEstimate?['pnl'],
                              ) ==
                              null
                          ? p.muted
                          : number(daily['pnl'] ?? latestEstimate?['pnl']) < 0
                          ? p.negative
                          : p.accent,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: homeMetric(
                      realized['status'] == 'ready'
                          ? 'Realized P&L · report period'
                          : number(g['cash']) < 0
                          ? 'Cash / borrowing'
                          : 'Cash balance',
                      realized['status'] == 'ready'
                          ? '已实现盈亏 · 报告期'
                          : number(g['cash']) < 0
                          ? '现金 / 融资余额'
                          : '现金余额',
                      hideAmounts
                          ? portfolioRateLabel(
                              portfolioRatio(
                                realized['status'] == 'ready'
                                    ? realized['total']
                                    : asList(g['positions']).any(
                                        (r) =>
                                            r['kind'] == 'cash' &&
                                            nullableNumber(r['value']) != null,
                                      )
                                    ? g['cash']
                                    : null,
                                realized['status'] == 'ready'
                                    ? realizedBasis
                                    : h['accountValue'],
                              ),
                            )
                          : amount(
                              realized['status'] == 'ready'
                                  ? realized['total']
                                  : asList(g['positions']).any(
                                      (r) =>
                                          r['kind'] == 'cash' &&
                                          nullableNumber(r['value']) != null,
                                    )
                                  ? g['cash']
                                  : null,
                            ),
                      (hideAmounts
                              ? realized['status'] == 'ready'
                                    ? w(
                                        '% of period-start NAV; not trade return · ',
                                        '占期初净值；非交易收益率 · ',
                                      )
                                    : w('% of account NAV · ', '占账户净值 · ')
                              : '') +
                          (realized['status'] == 'ready'
                              ? '${realized['fromDate']} → ${realized['toDate']} · FIFO'
                              : number(g['cash']) < 0
                              ? w('Negative cash is borrowing', '负现金表示借款')
                              : w('From your broker report', '来自券商报告')),
                      icon: realized['status'] == 'ready'
                          ? Icons.receipt_long_rounded
                          : Icons.account_balance_outlined,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: homeMetric(
                      'Holdings',
                      '持仓',
                      '${asList(g['positions']).where((r) => !['cash', 'accrual'].contains(r['kind'])).length}',
                      '${stocks.length} ${w('equities', '项股票')} · ${asList(g['positions']).where((r) => r['kind'] == 'other').length} ${w('other positions', '项其他资产')}',
                      icon: Icons.pie_chart_outline_rounded,
                    ),
                  ),
                ],
              );
            },
          ),
          if (latestEstimate != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p.secondary.withValues(alpha: .06),
                border: Border.all(color: p.secondary.withValues(alpha: .16)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: p.secondary,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: copy(
                      'Estimated P&L adjusts NAV changes for reported cash transfers. Security transfers are not reconciled. Cash / borrowing: ${amount(g['cash'])}.',
                      '盈亏估算已从净值变化中扣除已报告的现金转入转出；证券转仓尚未核对。现金 / 融资：${amount(g['cash'])}。',
                      size: 11,
                      color: p.secondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 18),
          homeAllocationOverview(g),
          const SizedBox(height: 18),
          panel([
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                title('Portfolio value & P&L', '组合净值与盈亏'),
                copy(
                  'Broker history · inspect any date',
                  '券商历史 · 查看任意日期',
                  size: 11,
                ),
              ],
            ),
            const SizedBox(height: 16),
            PortfolioAccountValueChart(
              key: ValueKey('account-nav-$selectedCurrency'),
              rows: asList(asMap(h['nav'])['rows']),
              history: history,
              currency: selectedCurrency,
              palette: p,
              hideAmounts: hideAmounts,
              chartHeight: 250,
            ),
            if (asList(asMap(h['nav'])['rows']).length < 2) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: homeHistoryHelp,
                  icon: const Icon(Icons.add_chart, size: 17),
                  label: Text(w('Set up account history', '设置账户历史数据')),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 18),
          homeMovers(h, asList(g['positions'])),
          const SizedBox(height: 18),
          homeHoldings(g),
        ],
      ],
    );
  }

  Widget homeMetric(
    String en,
    String zh,
    String value,
    String detail, {
    IconData icon = Icons.analytics_outlined,
    bool accent = false,
    Color? color,
  }) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: p.panel,
      border: Border.all(
        color: accent ? p.accent.withValues(alpha: .35) : p.border,
      ),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: (color ?? p.accent).withValues(alpha: .10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 17, color: color ?? p.accent),
            ),
            const SizedBox(width: 10),
            Expanded(child: copy(en, zh, size: 13)),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          value,
          style: heading(
            28,
          ).copyWith(color: color ?? p.text, letterSpacing: -.5),
        ),
        const SizedBox(height: 8),
        Text(
          detail,
          style: TextStyle(color: p.muted, fontSize: 12, height: 1.4),
        ),
      ],
    ),
  );

  Widget homeAllocationOverview(Map<String, dynamic> g) {
    final rows =
        asList(
          g['positions'],
        ).where((r) => !['cash', 'accrual'].contains(r['kind'])).toList()..sort(
          (a, b) =>
              number(b['value']).abs().compareTo(number(a['value']).abs()),
        );
    Widget positionTable() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(flex: 5, child: copy('Position', '持仓', size: 11)),
            Expanded(
              flex: 3,
              child: Align(
                alignment: Alignment.centerRight,
                child: copy('Value', '市值', size: 11),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 82,
              child: Align(
                alignment: Alignment.centerRight,
                child: copy('Allocation', '占比', size: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Divider(height: 1, color: p.border),
        for (final r in rows.take(6))
          InkWell(
            key: ValueKey('home-allocation-${r['id'] ?? r['ticker']}'),
            onTap: r['kind'] == 'equity'
                ? () => widget.onCompany(text(r['ticker']), 'evidence')
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p.border)),
              ),
              child: Row(
                children: [
                  if (r['kind'] == 'equity')
                    StockLogo(ticker: text(r['ticker']), palette: p, size: 31)
                  else
                    Icon(Icons.layers_outlined, color: p.secondary, size: 31),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          text(r['ticker']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: heading(14),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          text(r['name'], text(r['assetCategory'])),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(amount(r['value']), style: heading(13)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 82,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(percent(r['netWeight']), style: heading(13)),
                        const SizedBox(height: 5),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: number(r['netWeight']).abs().clamp(0, 1),
                            minHeight: 3,
                            backgroundColor: p.border,
                            color: p.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: widget.onDetails,
            child: Text(w('View all positions →', '查看全部持仓 →')),
          ),
        ),
      ],
    );
    return panel([
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          title('Portfolio allocation', '资产配置'),
          copy(
            '${rows.length} ${w('positions', '项持仓')} · ${percent(asMap(g['coverage'])['weight'])} ${w('valuation coverage', '估值覆盖')}',
            '${rows.length} 项持仓 · 估值覆盖 ${percent(asMap(g['coverage'])['weight'])}',
            size: 11,
          ),
        ],
      ),
      const SizedBox(height: 18),
      LayoutBuilder(
        builder: (_, c) {
          final chart = PortfolioAllocationChart(
            hideAmounts: hideAmounts,
            group: g,
            palette: p,
            onHolding: (ticker) =>
                widget.onCompany(portfolioValuationTicker(g, ticker), 'value'),
          );
          if (c.maxWidth >= 1040 &&
              MediaQuery.textScalerOf(context).scale(1) <= 1.2) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 5, child: chart),
                const SizedBox(width: 26),
                Container(width: 1, height: 420, color: p.border),
                const SizedBox(width: 26),
                Expanded(flex: 7, child: positionTable()),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              chart,
              const SizedBox(height: 18),
              Divider(color: p.border),
              const SizedBox(height: 8),
              positionTable(),
            ],
          );
        },
      ),
    ]);
  }

  Widget homeMovers(
    Map<String, dynamic> h,
    List<Map<String, dynamic>> positions,
  ) {
    final realizedMode = homePnlMode == 'realized';
    final open =
            homePnlMode == 'unrealized' ||
            (homePnlMode == 'auto' &&
                asMap(h['daily'])['status'] != 'ready' &&
                asMap(h['unrealized'])['status'] == 'ready'),
        metric = realizedMode
            ? asMap(asMap(h['history'])['realized'])
            : asMap(h[open ? 'unrealized' : 'daily']);
    final rows = asList(metric[realizedMode ? 'byInstrument' : 'rows']);
    final nav = asList(asMap(h['nav'])['rows']);
    final basis = portfolioNavBasis(
      nav,
      text(metric[realizedMode ? 'fromDate' : 'date']),
      strictlyBefore: !realizedMode,
    );
    double? rate(Map<String, dynamic> r) => open && !realizedMode
        ? portfolioOpenPnlRate(r, positions)
        : portfolioRatio(r['pnl'], basis);
    double? score(Map<String, dynamic> r) =>
        hideAmounts ? rate(r) : nullableNumber(r['pnl']);
    final winners = rows.where((r) => (score(r) ?? 0) > 0).toList()
      ..sort((a, b) => score(b)!.compareTo(score(a)!));
    final losers = rows.where((r) => (score(r) ?? 0) < 0).toList()
      ..sort((a, b) => score(a)!.compareTo(score(b)!));
    final unavailable = rows
        .where((r) => hideAmounts && rate(r) == null)
        .toList();
    final barExtent = rows.fold<double>(
      0,
      (max, r) => math.max(max, (score(r) ?? 0).abs()),
    );
    Widget group(
      String en,
      String zh,
      Color color,
      List<Map<String, dynamic>> items,
      String emptyEn,
      String emptyZh,
    ) => Material(
      color: p.card.withValues(alpha: .52),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    color == p.negative
                        ? Icons.trending_down_rounded
                        : Icons.trending_up_rounded,
                    size: 18,
                    color: color,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    w(en, zh),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: heading(16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (items.isEmpty && unavailable.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: copy(emptyEn, emptyZh, size: 12),
              ),
            for (final r in items.take(5))
              homeMoverRow(r, rate: rate(r), extent: barExtent),
          ],
        ),
      ),
    );
    return panel([
      title('Winners & losers', '盈利与亏损贡献'),
      const SizedBox(height: 8),
      copy(
        realizedMode
            ? 'Closed trades · ${metric['fromDate']} → ${metric['toDate']}'
            : open
            ? 'Open equities · unrealized P&L, not today’s move'
            : 'Session contribution · ${text(metric['date'], '—')}',
        realizedMode
            ? '平仓交易 · ${metric['fromDate']} → ${metric['toDate']}'
            : open
            ? '未平仓股票 · 累计浮盈亏，不是今日涨跌'
            : '当日持仓贡献 · ${text(metric['date'], '—')}',
        size: 12,
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ChoiceChip(
            label: Text(w('Day P&L', '当日盈亏')),
            selected: !open && !realizedMode,
            onSelected: (_) => homeUpdate(() => homePnlMode = 'daily'),
          ),
          ChoiceChip(
            label: Text(w('Open P&L', '累计浮盈亏')),
            selected: open && !realizedMode,
            onSelected: (_) => homeUpdate(() => homePnlMode = 'unrealized'),
          ),
          if (asMap(asMap(h['history'])['realized'])['status'] == 'ready')
            ChoiceChip(
              label: Text(w('Realized P&L', '已实现盈亏')),
              selected: realizedMode,
              onSelected: (_) => homeUpdate(() => homePnlMode = 'realized'),
            ),
        ],
      ),
      const SizedBox(height: 16),
      if (hideAmounts) ...[
        copy(
          open && !realizedMode
              ? 'Open P&L / reported cost basis. Ranked by percentage, not amount.'
              : realizedMode
              ? 'Realized P&L / period-start NAV. Account contribution, not trade return.'
              : 'Instrument P&L / previous reported NAV. Account contribution, not stock price change.',
          open && !realizedMode
              ? '持仓浮盈亏 / 报告成本，按百分比排名。'
              : realizedMode
              ? '已实现盈亏 / 期初净值，表示账户贡献，不是交易收益率。'
              : '证券盈亏 / 上期报告净值，表示账户贡献，不是股价涨跌幅。',
          color: p.accent,
          size: 11,
        ),
        const SizedBox(height: 10),
      ],
      if (open && !realizedMode && asMap(h['daily'])['status'] != 'ready') ...[
        copy(
          'Daily P&L unavailable · showing cumulative open-position P&L',
          '当日盈亏缺失 · 当前显示持仓累计浮盈亏',
          color: p.secondary,
          size: 11,
        ),
        const SizedBox(height: 10),
      ],
      if (metric['status'] != 'ready') ...[
        Icon(Icons.receipt_long_outlined, color: p.secondary, size: 32),
        const SizedBox(height: 12),
        title(
          open
              ? 'Cost basis is not in this report.'
              : 'Day P&L is not in this report.',
          open ? '报告中缺少持仓成本。' : '报告中缺少当日盈亏。',
          18,
        ),
        const SizedBox(height: 8),
        copy(
          open
              ? 'No unrealized ranking is calculated without a verified cost basis.'
              : 'A balance snapshot cannot tell us which positions won or lost this session.',
          open ? '没有核验的成本数据，不计算浮盈亏排名。' : '单张余额快照，无法判断哪些持仓在当日贡献了盈利或亏损。',
        ),
        if (!open && asMap(h['unrealized'])['status'] == 'ready')
          TextButton(
            onPressed: () => homeUpdate(() => homePnlMode = 'unrealized'),
            child: Text(w('View open-position P&L →', '查看累计浮盈亏 →')),
          ),
        TextButton(
          onPressed: homeHistoryHelp,
          child: Text(w('Which report fields do I need?', '需要哪些报告字段？')),
        ),
      ] else ...[
        LayoutBuilder(
          builder: (_, c) {
            final gains = group(
              'Top gainers',
              '主要盈利贡献',
              p.accent,
              winners,
              'No positive P&L in this report.',
              '该报告中没有正收益项目。',
            );
            final declines = group(
              'Top losers',
              '主要亏损贡献',
              p.negative,
              losers,
              'No negative P&L in this report.',
              '该报告中没有负收益项目。',
            );
            if (c.maxWidth >= 760 &&
                MediaQuery.textScalerOf(context).scale(1) <= 1.2) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: gains),
                  const SizedBox(width: 16),
                  Expanded(child: declines),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [gains, const SizedBox(height: 14), declines],
            );
          },
        ),
        if (unavailable.isNotEmpty) ...[
          const Divider(height: 24),
          copy(
            'Rate unavailable · positive NAV or verified cost basis needed',
            '变化率缺失 · 需要正净值或已核验成本',
            size: 11,
            color: p.secondary,
          ),
          for (final r in unavailable) homeMoverRow(r),
        ],
        const SizedBox(height: 12),
        copy(
          realizedMode
              ? '${metric['tradeCount']} reported trades · FIFO realized P&L at report FX. Excludes open-position P&L and account income / expenses.'
              : open
              ? '${metric['covered']} / ${metric['total']} equity positions with cost basis. Options excluded.'
              : hideAmounts
              ? 'Ranked by contribution to reported NAV. Not whole-account P&L.'
              : 'Ranked by instrument P&L in base currency, not price %. Not whole-account P&L.',
          realizedMode
              ? '${metric['tradeCount']} 条报告交易 · FIFO 已实现盈亏，使用报告汇率。不含持仓浮盈亏及账户收入 / 费用。'
              : open
              ? '${metric['covered']} / ${metric['total']} 项股票有成本数据，不含期权。'
              : hideAmounts
              ? '按占报告净值的贡献排名，不是完整账户盈亏。'
              : '按本币证券盈亏金额排名，不是涨跌幅，也不是完整账户盈亏。',
          size: 11,
        ),
      ],
    ]);
  }

  Widget homeMoverRow(Map<String, dynamic> r, {double? rate, double? extent}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: StockLogo(ticker: text(r['ticker']), palette: p, size: 30),
            title: Text(text(r['ticker']), style: heading(14)),
            subtitle: Text(
              text(r['name']),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.muted, fontSize: 11),
            ),
            trailing: Text(
              hideAmounts
                  ? portfolioRateLabel(rate)
                  : '${number(r['pnl']) > 0 ? '+' : ''}${amount(r['pnl'])}',
              style: TextStyle(
                color: number(r['pnl']) < 0 ? p.negative : p.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
            onTap:
                [
                  'STK',
                  'STOCK',
                  'EQUITY',
                  'COMMON STOCK',
                ].contains(r['assetCategory'])
                ? () => widget.onCompany(text(r['ticker']), 'evidence')
                : null,
          ),
          if (extent != null)
            Padding(
              padding: const EdgeInsets.only(left: 46, bottom: 6),
              child: PortfolioDivergingBar(
                value: hideAmounts ? rate : nullableNumber(r['pnl']),
                extent: extent,
                palette: p,
              ),
            ),
        ],
      );

  Widget homeHoldings(Map<String, dynamic> g) {
    final rows =
        asList(
          g['positions'],
        ).where((r) => !['cash', 'accrual'].contains(r['kind'])).toList()..sort(
          (a, b) =>
              number(b['value']).abs().compareTo(number(a['value']).abs()),
        );
    return panel([
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        children: [
          title('My holdings', '我的持仓'),
          TextButton(
            onPressed: widget.onDetails,
            child: Text(w('All positions & analysis →', '全部持仓与分析 →')),
          ),
        ],
      ),
      copy(
        'Your stocks, their valuation and the Gurus behind them. Expand Guru activity to see who added or reduced.',
        '你的持仓、估值与大佬动向放在一起。展开大佬动向，查看具体加减仓名单。',
        size: 12,
      ),
      copy(
        'Valuations as of ${widget.asOf} · compared with broker report marks.',
        '估值信息截止 ${widget.asOf} · 与券商报告市价比较。',
        size: 11,
      ),
      const SizedBox(height: 12),
      for (final r in rows.take(holdingLimit))
        LayoutBuilder(
          builder: (_, c) {
            final stock = r['kind'] == 'equity',
                gap = nullableNumber(r['modelGap']);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  key: ValueKey('home-position-${r['id'] ?? r['ticker']}'),
                  onTap: stock
                      ? () => widget.onCompany(text(r['ticker']), 'evidence')
                      : null,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: p.border)),
                    ),
                    child: Row(
                      children: [
                        if (stock)
                          StockLogo(
                            ticker: text(r['ticker']),
                            palette: p,
                            size: 34,
                          )
                        else
                          Icon(
                            Icons.layers_outlined,
                            color: p.secondary,
                            size: 34,
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                text(r['ticker']),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: heading(15),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                stock
                                    ? text(r['name'])
                                    : '${r['assetCategory']} · ${w('Not an equity valuation', '不适用股票估值')}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: p.muted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(amount(r['value']), style: heading(14)),
                              const SizedBox(height: 4),
                              copy(
                                '${percent(r['netWeight'])} ${w('of net marks', '占净市值')}',
                                '${percent(r['netWeight'])} 占净市值',
                                size: 11,
                              ),
                            ],
                          ),
                        ),
                        if (c.maxWidth > 650) ...[
                          const SizedBox(width: 22),
                          SizedBox(
                            width: 155,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  gap == null
                                      ? '—'
                                      : '${gap > 0 ? '+' : ''}${percent(gap)}',
                                  style: heading(14).copyWith(
                                    color: gap == null
                                        ? p.muted
                                        : gap < 0
                                        ? p.negative
                                        : p.accent,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                copy(
                                  'Model / price − 1',
                                  '模型 / 市价 − 1',
                                  size: 11,
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (stock)
                          Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Icon(
                              Icons.chevron_right,
                              color: p.accent,
                              size: 18,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (stock) ...[
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (c.maxWidth <= 650)
                        copy(
                          'Model / price − 1: ${percent(gap)}',
                          '模型 / 市价 − 1：${percent(gap)}',
                          size: 12,
                        ),
                      TextButton(
                        onPressed: () => widget.onCompany(
                          text(asMap(r['model'])['modelTicker'] ?? r['ticker']),
                          'value',
                        ),
                        child: Text(w('Valuation →', '查看估值 →')),
                      ),
                      TextButton(
                        onPressed: () =>
                            widget.onCompany(text(r['ticker']), 'evidence'),
                        child: Text(w('Financials & sources →', '财务与来源 →')),
                      ),
                    ],
                  ),
                  portfolioGuruEvidence(r),
                ],
              ],
            );
          },
        ),
      if (rows.length > holdingLimit)
        TextButton(
          onPressed: () => homeUpdate(() => holdingLimit += 20),
          child: Text(w('Show more holdings', '显示更多持仓')),
        ),
    ]);
  }

  Future<void> homeHistoryHelp() => showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: p.panel,
      title: Text(w('Complete your account history', '补齐账户历史数据')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              copy(
                '1. Account value: include Net Asset Value by report date in your Activity query. Sync also requests the last 365 days from that query; a separate history Query ID is optional.',
                '1. 净值曲线：在 Activity 查询中加入按报告日记录的净资产值。同步会同时请求该查询最近 365 天的数据，历史 Query ID 不是必填项。',
              ),
              const SizedBox(height: 16),
              copy(
                '2. Day winners / losers: include Mark-to-Market Performance Summary in Base, with instrument totals. Use a one-day statement; monthly totals are not daily P&L.',
                '2. 当日盈亏：加入 Mark-to-Market Performance Summary in Base 证券级总盈亏；使用单日报告，月度合计不能当作每日盈亏。',
              ),
              const SizedBox(height: 16),
              copy(
                '3. Realized P&L: include Trades with FIFO realized P&L and FX rate to base. Cash Transactions with deposits / withdrawals enables cash-adjusted P&L estimates. Verified total performance also needs security transfers or broker TWR.',
                '3. 已实现盈亏：加入 Trades 的 FIFO 已实现盈亏及本币汇率。Cash Transactions 中的入出金用于现金调整后的盈亏估算。核验完整收益还需证券转仓或券商 TWR。',
              ),
              const SizedBox(height: 16),
              copy(
                'Your existing holdings stay intact. No trading permission is needed.',
                '已有持仓保持不变，无需交易权限。',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(w('Got it', '知道了')),
        ),
        if (data?['source'] != 'local_owner_broker_snapshot')
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              connectIbkr();
            },
            child: Text(w('Update IBKR connection', '更新 IBKR 连接')),
          ),
      ],
    ),
  );
}

class PortfolioAccountValueChart extends StatefulWidget {
  const PortfolioAccountValueChart({
    super.key,
    required this.rows,
    required this.currency,
    required this.palette,
    this.history = const {},
    this.hideAmounts = false,
    this.chartHeight = 280,
  });
  final List<Map<String, dynamic>> rows;
  final String currency;
  final Palette palette;
  final Map<String, dynamic> history;
  final bool hideAmounts;
  final double chartHeight;
  @override
  State<PortfolioAccountValueChart> createState() =>
      _PortfolioAccountValueChartState();
}

class _PortfolioAccountValueChartState
    extends State<PortfolioAccountValueChart> {
  String range = 'All';
  String metric = 'nav';
  int? hover;
  String w(String en, String zh) => context.tr(zh, en);
  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final sourceRows = metric == 'nav'
        ? widget.rows
        : asList(
            asMap(widget.history[metric])['rows'],
          ).map((r) => {...r, 'nav': r['cumulativePnl']}).toList();
    final all = portfolioDatedNav(sourceRows);
    if (all.length < 2) {
      return Container(
        key: const ValueKey('nav-history-needed'),
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 18),
        decoration: BoxDecoration(
          color: p.card.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.radio_button_checked, color: p.accent, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    w('History starts here', '从真实记录开始'),
                    style: TextStyle(
                      color: p.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (all.isNotEmpty)
              Text(
                widget.hideAmounts
                    ? '••••'
                    : '${widget.currency} ${formatNumber(number(all.single['nav']))}',
                style: TextStyle(
                  color: p.text,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
            const SizedBox(height: 8),
            Text(
              all.isEmpty
                  ? w('No dated account balances yet.', '尚无带日期的账户净值。')
                  : w(
                      '1 verified balance · ${all.single['date']}',
                      '1 条已核验净值 · ${all.single['date']}',
                    ),
              style: TextStyle(color: p.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            Text(
              w(
                'Connect daily account history to see the curve. Today’s positions are not backfilled into historical performance.',
                '接入每日账户记录后展示曲线，不会把今天的持仓倒推成历史业绩。',
              ),
              style: TextStyle(color: p.muted, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      );
    }
    final end = DateTime.parse(text(all.last['date']));
    final start = range == 'All'
        ? DateTime(1900)
        : range == 'YTD'
        ? DateTime(end.year)
        : end.subtract(
            Duration(
              days: range == '1M'
                  ? 31
                  : range == '3M'
                  ? 93
                  : 366,
            ),
          );
    var rows = all
        .where((r) => !DateTime.parse(text(r['date'])).isBefore(start))
        .toList();
    final priorYear = range == 'YTD'
        ? all
              .where((r) => DateTime.parse(text(r['date'])).isBefore(start))
              .lastOrNull
        : null;
    final hasYearEnd =
        priorYear != null &&
        start.difference(DateTime.parse(text(priorYear['date']))).inDays <= 7;
    // Retain the real previous year-end observation as the NAV opening point.
    // Otherwise YTD is explicitly partial; never fabricate a January 1 balance.
    if (metric == 'nav' && range == 'YTD' && hasYearEnd) {
      rows = [priorYear, ...rows];
    }
    var basisDate = text(rows.first['date']);
    // P&L always starts at the selected period, not the full-history baseline.
    if (metric != 'nav') {
      final firstIndex = all.indexOf(rows.first);
      final baseline = firstIndex > 0
          ? number(all[firstIndex - 1]['nav'])
          : 0.0;
      basisDate = firstIndex > 0
          ? text(all[firstIndex - 1]['date'])
          : text(rows.first['date']);
      rows = rows
          .map((r) => {...r, 'nav': number(r['nav']) - baseline})
          .toList();
    }
    final basis = metric == 'nav'
        ? nullableNumber(rows.first['nav'])
        : portfolioNavBasis(widget.rows, basisDate);
    final displayRows = widget.hideAmounts
        ? portfolioPercentageSeries(rows, basis, nav: metric == 'nav')
        : rows;
    final rateAvailable = displayRows.every(
      (r) => nullableNumber(r['nav']) != null,
    );
    final cursor = (hover ?? rows.length - 1).clamp(0, rows.length - 1);
    final measures = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final mode in ['nav', 'realized', 'cashAdjusted'])
          ChoiceChip(
            key: ValueKey('history-metric-$mode'),
            label: Text(
              mode == 'nav'
                  ? w('Account value', '账户净值')
                  : mode == 'realized'
                  ? w('Realized P&L', '已实现盈亏')
                  : w('P&L estimate', '盈亏估算'),
            ),
            selected: metric == mode,
            onSelected:
                mode != 'nav' &&
                    asList(asMap(widget.history[mode])['rows']).length < 2
                ? null
                : (_) => setState(() {
                    metric = mode;
                    hover = null;
                  }),
          ),
      ],
    );
    final ranges = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final r in ['1M', '3M', 'YTD', '1Y', 'All'])
          ChoiceChip(
            key: ValueKey('history-range-$r'),
            label: Text(
              r == 'All'
                  ? w('All', '全部')
                  : r == 'YTD'
                  ? w('YTD', '今年至今')
                  : r,
            ),
            selected: range == r,
            onSelected: (_) => setState(() {
              range = r;
              hover = null;
            }),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (_, c) {
            if (widget.history.isEmpty) return ranges;
            if (c.maxWidth >= 660 &&
                MediaQuery.textScalerOf(context).scale(1) <= 1.1) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: measures),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: ranges),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [measures, const SizedBox(height: 10), ranges],
            );
          },
        ),
        const SizedBox(height: 16),
        if (range == 'YTD') ...[
          Text(
            w(
              'YTD ${end.year} · through ${all.last['date']}',
              '${end.year} 年初至今 · 截至 ${all.last['date']}',
            ),
            style: TextStyle(color: p.muted, fontSize: 12),
          ),
          if (!hasYearEnd)
            Text(
              w(
                'Partial history: no year-end baseline. Showing available observations from ${rows.first['date']}.',
                '历史不完整：缺少年末基准，仅显示 ${rows.first['date']} 起的已有记录。',
              ),
              style: TextStyle(color: p.secondary, fontSize: 12),
            ),
          const SizedBox(height: 10),
        ],
        Text(
          '${rows[cursor]['date']} · ${widget.hideAmounts ? portfolioRateLabel(displayRows[cursor]['nav']) : '${widget.currency} ${formatNumber(number(rows[cursor]['nav']))}'}',
          style: TextStyle(
            color: number(displayRows[cursor]['nav']) < 0
                ? p.negative
                : p.accent,
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: -.3,
          ),
        ),
        const SizedBox(height: 10),
        if (metric != 'nav') ...[
          Text(
            widget.hideAmounts
                ? w(
                    'On this date / interval: ${portfolioRateLabel(portfolioRatio(rows[cursor]['pnl'], basis))} of starting NAV',
                    '该日 / 该期盈亏：占起始净值 ${portfolioRateLabel(portfolioRatio(rows[cursor]['pnl'], basis))}',
                  )
                : metric == 'realized'
                ? w(
                    'Realized on this date: ${widget.currency} ${formatNumber(number(rows[cursor]['pnl']))}',
                    '该日已实现：${widget.currency} ${formatNumber(number(rows[cursor]['pnl']))}',
                  )
                : w(
                    'Interval change: ${widget.currency} ${formatNumber(number(rows[cursor]['pnl']))} · reported cash transfers: ${formatNumber(number(rows[cursor]['netFlow']))}',
                    '该期变化：${widget.currency} ${formatNumber(number(rows[cursor]['pnl']))} · 报告现金转入转出：${formatNumber(number(rows[cursor]['netFlow']))}',
                  ),
            style: TextStyle(color: p.muted, fontSize: 12),
          ),
          const SizedBox(height: 10),
        ],
        if (!rateAvailable)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 30),
            child: Text(
              w(
                'Rate unavailable — a positive starting account value is required.',
                '变化率暂不可用：需要正数的起始账户净值。',
              ),
              style: TextStyle(color: p.secondary),
            ),
          )
        else if (rows.length > 1) ...[
          Semantics(
            label: widget.hideAmounts
                ? w(
                    'Portfolio percentage chart. Use the date slider to inspect. Not an investment return.',
                    '组合百分比曲线。使用日期滑块查看，不代表投资收益率。',
                  )
                : w(
                    '${metric == 'nav'
                        ? 'Actual account value'
                        : metric == 'realized'
                        ? 'Realized trading P&L'
                        : 'Cash-adjusted P&L estimate'} in ${widget.currency}. Use the date slider to inspect. Not an investment return.',
                    '${widget.currency} ${metric == 'nav'
                        ? '实际账户净值'
                        : metric == 'realized'
                        ? '已实现交易盈亏'
                        : '现金调整后盈亏估算'}。使用日期滑块检查，不代表投资收益率。',
                  ),
            child: SizedBox(
              key: ValueKey(
                metric == 'nav' ? 'actual-nav-chart' : '$metric-pnl-chart',
              ),
              height: widget.chartHeight,
              child: LayoutBuilder(
                builder: (_, constraints) {
                  void inspect(double dx) {
                    final fraction = ((dx - 64) / (constraints.maxWidth - 76))
                        .clamp(0.0, 1.0);
                    final startMs = DateTime.parse(
                      text(rows.first['date']),
                    ).millisecondsSinceEpoch;
                    final endMs = DateTime.parse(
                      text(rows.last['date']),
                    ).millisecondsSinceEpoch;
                    final target = startMs + fraction * (endMs - startMs);
                    var nearest = 0;
                    for (var i = 1; i < rows.length; i++) {
                      if ((DateTime.parse(
                                    text(rows[i]['date']),
                                  ).millisecondsSinceEpoch -
                                  target)
                              .abs() <
                          (DateTime.parse(
                                    text(rows[nearest]['date']),
                                  ).millisecondsSinceEpoch -
                                  target)
                              .abs()) {
                        nearest = i;
                      }
                    }
                    if (hover != nearest) setState(() => hover = nearest);
                  }

                  return MouseRegion(
                    onHover: (e) => inspect(e.localPosition.dx),
                    child: GestureDetector(
                      onTapDown: (e) => inspect(e.localPosition.dx),
                      child: CustomPaint(
                        painter: _AccountNavPainter(
                          displayRows,
                          p,
                          cursor,
                          includeZero: widget.hideAmounts || metric != 'nav',
                          percentage: widget.hideAmounts,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          Slider(
            value: cursor.toDouble(),
            min: 0,
            max: (rows.length - 1).toDouble(),
            divisions: rows.length - 1,
            label: text(rows[cursor]['date']),
            semanticFormatterCallback: (v) =>
                text(rows[v.round().clamp(0, rows.length - 1)]['date']),
            onChanged: (v) =>
                setState(() => hover = v.round().clamp(0, rows.length - 1)),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 30),
            child: Text(
              w(
                'Only one observation in this range. Select a longer period.',
                '此区间只有一条记录，请选择更长区间。',
              ),
              style: TextStyle(color: p.muted),
            ),
          ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          children: [
            Text(
              text(rows.first['date']),
              style: TextStyle(color: p.muted, fontSize: 11),
            ),
            Text(
              '${rows.length} ${metric == 'nav' ? w('reported balances', '条报告净值') : w('dated observations', '条日期记录')} · ${rows.last['date']}',
              style: TextStyle(color: p.muted, fontSize: 11),
            ),
          ],
        ),
        if (widget.hideAmounts) ...[
          const SizedBox(height: 12),
          Text(
            metric == 'nav'
                ? w(
                    'Account value change since ${rows.first['date']}. Includes deposits and withdrawals; not investment return.',
                    '相对 ${rows.first['date']} 的账户净值变化，含入金和出金，不是投资收益率。',
                  )
                : w(
                    'Selected-period P&L / starting reported NAV ($basisDate or earlier). Contribution, not total return.',
                    '所选期间盈亏 / 起始报告净值（$basisDate 或之前）。是贡献比例，不是完整收益率。',
                  ),
            style: TextStyle(color: p.accent, fontSize: 12, height: 1.5),
          ),
        ],
        if (widget.history.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            metric == 'nav'
                ? w(
                    'Broker-reported balances, including cash, borrowing and options. Not a return index.',
                    '券商实际净值，包含现金、融资和期权，不是收益率指数。',
                  )
                : metric == 'realized'
                ? w(
                    'Cumulative FIFO realized trading P&L in the selected period. Open P&L and account income / expenses are excluded.',
                    '所选区间累计 FIFO 已实现交易盈亏。不含未平仓浮盈亏及账户收入 / 费用。',
                  )
                : w(
                    'Estimate: NAV change less reported cash transfers. Security transfers are not reconciled; not verified total performance.',
                    '估算：净值变化扣除已报告现金转入转出。证券转仓未核对，不是已核验的完整投资收益。',
                  ),
            style: TextStyle(
              color: metric == 'cashAdjusted' ? p.secondary : p.muted,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}

class _AccountNavPainter extends CustomPainter {
  _AccountNavPainter(
    this.rows,
    this.p,
    this.cursor, {
    this.includeZero = false,
    this.percentage = false,
  });
  final List<Map<String, dynamic>> rows;
  final Palette p;
  final int cursor;
  final bool includeZero;
  final bool percentage;
  @override
  void paint(Canvas canvas, Size size) {
    final values = rows.map((r) => number(r['nav'])).toList();
    final lo = includeZero
            ? math.min(0.0, values.reduce(math.min))
            : values.reduce(math.min),
        hi = includeZero
            ? math.max(0.0, values.reduce(math.max))
            : values.reduce(math.max);
    final pad = math.max(
      (hi - lo) * .12,
      math.max(hi.abs() * .005, percentage ? .001 : 1),
    );
    final min = lo - pad, max = hi + pad;
    final times = rows
        .map(
          (r) =>
              DateTime.parse(text(r['date'])).millisecondsSinceEpoch.toDouble(),
        )
        .toList();
    final rect = Rect.fromLTRB(64, 16, size.width - 12, size.height - 30);
    double x(int i) =>
        rect.left +
        (times[i] - times.first) / (times.last - times.first) * rect.width;
    double y(double v) => rect.bottom - (v - min) / (max - min) * rect.height;
    for (var i = 0; i < 4; i++) {
      final value = min + (max - min) * i / 3;
      canvas.drawLine(
        Offset(rect.left, y(value)),
        Offset(rect.right, y(value)),
        Paint()
          ..color = p.border.withValues(alpha: .6)
          ..strokeWidth = 1,
      );
      final label = TextPainter(
        text: TextSpan(
          text: percentage
              ? '${(value * 100).toStringAsFixed(1)}%'
              : value.abs() >= 1000000
              ? '${(value / 1000000).toStringAsFixed(2)}M'
              : value.abs() >= 1000
              ? '${(value / 1000).toStringAsFixed(1)}K'
              : value.toStringAsFixed(0),
          style: TextStyle(color: p.muted, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 60);
      label.paint(canvas, Offset(0, y(value) - 6));
    }
    final path = Path()..moveTo(x(0), y(values[0]));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(x(i), y(values[i]));
    }
    final fill = Path.from(path)
      ..lineTo(x(values.length - 1), rect.bottom)
      ..lineTo(x(0), rect.bottom)
      ..close();
    canvas.drawPath(fill, Paint()..color = p.accent.withValues(alpha: .055));
    for (var step = 0; step < 4; step++) {
      final time = times.first + (times.last - times.first) * step / 3;
      final date = DateTime.fromMillisecondsSinceEpoch(time.round());
      final tick = TextPainter(
        text: TextSpan(
          text:
              times.last - times.first <=
                  const Duration(days: 120).inMilliseconds
              ? '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}'
              : '${date.year}-${date.month.toString().padLeft(2, '0')}',
          style: TextStyle(color: p.muted, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = rect.left + rect.width * step / 3;
      tick.paint(
        canvas,
        Offset(
          (dx - tick.width / 2).clamp(rect.left, rect.right - tick.width),
          rect.bottom + 12,
        ),
      );
    }
    if (includeZero) {
      canvas.drawLine(
        Offset(rect.left, y(0)),
        Offset(rect.right, y(0)),
        Paint()
          ..color = p.muted.withValues(alpha: .7)
          ..strokeWidth = 1,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = p.accent
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
    canvas.drawLine(
      Offset(x(cursor), rect.top),
      Offset(x(cursor), rect.bottom),
      Paint()
        ..color = p.muted.withValues(alpha: .4)
        ..strokeWidth = 1,
    );
    canvas.drawCircle(
      Offset(x(cursor), y(values[cursor])),
      8,
      Paint()..color = p.accent.withValues(alpha: .18),
    );
    canvas.drawCircle(
      Offset(x(cursor), y(values[cursor])),
      4,
      Paint()..color = p.accent,
    );
    canvas.drawCircle(
      Offset(x(cursor), y(values[cursor])),
      1.8,
      Paint()..color = p.text,
    );
  }

  @override
  bool shouldRepaint(covariant _AccountNavPainter old) =>
      old.rows != rows ||
      old.cursor != cursor ||
      old.p != p ||
      old.includeZero != includeZero ||
      old.percentage != percentage;
}
