part of 'main.dart';

extension _PersonalPortfolioHome on _PortfolioResearchPanelState {
  Widget homeQuickstartLaunchpad() {
    const featured = ['NVDA', 'AMZN', 'MSFT', 'GOOGL', 'META'];
    return Container(
      key: const ValueKey('home-quickstart-launchpad'),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF14181D), Color(0xFF101114)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.accent.withValues(alpha: .32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_outlined, color: p.accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  w(
                    'START EXPLORING IMMEDIATELY · NO BROKER CONNECTION REQUIRED',
                    '无需绑定券商即可立即开始投研探索',
                  ),
                  style: TextStyle(
                    color: p.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: context.isChinese ? 0 : .6,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            w(
              'Explore company valuations, institutional 13F books, or audited strategies in one click',
              '一键体验个股深度估值、机构 13F 持仓共识与量化策略',
            ),
            style: TextStyle(
              color: p.text,
              fontSize: 19,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                w('Popular valuations:', '热门公司估值驾驶舱：'),
                style: TextStyle(color: p.muted, fontSize: 12.5),
              ),
              for (final symbol in featured)
                ActionChip(
                  key: ValueKey('quickstart-ticker-$symbol'),
                  avatar: StockLogo(ticker: symbol, palette: p, size: 18),
                  backgroundColor: const Color(0xFF181A20),
                  side: BorderSide(color: p.border),
                  label: Text(
                    symbol,
                    style: TextStyle(
                      color: p.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: () => widget.onCompany(symbol, 'evidence'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (widget.onExploreDiscover != null)
                FilledButton.tonalIcon(
                  key: const ValueKey('quickstart-discover'),
                  onPressed: widget.onExploreDiscover,
                  icon: const Icon(Icons.explore_outlined, size: 16),
                  label: Text(
                    w(
                      'Explore 30 Guru 13F Books & AI Insights',
                      '浏览 30 位大师持仓与 AI 洞察',
                    ),
                  ),
                ),
              if (widget.onExploreStrategies != null)
                OutlinedButton.icon(
                  key: const ValueKey('quickstart-strategies'),
                  onPressed: widget.onExploreStrategies,
                  icon: const Icon(Icons.layers_outlined, size: 16),
                  label: Text(
                    w('Inspect Audited Strategies', '查看零幸存者偏差量化策略'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

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
    return LayoutBuilder(
      builder: (_, outerConstraints) {
        if (widget.mobileSection != null) {
          return _snowballPocketRouter(
            section: widget.mobileSection!,
            groups: groups,
            g: g,
            h: h,
            daily: daily,
            history: history,
            realized: realized,
            latestEstimate: latestEstimate,
            navRows: navRows,
            navRatio: navRatio,
            sessionBasis: sessionBasis,
            realizedBasis: realizedBasis,
            stocks: stocks,
          );
        }
        if (outerConstraints.maxWidth > 0 && outerConstraints.maxWidth < 600) {
          return _mobilePersonalHome(
            groups: groups,
            g: g,
            h: h,
            daily: daily,
            history: history,
            realized: realized,
            latestEstimate: latestEstimate,
            navRows: navRows,
            navRatio: navRatio,
            sessionBasis: sessionBasis,
            realizedBasis: realizedBasis,
            stocks: stocks,
          );
        }
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
                          (groups.isEmpty &&
                              asMap(data?['connection'])['configured'] !=
                                  true) ||
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
        else if (groups.isEmpty) ...[
          if (widget.homeMode &&
              asMap(data?['connection'])['configured'] != true) ...[
            homeQuickstartLaunchpad(),
            const SizedBox(height: 18),
          ],
          emptyState(),
        ] else ...[
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
                              ? '${realized['fromDate']} → ${realized['toDate']} · ${w('FIFO', '先进先出 (FIFO)')}'
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
          homeHeroOverview(g, h, history),
          if (_hasPassiveIncomeContent(h)) ...[
            const SizedBox(height: 18),
            PortfolioPassiveIncomeCard(
              passiveIncome: asMap(h['passiveIncome']),
              currency: selectedCurrency,
              palette: p,
              hideAmounts: hideAmounts,
              onCompany: widget.onCompany,
            ),
          ],
          const SizedBox(height: 18),
          homeMovers(h, asList(g['positions'])),
          const SizedBox(height: 18),
          homeHoldings(g),
        ],
      ],
    );
      },
    );
  }

  bool _hasPassiveIncomeContent(Map<String, dynamic> h) {
    final passive = asMap(h['passiveIncome']);
    if (passive['status'] == 'ready') return true;
    return asList(asMap(passive['pendingShortCalls'])['rows']).isNotEmpty ||
        asList(asMap(passive['pendingShortPuts'])['rows']).isNotEmpty;
  }

  void _showMobilePnlFootnoteSheet(Map<String, dynamic> g) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0E131B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E3A4B),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                w('P&L Accounting & Cash Note', '盈亏口径与资金流说明'),
                style: heading(16),
              ),
              const SizedBox(height: 8),
              Text(
                w(
                  'Estimated P&L adjusts reported NAV changes for cash deposits and withdrawals. Security transfers are not reconciled. Cash / borrowing balance: ${amount(g['cash'])}.',
                  '盈亏估算已从净值变化中扣除券商报告的现金转入转出；跨券商证券转仓尚未核对。当前现金 / 融资余额：${amount(g['cash'])}。',
                ),
                style: TextStyle(color: p.muted, fontSize: 13, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _extractUnderlyingTicker(Map<String, dynamic> r) {
    final direct = text(r['underlyingSymbol'] ?? r['underlying'] ?? '', '').trim();
    if (RegExp(r'^[A-Z]{1,5}(\.[A-Z])?$').hasMatch(direct)) return direct;
    final raw = text(r['ticker'], '').trim().toUpperCase();
    if (raw.isEmpty) return null;
    final token = raw.split(RegExp(r'\s+')).first;
    if (RegExp(r'^[A-Z]{1,5}(\.[A-Z])?$').hasMatch(token)) return token;
    final prefix = RegExp(r'^([A-Z]{1,5})\d{6}[CP]').firstMatch(raw);
    return prefix?.group(1);
  }

  void _requestMobileMainChartMetric(String nextMetric) {
    homeUpdate(() {
      mobileRequestedChartMetric = nextMetric;
      mobileRequestedChartNonce++;
    });
  }

  void _notifyMobileActionStatus(String en, String zh) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF151D29),
        duration: const Duration(seconds: 3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: p.border),
        ),
        content: Text(
          w(en, zh),
          style: TextStyle(color: p.text, fontSize: 12.5),
        ),
      ),
    );
  }

  Widget _mobileSheetFrame({
    required BuildContext sheetContext,
    required Key sheetKey,
    required String titleEn,
    required String titleZh,
    String? subtitleEn,
    String? subtitleZh,
    required List<Widget> children,
  }) => ConstrainedBox(
    key: sheetKey,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.82,
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF2E3A4B),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w(titleEn, titleZh),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: heading(16),
                      ),
                      if (subtitleEn != null && subtitleZh != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          w(subtitleEn, subtitleZh),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 11.5),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: w('Close', '关闭'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  icon: Icon(Icons.close_rounded, size: 19, color: p.muted),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _mobileSheetMetricRow(
    String labelEn,
    String labelZh,
    String valueText, {
    Color? valueColor,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(
          child: Text(
            w(labelEn, labelZh),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.muted, fontSize: 12.5),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          valueText,
          style: TextStyle(
            color: valueColor ?? p.text,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );

  void _showMobileRealizedPnlSheet({
    required Map<String, dynamic> g,
    required Map<String, dynamic> h,
    required Map<String, dynamic> realized,
    required double? realizedBasis,
    String initialTab = 'bySymbol',
  }) {
    final realizedReady = realized['status'] == 'ready';
    if (!realizedReady && initialTab != 'income') {
      _showMobileCashAndAccountsSheet(g, h);
      return;
    }
    final byInst = asList(realized['byInstrument']);
    final rawRows = asList(realized['rows']);
    final activeDailyRows = rawRows
        .where((r) => number(r['pnl']).abs() > 0.005)
        .toList()
        .reversed
        .toList();
    final dailyList = activeDailyRows.isNotEmpty
        ? activeDailyRows
        : rawRows.reversed.take(30).toList();
    final passive = asMap(h['passiveIncome']);
    final dividends = asMap(passive['dividends']);
    final realizedOptions = asMap(passive['options']).isNotEmpty
        ? asMap(passive['options'])
        : asMap(passive['expiredCalls']);
    final passiveByTicker = asList(passive['byTicker']);
    final pendingShortCalls = asList(asMap(passive['pendingShortCalls'])['rows']);
    final trailing = asMap(h['trailingDividends']);
    final totalNum = nullableNumber(realized['total']) ?? 0;
    final totalColor = totalNum < 0 ? p.negative : p.accent;
    final totalDisplay = hideAmounts
        ? portfolioRateLabel(portfolioRatio(realized['total'], realizedBasis))
        : '${totalNum > 0 ? '+' : ''}${amount(realized['total'])}';
    final maxInstAbs = byInst.fold<double>(
      0,
      (prev, r) => math.max(prev, number(r['pnl']).abs()),
    );
    var activeTab = initialTab;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF131720),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => _mobileSheetFrame(
          sheetContext: sheetCtx,
          sheetKey: const ValueKey('mobile-realized-pnl-sheet'),
          titleEn: 'Realized P&L & Cash Income',
          titleZh: '已实现盈亏与现金收入明细',
          subtitleEn:
              '${text(realized['fromDate'], '—')} → ${text(realized['toDate'], '—')} · FIFO broker ledger',
          subtitleZh:
              '${text(realized['fromDate'], '—')} → ${text(realized['toDate'], '—')} · 券商 FIFO 平仓台账',
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF131A24),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF222E3F)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    w('CUMULATIVE REALIZED P&L (FIFO)', '累计已实现盈亏 (FIFO)'),
                    style: TextStyle(
                      color: p.muted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      totalDisplay,
                      style: TextStyle(
                        color: totalColor,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (nullableNumber(realized['tradeCount']) != null)
                        tag(
                          '${number(realized['tradeCount']).round()} closed trades',
                          '${number(realized['tradeCount']).round()} 笔平仓交割',
                        ),
                      tag(
                        '${byInst.length} instruments',
                        '${byInst.length} 个归因标的',
                      ),
                      if (passive['status'] == 'ready')
                        tag(
                          'Cash income ${hideAmounts ? '••••' : amount(passive['totalConfirmed'])}',
                          '股息与权利金 ${hideAmounts ? '••••' : amount(passive['totalConfirmed'])}',
                        ),
                    ],
                  ),
                  if (rawRows.length >= 2) ...[
                    const SizedBox(height: 12),
                    Material(
                      color: p.accent.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(9),
                      child: InkWell(
                        key: const ValueKey('sheet-switch-chart-realized'),
                        borderRadius: BorderRadius.circular(9),
                        onTap: () {
                          Navigator.of(sheetCtx).pop();
                          _requestMobileMainChartMetric('realized');
                        },
                        child: Container(
                          height: 38,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: p.accent.withValues(alpha: .35),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.show_chart_rounded,
                                size: 16,
                                color: p.accent,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  w(
                                    'Show Realized Curve on Main Chart',
                                    '在主图查看已实现盈亏曲线',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.accent,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Material(
              color: const Color(0xFF0A0D12),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: p.border),
                ),
                child: Row(
                  children: [
                    for (final tab in [
                      ('bySymbol', 'By Symbol', '标的归因'),
                      ('daily', 'Daily Log', '按日流水'),
                      ('income', 'Income & Divs', '股息与权利金'),
                    ])
                      Expanded(
                        child: InkWell(
                          key: ValueKey('realized-sheet-tab-${tab.$1}'),
                          borderRadius: BorderRadius.circular(7),
                          onTap: () => setSheetState(() => activeTab = tab.$1),
                          child: Container(
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: activeTab == tab.$1
                                  ? const Color(0xFF17202D)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              w(tab.$2, tab.$3),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: activeTab == tab.$1 ? p.text : p.muted,
                                fontSize: 12,
                                fontWeight: activeTab == tab.$1
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (activeTab == 'bySymbol') ...[
              if (byInst.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: copy(
                    'No symbol-level closed trade attribution in this report.',
                    '当前报告暂无按标的拆分的平仓归因记录。',
                  ),
                )
              else
                for (final item in byInst)
                  Builder(
                    builder: (_) {
                      final pnlVal = number(item['pnl']);
                      final isEquity = [
                        'STK',
                        'STOCK',
                        'EQUITY',
                        'COMMON STOCK',
                      ].contains(text(item['assetCategory']).toUpperCase());
                      final underlying = _extractUnderlyingTicker(item);
                      final barRatio = maxInstAbs > 0
                          ? (pnlVal.abs() / maxInstAbs).clamp(0.04, 1.0)
                          : 0.0;
                      final rowColor = pnlVal < 0 ? p.negative : p.accent;
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: ValueKey(
                            'realized-inst-${text(item['ticker'])}',
                          ),
                          borderRadius: BorderRadius.circular(9),
                          onTap: underlying == null
                              ? null
                              : () {
                                  Navigator.of(sheetCtx).pop();
                                  if (widget.mobileSection != null) {
                                    _showMobileStockSnapshotSheet(
                                      g: g,
                                      row: item,
                                      ticker: underlying,
                                    );
                                  } else {
                                    widget.onCompany(underlying, 'evidence');
                                  }
                                },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(color: p.border),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    if (isEquity)
                                      StockLogo(
                                        ticker: text(item['ticker']),
                                        palette: p,
                                        size: 28,
                                      )
                                    else
                                      Icon(
                                        Icons.layers_outlined,
                                        size: 24,
                                        color: p.secondary,
                                      ),
                                    const SizedBox(width: 9),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  text(item['ticker']),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: heading(13.5),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 5,
                                                      vertical: 1.5,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: p.card,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  isEquity
                                                      ? w('STK', '股票')
                                                      : w('OPT', '期权'),
                                                  style: TextStyle(
                                                    color: p.muted,
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          if (text(item['name'], '').isNotEmpty)
                                            Text(
                                              text(item['name']),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: p.muted,
                                                fontSize: 11,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      hideAmounts
                                          ? portfolioRateLabel(
                                              portfolioRatio(
                                                pnlVal,
                                                realizedBasis,
                                              ),
                                            )
                                          : '${pnlVal > 0 ? '+' : ''}${amount(pnlVal)}',
                                      style: TextStyle(
                                        color: rowColor,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                    if (underlying != null) ...[
                                      const SizedBox(width: 3),
                                      Icon(
                                        Icons.chevron_right_rounded,
                                        size: 15,
                                        color: p.muted,
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: Container(
                                    height: 4,
                                    color: const Color(0xFF18212E),
                                    alignment: Alignment.centerLeft,
                                    child: FractionallySizedBox(
                                      widthFactor: barRatio,
                                      child: Container(color: rowColor),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
            ] else if (activeTab == 'daily') ...[
              for (final row in dailyList.take(60))
                Builder(
                  builder: (_) {
                    final dPnl = number(row['pnl']);
                    final cumPnl = number(row['cumulativePnl']);
                    final dColor = dPnl < 0
                        ? p.negative
                        : dPnl > 0
                        ? p.accent
                        : p.muted;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 9,
                      ),
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
                                  text(row['date']),
                                  style: TextStyle(
                                    color: p.text,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                Text(
                                  hideAmounts
                                      ? w(
                                          'Cumulative tracked',
                                          '已计入累计平仓曲线',
                                        )
                                      : '${w('Cumulative', '累计')} ${cumPnl > 0 ? '+' : ''}${amount(cumPnl)}',
                                  style: TextStyle(
                                    color: p.muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            hideAmounts
                                ? portfolioRateLabel(
                                    portfolioRatio(dPnl, realizedBasis),
                                  )
                                : '${dPnl > 0 ? '+' : ''}${amount(dPnl)}',
                            style: TextStyle(
                              color: dColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF131A24),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: const Color(0xFF222E3F)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _mobileSheetMetricRow(
                      'Confirmed Passive Cash Income',
                      '已确认现金收入合计',
                      hideAmounts
                          ? '••••'
                          : amount(passive['totalConfirmed'] ?? 0),
                      valueColor: p.accent,
                    ),
                    Divider(height: 1, color: p.border),
                    _mobileSheetMetricRow(
                      'Net Cash Dividends (${number(dividends['eventCount']).round()})',
                      '税后现金股息 (${number(dividends['eventCount']).round()} 笔)',
                      hideAmounts ? '••••' : amount(dividends['netAmount'] ?? 0),
                    ),
                    Divider(height: 1, color: p.border),
                    _mobileSheetMetricRow(
                      'Realized Options Call/Put (${number(realizedOptions['contractCount']).round()})',
                      '期权已实现盈亏 Call/Put (${number(realizedOptions['contractCount']).round()} 张)',
                      hideAmounts
                          ? '••••'
                          : amount(realizedOptions['amount'] ?? 0),
                      valueColor: number(realizedOptions['amount']) < 0
                          ? p.negative
                          : null,
                    ),
                    if (trailing['status'] == 'ready') ...[
                      Divider(height: 1, color: p.border),
                      _mobileSheetMetricRow(
                        'Trailing 12M Est. Dividends',
                        '持仓近12月预计年化股息',
                        hideAmounts
                            ? portfolioRateLabel(
                                nullableNumber(trailing['estimatedYield']),
                              )
                            : amount(trailing['annualAmount']),
                      ),
                    ],
                  ],
                ),
              ),
              if (passiveByTicker.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  w('Confirmed Income by Ticker', '按标的已实现股息与权利金'),
                  style: heading(13.5),
                ),
                const SizedBox(height: 6),
                for (final row in passiveByTicker.take(25))
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        final sym = _extractUnderlyingTicker(row);
                        if (sym != null) {
                          Navigator.of(sheetCtx).pop();
                          if (widget.mobileSection != null) {
                            _showMobileStockSnapshotSheet(
                              g: g,
                              row: row,
                              ticker: sym,
                            );
                          } else {
                            widget.onCompany(sym, 'evidence');
                          }
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                text(row['ticker']),
                                style: heading(13),
                              ),
                            ),
                            Text(
                              hideAmounts
                                  ? '••••'
                                  : '+${amount(row['total'] ?? row['amount'] ?? 0)}',
                              style: TextStyle(
                                color: p.accent,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 15,
                              color: p.muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
              if (pendingShortCalls.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  w('Open Short Calls Pending Expiry', '待到期卖出看涨期权'),
                  style: heading(13.5),
                ),
                const SizedBox(height: 6),
                for (final sc in pendingShortCalls.take(15))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            text(sc['ticker'] ?? sc['symbol']),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: p.text, fontSize: 12.5),
                          ),
                        ),
                        Text(
                          hideAmounts
                              ? '••••'
                              : amount(sc['premiumBasis'] ?? sc['costBasis'] ?? 0),
                          style: TextStyle(color: p.muted, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
              ],
              if (passiveByTicker.isEmpty && pendingShortCalls.isEmpty) ...[
                const SizedBox(height: 10),
                copy(
                  'Include Cash Transactions / Dividends in your IBKR Activity Flex Query to track settled dividend & option premium cash flows.',
                  '在 IBKR Activity Flex Query 中勾选现金交易与股息明细后，将在此自动汇总每笔税后股息与期权权利金落袋流水。',
                  size: 12,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  void _showMobileDailyAndEstimatePnlSheet({
    required Map<String, dynamic> g,
    required Map<String, dynamic> h,
    required Map<String, dynamic> daily,
    required Map<String, dynamic> history,
    required Map<String, dynamic>? latestEstimate,
    required double? sessionBasis,
  }) {
    final dailyReady = daily['status'] == 'ready';
    final sessionRaw = dailyReady ? daily['pnl'] : latestEstimate?['pnl'];
    final sessionNum = nullableNumber(sessionRaw);
    final sessionColor = sessionNum == null
        ? p.muted
        : sessionNum < 0
        ? p.negative
        : p.accent;
    final sessionDisplay = hideAmounts
        ? portfolioRateLabel(portfolioRatio(sessionRaw, sessionBasis))
        : sessionNum == null
        ? '—'
        : '${sessionNum > 0 ? '+' : ''}${amount(sessionRaw)}';
    final cashAdj = asMap(history['cashAdjusted']);
    final cashAdjRows = asList(cashAdj['rows']);
    final attributionRows = dailyReady
        ? asList(daily['rows'])
        : asList(asMap(h['unrealized'])['rows']);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E131B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _mobileSheetFrame(
        sheetContext: sheetCtx,
        sheetKey: const ValueKey('mobile-daily-pnl-sheet'),
        titleEn: dailyReady
            ? 'Session Mark-to-Market P&L'
            : 'Latest P&L Estimate & Attribution',
        titleZh: dailyReady ? '当日持仓盯市盈亏归因' : '最近盈亏估算与持仓归因',
        subtitleEn: dailyReady
            ? 'Report date ${text(daily['date'], '—')}'
            : latestEstimate != null
            ? '${text(latestEstimate['previousDate'])} → ${text(latestEstimate['date'])} · Cash-adjusted NAV bridge'
            : 'Broker report snapshot',
        subtitleZh: dailyReady
            ? '报告日期 ${text(daily['date'], '—')}'
            : latestEstimate != null
            ? '${text(latestEstimate['previousDate'])} → ${text(latestEstimate['date'])} · 扣除出入金净值桥'
            : '券商报告快照',
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF131A24),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF222E3F)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  dailyReady
                      ? w('SESSION P&L', '当日盯市盈亏')
                      : w('LATEST PERIOD P&L ESTIMATE', '最近报告期盈亏估算'),
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  sessionDisplay,
                  style: TextStyle(
                    color: sessionColor,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (latestEstimate != null && !hideAmounts) ...[
                  const SizedBox(height: 8),
                  Divider(height: 1, color: p.border),
                  _mobileSheetMetricRow(
                    'Reported NAV Delta',
                    '区间账面净值变动',
                    '${number(latestEstimate['navChange']) > 0 ? '+' : ''}${amount(latestEstimate['navChange'])}',
                  ),
                  _mobileSheetMetricRow(
                    'Cash Deposits / Withdrawals',
                    '扣除现金转入转出',
                    amount(latestEstimate['netFlow'] ?? 0),
                  ),
                ],
                if (cashAdj['status'] == 'ready' && !hideAmounts) ...[
                  _mobileSheetMetricRow(
                    'Cumulative Cash-Adjusted P&L',
                    '历史累计估算总盈亏',
                    '${number(cashAdj['total']) > 0 ? '+' : ''}${amount(cashAdj['total'])}',
                    valueColor: number(cashAdj['total']) < 0
                        ? p.negative
                        : p.accent,
                  ),
                ],
                if (cashAdjRows.length >= 2) ...[
                  const SizedBox(height: 10),
                  Material(
                    color: p.accent.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(9),
                    child: InkWell(
                      key: const ValueKey('sheet-switch-chart-estimate'),
                      borderRadius: BorderRadius.circular(9),
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        _requestMobileMainChartMetric('cashAdjusted');
                      },
                      child: Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: p.accent.withValues(alpha: .35),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.insights_rounded,
                              size: 16,
                              color: p.accent,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                w(
                                  'Show Estimated P&L Curve on Main Chart',
                                  '在主图查看估算盈亏曲线',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.accent,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            dailyReady
                ? w('Top Session Contributors', '当日持仓盈亏贡献榜')
                : w('Open Position Unrealized P&L', '当前持仓累计浮盈亏归因'),
            style: heading(14),
          ),
          const SizedBox(height: 6),
          if (attributionRows.isEmpty)
            copy(
              'No position-level P&L rows available in this snapshot.',
              '当前快照暂无逐笔持仓盈亏明细。',
            )
          else
            for (final r in attributionRows.take(16))
              Builder(
                builder: (_) {
                  final rowPnl = number(r['pnl']);
                  final isEq = [
                    'STK',
                    'STOCK',
                    'EQUITY',
                    'COMMON STOCK',
                  ].contains(text(r['assetCategory']).toUpperCase());
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        if (widget.mobileSection != null) {
                          _showMobileStockSnapshotSheet(
                            g: g,
                            row: r,
                            ticker: text(r['ticker']),
                          );
                        } else if (isEq) {
                          widget.onCompany(text(r['ticker']), 'evidence');
                        } else {
                          _showMobilePositionDetailSheet(r);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: p.border)),
                        ),
                        child: Row(
                          children: [
                            if (isEq)
                              StockLogo(
                                ticker: text(r['ticker']),
                                palette: p,
                                size: 28,
                              )
                            else
                              Icon(
                                Icons.layers_outlined,
                                size: 24,
                                color: p.secondary,
                              ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    text(r['ticker']),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: heading(13.5),
                                  ),
                                  Text(
                                    text(r['name']),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: p.muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              hideAmounts
                                  ? portfolioRateLabel(
                                      portfolioRatio(rowPnl, sessionBasis),
                                    )
                                  : '${rowPnl > 0 ? '+' : ''}${amount(rowPnl)}',
                              style: TextStyle(
                                color: rowPnl < 0 ? p.negative : p.accent,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            const SizedBox(width: 3),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 15,
                              color: p.muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
        ],
      ),
    );
  }

  void _showMobileCashAndAccountsSheet(
    Map<String, dynamic> g,
    Map<String, dynamic> h,
  ) {
    final accounts = asList(g['accountMeta']);
    final navVal = number(h['accountValue'] ?? g['reportedNav'] ?? g['netValue']);
    final cashVal = number(g['cash']);
    final grossVal = number(g['grossExposure']);
    final leverage = navVal.abs() > 0 ? grossVal / navVal.abs() : 0.0;
    final isSnapshotOnly =
        data?['status'] == 'preview_account' ||
        data?['source'] == 'local_owner_broker_snapshot';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E131B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _mobileSheetFrame(
        sheetContext: sheetCtx,
        sheetKey: const ValueKey('mobile-cash-accounts-sheet'),
        titleEn: 'Cash, Margin & Connected Accounts',
        titleZh: '现金、融资负债与合并账户明细',
        subtitleEn:
            '${g['accountCount']} connected IBKR account(s) · ${selectedCurrency.isEmpty ? text(g['currency']) : selectedCurrency}',
        subtitleZh:
            '已合并 ${g['accountCount']} 个 IBKR 账户 · 结算币种 ${selectedCurrency.isEmpty ? text(g['currency']) : selectedCurrency}',
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF131A24),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF222E3F)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _mobileSheetMetricRow(
                  'Combined Net Asset Value',
                  '合并总资产净值 (NAV)',
                  hideAmounts ? '••••' : amount(navVal),
                  valueColor: p.accent,
                ),
                Divider(height: 1, color: p.border),
                _mobileSheetMetricRow(
                  'Long Equities & ETFs',
                  '股票与 ETF 多头市值',
                  hideAmounts ? '••••' : amount(g['equityValue'] ?? 0),
                ),
                Divider(height: 1, color: p.border),
                _mobileSheetMetricRow(
                  'Options & Other Derivatives',
                  '期权与衍生品净市值',
                  hideAmounts ? '••••' : amount(g['otherValue'] ?? 0),
                ),
                if (number(g['shortValue']).abs() > 0.01) ...[
                  Divider(height: 1, color: p.border),
                  _mobileSheetMetricRow(
                    'Short Positions Exposure',
                    '空头持仓市值',
                    hideAmounts ? '••••' : amount(g['shortValue']),
                    valueColor: p.negative,
                  ),
                ],
                Divider(height: 1, color: p.border),
                _mobileSheetMetricRow(
                  cashVal < 0
                      ? 'Margin Loan / Cash Debit'
                      : 'Settled Cash Balance',
                  cashVal < 0 ? '证券融资负债余额' : '可用清算正现金',
                  hideAmounts ? '••••' : amount(cashVal),
                  valueColor: cashVal < 0 ? p.negative : p.accent,
                ),
                Divider(height: 1, color: p.border),
                _mobileSheetMetricRow(
                  'Gross Exposure & Leverage',
                  '总敞口与总杠杆倍数',
                  hideAmounts
                      ? '${leverage.toStringAsFixed(2)}x'
                      : '${amount(grossVal)} (${leverage.toStringAsFixed(2)}x)',
                ),
              ],
            ),
          ),
          if (accounts.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              w('Sub-Account Breakdown', '各子账户净值占比'),
              style: heading(14),
            ),
            const SizedBox(height: 8),
            for (final acc in accounts)
              Builder(
                builder: (_) {
                  final accNav = nullableNumber(acc['reportedNav']);
                  final share = (accNav != null && navVal > 0)
                      ? (accNav / navVal)
                      : null;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF111720),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: p.border),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 18,
                          color: p.accent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                text(
                                  acc['label'],
                                  text(acc['accountNumber'], 'IBKR'),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: heading(13),
                              ),
                              Text(
                                '${text(acc['accountNumber'], '—')} · ${text(acc['reportDate'], '—')}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: p.muted, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              hideAmounts || accNav == null
                                  ? '••••'
                                  : amount(accNav),
                              style: TextStyle(
                                color: p.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            if (share != null)
                              Text(
                                percent(share),
                                style: TextStyle(color: p.muted, fontSize: 11),
                              ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(sheetCtx).pop();
                    if (isSnapshotOnly) {
                      _notifyMobileActionStatus(
                        'Sign in to manage live IBKR Flex credentials.',
                        '请先登录账户以管理或修改实时 IBKR Flex 连接凭证。',
                      );
                    } else {
                      managePortfolioConnection();
                    }
                  },
                  icon: const Icon(Icons.link_rounded, size: 16),
                  label: Text(w('Manage IBKR', '管理连接')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: p.accent,
                    foregroundColor: const Color(0xFF06110D),
                  ),
                  onPressed: () {
                    Navigator.of(sheetCtx).pop();
                    if (isSnapshotOnly) {
                      _notifyMobileActionStatus(
                        'Viewing verified broker snapshot. Sign in to trigger live sync.',
                        '当前为已核验券商快照视图；登录后可触发实时云端同步。',
                      );
                    } else if (!portfolioSyncing) {
                      syncConnectedPortfolio();
                    }
                  },
                  icon: const Icon(Icons.cloud_sync_outlined, size: 16),
                  label: Text(w('Sync Now', '立即同步')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showMobileAllPositionsSheet(
    Map<String, dynamic> g, {
    String initialFilter = 'all',
  }) {
    final allNonCash =
        asList(
          g['positions'],
        ).where((r) => !['cash', 'accrual'].contains(r['kind'])).toList()..sort(
          (a, b) =>
              number(b['value']).abs().compareTo(number(a['value']).abs()),
        );
    final equities = allNonCash.where((r) => r['kind'] == 'equity').toList();
    final others = allNonCash.where((r) => r['kind'] != 'equity').toList();
    var activeFilter = initialFilter;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E131B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final visible = activeFilter == 'equity'
              ? equities
              : activeFilter == 'other'
              ? others
              : allNonCash;
          return _mobileSheetFrame(
            sheetContext: sheetCtx,
            sheetKey: const ValueKey('mobile-positions-sheet'),
            titleEn: 'Active Portfolio Positions',
            titleZh: '全部持仓标的明细',
            subtitleEn:
                '${equities.length} equities · ${others.length} options / derivatives',
            subtitleZh:
                '${equities.length} 只股票/ETF · ${others.length} 项期权与衍生品',
            children: [
              Material(
                color: const Color(0xFF0A0D12),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: p.border),
                  ),
                  child: Row(
                    children: [
                      for (final tab in [
                        ('all', 'All (${allNonCash.length})', '全部 (${allNonCash.length})'),
                        ('equity', 'Equities (${equities.length})', '股票 (${equities.length})'),
                        ('other', 'Options (${others.length})', '期权 (${others.length})'),
                      ])
                        Expanded(
                          child: InkWell(
                            key: ValueKey('positions-sheet-tab-${tab.$1}'),
                            borderRadius: BorderRadius.circular(7),
                            onTap: () =>
                                setSheetState(() => activeFilter = tab.$1),
                            child: Container(
                              height: 36,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: activeFilter == tab.$1
                                    ? const Color(0xFF17202D)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Text(
                                w(tab.$2, tab.$3),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: activeFilter == tab.$1
                                      ? p.text
                                      : p.muted,
                                  fontSize: 11.5,
                                  fontWeight: activeFilter == tab.$1
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: copy(
                    'No positions in this category.',
                    '该分类下暂无持仓标的。',
                  ),
                )
              else
                for (final r in visible)
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: ValueKey(
                        'sheet-position-${r['id'] ?? r['ticker']}',
                      ),
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        if (widget.mobileSection != null) {
                          _showMobileStockSnapshotSheet(
                            g: g,
                            row: r,
                            ticker: text(r['ticker']),
                          );
                        } else if (r['kind'] == 'equity') {
                          widget.onCompany(text(r['ticker']), 'evidence');
                        } else {
                          _showMobilePositionDetailSheet(r);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: p.border)),
                        ),
                        child: Row(
                          children: [
                            if (r['kind'] == 'equity')
                              StockLogo(
                                ticker: text(r['ticker']),
                                palette: p,
                                size: 28,
                              )
                            else
                              Icon(
                                Icons.layers_outlined,
                                size: 24,
                                color: p.secondary,
                              ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    text(r['ticker']),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: heading(13.5),
                                  ),
                                  Text(
                                    text(r['name']),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: p.muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  hideAmounts ? '••••' : amount(r['value']),
                                  style: TextStyle(
                                    color: p.text,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                                Text(
                                  percent(r['netWeight']),
                                  style: TextStyle(
                                    color: p.muted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 3),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 15,
                              color: p.muted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              if (widget.onDetails != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(sheetCtx).pop();
                    widget.onDetails?.call();
                  },
                  icon: const Icon(Icons.analytics_outlined, size: 16),
                  label: Text(
                    w('Open Full Portfolio Analysis', '进入完整组合深度分析'),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  void _showMobilePositionDetailSheet(Map<String, dynamic> r) {
    final underlying = _extractUnderlyingTicker(r);
    final openPnl = nullableNumber(r['unrealizedPnl'] ?? r['pnl']);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E131B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _mobileSheetFrame(
        sheetContext: sheetCtx,
        sheetKey: const ValueKey('mobile-position-detail-sheet'),
        titleEn: text(r['ticker']),
        titleZh: text(r['ticker']),
        subtitleEn: text(r['name'], 'Derivative / Non-equity contract'),
        subtitleZh: text(r['name'], '期权与衍生品合约明细'),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF131A24),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF222E3F)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _mobileSheetMetricRow(
                  'Asset Category',
                  '资产类别',
                  text(r['assetCategory'], 'OPT'),
                ),
                Divider(height: 1, color: p.border),
                _mobileSheetMetricRow(
                  'Position Quantity',
                  '持仓数量',
                  hideAmounts ? '••••' : formatNumber(number(r['quantity'])),
                ),
                Divider(height: 1, color: p.border),
                _mobileSheetMetricRow(
                  'Market Value',
                  '当前市值',
                  hideAmounts ? '••••' : amount(r['value']),
                ),
                if (nullableNumber(r['costBasis']) != null) ...[
                  Divider(height: 1, color: p.border),
                  _mobileSheetMetricRow(
                    'Cost Basis',
                    '持仓成本基准',
                    hideAmounts ? '••••' : amount(r['costBasis']),
                  ),
                ],
                if (openPnl != null) ...[
                  Divider(height: 1, color: p.border),
                  _mobileSheetMetricRow(
                    'Unrealized P&L',
                    '浮动盈亏',
                    hideAmounts
                        ? '••••'
                        : '${openPnl > 0 ? '+' : ''}${amount(openPnl)}',
                    valueColor: openPnl < 0 ? p.negative : p.accent,
                  ),
                ],
                if (nullableNumber(r['netWeight']) != null) ...[
                  Divider(height: 1, color: p.border),
                  _mobileSheetMetricRow(
                    'Portfolio NAV Weight',
                    '占组合净值比例',
                    percent(r['netWeight']),
                  ),
                ],
              ],
            ),
          ),
          if (underlying != null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('position-sheet-open-underlying'),
              style: FilledButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: const Color(0xFF06110D),
                minimumSize: const Size.fromHeight(42),
              ),
              onPressed: () {
                Navigator.of(sheetCtx).pop();
                if (widget.mobileSection != null) {
                  _showMobileStockSnapshotSheet(
                    g: asList(data?['groups']).firstWhere(
                      (grp) => text(grp['currency']) == selectedCurrency,
                      orElse: () =>
                          asList(data?['groups']).firstOrNull ??
                          <String, dynamic>{},
                    ),
                    row: r,
                    ticker: underlying,
                  );
                } else {
                  widget.onCompany(underlying, 'evidence');
                }
              },
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: Text(
                w(
                  'Open $underlying Underlying Research',
                  '查看标的 $underlying 正股深度研究',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _snowballMoneyCompact(Map<String, dynamic> g, dynamic rawVal, {bool signed = false}) {
    final v = nullableNumber(rawVal);
    if (v == null || !v.isFinite) return '—';
    final cur = selectedCurrency.isEmpty ? text(g['currency'], 'USD') : selectedCurrency;
    final sym = cur == 'USD'
        ? r'$'
        : cur == 'EUR'
        ? '€'
        : cur == 'GBP'
        ? '£'
        : '$cur ';
    final sign = v < 0 ? '-' : (signed && v > 0 ? '+' : '');
    return '$sign$sym${formatNumber(v.abs())}';
  }

  Widget _buildSnowballHeroValue(
    Map<String, dynamic> g,
    Map<String, dynamic> h,
    double? navRatio,
  ) {
    if (hideAmounts) {
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          portfolioRateLabel(navRatio == null ? null : navRatio - 1),
          style: const TextStyle(
            color: Color(0xFFF8FAFC),
            fontSize: 34,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.9,
            height: 1.12,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      );
    }
    final val = nullableNumber(h['accountValue']);
    if (val == null || !val.isFinite) {
      return Text('—', style: heading(32));
    }
    final cur = selectedCurrency.isEmpty ? text(g['currency'], 'USD') : selectedCurrency;
    final sym = cur == 'USD'
        ? r'$'
        : cur == 'EUR'
        ? '€'
        : cur == 'GBP'
        ? '£'
        : '$cur ';
    final neg = val < 0 ? '-' : '';
    final fixed = val.abs().toStringAsFixed(2);
    final dotIdx = fixed.indexOf('.');
    final wholeRaw = fixed.substring(0, dotIdx);
    final fracPart = fixed.substring(dotIdx);
    final wholeWithCommas = wholeRaw.replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$neg$sym$wholeWithCommas',
              style: const TextStyle(
                color: Color(0xFFF8FAFC),
                fontSize: 34,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.0,
                height: 1.12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            TextSpan(
              text: fracPart,
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 20,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.4,
                height: 1.12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileBentoTile({
    Key? tileKey,
    required IconData icon,
    required Color iconColor,
    required String labelText,
    required String valueText,
    required String subText,
    Color? valueColor,
    VoidCallback? onTap,
  }) => Material(
    color: const Color(0xFF161B24),
    borderRadius: BorderRadius.circular(20),
    child: InkWell(
      key: tileKey,
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: .05),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: .14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 14, color: iconColor),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    labelText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (onTap != null)
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 15,
                    color: p.muted.withValues(alpha: .72),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              valueText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: valueColor ?? const Color(0xFFF8FAFC),
                fontSize: 17,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.35,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _mobilePersonalHome({
    required List<Map<String, dynamic>> groups,
    required Map<String, dynamic> g,
    required Map<String, dynamic> h,
    required Map<String, dynamic> daily,
    required Map<String, dynamic> history,
    required Map<String, dynamic> realized,
    required Map<String, dynamic>? latestEstimate,
    required List<Map<String, dynamic>> navRows,
    required double? navRatio,
    required double? sessionBasis,
    required double? realizedBasis,
    required List<Map<String, dynamic>> stocks,
  }) {
    final sessionRaw = daily['status'] == 'ready'
        ? daily['pnl']
        : latestEstimate?['pnl'];
    final sessionNum = nullableNumber(sessionRaw);
    final sessionRate = portfolioRatio(sessionRaw, sessionBasis);
    final sessionColor = sessionNum == null
        ? p.muted
        : sessionNum < 0
        ? const Color(0xFFFB7185)
        : const Color(0xFF34D399);
    final sessionDisplay = hideAmounts
        ? portfolioRateLabel(sessionRate)
        : sessionNum == null
        ? '—'
        : _snowballMoneyCompact(g, sessionRaw, signed: true);
    final sessionPillText = hideAmounts
        ? '${daily['status'] == 'ready' ? w('Day', '日变动') : w('Latest', '最近')} ${portfolioRateLabel(sessionRate)}'
        : sessionNum == null
        ? '${daily['status'] == 'ready' ? w('Day', '日变动') : w('Latest', '最近')} —'
        : '${daily['status'] == 'ready' ? w('Day', '日变动') : w('Latest', '最近')} ${_snowballMoneyCompact(g, sessionRaw, signed: true)}${sessionRate != null ? ' (${portfolioRateLabel(sessionRate)})' : ''}';

    final realizedReady = realized['status'] == 'ready';
    final realizedNum = nullableNumber(realized['total']);
    final realizedRate = portfolioRatio(realized['total'], realizedBasis);
    final realizedColor = (realizedNum ?? 0) < 0
        ? const Color(0xFFFB7185)
        : const Color(0xFF34D399);
    final realizedDisplay = hideAmounts
        ? portfolioRateLabel(
            portfolioRatio(
              realizedReady ? realized['total'] : g['cash'],
              realizedReady ? realizedBasis : h['accountValue'],
            ),
          )
        : realizedReady && realizedNum != null
        ? _snowballMoneyCompact(g, realized['total'], signed: true)
        : _snowballMoneyCompact(g, g['cash']);
    final realizedPillText = hideAmounts
        ? '${w('Realized', '已实现')} ${portfolioRateLabel(realizedRate)}'
        : '${w('Realized', '已实现')} ${_snowballMoneyCompact(g, realized['total'], signed: true)}${realizedRate != null ? ' (${portfolioRateLabel(realizedRate)})' : ''}';

    final passive = asMap(h['passiveIncome']);
    final trailingDivs = asMap(h['trailingDividends']);
    final hasIncomeSummary =
        passive['status'] == 'ready' || trailingDivs['status'] == 'ready';

    final totalHoldingsCount = asList(
      g['positions'],
    ).where((r) => !['cash', 'accrual'].contains(r['kind'])).length;
    final otherHoldingsCount = asList(
      g['positions'],
    ).where((r) => r['kind'] == 'other').length;

    final isSnapshotOnly =
        data?['status'] == 'preview_account' ||
        data?['source'] == 'local_owner_broker_snapshot';
    final syncDisabled =
        loading ||
        portfolioSyncing ||
        (groups.isEmpty && asMap(data?['connection'])['configured'] != true) ||
        isSnapshotOnly;

    void openSessionSheet() => _showMobileDailyAndEstimatePnlSheet(
      g: g,
      h: h,
      daily: daily,
      history: history,
      latestEstimate: latestEstimate,
      sessionBasis: sessionBasis,
    );
    void openRealizedSheet([String tab = 'bySymbol']) =>
        _showMobileRealizedPnlSheet(
          g: g,
          h: h,
          realized: realized,
          realizedBasis: realizedBasis,
          initialTab: tab,
        );
    void openAccountsSheet() => _showMobileCashAndAccountsSheet(g, h);
    void openPositionsSheet() => _showMobileAllPositionsSheet(g);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (portfolioActionError != null || portfolioActionMessage != null) ...[
          portfolioSyncNotice(),
          const SizedBox(height: 10),
        ],
        if (loading)
          panel([
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 12),
            copy('Reading your connected portfolio…', '正在读取你的真实组合…'),
          ])
        else if (failed)
          panel([
            title('Could not read your portfolio', '暂时无法读取你的组合', 17),
            const SizedBox(height: 8),
            copy(
              'Your holdings are unchanged. No sample portfolio has been substituted.',
              '原始持仓没有改变，也没有使用示例数据替代。',
            ),
            TextButton(onPressed: load, child: Text(w('Try again', '重试'))),
          ])
        else if (groups.isEmpty) ...[
          if (widget.homeMode &&
              asMap(data?['connection'])['configured'] != true) ...[
            homeQuickstartLaunchpad(),
            const SizedBox(height: 14),
          ],
          emptyState(),
        ] else ...[
          // 1. Snowball Analytics Signature Portfolio Switcher Pill + Soft Action Bar
          if (groups.length > 1) ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final currency in groups)
                    Padding(
                      padding: const EdgeInsets.only(right: 6, bottom: 6),
                      child: ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(text(currency['currency'], '—')),
                        selected: identical(currency, g),
                        onSelected: (_) => homeUpdate(
                          () => selectedCurrency = text(currency['currency']),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Material(
                    color: const Color(0xFF171D28),
                    borderRadius: BorderRadius.circular(999),
                    child: InkWell(
                      key: const ValueKey('mobile-hero-accounts-pill'),
                      borderRadius: BorderRadius.circular(999),
                      onTap: openAccountsSheet,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: .07),
                          ),
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6.5,
                                height: 6.5,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF34D399),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                w(
                                  'All (${g['accountCount']})',
                                  '全部组合 · ${g['accountCount']} 账户',
                                ),
                                maxLines: 1,
                                style: const TextStyle(
                                  color: Color(0xFFE2E8F0),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 2),
                              const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 15,
                                color: Color(0xFF94A3B8),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const ValueKey('mobile-privacy-toggle'),
                tooltip: hideAmounts
                    ? w('Show amounts', '显示金额')
                    : w('Hide amounts', '隐藏金额'),
                padding: const EdgeInsets.all(4),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
                onPressed: () =>
                    portfolioPrivacyMode.value = !portfolioPrivacyMode.value,
                icon: Icon(
                  hideAmounts
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 17,
                  color: const Color(0xFF94A3B8),
                ),
              ),
              IconButton(
                key: const ValueKey('home-sync-now'),
                tooltip: w('Sync IBKR now', '立即同步 IBKR'),
                padding: const EdgeInsets.all(4),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
                onPressed: syncDisabled
                    ? () {
                        if (portfolioSyncing) {
                          _notifyMobileActionStatus(
                            'IBKR cloud sync is currently in progress…',
                            '正在同步 IBKR 最新报告数据，请稍候…',
                          );
                        } else if (isSnapshotOnly) {
                          openAccountsSheet();
                        } else {
                          managePortfolioConnection();
                        }
                      }
                    : syncConnectedPortfolio,
                icon: portfolioSyncing
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.cloud_sync_outlined, size: 18, color: p.accent),
              ),
              IconButton(
                key: const ValueKey('home-manage-ibkr'),
                tooltip: w('Manage IBKR', '管理 IBKR 连接'),
                padding: const EdgeInsets.all(4),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
                onPressed: isSnapshotOnly
                    ? openAccountsSheet
                    : managePortfolioConnection,
                icon: const Icon(
                  Icons.link_rounded,
                  size: 18,
                  color: Color(0xFF94A3B8),
                ),
              ),
              Flexible(
                flex: 0,
                child: Material(
                  color: const Color(0xFF171D28),
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    key: const ValueKey('home-full-analysis'),
                    borderRadius: BorderRadius.circular(999),
                    onTap: widget.onDetails ?? openPositionsSheet,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 6,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              w('Detail', '深度分析'),
                              style: const TextStyle(
                                color: Color(0xFF34D399),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right_rounded,
                              size: 14,
                              color: Color(0xFF34D399),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),

          // 2. Snowball Signature Split-Decimal Hero Value + Dual 999px Plush Return Pills
          _buildSnowballHeroValue(g, h, navRatio),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (realizedReady)
                Material(
                  color: (realizedNum ?? 0) < 0
                      ? const Color(0xFF2D161C)
                      : const Color(0xFF112D25),
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    key: const ValueKey('mobile-hero-realized-pill'),
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => openRealizedSheet('bySymbol'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              realizedPillText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: realizedColor,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 14,
                            color: realizedColor,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Material(
                color: (sessionNum ?? 0) < 0
                    ? const Color(0xFF2D161C)
                    : const Color(0xFF112D25),
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  key: const ValueKey('mobile-hero-session-pill'),
                  borderRadius: BorderRadius.circular(999),
                  onTap: openSessionSheet,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            sessionPillText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: sessionColor,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 14,
                          color: sessionColor,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (latestEstimate != null)
                InkWell(
                  key: const ValueKey('mobile-pnl-footnote-info'),
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => _showMobilePnlFootnoteSheet(g),
                  child: const Padding(
                    padding: EdgeInsets.all(5),
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ),
              if (navRows.length < 2 ||
                  (!realizedReady && daily['status'] != 'ready'))
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: homeHistoryHelp,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Text(
                      w('Set up account history', '设置账户历史数据'),
                      style: const TextStyle(
                        color: Color(0xFF34D399),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),

          // 3. Snowball Smooth Glowing Curve inside Plush 20px Slate Card
          Container(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            decoration: BoxDecoration(
              color: const Color(0xFF161B24),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: .05),
              ),
            ),
            child: PortfolioAccountValueChart(
              key: ValueKey('account-nav-$selectedCurrency'),
              rows: asList(asMap(h['nav'])['rows']),
              history: history,
              currency: selectedCurrency,
              palette: p,
              hideAmounts: hideAmounts,
              chartHeight: 148,
              compactMobile: true,
              requestedMetric: mobileRequestedChartMetric,
              requestedMetricNonce: mobileRequestedChartNonce,
              onInsufficientHistory: homeHistoryHelp,
            ),
          ),
          const SizedBox(height: 8),

          // 4. Snowball 2x2 Plush 20px Icon-Badged Summary Grid
          LayoutBuilder(
            key: const ValueKey('mobile-portfolio-bento-grid'),
            builder: (_, bc) {
              final tileWidth = (bc.maxWidth - 10) / 2;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  SizedBox(
                    width: tileWidth,
                    child: _mobileBentoTile(
                      tileKey: const ValueKey('mobile-bento-realized'),
                      icon: Icons.workspace_premium_rounded,
                      iconColor: realizedColor,
                      onTap: () => openRealizedSheet('bySymbol'),
                      labelText: realizedReady
                          ? w('Realized FIFO', '已实现盈亏')
                          : w('Cash Balance', '现金余额'),
                      valueText: realizedDisplay,
                      subText: realizedReady
                          ? '${w('Closed', '平仓归因')} · ${asList(realized['byInstrument']).length} ${w('tickers', '标的')}'
                          : w('Tap for breakdown', '点击查看明细'),
                      valueColor: realizedReady && realizedNum != null
                          ? realizedColor
                          : const Color(0xFFF8FAFC),
                    ),
                  ),
                  SizedBox(
                    width: tileWidth,
                    child: _mobileBentoTile(
                      tileKey: const ValueKey('mobile-bento-session'),
                      icon: Icons.insights_rounded,
                      iconColor: sessionColor,
                      onTap: openSessionSheet,
                      labelText: daily['status'] == 'ready'
                          ? w('Session P&L', '当日盈亏')
                          : w('Net P&L Est.', '净收益估算'),
                      valueText: sessionDisplay,
                      subText: daily['status'] == 'ready'
                          ? text(daily['date'], '—')
                          : latestEstimate != null
                          ? '${text(latestEstimate['previousDate']).length >= 10 ? text(latestEstimate['previousDate']).substring(5) : text(latestEstimate['previousDate'])} → ${text(latestEstimate['date']).length >= 10 ? text(latestEstimate['date']).substring(5) : text(latestEstimate['date'])}'
                          : w('Tap for attribution', '点击查看归因'),
                      valueColor: sessionColor,
                    ),
                  ),
                  SizedBox(
                    width: tileWidth,
                    child: _mobileBentoTile(
                      tileKey: const ValueKey('mobile-bento-cash'),
                      icon: Icons.account_balance_wallet_rounded,
                      iconColor: const Color(0xFF60A5FA),
                      onTap: openAccountsSheet,
                      labelText: number(g['cash']) < 0
                          ? w('Cash & Margin', '现金与净杠杆')
                          : w('Settled Cash', '可用现金'),
                      valueText: hideAmounts
                          ? '••••'
                          : _snowballMoneyCompact(g, g['cash']),
                      subText: number(g['cash']) < 0
                          ? w('Margin & sub-accts', '融资负债与子账户')
                          : w('Cash & sub-accts', '现金与子账户占比'),
                    ),
                  ),
                  SizedBox(
                    width: tileWidth,
                    child: _mobileBentoTile(
                      tileKey: const ValueKey('mobile-bento-positions'),
                      icon: Icons.pie_chart_rounded,
                      iconColor: const Color(0xFFA78BFA),
                      onTap: openPositionsSheet,
                      labelText: w('Holdings', '持仓构成'),
                      valueText: '$totalHoldingsCount',
                      subText:
                          '${stocks.length} ${w('equities', '股票')} · $otherHoldingsCount ${w('options', '期权')}',
                    ),
                  ),
                ],
              );
            },
          ),
          if (realizedReady || hasIncomeSummary) ...[
            const SizedBox(height: 10),
            Material(
              color: const Color(0xFF161B24),
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                key: const ValueKey('mobile-bento-income-banner'),
                borderRadius: BorderRadius.circular(18),
                onTap: () => openRealizedSheet('income'),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .05),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: const Color(0xFF38BDF8).withValues(alpha: .14),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.payments_rounded,
                          size: 15,
                          color: Color(0xFF38BDF8),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              w(
                                'Dividends & Option Premium Income',
                                '股息分红与期权权利金收入',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFF8FAFC),
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              passive['status'] == 'ready'
                                  ? w(
                                      'Confirmed cash dividends + expired short calls',
                                      '已确认税后股息 + 到期落袋权利金明细',
                                    )
                                  : w(
                                      'Tap to inspect dividend yield & option cash flow',
                                      '点击查看预计年化股息与权利金流水',
                                    ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        hideAmounts
                            ? (trailingDivs['status'] == 'ready'
                                  ? portfolioRateLabel(
                                      nullableNumber(
                                        trailingDivs['estimatedYield'],
                                      ),
                                    )
                                  : '••••')
                            : passive['status'] == 'ready'
                            ? _snowballMoneyCompact(
                                g,
                                passive['totalConfirmed'],
                                signed: true,
                              )
                            : trailingDivs['status'] == 'ready'
                            ? _snowballMoneyCompact(
                                g,
                                trailingDivs['annualAmount'],
                              )
                            : w('View', '查看'),
                        style: const TextStyle(
                          color: Color(0xFF38BDF8),
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: Color(0xFF64748B),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),

          // 5. Snowball Signature Donut Ring Allocation Card
          homeAllocationOverview(g),
          if (widget.mobileSection != null) ...[
            const SizedBox(height: 12),
            Material(
              color: const Color(0xFF161B24),
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                key: const ValueKey('overview-open-holdings-tab'),
                borderRadius: BorderRadius.circular(18),
                onTap: () {
                  if (widget.onSwitchMobileTab != null) {
                    widget.onSwitchMobileTab!('holdings');
                  } else {
                    openPositionsSheet();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 13,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .05),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: const Color(0xFF34D399).withValues(alpha: .14),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.account_balance_wallet_rounded,
                          size: 15,
                          color: Color(0xFF34D399),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          w(
                            'View all $totalHoldingsCount holdings & option positions',
                            '查看全部 $totalHoldingsCount 项持仓、浮盈与估值速览',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFF8FAFC),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: Color(0xFF34D399),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: 14),
            homeHoldings(g),
            if (_hasPassiveIncomeContent(h)) ...[
              const SizedBox(height: 14),
              PortfolioPassiveIncomeCard(
                passiveIncome: asMap(h['passiveIncome']),
                currency: selectedCurrency,
                palette: p,
                hideAmounts: hideAmounts,
                onCompany: widget.onCompany,
              ),
            ],
            const SizedBox(height: 14),
            homeMovers(h, asList(g['positions'])),
          ],
        ],
      ],
    );
  }

  Widget homeHeroOverview(
    Map<String, dynamic> g,
    Map<String, dynamic> h,
    Map<String, dynamic> history,
  ) {
    final navPanel = panel([
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
        chartHeight: 235,
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
    ]);
    final allocPanel = homeAllocationOverview(g);
    return LayoutBuilder(
      builder: (_, c) {
        if (c.maxWidth >= 1020 &&
            MediaQuery.textScalerOf(context).scale(1) <= 1.25) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 7, child: navPanel),
              const SizedBox(width: 18),
              Expanded(flex: 5, child: allocPanel),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [navPanel, const SizedBox(height: 18), allocPanel],
        );
      },
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
    final rows = asList(
      g['positions'],
    ).where((r) => !['cash', 'accrual'].contains(r['kind'])).toList();
    final isMobile =
        MediaQuery.sizeOf(context).width > 0 &&
        MediaQuery.sizeOf(context).width < 640;
    return panel([
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          title('Portfolio allocation', '资产分布'),
          if (isMobile)
            Material(
              color: const Color(0xFF1E2533),
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                key: const ValueKey('allocation-open-all-sheet'),
                borderRadius: BorderRadius.circular(999),
                onTap: () {
                  if (widget.mobileSection != null &&
                      widget.onSwitchMobileTab != null) {
                    widget.onSwitchMobileTab!('holdings');
                  } else {
                    _showMobileAllPositionsSheet(g);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        w('${rows.length} holdings', '${rows.length} 项分布明细'),
                        style: const TextStyle(
                          color: Color(0xFFCBD5E1),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 14,
                        color: Color(0xFF94A3B8),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            copy(
              '${rows.length} ${w('positions', '项持仓')} · ${percent(asMap(g['coverage'])['weight'])} ${w('covered', '估值覆盖')}',
              '${rows.length} 项持仓 · 覆盖 ${percent(asMap(g['coverage'])['weight'])}',
              size: 11,
            ),
        ],
      ),
      const SizedBox(height: 14),
      PortfolioAllocationChart(
        hideAmounts: hideAmounts,
        compact: true,
        group: g,
        palette: p,
        onHolding: (ticker) {
          final modelSym = portfolioValuationTicker(g, ticker);
          if (widget.mobileSection != null) {
            _showMobileStockSnapshotSheet(g: g, ticker: modelSym);
          } else {
            widget.onCompany(modelSym, 'value');
          }
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
                : () => _showMobilePositionDetailSheet(r),
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

  void _openHomeGuruDialog(Map<String, dynamic> position) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: p.panel,
        title: Text(
          '${position['ticker']} · ${w('Guru filing evidence', '投资大师持仓证据')}',
        ),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: portfolioGuruEvidence(
              position,
              beforeNavigate: () => Navigator.of(dialogContext).pop(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(w('Close', '关闭')),
          ),
        ],
      ),
    );
  }

  Widget _homeValuationPill(Map<String, dynamic> r) {
    final gap = nullableNumber(r['modelGap']);
    final key = ValueKey('home-valuation-${r['id'] ?? r['ticker']}');
    final modelTicker = text(asMap(r['model'])['modelTicker'] ?? r['ticker']);
    if (gap == null) {
      return Text('—', key: key, style: TextStyle(color: p.muted, fontSize: 13));
    }
    final positive = gap >= 0;
    final tint = positive ? p.accent : p.negative;
    return InkWell(
      key: key,
      onTap: () => widget.onCompany(modelTicker, 'value'),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: tint.withValues(alpha: .24)),
        ),
        child: Text(
          '${positive ? '+' : ''}${percent(gap)}',
          style: TextStyle(
            color: tint,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _homeGuruPill(Map<String, dynamic> r) {
    final activity = asMap(r['guruActivity']);
    final guruRows = asList(activity['rows']);
    if (guruRows.isEmpty) {
      return Text('—', style: TextStyle(color: p.muted, fontSize: 13));
    }
    final holders = number(activity['holders'] ?? guruRows.length).round();
    final adds = number(activity['adds']).round();
    final trims = number(activity['trims']).round();
    return InkWell(
      key: ValueKey('home-guru-open-${r['id'] ?? r['ticker']}'),
      onTap: () => _openHomeGuruDialog(r),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: p.card.withValues(alpha: .65),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: p.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_outlined, size: 14, color: p.accent),
            const SizedBox(width: 5),
            Text(
              '$holders',
              style: TextStyle(
                color: p.text,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (adds > 0 || trims > 0) ...[
              const SizedBox(width: 5),
              Text(
                '+$adds/-$trims',
                style: TextStyle(color: p.muted, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget homeHoldings(Map<String, dynamic> g) {
    final allNonCash =
        asList(
          g['positions'],
        ).where((r) => !['cash', 'accrual'].contains(r['kind'])).toList()..sort(
          (a, b) =>
              number(b['value']).abs().compareTo(number(a['value']).abs()),
        );
    final equities = allNonCash.where((r) => r['kind'] == 'equity').toList();
    final otherRows = allNonCash.where((r) => r['kind'] != 'equity').toList();
    final showOtherTab =
        equities.isNotEmpty &&
        otherRows.isNotEmpty &&
        mobileHoldingsKind == 'other';
    final rows = showOtherTab
        ? otherRows
        : (equities.isNotEmpty ? equities : allNonCash);

    double? openPnlRateFor(Map<String, dynamic> r) {
      final val = nullableNumber(r['value']);
      final gain = nullableNumber(r['unrealizedPnl']);
      if (val == null ||
          gain == null ||
          !val.isFinite ||
          !gain.isFinite ||
          number(r['quantity']) <= 0 ||
          val - gain <= 0) {
        return null;
      }
      return portfolioRatio(gain, val - gain);
    }

    return panel([
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 6,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              title('My holdings', '我的持仓'),
              if (equities.isNotEmpty && otherRows.isNotEmpty) ...[
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const ValueKey('home-holdings-kind-equity'),
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => homeUpdate(() => mobileHoldingsKind = 'equity'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: !showOtherTab
                            ? p.accent.withValues(alpha: .15)
                            : p.card,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: !showOtherTab
                              ? p.accent.withValues(alpha: .4)
                              : p.border,
                        ),
                      ),
                      child: Text(
                        w(
                          '${equities.length} equities',
                          '${equities.length} 只股票/ETF',
                        ),
                        style: TextStyle(
                          color: !showOtherTab ? p.accent : p.muted,
                          fontSize: 11.5,
                          fontWeight: !showOtherTab
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const ValueKey('home-holdings-kind-other'),
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => homeUpdate(() => mobileHoldingsKind = 'other'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: showOtherTab
                            ? p.accent.withValues(alpha: .15)
                            : p.card,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: showOtherTab
                              ? p.accent.withValues(alpha: .4)
                              : p.border,
                        ),
                      ),
                      child: Text(
                        w(
                          '${otherRows.length} options',
                          '${otherRows.length} 项期权',
                        ),
                        style: TextStyle(
                          color: showOtherTab ? p.accent : p.muted,
                          fontSize: 11.5,
                          fontWeight: showOtherTab
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ] else
                tag(
                  '${equities.length} ${w('equities', '只股票/ETF')}',
                  '${equities.length} 只股票/ETF',
                ),
            ],
          ),
          TextButton(
            onPressed: widget.onDetails ?? () => _showMobileAllPositionsSheet(g),
            child: Text(w('All positions & analysis →', '全部持仓与分析 →')),
          ),
        ],
      ),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (_, c) {
          final wide =
              c.maxWidth >= 760 &&
              MediaQuery.textScalerOf(context).scale(1) <= 1.25;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Expanded(flex: 4, child: copy('Holding', '持仓标的', size: 11)),
                      Expanded(
                        flex: 3,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: copy('Market value', '市值与单价', size: 11),
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 92,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: copy('Weight', '净值占比', size: 11),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        flex: 2,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: copy('Open P&L', '累计浮盈亏', size: 11),
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 96,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: copy('Valuation', '模型空间', size: 11),
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 112,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: copy('Gurus', '大师持仓', size: 11),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: p.border),
              ],
              for (final r in rows.take(holdingLimit))
                InkWell(
                  key: ValueKey('home-position-${r['id'] ?? r['ticker']}'),
                  onTap: r['kind'] == 'equity'
                      ? () => widget.onCompany(text(r['ticker']), 'evidence')
                      : () => _showMobilePositionDetailSheet(r),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: p.border)),
                    ),
                    child: wide
                        ? Row(
                            children: [
                              Expanded(
                                flex: 4,
                                child: Row(
                                  children: [
                                    if (r['kind'] == 'equity')
                                      StockLogo(
                                        ticker: text(r['ticker']),
                                        palette: p,
                                        size: 32,
                                      )
                                    else
                                      Icon(
                                        Icons.layers_outlined,
                                        color: p.secondary,
                                        size: 30,
                                      ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  text(r['ticker']),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: heading(14),
                                                ),
                                              ),
                                              if (!hideAmounts &&
                                                  number(r['accountCount']) >
                                                      1) ...[
                                                const SizedBox(width: 6),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 5,
                                                        vertical: 1.5,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: p.accent.withValues(
                                                      alpha: .10,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          4,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    '${r['accountCount']} ${w('accts', '账户')}',
                                                    style: TextStyle(
                                                      color: p.accent,
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            text(r['name']),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: p.muted,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(amount(r['value']), style: heading(13)),
                                    const SizedBox(height: 2),
                                    Text(
                                      hideAmounts
                                          ? '••••'
                                          : nullableNumber(r['quantity']) !=
                                                null
                                          ? '${formatNumber(number(r['quantity']))} · ${amount(r['price'], text(r['currency']))}'
                                          : '—',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: p.muted,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 14),
                              SizedBox(
                                width: 92,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      percent(r['netWeight']),
                                      style: heading(13),
                                    ),
                                    const SizedBox(height: 4),
                                    SizedBox(
                                      width: 68,
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(2),
                                        child: LinearProgressIndicator(
                                          value: number(
                                            r['netWeight'],
                                          ).abs().clamp(0, 1),
                                          minHeight: 3.5,
                                          backgroundColor: p.border,
                                          color: p.accent,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                flex: 2,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Builder(
                                    builder: (_) {
                                      final pnl = nullableNumber(
                                        r['unrealizedPnl'],
                                      );
                                      if (pnl == null) {
                                        return Text(
                                          '—',
                                          style: TextStyle(
                                            color: p.muted,
                                            fontSize: 13,
                                          ),
                                        );
                                      }
                                      final color = pnl < 0
                                          ? p.negative
                                          : p.accent;
                                      final rate = openPnlRateFor(r);
                                      return Text(
                                        hideAmounts
                                            ? (rate == null
                                                  ? '—'
                                                  : '${rate > 0 ? '+' : ''}${percent(rate)}')
                                            : '${pnl > 0 ? '+' : ''}${amount(pnl)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: color,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              SizedBox(
                                width: 96,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: _homeValuationPill(r),
                                ),
                              ),
                              const SizedBox(width: 14),
                              SizedBox(
                                width: 112,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: _homeGuruPill(r),
                                ),
                              ),
                            ],
                          )
                        : Builder(
                            builder: (_) {
                              final weightVal =
                                  (nullableNumber(r['netWeight']) ?? 0)
                                      .abs()
                                      .clamp(0.0, 1.0);
                              final pnl = nullableNumber(r['unrealizedPnl']);
                              final rate = openPnlRateFor(r);
                              final pnlPositive = (pnl ?? 0) >= 0;
                              final pnlColor = pnl == null
                                  ? const Color(0xFF94A3B8)
                                  : pnlPositive
                                  ? const Color(0xFF34D399)
                                  : const Color(0xFFFB7185);
                              final pnlText = pnl == null
                                  ? percent(r['netWeight'])
                                  : hideAmounts
                                  ? (rate == null
                                        ? percent(r['netWeight'])
                                        : '${rate > 0 ? '+' : ''}${percent(rate)}')
                                  : '${_snowballMoneyCompact(g, pnl, signed: true)}${rate != null ? ' · ${rate > 0 ? '+' : ''}${percent(rate)}' : ''}';
                              final barTint = r['kind'] == 'equity'
                                  ? const Color(0xFF34D399)
                                  : const Color(0xFFA78BFA);
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      if (r['kind'] == 'equity')
                                        StockLogo(
                                          ticker: text(r['ticker']),
                                          palette: p,
                                          size: 38,
                                        )
                                      else
                                        Container(
                                          width: 38,
                                          height: 38,
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF1F2737),
                                            borderRadius:
                                                BorderRadius.circular(11),
                                          ),
                                          child: const Icon(
                                            Icons.layers_rounded,
                                            color: Color(0xFFA78BFA),
                                            size: 19,
                                          ),
                                        ),
                                      const SizedBox(width: 11),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              text(r['ticker']),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Color(0xFFF8FAFC),
                                                fontSize: 15,
                                                fontWeight: FontWeight.w700,
                                                letterSpacing: -0.2,
                                              ),
                                            ),
                                            const SizedBox(height: 1),
                                            Text(
                                              text(r['name']),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Color(0xFF64748B),
                                                fontSize: 11.5,
                                              ),
                                            ),
                                            const SizedBox(height: 5),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          999,
                                                        ),
                                                    child: Container(
                                                      height: 4,
                                                      color: const Color(
                                                        0xFF222A3A,
                                                      ),
                                                      alignment:
                                                          Alignment.centerLeft,
                                                      child:
                                                          FractionallySizedBox(
                                                            widthFactor:
                                                                weightVal
                                                                    .clamp(
                                                                      0.04,
                                                                      1.0,
                                                                    ),
                                                            child: Container(
                                                              color: barTint,
                                                            ),
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 7),
                                                Text(
                                                  percent(r['netWeight']),
                                                  style: const TextStyle(
                                                    color: Color(0xFF94A3B8),
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.w600,
                                                    fontFeatures: [
                                                      FontFeature
                                                          .tabularFigures(),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            hideAmounts
                                                ? '••••'
                                                : _snowballMoneyCompact(
                                                    g,
                                                    r['value'],
                                                  ),
                                            style: const TextStyle(
                                              color: Color(0xFFF8FAFC),
                                              fontSize: 14.5,
                                              fontWeight: FontWeight.w700,
                                              fontFeatures: [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            pnlText,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: pnlColor,
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                              fontFeatures: const [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  if (r['kind'] == 'equity' &&
                                      (nullableNumber(r['modelGap']) != null ||
                                          asList(
                                            asMap(r['guruActivity'])['rows'],
                                          ).isNotEmpty)) ...[
                                    const SizedBox(height: 8),
                                    Padding(
                                      padding: const EdgeInsets.only(left: 49),
                                      child: Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          if (nullableNumber(r['modelGap']) !=
                                              null)
                                            _homeValuationPill(r),
                                          if (asList(
                                            asMap(r['guruActivity'])['rows'],
                                          ).isNotEmpty)
                                            _homeGuruPill(r),
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                  ),
                ),
            ],
          );
        },
      ),
      if (rows.length > holdingLimit)
        TextButton(
          onPressed: () => homeUpdate(() => holdingLimit += 20),
          child: Text(w('Show more holdings', '显示更多持仓')),
        ),
      if (equities.isNotEmpty && otherRows.isNotEmpty) ...[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: widget.onDetails,
            icon: Icon(Icons.layers_outlined, size: 15, color: p.muted),
            label: Text(
              hideAmounts
                  ? w(
                      'Option positions · open Full analysis →',
                      '期权持仓 · 打开完整分析查看 →',
                    )
                  : w(
                      '${otherRows.length} option / derivative positions · open Full analysis →',
                      '另有 ${otherRows.length} 项期权持仓 · 打开完整分析查看 →',
                    ),
              style: TextStyle(color: p.muted, fontSize: 11.5),
            ),
          ),
        ),
      ],
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

  Widget _snowballPocketRouter({
    required String section,
    required List<Map<String, dynamic>> groups,
    required Map<String, dynamic> g,
    required Map<String, dynamic> h,
    required Map<String, dynamic> daily,
    required Map<String, dynamic> history,
    required Map<String, dynamic> realized,
    required Map<String, dynamic>? latestEstimate,
    required List<Map<String, dynamic>> navRows,
    required double? navRatio,
    required double? sessionBasis,
    required double? realizedBasis,
    required List<Map<String, dynamic>> stocks,
  }) {
    if (section == 'accounts') {
      return _buildSnowballAccountsScreen(groups: groups, g: g, h: h);
    }
    if (section == 'holdings' || section == 'income') {
      if (loading) {
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF161B24),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: .05)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 12),
              copy('Reading your connected portfolio…', '正在读取你的真实组合…'),
            ],
          ),
        );
      }
      if (failed) {
        return panel([
          title('Could not read your portfolio', '暂时无法读取你的组合', 17),
          const SizedBox(height: 8),
          copy(
            'Your holdings are unchanged. No sample portfolio has been substituted.',
            '原始持仓没有改变，也没有使用示例数据替代。',
          ),
          TextButton(onPressed: load, child: Text(w('Try again', '重试'))),
        ]);
      }
      if (groups.isEmpty) {
        return emptyState();
      }
      if (section == 'holdings') {
        return _buildSnowballHoldingsScreen(groups: groups, g: g, h: h);
      }
      return _buildSnowballIncomeScreen(
        groups: groups,
        g: g,
        h: h,
        realized: realized,
        realizedBasis: realizedBasis,
      );
    }
    return _mobilePersonalHome(
      groups: groups,
      g: g,
      h: h,
      daily: daily,
      history: history,
      realized: realized,
      latestEstimate: latestEstimate,
      navRows: navRows,
      navRatio: navRatio,
      sessionBasis: sessionBasis,
      realizedBasis: realizedBasis,
      stocks: stocks,
    );
  }

  void _showMobileStockSnapshotSheet({
    required Map<String, dynamic> g,
    Map<String, dynamic>? row,
    String? ticker,
  }) {
    final allPos = asList(g['positions']);
    final resolvedRow =
        row ??
        allPos.firstWhere(
          (r) =>
              text(r['ticker']).toUpperCase() ==
                  (ticker ?? '').trim().toUpperCase() ||
              _extractUnderlyingTicker(r) ==
                  (ticker ?? '').trim().toUpperCase(),
          orElse: () => <String, dynamic>{},
        );
    final rawSym = text(
      resolvedRow['ticker'],
      ticker ?? '',
    ).trim().toUpperCase();
    final underlying =
        (resolvedRow.isNotEmpty
            ? _extractUnderlyingTicker(resolvedRow)
            : null) ??
        stockLogoTicker(rawSym);
    final modelTicker = underlying.isNotEmpty
        ? portfolioValuationTicker(g, underlying)
        : '';
    final isEquity =
        resolvedRow['kind'] == 'equity' ||
        (resolvedRow.isEmpty && modelTicker.isNotEmpty);
    final posVal = nullableNumber(resolvedRow['value']);
    final posCost = nullableNumber(resolvedRow['costBasis']);
    final posPnl = nullableNumber(
      resolvedRow['unrealizedPnl'] ?? resolvedRow['pnl'],
    );
    final posWeight = nullableNumber(resolvedRow['netWeight']);
    final posQty = nullableNumber(resolvedRow['quantity']);
    final inlineGap = nullableNumber(resolvedRow['modelGap']);
    final posPnlRate =
        (posVal != null &&
            posPnl != null &&
            posQty != null &&
            posQty > 0 &&
            (posVal - posPnl) > 0)
        ? portfolioRatio(posPnl, posVal - posPnl)
        : null;

    Map<String, dynamic>? valPayload;
    var valLoading = modelTicker.isNotEmpty;
    var valNotCovered = false;
    var startedFetch = false;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF131720),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          if (!startedFetch && modelTicker.isNotEmpty) {
            startedFetch = true;
            Future<void>.microtask(() async {
              try {
                final res = await StockResearchCache.of(
                  widget.api,
                ).load(modelTicker, full: false);
                if (sheetCtx.mounted) {
                  setSheetState(() {
                    valPayload = res;
                    valLoading = false;
                  });
                }
              } catch (_) {
                if (sheetCtx.mounted) {
                  setSheetState(() {
                    valLoading = false;
                    valNotCovered = true;
                  });
                }
              }
            });
          }

          final detail = asMap(valPayload?['ticker']);
          final latest = asMap(detail['latest']);
          final valCurrency = text(detail['currency'], 'USD');
          final latestPrice =
              nullableNumber(latest['latestPrice']) ??
              nullableNumber(resolvedRow['price']);
          final fairVal = nullableNumber(latest['baseFairValue']);
          final upside = nullableNumber(latest['upsideToBase']) ?? inlineGap;
          final valHist = asList(detail['history']).toList()
            ..sort((a, b) => text(a['asOfDate']).compareTo(text(b['asOfDate'])));
          final lastQuarter = valHist.isNotEmpty
              ? valHist.last
              : <String, dynamic>{};
          final scoreInputs = asMap(
            asMap(
              asMap(lastQuarter['dataSnapshot'])['valuationSemantics'],
            )['scoreInputs'],
          );
          final revGrowth = nullableNumber(
            scoreInputs['revenueGrowth'] ?? scoreInputs['revenueYoY'],
          );
          final opMargin = nullableNumber(scoreInputs['operatingMargin']);
          final fcfMargin = nullableNumber(
            scoreInputs['fcfMargin'] ?? scoreInputs['freeCashFlowMargin'],
          );

          String fmtValMoney(double? v) {
            if (v == null || !v.isFinite) return '—';
            final sym = valCurrency == 'USD'
                ? r'$'
                : valCurrency == 'EUR'
                ? '€'
                : '$valCurrency ';
            return '$sym${formatNumber(v)}';
          }

          return ConstrainedBox(
            key: const ValueKey('mobile-stock-snapshot-sheet'),
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.84,
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 38,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E3A4B),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        if (modelTicker.isNotEmpty)
                          StockLogo(
                            ticker: modelTicker,
                            palette: p,
                            size: 38,
                          )
                        else
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: const Color(0xFFA78BFA).withValues(
                                alpha: .16,
                              ),
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: const Icon(
                              Icons.layers_rounded,
                              color: Color(0xFFA78BFA),
                              size: 20,
                            ),
                          ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      rawSym.isNotEmpty ? rawSym : modelTicker,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFFF8FAFC),
                                        fontSize: 17,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: -0.3,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E2634),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      isEquity
                                          ? w('EQUITY', '正股')
                                          : w('OPTION', '期权合约'),
                                      style: const TextStyle(
                                        color: Color(0xFF94A3B8),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                text(
                                  resolvedRow['name'],
                                  text(
                                    detail['name'],
                                    w('Position & Valuation Snapshot', '持仓与估值速览'),
                                  ),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF94A3B8),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: w('Close', '关闭'),
                          onPressed: () => Navigator.of(sheetCtx).pop(),
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Color(0xFF94A3B8),
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (resolvedRow.isNotEmpty) ...[
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF181E29),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: .06),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      w('MY POSITION', '我的持仓明细'),
                                      style: const TextStyle(
                                        color: Color(0xFF64748B),
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    if (posVal != null)
                                      _mobileSheetMetricRow(
                                        'Market Value',
                                        '当前持仓市值',
                                        hideAmounts
                                            ? '••••'
                                            : _snowballMoneyCompact(g, posVal),
                                      ),
                                    if (posWeight != null) ...[
                                      Divider(
                                        height: 1,
                                        color: Colors.white.withValues(
                                          alpha: .06,
                                        ),
                                      ),
                                      _mobileSheetMetricRow(
                                        'Portfolio Weight',
                                        '占总净值权重',
                                        percent(posWeight),
                                      ),
                                    ],
                                    if (posQty != null) ...[
                                      Divider(
                                        height: 1,
                                        color: Colors.white.withValues(
                                          alpha: .06,
                                        ),
                                      ),
                                      _mobileSheetMetricRow(
                                        isEquity ? 'Shares Held' : 'Contracts',
                                        isEquity ? '持仓股数' : '合约张数',
                                        hideAmounts
                                            ? '••••'
                                            : formatNumber(posQty),
                                      ),
                                    ],
                                    if (posCost != null) ...[
                                      Divider(
                                        height: 1,
                                        color: Colors.white.withValues(
                                          alpha: .06,
                                        ),
                                      ),
                                      _mobileSheetMetricRow(
                                        'Cost Basis',
                                        '持仓总成本',
                                        hideAmounts
                                            ? '••••'
                                            : _snowballMoneyCompact(g, posCost),
                                      ),
                                    ],
                                    if (posPnl != null) ...[
                                      Divider(
                                        height: 1,
                                        color: Colors.white.withValues(
                                          alpha: .06,
                                        ),
                                      ),
                                      _mobileSheetMetricRow(
                                        'Unrealized P&L',
                                        '累计浮动盈亏',
                                        hideAmounts
                                            ? (posPnlRate != null
                                                  ? portfolioRateLabel(
                                                      posPnlRate,
                                                    )
                                                  : '••••')
                                            : '${_snowballMoneyCompact(g, posPnl, signed: true)}${posPnlRate != null ? ' (${portfolioRateLabel(posPnlRate)})' : ''}',
                                        valueColor: posPnl < 0
                                            ? const Color(0xFFFB7185)
                                            : const Color(0xFF34D399),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                            ],
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: const Color(0xFF181E29),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: .06),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          w(
                                            'VALUATION & FUNDAMENTALS',
                                            '估值与核心基本面速览',
                                          ),
                                          style: const TextStyle(
                                            color: Color(0xFF64748B),
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.4,
                                          ),
                                        ),
                                      ),
                                      if (valLoading)
                                        const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.8,
                                          ),
                                        )
                                      else if (upside != null)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: upside >= 0
                                                ? const Color(0xFF112D25)
                                                : const Color(0xFF2D161C),
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            '${upside >= 0 ? w('Upside ', '安全边际 ') : w('Gap ', '估值偏离 ')}${portfolioRateLabel(upside)}',
                                            style: TextStyle(
                                              color: upside >= 0
                                                  ? const Color(0xFF34D399)
                                                  : const Color(0xFFFB7185),
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (modelTicker.isEmpty ||
                                      (valNotCovered &&
                                          upside == null &&
                                          latestPrice == null))
                                    Text(
                                      w(
                                        'No standalone DCF valuation model for this instrument. Full desktop DCF workbench remains available on Mac / PC.',
                                        '该合约/ETF 暂无独立 DCF 估值模型覆盖；深度财务建模可在电脑端完整工作台查看。',
                                      ),
                                      style: const TextStyle(
                                        color: Color(0xFF94A3B8),
                                        fontSize: 12,
                                        height: 1.45,
                                      ),
                                    )
                                  else ...[
                                    if (latestPrice != null)
                                      _mobileSheetMetricRow(
                                        'Latest Stock Price',
                                        '最新正股价格',
                                        fmtValMoney(latestPrice),
                                      ),
                                    if (fairVal != null) ...[
                                      Divider(
                                        height: 1,
                                        color: Colors.white.withValues(
                                          alpha: .06,
                                        ),
                                      ),
                                      _mobileSheetMetricRow(
                                        'Base DCF Fair Value',
                                        '基准内在价值估算',
                                        fmtValMoney(fairVal),
                                        valueColor: const Color(0xFF34D399),
                                      ),
                                    ],
                                    if (revGrowth != null) ...[
                                      Divider(
                                        height: 1,
                                        color: Colors.white.withValues(
                                          alpha: .06,
                                        ),
                                      ),
                                      _mobileSheetMetricRow(
                                        'Revenue Growth (YoY)',
                                        '营收同比增速',
                                        portfolioRateLabel(revGrowth),
                                      ),
                                    ],
                                    if (opMargin != null) ...[
                                      Divider(
                                        height: 1,
                                        color: Colors.white.withValues(
                                          alpha: .06,
                                        ),
                                      ),
                                      _mobileSheetMetricRow(
                                        'Operating Margin',
                                        '经营利润率',
                                        percent(opMargin),
                                      ),
                                    ],
                                    if (fcfMargin != null) ...[
                                      Divider(
                                        height: 1,
                                        color: Colors.white.withValues(
                                          alpha: .06,
                                        ),
                                      ),
                                      _mobileSheetMetricRow(
                                        'FCF Margin',
                                        '自由现金流率',
                                        percent(fcfMargin),
                                      ),
                                    ],
                                    const SizedBox(height: 6),
                                    Text(
                                      w(
                                        'Pocket snapshot · full interactive 3-statement DCF stays on Desktop.',
                                        '手机端精简速览 · 完整三表 DCF 调参请在电脑端使用。',
                                      ),
                                      style: const TextStyle(
                                        color: Color(0xFF64748B),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSnowballHoldingsScreen({
    required List<Map<String, dynamic>> groups,
    required Map<String, dynamic> g,
    required Map<String, dynamic> h,
  }) {
    final allNonCash = asList(
      g['positions'],
    ).where((r) => !['cash', 'accrual'].contains(r['kind'])).toList();
    final equities = allNonCash.where((r) => r['kind'] == 'equity').toList();
    final others = allNonCash.where((r) => r['kind'] != 'equity').toList();

    var filtered = mobileHoldingsTabFilter == 'equity'
        ? List<Map<String, dynamic>>.from(equities)
        : mobileHoldingsTabFilter == 'other'
        ? List<Map<String, dynamic>>.from(others)
        : List<Map<String, dynamic>>.from(allNonCash);

    final q = mobileHoldingsQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      filtered = filtered
          .where(
            (r) =>
                text(r['ticker']).toLowerCase().contains(q) ||
                text(r['name']).toLowerCase().contains(q),
          )
          .toList();
    }

    filtered.sort((a, b) {
      if (mobileHoldingsSort == 'pnl') {
        final pa = number(a['unrealizedPnl'] ?? a['pnl']);
        final pb = number(b['unrealizedPnl'] ?? b['pnl']);
        return pb.compareTo(pa);
      }
      if (mobileHoldingsSort == 'value') {
        return number(b['value']).abs().compareTo(number(a['value']).abs());
      }
      return number(b['netWeight']).abs().compareTo(
        number(a['netWeight']).abs(),
      );
    });

    final totalOpenPnl = allNonCash.fold<double>(
      0,
      (sum, r) => sum + number(r['unrealizedPnl']),
    );
    final maxWeight = allNonCash.fold<double>(
      0.01,
      (mx, r) => math.max(mx, number(r['netWeight']).abs()),
    );

    double? openPnlRate(Map<String, dynamic> r) {
      final val = nullableNumber(r['value']);
      final gain = nullableNumber(r['unrealizedPnl']);
      if (val == null ||
          gain == null ||
          !val.isFinite ||
          !gain.isFinite ||
          number(r['quantity']) <= 0 ||
          val - gain <= 0) {
        return null;
      }
      return portfolioRatio(gain, val - gain);
    }

    return Column(
      key: const ValueKey('snowball-mobile-holdings-screen'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (groups.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                for (final currency in groups)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(text(currency['currency'], '—')),
                      selected: identical(currency, g),
                      onSelected: (_) => homeUpdate(
                        () => selectedCurrency = text(currency['currency']),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        // Top Summary Card
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF161B24),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: .05)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w('EQUITIES MV', '正股持仓市值'),
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hideAmounts
                          ? '${equities.length} ${w('stocks', '只')}'
                          : _snowballMoneyCompact(g, g['equityValue'] ?? 0),
                      style: const TextStyle(
                        color: Color(0xFFF8FAFC),
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 1,
                height: 30,
                color: Colors.white.withValues(alpha: .06),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w('OPEN UNREALIZED P&L', '持仓累计浮盈亏'),
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      hideAmounts
                          ? '••••'
                          : _snowballMoneyCompact(
                              g,
                              totalOpenPnl,
                              signed: true,
                            ),
                      style: TextStyle(
                        color: totalOpenPnl < 0
                            ? const Color(0xFFFB7185)
                            : const Color(0xFF34D399),
                        fontSize: 16.5,
                        fontWeight: FontWeight.w800,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // Category Filter Pills
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: const Color(0xFF131720),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: .05)),
          ),
          child: Row(
            children: [
              for (final seg in [
                ('all', 'All (${allNonCash.length})', '全部 (${allNonCash.length})'),
                ('equity', 'Stocks (${equities.length})', '正股 (${equities.length})'),
                ('other', 'Options (${others.length})', '期权 (${others.length})'),
              ])
                Expanded(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: ValueKey('mobile-holdings-filter-${seg.$1}'),
                      borderRadius: BorderRadius.circular(11),
                      onTap: () =>
                          homeUpdate(() => mobileHoldingsTabFilter = seg.$1),
                      child: Container(
                        height: 38,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: mobileHoldingsTabFilter == seg.$1
                              ? const Color(0xFF1F2736)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(
                          w(seg.$2, seg.$3),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: mobileHoldingsTabFilter == seg.$1
                                ? const Color(0xFFF8FAFC)
                                : const Color(0xFF94A3B8),
                            fontSize: 12,
                            fontWeight: mobileHoldingsTabFilter == seg.$1
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Search + Sort Row
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 40,
                child: TextField(
                  key: const ValueKey('mobile-holdings-search-input'),
                  controller: mobileHoldingsSearchCtrl,
                  onChanged: (v) => homeUpdate(() => mobileHoldingsQuery = v),
                  style: const TextStyle(
                    color: Color(0xFFF8FAFC),
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    hintText: w('Filter ticker…', '筛选代码或名称…'),
                    hintStyle: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 12.5,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 17,
                      color: Color(0xFF64748B),
                    ),
                    suffixIcon: mobileHoldingsQuery.isEmpty
                        ? null
                        : IconButton(
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              mobileHoldingsSearchCtrl.clear();
                              homeUpdate(() => mobileHoldingsQuery = '');
                            },
                            icon: const Icon(
                              Icons.clear_rounded,
                              size: 16,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                    filled: true,
                    fillColor: const Color(0xFF161B24),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: .05),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                        color: Color(0xFF34D399),
                        width: 1.1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            for (final srt in [
              ('weight', 'Weight', '按权重'),
              ('pnl', 'P&L', '按浮盈'),
            ])
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Material(
                  color: mobileHoldingsSort == srt.$1
                      ? const Color(0xFF112D25)
                      : const Color(0xFF161B24),
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    key: ValueKey('mobile-holdings-sort-${srt.$1}'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => homeUpdate(() => mobileHoldingsSort = srt.$1),
                    child: Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: mobileHoldingsSort == srt.$1
                              ? const Color(0xFF34D399).withValues(alpha: .35)
                              : Colors.white.withValues(alpha: .05),
                        ),
                      ),
                      child: Text(
                        w(srt.$2, srt.$3),
                        style: TextStyle(
                          color: mobileHoldingsSort == srt.$1
                              ? const Color(0xFF34D399)
                              : const Color(0xFF94A3B8),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (filtered.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF161B24),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Center(
              child: Text(
                w('No matching positions.', '没有匹配的持仓标的。'),
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
              ),
            ),
          )
        else
          for (final r in filtered)
            Builder(
              builder: (_) {
                final isEq = r['kind'] == 'equity';
                final sym = text(r['ticker']);
                final uPnl = nullableNumber(r['unrealizedPnl']);
                final uRate = openPnlRate(r);
                final wRatio =
                    (number(r['netWeight']).abs() / maxWeight).clamp(0.03, 1.0);
                final pnlTint = (uPnl ?? 0) < 0
                    ? const Color(0xFFFB7185)
                    : const Color(0xFF34D399);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: const Color(0xFF161B24),
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      key: ValueKey(
                        'snowball-holding-card-${r['id'] ?? sym}',
                      ),
                      borderRadius: BorderRadius.circular(18),
                      onTap: () =>
                          _showMobileStockSnapshotSheet(g: g, row: r),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(13, 12, 13, 11),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: .05),
                          ),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                if (isEq)
                                  StockLogo(ticker: sym, palette: p, size: 38)
                                else
                                  Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFA78BFA).withValues(
                                        alpha: .15,
                                      ),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Icon(
                                      Icons.layers_rounded,
                                      color: Color(0xFFA78BFA),
                                      size: 19,
                                    ),
                                  ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              sym,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Color(0xFFF8FAFC),
                                                fontSize: 14.5,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            percent(r['netWeight']),
                                            style: const TextStyle(
                                              color: Color(0xFF94A3B8),
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                              fontFeatures: [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        hideAmounts
                                            ? text(r['name'])
                                            : nullableNumber(r['quantity']) !=
                                                  null
                                            ? '${formatNumber(number(r['quantity']))} ${isEq ? w('sh', '股') : w('ct', '张')} · ${text(r['name'])}'
                                            : text(r['name']),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Color(0xFF64748B),
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      hideAmounts
                                          ? '••••'
                                          : _snowballMoneyCompact(
                                              g,
                                              r['value'],
                                            ),
                                      style: const TextStyle(
                                        color: Color(0xFFF8FAFC),
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w800,
                                        fontFeatures: [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    if (uPnl != null)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6.5,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: uPnl < 0
                                              ? const Color(0xFF2D161C)
                                              : const Color(0xFF112D25),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                        child: Text(
                                          hideAmounts
                                              ? (uRate != null
                                                    ? portfolioRateLabel(uRate)
                                                    : '••••')
                                              : '${_snowballMoneyCompact(g, uPnl, signed: true)}${uRate != null ? ' · ${portfolioRateLabel(uRate)}' : ''}',
                                          style: TextStyle(
                                            color: pnlTint,
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w700,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: Container(
                                height: 3.5,
                                color: const Color(0xFF0E1219),
                                alignment: Alignment.centerLeft,
                                child: FractionallySizedBox(
                                  widthFactor: wRatio,
                                  child: Container(
                                    color: isEq
                                        ? const Color(0xFF34D399)
                                        : const Color(0xFFA78BFA),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
      ],
    );
  }

  Widget _buildSnowballIncomeScreen({
    required List<Map<String, dynamic>> groups,
    required Map<String, dynamic> g,
    required Map<String, dynamic> h,
    required Map<String, dynamic> realized,
    required double? realizedBasis,
  }) {
    final realizedReady = realized['status'] == 'ready';
    final byInst = asList(realized['byInstrument']);
    final rawRows = asList(realized['rows']);
    final activeDailyRows = rawRows
        .where((r) => number(r['pnl']).abs() > 0.005)
        .toList()
        .reversed
        .toList();
    final dailyList = activeDailyRows.isNotEmpty
        ? activeDailyRows
        : rawRows.reversed.take(40).toList();
    final passive = asMap(h['passiveIncome']);
    final dividends = asMap(passive['dividends']);
    final realizedOptions = asMap(passive['options']).isNotEmpty
        ? asMap(passive['options'])
        : asMap(passive['expiredCalls']);
    final passiveByTicker = asList(passive['byTicker']);
    final pendingShortCalls = asList(asMap(passive['pendingShortCalls'])['rows']);
    final trailing = asMap(h['trailingDividends']);
    final totalNum = nullableNumber(realized['total']) ?? 0;
    final totalColor = totalNum < 0
        ? const Color(0xFFFB7185)
        : const Color(0xFF34D399);
    final maxInstAbs = byInst.fold<double>(
      0.01,
      (prev, r) => math.max(prev, number(r['pnl']).abs()),
    );

    return Column(
      key: const ValueKey('snowball-mobile-income-screen'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Plush Hero Card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF161B24),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withValues(alpha: .05)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                w('CUMULATIVE REALIZED P&L (FIFO)', '累计已实现平仓盈亏 (FIFO)'),
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  !realizedReady
                      ? '—'
                      : hideAmounts
                      ? portfolioRateLabel(
                          portfolioRatio(realized['total'], realizedBasis),
                        )
                      : _snowballMoneyCompact(
                          g,
                          realized['total'],
                          signed: true,
                        ),
                  style: TextStyle(
                    color: realizedReady
                        ? totalColor
                        : const Color(0xFF94A3B8),
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.7,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (nullableNumber(realized['tradeCount']) != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E2634),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        w(
                          '${number(realized['tradeCount']).round()} closed trades',
                          '${number(realized['tradeCount']).round()} 笔平仓交割',
                        ),
                        style: const TextStyle(
                          color: Color(0xFFCBD5E1),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (passive['status'] == 'ready')
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF38BDF8).withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        hideAmounts
                            ? w('Cash income tracked', '已记录股息与权利金')
                            : '${w('Cash income ', '股息与权利金 ')}${_snowballMoneyCompact(g, passive['totalConfirmed'], signed: true)}',
                        style: const TextStyle(
                          color: Color(0xFF38BDF8),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // 3-Segment Snowball Selector
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: const Color(0xFF131720),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: .05)),
          ),
          child: Row(
            children: [
              for (final seg in [
                ('bySymbol', 'By Ticker', '标的盈亏榜'),
                ('daily', 'Daily Ledger', '平仓流水'),
                ('dividends', 'Divs & Calls', '股息与权利金'),
              ])
                Expanded(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: ValueKey('snowball-income-tab-${seg.$1}'),
                      borderRadius: BorderRadius.circular(11),
                      onTap: () =>
                          homeUpdate(() => mobileIncomeSubTab = seg.$1),
                      child: Container(
                        height: 38,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: mobileIncomeSubTab == seg.$1
                              ? const Color(0xFF1F2736)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(
                          w(seg.$2, seg.$3),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: mobileIncomeSubTab == seg.$1
                                ? const Color(0xFFF8FAFC)
                                : const Color(0xFF94A3B8),
                            fontSize: 12,
                            fontWeight: mobileIncomeSubTab == seg.$1
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (mobileIncomeSubTab == 'bySymbol') ...[
          if (byInst.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF161B24),
                borderRadius: BorderRadius.circular(18),
              ),
              child: copy(
                'No closed trade attribution in this report period.',
                '当前报告期暂无按标的拆分的平仓盈亏记录。',
              ),
            )
          else
            for (final item in byInst)
              Builder(
                builder: (_) {
                  final pnlVal = number(item['pnl']);
                  final isEq = [
                    'STK',
                    'STOCK',
                    'EQUITY',
                    'COMMON STOCK',
                  ].contains(text(item['assetCategory']).toUpperCase());
                  final underlying = _extractUnderlyingTicker(item);
                  final ratio = (pnlVal.abs() / maxInstAbs).clamp(0.04, 1.0);
                  final tint = pnlVal < 0
                      ? const Color(0xFFFB7185)
                      : const Color(0xFF34D399);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: const Color(0xFF161B24),
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: underlying == null
                            ? null
                            : () => _showMobileStockSnapshotSheet(
                                g: g,
                                row: item,
                                ticker: underlying,
                              ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 13,
                            vertical: 11,
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  if (isEq)
                                    StockLogo(
                                      ticker: text(item['ticker']),
                                      palette: p,
                                      size: 32,
                                    )
                                  else
                                    const Icon(
                                      Icons.layers_rounded,
                                      color: Color(0xFFA78BFA),
                                      size: 26,
                                    ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          text(item['ticker']),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Color(0xFFF8FAFC),
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        if (text(item['name']).isNotEmpty)
                                          Text(
                                            text(item['name']),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Color(0xFF64748B),
                                              fontSize: 11,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    hideAmounts
                                        ? portfolioRateLabel(
                                            portfolioRatio(
                                              pnlVal,
                                              realizedBasis,
                                            ),
                                          )
                                        : _snowballMoneyCompact(
                                            g,
                                            pnlVal,
                                            signed: true,
                                          ),
                                    style: TextStyle(
                                      color: tint,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w800,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 7),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: Container(
                                  height: 4,
                                  color: const Color(0xFF0E1219),
                                  alignment: Alignment.centerLeft,
                                  child: FractionallySizedBox(
                                    widthFactor: ratio,
                                    child: Container(color: tint),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
        ] else if (mobileIncomeSubTab == 'daily') ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF161B24),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: .05)),
            ),
            child: dailyList.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: copy(
                      'No daily closed P&L entries.',
                      '暂无按日平仓盈亏流水。',
                    ),
                  )
                : Column(
                    children: [
                      for (var i = 0; i < dailyList.take(60).length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: 1,
                            color: Colors.white.withValues(alpha: .05),
                          ),
                        Builder(
                          builder: (_) {
                            final row = dailyList[i];
                            final dPnl = number(row['pnl']);
                            final cumPnl = number(row['cumulativePnl']);
                            final tint = dPnl < 0
                                ? const Color(0xFFFB7185)
                                : dPnl > 0
                                ? const Color(0xFF34D399)
                                : const Color(0xFF94A3B8);
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          text(row['date']),
                                          style: const TextStyle(
                                            color: Color(0xFFF8FAFC),
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                            fontFeatures: [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                        Text(
                                          hideAmounts
                                              ? w('Cumulative tracked', '已计入累计')
                                              : '${w('Cum. ', '累计 ')}${_snowballMoneyCompact(g, cumPnl, signed: true)}',
                                          style: const TextStyle(
                                            color: Color(0xFF64748B),
                                            fontSize: 11,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    hideAmounts
                                        ? portfolioRateLabel(
                                            portfolioRatio(dPnl, realizedBasis),
                                          )
                                        : _snowballMoneyCompact(
                                            g,
                                            dPnl,
                                            signed: true,
                                          ),
                                    style: TextStyle(
                                      color: tint,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w800,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
          ),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF161B24),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: .05)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _mobileSheetMetricRow(
                  'Confirmed Cash Income',
                  '已确认税后股息与权利金合计',
                  hideAmounts
                      ? '••••'
                      : _snowballMoneyCompact(
                          g,
                          passive['totalConfirmed'] ?? 0,
                          signed: true,
                        ),
                  valueColor: const Color(0xFF34D399),
                ),
                Divider(height: 1, color: Colors.white.withValues(alpha: .06)),
                _mobileSheetMetricRow(
                  'Net Cash Dividends (${number(dividends['eventCount']).round()})',
                  '税后现金股息 (${number(dividends['eventCount']).round()} 笔)',
                  hideAmounts
                      ? '••••'
                      : _snowballMoneyCompact(g, dividends['netAmount'] ?? 0),
                ),
                Divider(height: 1, color: Colors.white.withValues(alpha: .06)),
                _mobileSheetMetricRow(
                  'Realized Options Call/Put (${number(realizedOptions['contractCount']).round()})',
                  '期权已实现盈亏 Call/Put (${number(realizedOptions['contractCount']).round()} 张)',
                  hideAmounts
                      ? '••••'
                      : _snowballMoneyCompact(
                          g,
                          realizedOptions['amount'] ?? 0,
                          signed: true,
                        ),
                  valueColor: number(realizedOptions['amount']) < 0
                      ? const Color(0xFFFB7185)
                      : null,
                ),
                if (trailing['status'] == 'ready') ...[
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: .06),
                  ),
                  _mobileSheetMetricRow(
                    'Est. Forward 12M Dividends',
                    '预计近 12 月年化股息',
                    hideAmounts
                        ? portfolioRateLabel(
                            nullableNumber(trailing['estimatedYield']),
                          )
                        : _snowballMoneyCompact(g, trailing['annualAmount']),
                  ),
                ],
              ],
            ),
          ),
          if (passiveByTicker.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF161B24),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withValues(alpha: .05)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    w('BY TICKER', '按标的现金收入明细'),
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final row in passiveByTicker.take(25))
                    InkWell(
                      onTap: () {
                        final sym = _extractUnderlyingTicker(row);
                        if (sym != null) {
                          _showMobileStockSnapshotSheet(
                            g: g,
                            row: row,
                            ticker: sym,
                          );
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                text(row['ticker']),
                                style: const TextStyle(
                                  color: Color(0xFFF8FAFC),
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Text(
                              hideAmounts
                                  ? '••••'
                                  : _snowballMoneyCompact(
                                      g,
                                      row['total'] ?? row['amount'] ?? 0,
                                      signed: true,
                                    ),
                              style: const TextStyle(
                                color: Color(0xFF34D399),
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.chevron_right_rounded,
                              size: 15,
                              color: Color(0xFF64748B),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (pendingShortCalls.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF161B24),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withValues(alpha: .05)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    w('OPEN SHORT CALLS', '待到期卖出看涨期权'),
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final sc in pendingShortCalls.take(15))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              text(sc['ticker'] ?? sc['symbol']),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFF8FAFC),
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                          Text(
                            hideAmounts
                                ? '••••'
                                : _snowballMoneyCompact(
                                    g,
                                    sc['premiumBasis'] ?? sc['costBasis'] ?? 0,
                                  ),
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildSnowballAccountsScreen({
    required List<Map<String, dynamic>> groups,
    required Map<String, dynamic> g,
    required Map<String, dynamic> h,
  }) {
    final accounts = asList(g['accountMeta']);
    final navVal = number(
      h['accountValue'] ?? g['reportedNav'] ?? g['netValue'],
    );
    final cashVal = number(g['cash']);
    final grossVal = number(g['grossExposure']);
    final leverage = navVal.abs() > 0 ? grossVal / navVal.abs() : 0.0;
    final isSnapshotOnly =
        data?['status'] == 'preview_account' ||
        data?['source'] == 'local_owner_broker_snapshot';

    return Column(
      key: const ValueKey('snowball-mobile-accounts-screen'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (portfolioActionError != null || portfolioActionMessage != null) ...[
          portfolioSyncNotice(),
          const SizedBox(height: 10),
        ],
        // 1. Session & Native App Direct Login Card
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: const Color(0xFF161B24),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: .05)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFF34D399).withValues(alpha: .14),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.verified_user_rounded,
                      color: Color(0xFF34D399),
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.localPreview
                              ? w('Local Preview Mode', '本地预览工作区')
                              : (widget.userEmail.trim().isNotEmpty
                                    ? widget.userEmail.trim()
                                    : w('Signed-In Investor', '已认证云端账户')),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFF8FAFC),
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          w(
                            '100% Native In-App Session · Zero Browser Jump',
                            'App 原生持久会话 · 支持密码 FaceID 与 6 位码秒登',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (widget.onSetAppPassword != null ||
                  widget.onShowPairCode != null) ...[
                const SizedBox(height: 12),
                if (widget.onSetAppPassword != null)
                  FilledButton.icon(
                    key: const ValueKey('mobile-account-set-password-btn'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF34D399),
                      foregroundColor: const Color(0xFF04130D),
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: widget.onSetAppPassword,
                    icon: const Icon(
                      Icons.face_retouching_natural_rounded,
                      size: 18,
                    ),
                    label: Text(
                      w(
                        'Set Direct App Password (FaceID)',
                        '设置 / 修改 App 直登密码（开启 FaceID 秒登）',
                      ),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                if (widget.onShowPairCode != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('mobile-account-pair-code-btn'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF38BDF8),
                      minimumSize: const Size.fromHeight(44),
                      side: BorderSide(
                        color: const Color(0xFF38BDF8).withValues(alpha: .35),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: widget.onShowPairCode,
                    icon: const Icon(Icons.phonelink_lock_rounded, size: 17),
                    label: Text(
                      w(
                        'Generate 6-Digit Sign-In Code',
                        '生成其他设备 6 位数字秒登码',
                      ),
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 2. IBKR Accounts, Cash & Margin Breakdown
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: const Color(0xFF161B24),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: .05)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                w('CONNECTED IBKR ACCOUNTS & MARGIN', 'IBKR 合并账户与融资净值'),
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 8),
              if (groups.isNotEmpty) ...[
                _mobileSheetMetricRow(
                  'Combined Net Worth (NAV)',
                  '合并账户总净值',
                  hideAmounts ? '••••' : _snowballMoneyCompact(g, navVal),
                  valueColor: const Color(0xFF34D399),
                ),
                Divider(height: 1, color: Colors.white.withValues(alpha: .06)),
                _mobileSheetMetricRow(
                  cashVal < 0 ? 'Margin Loan / Debit' : 'Settled Cash',
                  cashVal < 0 ? '证券融资负债余额' : '可用清算正现金',
                  hideAmounts ? '••••' : _snowballMoneyCompact(g, cashVal),
                  valueColor: cashVal < 0
                      ? const Color(0xFFFB7185)
                      : const Color(0xFF34D399),
                ),
                Divider(height: 1, color: Colors.white.withValues(alpha: .06)),
                _mobileSheetMetricRow(
                  'Gross Exposure & Leverage',
                  '总敞口与杠杆倍数',
                  hideAmounts
                      ? '${leverage.toStringAsFixed(2)}x'
                      : '${_snowballMoneyCompact(g, grossVal)} (${leverage.toStringAsFixed(2)}x)',
                ),
                if (accounts.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  for (final acc in accounts)
                    Container(
                      margin: const EdgeInsets.only(bottom: 7),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF11151E),
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: .04),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.account_balance_wallet_outlined,
                            size: 17,
                            color: Color(0xFF34D399),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  text(
                                    acc['label'],
                                    text(acc['accountNumber'], 'IBKR'),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFF8FAFC),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  '${text(acc['accountNumber'], '—')} · ${text(acc['reportDate'], '—')}',
                                  style: const TextStyle(
                                    color: Color(0xFF64748B),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            hideAmounts ||
                                    nullableNumber(acc['reportedNav']) == null
                                ? '••••'
                                : _snowballMoneyCompact(g, acc['reportedNav']),
                            style: const TextStyle(
                              color: Color(0xFFF8FAFC),
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ] else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: copy(
                    'Connect your read-only IBKR Flex Query to sync multi-account NAV, holdings, and FIFO P&L.',
                    '连接只读 IBKR Flex Query 即可自动同步多账户净值、持仓与平仓流水。',
                    size: 12.5,
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('mobile-account-manage-ibkr-btn'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      onPressed: isSnapshotOnly
                          ? () => _notifyMobileActionStatus(
                              'Sign in to manage live IBKR Flex credentials.',
                              '请先登录云端账户以管理或修改 IBKR Flex 连接凭证。',
                            )
                          : managePortfolioConnection,
                      icon: const Icon(Icons.link_rounded, size: 16),
                      label: Text(w('Manage IBKR', '管理连接')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('mobile-account-sync-ibkr-btn'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF34D399),
                        foregroundColor: const Color(0xFF04130D),
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      onPressed: isSnapshotOnly || portfolioSyncing
                          ? null
                          : syncConnectedPortfolio,
                      icon: portfolioSyncing
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_sync_rounded, size: 16),
                      label: Text(
                        portfolioSyncing
                            ? w('Syncing…', '同步中…')
                            : w('Sync IBKR', '立即同步'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 3. Display Preferences & Sign Out
        Material(
          color: const Color(0xFF161B24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: .05)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile.adaptive(
                  key: const ValueKey('mobile-account-privacy-switch'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: const Color(0xFF34D399),
                  title: Text(
                    w('Privacy mode (hide amounts)', '隐私模式（隐藏具体金额）'),
                    style: const TextStyle(
                      color: Color(0xFFF8FAFC),
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  value: hideAmounts,
                  onChanged: (next) => portfolioPrivacyMode.value = next,
                ),
                if (widget.onToggleColorBlind != null) ...[
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: .05),
                  ),
                  SwitchListTile.adaptive(
                    key: const ValueKey('mobile-account-colorblind-switch'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: const Color(0xFF34D399),
                    title: Text(
                      w('Color-blind safe palette', '色盲友好高对比配色'),
                      style: const TextStyle(
                        color: Color(0xFFF8FAFC),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    value: widget.colorBlind,
                    onChanged: widget.onToggleColorBlind,
                  ),
                ],
                if (widget.onLanguage != null) ...[
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: .05),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            w('Language', '界面语言'),
                            style: const TextStyle(
                              color: Color(0xFFF8FAFC),
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        SegmentedButton<AppLanguage>(
                          key: const ValueKey('mobile-account-language-toggle'),
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: const [
                            ButtonSegment(
                              value: AppLanguage.zh,
                              label: Text('中文'),
                            ),
                            ButtonSegment(
                              value: AppLanguage.en,
                              label: Text('EN'),
                            ),
                          ],
                          selected: {context.language},
                          onSelectionChanged: (s) {
                            if (s.isNotEmpty) widget.onLanguage!(s.first);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
                if (widget.onShowCutoffPicker != null) ...[
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: .05),
                  ),
                  ListTile(
                    key: const ValueKey('mobile-account-cutoff-row'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      w('Information cutoff date', '数据截止日 / 历史回放'),
                      style: const TextStyle(
                        color: Color(0xFFF8FAFC),
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.asOf,
                          style: const TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 12.5,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: Color(0xFF64748B),
                        ),
                      ],
                    ),
                    onTap: widget.onShowCutoffPicker,
                  ),
                ],
                if (widget.onShowInstallGuide != null) ...[
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: .05),
                  ),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.phone_iphone_rounded,
                      color: Color(0xFF34D399),
                      size: 19,
                    ),
                    title: Text(
                      w(
                        'Install Fullscreen Home Screen App',
                        '安装 iPhone 纯净桌面 App (.mobileconfig)',
                      ),
                      style: const TextStyle(
                        color: Color(0xFFF8FAFC),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onTap: widget.onShowInstallGuide,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (widget.onLogout != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('mobile-account-logout-btn'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFFB7185),
              minimumSize: const Size.fromHeight(46),
              side: BorderSide(
                color: const Color(0xFFFB7185).withValues(alpha: .4),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout_rounded, size: 17),
            label: Text(
              w('Sign Out of Current Account', '退出当前账号'),
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
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
    this.compactMobile = false,
    this.requestedMetric,
    this.requestedMetricNonce = 0,
    this.onInsufficientHistory,
  });
  final List<Map<String, dynamic>> rows;
  final String currency;
  final Palette palette;
  final Map<String, dynamic> history;
  final bool hideAmounts;
  final double chartHeight;
  final bool compactMobile;
  final String? requestedMetric;
  final int requestedMetricNonce;
  final VoidCallback? onInsufficientHistory;
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
  void didUpdateWidget(covariant PortfolioAccountValueChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.requestedMetricNonce != oldWidget.requestedMetricNonce &&
        widget.requestedMetric != null) {
      final target = widget.requestedMetric!;
      final canSwitch =
          target == 'nav' ||
          asList(asMap(widget.history[target])['rows']).length >= 2;
      if (canSwitch && metric != target) {
        metric = target;
        hover = null;
      }
    }
  }
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
    if (widget.compactMobile) {
      final cursorValue = widget.hideAmounts
          ? portfolioRateLabel(displayRows[cursor]['nav'])
          : '${widget.currency} ${formatNumber(number(rows[cursor]['nav']))}';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              if (widget.history.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width > 0
                        ? MediaQuery.sizeOf(context).width - 64
                        : 320,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Material(
                      color: const Color(0xFF0E1219),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: .045),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final mode in [
                              'nav',
                              'realized',
                              'cashAdjusted',
                            ])
                              Builder(
                                builder: (_) {
                                  final disabled =
                                      mode != 'nav' &&
                                      asList(
                                            asMap(widget.history[mode])['rows'],
                                          ).length <
                                          2;
                                  final active = metric == mode;
                                  return InkWell(
                                    key: ValueKey('history-metric-$mode'),
                                    borderRadius: BorderRadius.circular(9),
                                    onTap: disabled
                                        ? widget.onInsufficientHistory
                                        : () => setState(() {
                                            metric = mode;
                                            hover = null;
                                          }),
                                    child: Container(
                                      constraints: const BoxConstraints(
                                        minHeight: 28,
                                      ),
                                      alignment: Alignment.center,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: active
                                            ? const Color(0xFF252D3D)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: Text(
                                        mode == 'nav'
                                            ? w('NAV', '净值')
                                            : mode == 'realized'
                                            ? w('Realized', '已实现')
                                            : w('Est.', '净收益'),
                                        style: TextStyle(
                                          color: disabled
                                              ? p.muted.withValues(alpha: .42)
                                              : active
                                              ? const Color(0xFFF8FAFC)
                                              : const Color(0xFF94A3B8),
                                          fontSize: 11.5,
                                          fontWeight: active
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E2534),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${rows[cursor]['date']} · $cursorValue',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: number(displayRows[cursor]['nav']) < 0
                        ? const Color(0xFFFB7185)
                        : const Color(0xFF34D399),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          if (!rateAvailable)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                w(
                  'Rate unavailable — a positive starting account value is required.',
                  '变化率暂不可用：需要正数的起始账户净值。',
                ),
                style: TextStyle(color: p.secondary, fontSize: 12),
              ),
            )
          else if (rows.length > 1)
            SizedBox(
              key: ValueKey(
                metric == 'nav' ? 'actual-nav-chart' : '$metric-pnl-chart',
              ),
              height: widget.chartHeight,
              child: LayoutBuilder(
                builder: (_, constraints) {
                  void inspect(double dx) {
                    const leftGutter = 46.0;
                    final fraction =
                        ((dx - leftGutter) /
                                (constraints.maxWidth - leftGutter - 8))
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

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (e) => inspect(e.localPosition.dx),
                    onHorizontalDragStart: (e) => inspect(e.localPosition.dx),
                    onHorizontalDragUpdate: (e) => inspect(e.localPosition.dx),
                    child: CustomPaint(
                      painter: _AccountNavPainter(
                        displayRows,
                        p,
                        cursor,
                        includeZero: widget.hideAmounts || metric != 'nav',
                        percentage: widget.hideAmounts,
                        compactMobile: true,
                      ),
                      size: Size.infinite,
                    ),
                  );
                },
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                w(
                  'Only one observation in this range. Select a longer period.',
                  '此区间只有一条记录，请选择更长区间。',
                ),
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          Material(
            color: const Color(0xFF0E1219),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: .045),
                ),
              ),
              child: Row(
                children: [
                  for (final r in ['1M', '3M', 'YTD', '1Y', 'All'])
                    Expanded(
                      child: InkWell(
                        key: ValueKey('history-range-$r'),
                        borderRadius: BorderRadius.circular(9),
                        onTap: () => setState(() {
                          range = r;
                          hover = null;
                        }),
                        child: Container(
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: range == r
                                ? const Color(0xFF252D3D)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            r == 'All' ? w('All', '全部') : r,
                            style: TextStyle(
                              color: range == r
                                  ? const Color(0xFFF8FAFC)
                                  : const Color(0xFF94A3B8),
                              fontSize: 11.5,
                              fontWeight: range == r
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8,
            runSpacing: 2,
            children: [
              Text(
                '${rows.first['date']} → ${rows.last['date']}',
                style: TextStyle(
                  color: p.muted,
                  fontSize: 10.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                '${rows.length} ${metric == 'nav' ? w('pts · drag chart', '日净值 · 滑动查日') : w('obs · drag chart', '条记录 · 滑动查日')}',
                style: TextStyle(color: p.muted, fontSize: 10.5),
              ),
            ],
          ),
          if (metric == 'cashAdjusted') ...[
            const SizedBox(height: 4),
            Text(
              w(
                'Estimate · Security transfers are not reconciled.',
                '估算 · 证券转仓未核对。',
              ),
              style: TextStyle(color: p.secondary, fontSize: 10.5),
            ),
          ],
        ],
      );
    }
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
              switch (r) {
                'All' => w('All', '全部'),
                'YTD' => w('YTD', '今年至今'),
                '1M' => w('1M', '近 1 月'),
                '3M' => w('3M', '近 3 月'),
                '1Y' => w('1Y', '近 1 年'),
                _ => r,
              },
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
              '${end.year} 今年至今 · 截至 ${all.last['date']}',
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
    this.compactMobile = false,
  });
  final List<Map<String, dynamic>> rows;
  final Palette p;
  final int cursor;
  final bool includeZero;
  final bool percentage;
  final bool compactMobile;
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
    final leftGutter = compactMobile ? 46.0 : 64.0;
    final bottomGutter = compactMobile ? 22.0 : 30.0;
    final rect = Rect.fromLTRB(
      leftGutter,
      compactMobile ? 10 : 16,
      size.width - (compactMobile ? 8 : 12),
      size.height - bottomGutter,
    );
    double x(int i) =>
        rect.left +
        (times[i] - times.first) / (times.last - times.first) * rect.width;
    double y(double v) => rect.bottom - (v - min) / (max - min) * rect.height;
    final lineTint = compactMobile && values.last < 0 && includeZero
        ? const Color(0xFFFB7185)
        : compactMobile
        ? const Color(0xFF34D399)
        : p.accent;
    final gridCount = compactMobile ? 3 : 4;
    for (var i = 0; i < gridCount; i++) {
      final value = min + (max - min) * i / (gridCount - 1);
      final gy = y(value);
      if (compactMobile) {
        final gridPaint = Paint()
          ..color = Colors.white.withValues(alpha: .06)
          ..strokeWidth = 1;
        for (double dx = rect.left; dx < rect.right; dx += 8) {
          canvas.drawLine(
            Offset(dx, gy),
            Offset(math.min(dx + 4, rect.right), gy),
            gridPaint,
          );
        }
      } else {
        canvas.drawLine(
          Offset(rect.left, gy),
          Offset(rect.right, gy),
          Paint()
            ..color = p.border.withValues(alpha: .6)
            ..strokeWidth = 1,
        );
      }
      final label = TextPainter(
        text: TextSpan(
          text: percentage
              ? '${(value * 100).toStringAsFixed(1)}%'
              : value.abs() >= 1000000
              ? '${(value / 1000000).toStringAsFixed(compactMobile ? 1 : 2)}M'
              : value.abs() >= 1000
              ? '${(value / 1000).toStringAsFixed(compactMobile ? 0 : 1)}K'
              : value.toStringAsFixed(0),
          style: TextStyle(
            color: compactMobile ? const Color(0xFF64748B) : p.muted,
            fontSize: compactMobile ? 10 : 11,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: leftGutter - 4);
      label.paint(canvas, Offset(0, gy - 6));
    }
    final path = Path()..moveTo(x(0), y(values[0]));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(x(i), y(values[i]));
    }
    final fill = Path.from(path)
      ..lineTo(x(values.length - 1), rect.bottom)
      ..lineTo(x(0), rect.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: compactMobile
              ? [
                  lineTint.withValues(alpha: .26),
                  lineTint.withValues(alpha: .05),
                  lineTint.withValues(alpha: 0),
                ]
              : [
                  lineTint.withValues(alpha: .08),
                  lineTint.withValues(alpha: 0),
                ],
        ).createShader(rect),
    );
    final tickSteps = compactMobile ? 3 : 4;
    for (var step = 0; step < tickSteps; step++) {
      final time =
          times.first + (times.last - times.first) * step / (tickSteps - 1);
      final date = DateTime.fromMillisecondsSinceEpoch(time.round());
      final tick = TextPainter(
        text: TextSpan(
          text:
              times.last - times.first <=
                  const Duration(days: 120).inMilliseconds
              ? '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}'
              : '${date.year}-${date.month.toString().padLeft(2, '0')}',
          style: TextStyle(
            color: compactMobile ? const Color(0xFF64748B) : p.muted,
            fontSize: compactMobile ? 9.5 : 10,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = rect.left + rect.width * step / (tickSteps - 1);
      tick.paint(
        canvas,
        Offset(
          (dx - tick.width / 2).clamp(rect.left, rect.right - tick.width),
          rect.bottom + (compactMobile ? 6 : 12),
        ),
      );
    }
    if (includeZero) {
      canvas.drawLine(
        Offset(rect.left, y(0)),
        Offset(rect.right, y(0)),
        Paint()
          ..color = p.muted.withValues(alpha: compactMobile ? .38 : .7)
          ..strokeWidth = 1,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = lineTint
        ..strokeWidth = compactMobile ? 2.4 : 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
    canvas.drawLine(
      Offset(x(cursor), rect.top),
      Offset(x(cursor), rect.bottom),
      Paint()
        ..color = (compactMobile ? Colors.white : p.muted).withValues(
          alpha: compactMobile ? .18 : .4,
        )
        ..strokeWidth = 1,
    );
    canvas.drawCircle(
      Offset(x(cursor), y(values[cursor])),
      compactMobile ? 9.5 : 8,
      Paint()..color = lineTint.withValues(alpha: compactMobile ? .24 : .18),
    );
    canvas.drawCircle(
      Offset(x(cursor), y(values[cursor])),
      compactMobile ? 4.6 : 4,
      Paint()..color = lineTint,
    );
    canvas.drawCircle(
      Offset(x(cursor), y(values[cursor])),
      compactMobile ? 2.1 : 1.8,
      Paint()..color = const Color(0xFFF8FAFC),
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
