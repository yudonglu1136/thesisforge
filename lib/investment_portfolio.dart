part of 'main.dart';

// Account ownership and all calculations stay on the server. These selectors
// only change presentation; they cannot select another user's account.
class PortfolioResearchPanel extends StatefulWidget {
  const PortfolioResearchPanel({
    super.key,
    required this.api,
    required this.palette,
    required this.asOf,
    required this.onCompany,
    required this.onGuru,
    this.homeMode = false,
    this.onDetails,
    this.cutoffControl,
  });
  final ApiClient api;
  final Palette palette;
  final String asOf;
  final void Function(String ticker, String section) onCompany;
  final void Function(String id, String filing) onGuru;
  final bool homeMode;
  final VoidCallback? onDetails;
  final Widget? cutoffControl;
  @override
  State<PortfolioResearchPanel> createState() => _PortfolioResearchPanelState();
}

class _PortfolioResearchPanelState extends State<PortfolioResearchPanel> {
  Map<String, dynamic>? data;
  bool loading = true, failed = false;
  bool portfolioSyncing = false;
  String? portfolioActionMessage, portfolioActionError;
  String tab = 'overview', selectedCurrency = '', manager = '', query = '';
  int serial = 0;
  int holdingLimit = 20, comparisonLimit = 20;
  int portfolioSortColumn = 2;
  bool portfolioSortAscending = false;
  double riskFreeRate = .04;
  String homePnlMode = 'auto';
  bool get hideAmounts => portfolioPrivacyMode.value;
  void privacyChanged() => setState(() {});
  void homeUpdate(VoidCallback action) => setState(action);
  final search = TextEditingController();
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  String percent(dynamic v) => nullableNumber(v) == null
      ? '—'
      : '${(number(v) * 100).toStringAsFixed(1)}%';
  String amount(dynamic v, [String? currency]) => hideAmounts
      ? '••••'
      : nullableNumber(v) == null
      ? '—'
      : '${currency ?? selectedCurrency} ${formatNumber(number(v))}';
  @override
  void initState() {
    super.initState();
    portfolioPrivacyMode.addListener(privacyChanged);
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant PortfolioResearchPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asOf != widget.asOf || oldWidget.api != widget.api) {
      unawaited(load());
    }
  }

  @override
  void dispose() {
    serial++;
    portfolioPrivacyMode.removeListener(privacyChanged);
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final request = ++serial;
    setState(() {
      loading = true;
      failed = false;
      data = null;
    });
    try {
      final result = await widget.api.getJson(
        '/api/investment/portfolio-analysis?asOf=${widget.asOf}&riskFreeRate=$riskFreeRate${widget.homeMode ? '&scope=home' : ''}',
      );
      if (!mounted || request != serial) return;
      if (result['asOf'] != widget.asOf ||
          result['version'] != 'portfolio-research-v1') {
        throw StateError('portfolio_contract_mismatch');
      }
      setState(() {
        data = result;
        loading = false;
        final groups = asList(result['groups']);
        if (!groups.any((g) => text(g['currency']) == selectedCurrency)) {
          selectedCurrency = text(groups.firstOrNull?['currency']);
        }
      });
    } catch (_) {
      if (mounted && request == serial) {
        setState(() {
          loading = false;
          failed = true;
        });
      }
    }
  }

  Future<void> syncConnectedPortfolio() async {
    if (portfolioSyncing) return;
    setState(() {
      portfolioSyncing = true;
      portfolioActionMessage = null;
      portfolioActionError = null;
    });
    try {
      final result = await widget.api.postJson('/api/portfolio/sync', {});
      if (!mounted) return;
      if (result['ok'] != true) {
        final report = asMap(result['portfolio']);
        final saved = isSavedPortfolioReport(report);
        setState(() {
          portfolioActionError = saved
              ? savedPortfolioReportNotice(report, context.language)
              : w(
                  'IBKR did not complete a new sync. Your last saved portfolio is unchanged.',
                  'IBKR 未完成新的同步，上一份已保存组合保持不变。',
                );
        });
      } else {
        final incomeStatus = text(result['incomeStatus']);
        final historyStatus = text(result['historyStatus']);
        setState(() {
          portfolioActionMessage = incomeStatus == 'ready'
              ? w(
                  'IBKR sync completed. Holdings, NAV and reported cash dividends and interest were refreshed.',
                  'IBKR 同步完成，持仓、净值及券商报告的现金股息与利息已更新。',
                )
              : historyStatus == 'error'
              ? w(
                  'Holdings and today’s NAV were saved. Historical cash transactions are unavailable, so dividend income was not claimed.',
                  '持仓与今日净值已保存。历史现金交易暂不可用，因此没有把股息收入误报为已更新。',
                )
              : w(
                  'Holdings and NAV were refreshed. To show received dividends, include Detailed Cash Transactions in the IBKR Activity Flex report.',
                  '持仓与净值已更新。若要显示实际收到的股息，请在 IBKR Activity Flex 报告中加入 Detailed Cash Transactions。',
                );
        });
      }
      await load();
    } catch (error) {
      if (mounted) {
        setState(() {
          portfolioActionError = w(
            'IBKR sync could not be completed. Your saved portfolio was not replaced.',
            'IBKR 同步未完成，已保存的组合没有被替换。',
          );
        });
      }
    } finally {
      if (mounted) setState(() => portfolioSyncing = false);
    }
  }

  Future<void> managePortfolioConnection() async {
    Map<String, dynamic> connection;
    try {
      connection = await widget.api.getJson('/api/portfolio/connection');
    } catch (_) {
      if (mounted) {
        setState(() {
          portfolioActionError = w(
            'The IBKR connection settings could not be loaded.',
            '暂时无法读取 IBKR 连接设置。',
          );
        });
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateDialog) {
          Future<void> refreshConnection() async {
            final next = await widget.api.getJson('/api/portfolio/connection');
            if (dialogContext.mounted) {
              updateDialog(() => connection = next);
            }
            if (mounted) await load();
          }

          final registered =
              truthy(connection['registered']) ||
              truthy(connection['configured']);
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(18),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 940, maxHeight: 780),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: panelDecoration(p),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: title(
                            'Manage IBKR connection',
                            '管理 IBKR 连接',
                            20,
                          ),
                        ),
                        IconButton(
                          tooltip: w('Close', '关闭'),
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: Icon(Icons.close_rounded, color: p.muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Flexible(
                      child: SingleChildScrollView(
                        child: registered
                            ? PortfolioConnectionStatusPanel(
                                connection: connection,
                                api: widget.api,
                                palette: p,
                                onRefresh: refreshConnection,
                              )
                            : PortfolioConnectionPanel(
                                connection: connection,
                                api: widget.api,
                                palette: p,
                                onConnected: refreshConnection,
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

  Widget portfolioSyncNotice() {
    final error = portfolioActionError;
    final message = portfolioActionMessage;
    if (error == null && message == null) return const SizedBox.shrink();
    return PortfolioDataNotice(
      icon: error == null
          ? Icons.cloud_done_rounded
          : Icons.error_outline_rounded,
      text: error ?? message!,
      palette: p,
    );
  }

  TextStyle heading([double size = 20]) => TextStyle(
    color: p.text,
    fontSize: size,
    fontWeight: FontWeight.w700,
    height: 1.2,
  );
  Widget copy(String en, String zh, {Color? color, double size = 13}) => Text(
    w(en, zh),
    style: TextStyle(color: color ?? p.muted, fontSize: size, height: 1.5),
  );
  Widget panel(List<Widget> children) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: p.panel,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: p.border),
    ),
    child: Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
  Widget title(String en, String zh, [double size = 20]) =>
      Text(w(en, zh), style: heading(size));
  Widget pair(Widget left, Widget right) => LayoutBuilder(
    builder: (_, c) =>
        c.maxWidth > 920 && MediaQuery.textScalerOf(context).scale(1) <= 1.3
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: left),
              const SizedBox(width: 18),
              Expanded(child: right),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [left, const SizedBox(height: 18), right],
          ),
  );
  Widget tag(String en, String zh, {Color? color}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: (color ?? p.accent).withValues(alpha: .09),
      borderRadius: BorderRadius.circular(5),
    ),
    child: copy(en, zh, color: color ?? p.accent, size: 12),
  );

  @override
  Widget build(BuildContext context) {
    final groups = asList(data?['groups']);
    final group =
        groups
            .where((g) => text(g['currency']) == selectedCurrency)
            .firstOrNull ??
        {};
    if (widget.homeMode) return personalHome(groups, group);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (_, constraints) {
            final heading = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                copy(
                  'PORTFOLIO / YOUR INVESTMENT DESK',
                  '组合 / 你的投资工作台',
                  color: p.accent,
                  size: 12,
                ),
                const SizedBox(height: 8),
                title(
                  'Your portfolio. The whole picture.',
                  '从单只股票，看到整个组合。',
                  30,
                ),
              ],
            );
            if (widget.cutoffControl == null) return heading;
            if (constraints.maxWidth >= 780 &&
                MediaQuery.textScalerOf(context).scale(1) <= 1.2) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: heading),
                  const SizedBox(width: 20),
                  widget.cutoffControl!,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading,
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: widget.cutoffControl!,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            tag(
              data?['source'] == 'local_owner_broker_snapshot'
                  ? 'Your IBKR report · local read-only copy'
                  : groups.isEmpty
                  ? 'Account data · read only'
                  : 'Broker reports · read only',
              data?['source'] == 'local_owner_broker_snapshot'
                  ? '你的 IBKR 报告 · 本地只读副本'
                  : groups.isEmpty
                  ? '账户数据 · 只读'
                  : '券商报告 · 只读',
            ),
            OutlinedButton.icon(
              onPressed:
                  data?['status'] == 'preview_account' ||
                      data?['source'] == 'local_owner_broker_snapshot'
                  ? () => openBrowserPath(
                      'https://www.thesisforge.tech/?view=book&lang=${appLanguageCode(context.language)}',
                    )
                  : managePortfolioConnection,
              icon: const Icon(Icons.settings_outlined, size: 17),
              label: Text(
                data?['status'] == 'preview_account'
                    ? w('Open online Portfolio', '打开线上 Portfolio')
                    : data?['source'] == 'local_owner_broker_snapshot'
                    ? w('Open live account', '打开线上账户')
                    : w('Manage IBKR', '管理 IBKR'),
              ),
            ),
            FilledButton.icon(
              key: const ValueKey('portfolio-sync-now'),
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
              key: const ValueKey('portfolio-reload-analysis'),
              tooltip: w('Reload portfolio analysis', '重新读取组合分析'),
              onPressed: loading ? null : load,
              icon: Icon(Icons.refresh_rounded, color: p.accent),
            ),
            privacyToggle(),
          ],
        ),
        const SizedBox(height: 12),
        if (portfolioActionError != null || portfolioActionMessage != null) ...[
          portfolioSyncNotice(),
          const SizedBox(height: 12),
        ],
        if (isSavedPortfolioReport(data)) ...[
          PortfolioDataNotice(
            icon: Icons.history_rounded,
            text: savedPortfolioReportNotice(data, context.language),
            palette: p,
          ),
          const SizedBox(height: 12),
        ],
        if (loading)
          panel([
            const LinearProgressIndicator(),
            const SizedBox(height: 16),
            copy('Reading your connected portfolio…', '正在读取你已有的账户持仓…'),
          ])
        else if (failed)
          panel([
            title('Portfolio could not be loaded', '组合暂时读取失败'),
            const SizedBox(height: 10),
            copy(
              'Your holdings have not been changed. Retry the account request.',
              '原始持仓没有变化，请重试账户读取。',
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: load,
                child: Text(w('Try again', '重试')),
              ),
            ),
          ])
        else if (groups.isEmpty)
          emptyState()
        else ...[
          if (data?['status'] == 'partial_accounts') ...[
            tag(
              'Some accounts did not load · analysis covers returned accounts only',
              '部分账户读取失败 · 分析仅覆盖已返回账户',
              color: p.secondary,
            ),
            const SizedBox(height: 12),
          ],
          if (groups.length > 1)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final g in groups)
                  ChoiceChip(
                    label: Text(
                      '${g['currency'] ?? w('Unknown currency', '未知币种')} · ${g['accountCount']} ${w('accounts', '个账户')}',
                    ),
                    selected: identical(group, g),
                    onSelected: (_) =>
                        setState(() => selectedCurrency = text(g['currency'])),
                  ),
                copy(
                  'Currencies stay separate; no assumed FX.',
                  '不同基础币种分组，不猜测汇率。',
                  size: 12,
                ),
              ],
            ),
          if (groups.length > 1) const SizedBox(height: 10),
          Tooltip(
            message: w(
              'These are your latest reported positions, not a historical portfolio at the research cutoff. Currencies stay separate; no assumed FX.',
              '展示最新报告持仓，不是研究截止日的历史组合复原。币种分组，不猜测汇率。',
            ),
            child: copy(
              '${selectedCurrency.isEmpty ? '' : '$selectedCurrency · '}Holdings reports: ${asListDates(group['reportDates'])} · Research cutoff: ${widget.asOf}',
              '${selectedCurrency.isEmpty ? '' : '$selectedCurrency · '}持仓报告：${asListDates(group['reportDates'])} · 研究信息截止：${widget.asOf}',
              size: 11,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in [
                ('overview', 'Overview', '组合总览'),
                ('holdings', 'Holdings & value', '持仓与估值'),
                ('risk', 'Risk & SPY', '风险与 SPY'),
                ('gurus', 'Compare with Gurus', '对比大佬'),
              ])
                ChoiceChip(
                  label: Text(w(t.$2, t.$3)),
                  selected: tab == t.$1,
                  onSelected: (_) => setState(() => tab = t.$1),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (tab == 'overview') portfolioDesk(group),
          if (tab == 'holdings') portfolioHoldingsTable(group),
          if (tab == 'risk') riskView(group),
          if (tab == 'gurus') gurus(group),
          const SizedBox(height: 20),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(w('How this analysis is calculated', '这些分析如何计算')),
            children: [
              copy(
                'Valuation uses reported shares × published fair value × report FX. Only long equities with reconciled units and currency are included. Uncovered positions stay at their report marks; this is not a complete portfolio fair value.',
                '估值使用报告股数 × 平台估值 × 报告汇率。仅纳入股数与币种核验通过的股票多头。未覆盖部分维持报告市价，不代表完整组合内在价值。',
              ),
              const SizedBox(height: 10),
              copy(
                'Guru comparisons use each disclosed common-stock long book. Cash, options, shorts and private investments are outside that comparison. Different report dates and partial coverage are shown.',
                '大佬比较基于已披露普通股多头。现金、期权、空头和私募资产不在比较范围；披露日期和不完整覆盖均单独标注。',
              ),
              const SizedBox(height: 10),
              copy(
                'Sector labels use current stored issuer classifications. Stress tests are hypothetical equity mark changes, not a forecast, historical return, or VaR.',
                '行业使用当前已存分类；压力测试是假设股票市值变化，不是预测、历史收益或风险价值。',
              ),
            ],
          ),
        ],
      ],
    );
  }

  String asListDates(dynamic dates) => dates is List
      ? dates.map((d) => d ?? w('Unknown', '未知')).join(' / ')
      : '—';
  Widget emptyState() {
    final status = data?['status'];
    final preview = status == 'preview_account';
    return panel([
      Icon(Icons.account_balance_wallet_outlined, color: p.accent, size: 38),
      const SizedBox(height: 18),
      title(
        preview
            ? 'This preview is not your online account.'
            : status == 'empty_account'
            ? 'No positions in the connected report.'
            : 'Your account data is needed here.',
        preview
            ? '本地预览不是你的线上账户。'
            : status == 'empty_account'
            ? '已连接报告暂时没有持仓。'
            : '这里需要接入你的账户数据。',
      ),
      const SizedBox(height: 12),
      copy(
        preview
            ? 'This local development preview is not signed into your portfolio account. Your existing holdings need the correct account connection. No demo holdings are substituted.'
            : status == 'report_inputs_unavailable'
            ? 'The account is connected, but the raw report inputs required for portfolio analysis are unavailable. No inferred holdings or valuation totals are shown.'
            : 'Use your existing account connection. No sample holdings, invented returns or other users’ portfolios are shown.',
        preview
            ? '本地开发预览尚未登录你的持仓账户，需要接入正确账户才能读取已有组合。不会用研究示例或其他用户持仓替代。'
            : status == 'report_inputs_unavailable'
            ? '账户已连接，但组合分析所需的原始报告字段缺失。不会推测持仓或填入估值总额。'
            : '使用原有账户连接，不展示示例持仓、虚构收益或其他用户的组合。',
      ),
      const SizedBox(height: 22),
      pair(
        panel([
          title('1  Create a read-only IBKR report', '1  创建 IBKR 只读报告', 17),
          const SizedBox(height: 8),
          copy(
            'In IBKR Client Portal, open Reporting → Flex Queries. Create an Activity Flex Query in XML with Account Information, Open Positions, Cash Report and Net Asset Value.',
            '在 IBKR Client Portal 打开 Reporting → Flex Queries，新建 XML 格式 Activity Flex Query，包含账户信息、持仓、现金报告和净资产值。',
          ),
        ]),
        panel([
          title(
            '2  Connect with Token + Query ID',
            '2  用 Token + Query ID 连接',
            17,
          ),
          const SizedBox(height: 8),
          copy(
            'Enable Flex Web Service and copy its Token and your report’s Query ID. No trading password or order permission is needed. Credentials stay encrypted on the backend.',
            '启用 Flex Web Service，复制 Token 和报告 Query ID。不需要交易密码或下单权限；凭证仅在后端加密保存。',
          ),
        ]),
      ),
      const SizedBox(height: 16),
      copy(
        'For actual performance, also include daily NAV and deposits/withdrawals, or broker time-weighted returns. A single balance cannot establish Sharpe or Beta.',
        '如需实际业绩，还需每日净值和入出金记录，或券商时间加权收益；单日余额无法计算真实 Sharpe 或 Beta。',
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 10,
        children: [
          FilledButton.icon(
            onPressed: preview
                ? () => openBrowserPath(
                    'https://www.thesisforge.tech/?view=book&lang=${appLanguageCode(context.language)}',
                  )
                : connectIbkr,
            icon: const Icon(Icons.lock_outline, size: 17),
            label: Text(
              w(
                preview ? 'Sign in to connect IBKR' : 'Connect IBKR',
                preview ? '登录后连接 IBKR' : '连接 IBKR',
              ),
            ),
          ),
          TextButton(
            onPressed: () => openBrowserPath(
              'https://www.interactivebrokers.com/docs/web-api/flex-web-service/client-portal-configuration/enable-and-create-access-token',
            ),
            child: Text(w('Official setup guide ↗', '官方设置指南 ↗')),
          ),
        ],
      ),
    ]);
  }

  Future<void> connectIbkr() async {
    final connected = await showDialog<bool>(
      context: context,
      builder: (_) => PortfolioIbkrSetup(api: widget.api, palette: p),
    );
    if (mounted && connected == true) await load();
  }

  String decimal(dynamic v) =>
      nullableNumber(v) == null ? '—' : number(v).toStringAsFixed(2);

  Widget portfolioContext(Map<String, dynamic> g) {
    final l = asMap(g['leverage']), r = asMap(g['risk']);
    return pair(
      panel([
        title('Risk starts with the whole account', '先看清整个账户的风险'),
        const SizedBox(height: 18),
        valueRow('Broker net asset value', '券商净资产', amount(g['reportedNav'])),
        valueRow(
          'Gross exposure / NAV · mark basis',
          '总敞口 / 净资产 · 市值口径',
          '${decimal(l['grossToNav'])}×',
        ),
        valueRow('Borrowing / NAV', '负现金 / 净资产', percent(l['borrowingToNav'])),
        valueRow(
          'Short option positions',
          '卖出期权持仓数',
          '${l['shortOptions'] ?? '—'}',
        ),
        const SizedBox(height: 12),
        copy(
          number(l['shortOptions']) > 0
              ? 'Option market value is not the capital at risk. Stock-only shocks do not model assignment or nonlinear option losses.'
              : 'Exposure is measured at reported market values. Inspect cash and concentration before comparing returns.',
          number(l['shortOptions']) > 0
              ? '期权市值不等于风险本金；纯股票压力测试不包含指派和期权非线性损失。'
              : '敞口按报告市值计量。比较收益之前，先检查现金和集中度。',
          color: p.secondary,
        ),
      ]),
      panel([
        title('How sensitive are the covered holdings?', '已覆盖持仓对市场有多敏感？'),
        const SizedBox(height: 10),
        copy(
          'Current USD long-stock sleeve · retrospective simulation',
          '当前美元股票多头部分 · 历史模拟',
        ),
        const SizedBox(height: 18),
        valueRow(
          'Beta vs SPY · covered sleeve',
          '对 SPY 的 Beta · 覆盖部分',
          decimal(asMap(r['metrics'])['beta']),
        ),
        valueRow('Price-history coverage', '历史行情覆盖', percent(r['coverage'])),
        valueRow(
          'Common daily return observations',
          '共同日期收益样本',
          '${asMap(r['metrics'])['observations'] ?? 0}',
        ),
        const SizedBox(height: 12),
        copy(
          'Not your actual account performance. Cash, leverage, options and uncovered securities are outside this return series.',
          '不是账户真实业绩。这条收益曲线不包含现金、杠杆、期权和未覆盖证券。',
          size: 12,
        ),
        TextButton(
          onPressed: () => setState(() => tab = 'risk'),
          child: Text(
            w('Inspect risk and compare with SPY →', '查看风险并与 SPY 比较 →'),
          ),
        ),
      ]),
    );
  }

  Widget riskView(Map<String, dynamic> g) {
    final r = asMap(g['risk']),
        a = asMap(g['actualPerformance']),
        m = asMap(r['metrics']),
        b = asMap(r['benchmarkMetrics']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        benchmarkValue(g),
        const SizedBox(height: 18),
        panel([
          title(
            'Separate account performance from a holdings experiment',
            '区分真实账户业绩与持仓实验',
          ),
          const SizedBox(height: 10),
          copy(
            'Actual account: ${a['navPointCount'] ?? 0} NAV observations. Daily cash-flow-adjusted return history is not yet available, so actual-account Beta and Sharpe are not shown.',
            '真实账户：${a['navPointCount'] ?? 0} 个净值观测点。尚无可核验的每日剔除入出金收益序列，因此不展示账户真实 Beta 和 Sharpe。',
          ),
          const SizedBox(height: 14),
          tag(
            'Below: current holdings simulation · not actual P&L',
            '以下：当前持仓模拟 · 非实际损益',
            color: p.secondary,
          ),
        ]),
        const SizedBox(height: 18),
        panel([
          title('Covered holdings vs SPY', '已覆盖持仓与 SPY'),
          const SizedBox(height: 10),
          copy(
            '${r['start'] ?? '—'} → ${r['end'] ?? '—'} · ${percent(r['coverage'])} of positive non-cash report value',
            '${r['start'] ?? '—'} → ${r['end'] ?? '—'} · 覆盖报告正市值非现金资产 ${percent(r['coverage'])}',
          ),
          copy(
            'Daily-rebalanced current weights. Dividends adjusted. No fees, financing, option P&L or currency returns.',
            '按当前权重每日再平衡的模拟，使用股息调整行情；不含费用、融资、期权损益和汇率收益。',
            size: 12,
          ),
          const SizedBox(height: 16),
          if (r['status'] == 'ready') ...[
            PortfolioRiskChart(rows: asList(r['curve']), palette: p),
            const SizedBox(height: 18),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 36,
                columns: [
                  DataColumn(label: Text(w('Measure', '指标'))),
                  DataColumn(
                    label: Text(w('Covered sleeve', '已覆盖部分')),
                    numeric: true,
                  ),
                  const DataColumn(label: Text('SPY'), numeric: true),
                ],
                rows: [
                  for (final x in [
                    ('beta', 'Beta', 'Beta', false),
                    ('sharpe', 'Sharpe', 'Sharpe', false),
                    ('volatility', 'Annual volatility', '年化波动率', true),
                    ('maxDrawdown', 'Max drawdown', '最大回撤', true),
                    ('totalReturn', 'Simulated total return', '模拟累计收益', true),
                    ('trackingError', 'Tracking error', '跟踪误差', true),
                  ])
                    DataRow(
                      cells: [
                        DataCell(Text(w(x.$2, x.$3))),
                        DataCell(
                          Text(x.$4 ? percent(m[x.$1]) : decimal(m[x.$1])),
                        ),
                        DataCell(
                          Text(x.$4 ? percent(b[x.$1]) : decimal(b[x.$1])),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ] else
            copy(
              'The available history cannot support this comparison yet. Check the coverage list below.',
              '当前历史数据不足以完成比较，请检查下方覆盖列表。',
              color: p.secondary,
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              copy('Risk-free rate assumption', '无风险利率假设'),
              for (final rate in [0.0, .02, .04, .05])
                ChoiceChip(
                  label: Text('${(rate * 100).toStringAsFixed(0)}%'),
                  selected: riskFreeRate == rate,
                  onSelected: (_) {
                    setState(() => riskFreeRate = rate);
                    unawaited(load());
                  },
                ),
            ],
          ),
          copy(
            'Sharpe = √252 × mean(daily return − daily risk-free rate) / sample standard deviation. Beta uses covariance with SPY on exactly the same dates.',
            'Sharpe = √252 × 每日超额收益均值 / 样本标准差；Beta 使用完全相同日期与 SPY 收益的协方差。',
            size: 12,
          ),
        ]),
        const SizedBox(height: 18),
        pair(
          panel([
            title('What is included', '纳入了哪些持仓'),
            const SizedBox(height: 14),
            for (final x in asList(r['included']))
              valueRow(
                '${x['ticker']} · Beta ${decimal(x['beta'])}',
                '${x['ticker']} · Beta ${decimal(x['beta'])}',
                percent(x['weight']),
              ),
          ]),
          panel([
            title('What is outside the curve', '哪些风险不在曲线内'),
            const SizedBox(height: 14),
            for (final x in asList(r['excluded']))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: copy(
                  '${x['ticker']} · ${x['reason'] == 'incomplete_common_date_history' ? 'incomplete common-date history' : 'FX / option / short exposure'}',
                  '${x['ticker']} · ${x['reason'] == 'incomplete_common_date_history' ? '共同日期行情不全' : '外汇 / 期权 / 空头敞口'}',
                ),
              ),
            copy(
              'These positions are not assumed to have zero risk.',
              '这些持仓并非风险为零。',
              color: p.secondary,
            ),
          ]),
        ),
      ],
    );
  }

  Widget benchmarkValue(Map<String, dynamic> g) {
    final b = asMap(data?['benchmarkValuation']),
        v = asMap(g['benchmarkComparison']);
    return panel([
      title('Are your holdings cheaper than the market?', '你的持仓比市场便宜吗？'),
      const SizedBox(height: 10),
      copy(
        'Weighted model value / price − 1 · covered USD equities only',
        '加权模型估值 / 价格 − 1 · 仅覆盖美元股票',
      ),
      if (b['status'] != 'ready') ...[
        const SizedBox(height: 12),
        copy(
          'No SPY constituent-weight snapshot was available by this cutoff. Today’s weights are not inserted into the past.',
          '截止该日期尚无可用 SPY 成分权重快照，不会用今天的权重填入历史。',
        ),
      ] else ...[
        const SizedBox(height: 18),
        pair(
          metric(
            'Your covered USD equities',
            '你的已覆盖美元股票',
            percent(v['gap']),
            w(
              'Model coverage ${percent(v['coverage'])} · ${v['coveredCount']}/${v['totalCount']} positions',
              '模型覆盖 ${percent(v['coverage'])} · ${v['coveredCount']}/${v['totalCount']} 项',
            ),
            color: nullableNumber(v['gap']) == null
                ? p.muted
                : number(v['gap']) >= 0
                ? p.accent
                : p.negative,
          ),
          metric(
            'SPY covered constituents',
            'SPY 已覆盖成分股',
            percent(b['gap']),
            w(
              'Model coverage ${percent(b['coverage'])} · ${b['coveredCount']}/${b['totalCount']} securities',
              '模型覆盖 ${percent(b['coverage'])} · ${b['coveredCount']}/${b['totalCount']} 只',
            ),
            color: nullableNumber(b['gap']) == null
                ? p.muted
                : number(b['gap']) >= 0
                ? p.accent
                : p.negative,
          ),
        ),
        const SizedBox(height: 14),
        valueRow(
          'Difference · percentage points',
          '差异 · 百分点',
          nullableNumber(v['difference']) == null
              ? '—'
              : '${(number(v['difference']) * 100).toStringAsFixed(1)} pp',
        ),
        copy(
          'Both price and model cutoff: ${b['priceDate']}. Your weights: reported holdings ${asListDates(g['reportDates'])}. SPY weights: ${b['weightDate']}. Positive means model value exceeds price; it is not an expected return.',
          '价格与模型截止：${b['priceDate']}。你的权重来自 ${asListDates(g['reportDates'])} 报告；SPY 权重日期 ${b['weightDate']}。正数表示模型估值高于价格，不代表预期收益。',
          size: 12,
        ),
        copy(
          'Different coverage can change the comparison. Foreign-currency holdings and options are excluded. No share-price averages or guessed FX.',
          '覆盖范围不同会影响比较；外币持仓与期权不纳入。不会直接平均每股估值或猜测汇率。',
          size: 12,
          color: p.secondary,
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(w('Inspect constituents & gaps', '检查成分与缺口')),
          children: [
            for (final x in asList(v['covered']))
              valueRow(
                '${x['ticker']} · ${x['modelDate']}',
                '${x['ticker']} · ${x['modelDate']}',
                percent(x['gap']),
              ),
            for (final x in asList(v['excluded']))
              copy(
                '${x['ticker']} · ${x['reason']}',
                '${x['ticker']} · ${x['reason'] == 'no_dated_model' ? '缺少已发布模型' : '日期价格或币种未核验'}',
              ),
            TextButton(
              onPressed: () => openBrowserPath(text(b['source'])),
              child: Text(w('Official SPY holdings ↗', 'SPY 官方持仓 ↗')),
            ),
          ],
        ),
      ],
    ]);
  }

  Widget metric(
    String en,
    String zh,
    String value,
    String detail, {
    Color? color,
  }) => panel([
    copy(en, zh, size: 12),
    const SizedBox(height: 14),
    Text(value, style: heading(27).copyWith(color: color ?? p.text)),
    const SizedBox(height: 10),
    Text(detail, style: TextStyle(color: p.muted, fontSize: 12, height: 1.4)),
  ]);
  List<Widget> overview(Map<String, dynamic> g) {
    final coverage = asMap(g['coverage']), v = asMap(g['valuation']);
    final hasHome = asMap(g['home']).isNotEmpty;
    return [
      if (hasHome)
        portfolioOverviewMetrics(g)
      else
        LayoutBuilder(
          builder: (_, c) {
            final cols = c.maxWidth >= 1000
                ? 3
                : c.maxWidth >= 620
                ? 2
                : 1;
            final cards = [
              metric(
                'Reported holdings value',
                '报告持仓净值',
                amount(g['netValue']),
                w(
                  'Cash ${amount(g['cash'])} · ${g['unpriced']} unpriced rows',
                  '现金 ${amount(g['cash'])} · ${g['unpriced']} 项市值缺失',
                ),
              ),
              metric(
                'Model coverage',
                '模型覆盖',
                percent(coverage['weight']),
                w(
                  '${coverage['count']} / ${coverage['total']} known long positions by value',
                  '按市值覆盖 ${coverage['count']} / ${coverage['total']} 项已知多头',
                ),
                color: p.accent,
              ),
              metric(
                'Top 5 concentration',
                '前五大持仓集中度',
                percent(g['top5Weight']),
                w('Of known positive non-cash holdings', '占已知正市值非现金持仓'),
              ),
            ];
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: cards
                  .map(
                    (x) => SizedBox(
                      width: (c.maxWidth - 16 * (cols - 1)) / cols,
                      child: x,
                    ),
                  )
                  .toList(),
            );
          },
        ),
      const SizedBox(height: 18),
      if (hasHome) ...[
        portfolioVisualHero(g),
        const SizedBox(height: 18),
        pair(
          homeMovers(asMap(g['home']), asList(g['positions'])),
          valuationVisual(g),
        ),
        const SizedBox(height: 18),
      ],
      if (g['risk'] != null) ...[
        portfolioContext(g),
        const SizedBox(height: 18),
      ],
      pair(
        panel([
          title('What does valuation mean for the book?', '估值对整个组合意味着什么？'),
          const SizedBox(height: 10),
          copy(
            'Revalue covered equities; keep everything else at its reported mark.',
            '仅重估模型覆盖的股票，其他资产维持报告市值。',
          ),
          const SizedBox(height: 22),
          Wrap(
            spacing: 16,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                amount(v['delta']),
                style: heading(30).copyWith(
                  color: number(v['delta']) >= 0 ? p.accent : p.negative,
                ),
              ),
              tag(
                '${percent(v['netImpact'])} of net holdings',
                '${percent(v['netImpact'])} 占净持仓',
              ),
            ],
          ),
          const SizedBox(height: 18),
          valueRow('Covered market value', '已覆盖部分市值', amount(v['coveredMark'])),
          valueRow(
            'Covered model value',
            '已覆盖部分模型估值',
            amount(v['coveredModel']),
          ),
          valueRow('Covered model gap', '已覆盖部分估值价差', percent(v['gap'])),
          Divider(color: p.border),
          valueRow(
            'Revalued + marked remainder',
            '重估部分 + 其余报告市值',
            amount(v['markedRemainderValue']),
          ),
          const SizedBox(height: 12),
          copy(
            'Not a full-portfolio fair value or an expected return. Uncovered is not zero.',
            '不是完整组合内在价值或预期收益。未覆盖不代表价值为零。',
            size: 12,
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => tab = 'holdings'),
              child: Text(
                w('See each holding’s contribution →', '查看每项持仓的贡献 →'),
              ),
            ),
          ),
        ]),
        panel([
          title('Where is the portfolio concentrated?', '组合风险集中在哪里？'),
          const SizedBox(height: 8),
          copy(
            'Weights of known positive non-cash holdings.',
            '按已知正市值非现金持仓计算权重。',
            size: 12,
          ),
          const SizedBox(height: 18),
          if (!hasHome)
            PortfolioAllocationChart(
              hideAmounts: hideAmounts,
              group: g,
              palette: p,
              onHolding: (ticker) => widget.onCompany(
                portfolioValuationTicker(g, ticker),
                'value',
              ),
            )
          else ...[
            Text(percent(g['top5Weight']), style: heading(36)),
            const SizedBox(height: 6),
            copy('In your five largest holdings', '集中在前五大持仓', size: 12),
            const SizedBox(height: 18),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: LinearProgressIndicator(
                value: nullableNumber(g['top5Weight'])?.clamp(0, 1),
                minHeight: 10,
                color: p.accent,
                backgroundColor: p.border,
              ),
            ),
            const SizedBox(height: 20),
            valueRow(
              'Gross exposure / NAV · mark basis',
              '总敞口 / 净资产 · 市值口径',
              '${decimal(asMap(g['leverage'])['grossToNav'])}×',
            ),
            copy(
              'A concentrated book can move very differently from an index. Position market values are not option risk.',
              '集中持仓的表现可能明显偏离指数，期权市值不等于期权风险。',
              size: 12,
            ),
          ],
          const SizedBox(height: 12),
          valueRow(
            'Short positions · report marks',
            '空头 · 报告市值',
            amount(g['shortValue']),
          ),
          valueRow(
            'Other securities · report marks',
            '其他证券 · 报告市值',
            amount(g['otherValue']),
          ),
        ]),
      ),
      const SizedBox(height: 18),
      pair(
        panel([
          title('A downside rehearsal', '组合下行情景'),
          const SizedBox(height: 8),
          copy(
            'What if every long equity falls together? Other assets stay unchanged.',
            '如果所有股票多头同时下跌？其他资产保持不变。',
          ),
          const SizedBox(height: 16),
          for (final s in asList(g['stress']))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: copy(
                          'Equities ${percent(s['move'])}',
                          '股票 ${percent(s['move'])}',
                          color: p.text,
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              amount(s['pnl']),
                              style: heading(20).copyWith(color: p.negative),
                            ),
                            copy(
                              '${percent(s['netImpact'])} of net holdings value',
                              '占净持仓市值 ${percent(s['netImpact'])}',
                              size: 12,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  PortfolioDivergingBar(
                    value: nullableNumber(s['netImpact']),
                    extent: asList(g['stress']).fold<double>(
                      .1,
                      (max, row) =>
                          math.max(max, number(row['netImpact']).abs()),
                    ),
                    palette: p,
                  ),
                ],
              ),
            ),
          copy(
            'A uniform mark shock, not a probability. Does not model option Greeks, correlations or short squeezes.',
            '统一市值冲击，不附带发生概率；不模拟期权敏感度、相关性或轧空。',
            size: 12,
          ),
        ]),
        panel([
          title('Sector exposure', '行业敞口'),
          const SizedBox(height: 8),
          copy(
            'Current issuer classifications. Unknown sectors stay visible.',
            '当前发行人行业分类，未知行业不隐藏。',
            size: 12,
          ),
          const SizedBox(height: 16),
          for (final r in asList(g['sectors']).take(6))
            allocationRow(
              text(r['name']) == 'Unclassified'
                  ? w('Unclassified', '未分类')
                  : text(r['name']),
              number(r['weight']),
            ),
          if (asList(g['sectors']).isEmpty)
            copy('No classified exposure available.', '暂无可分类敞口。'),
        ]),
      ),
      const SizedBox(height: 18),
      panel([
        title('Your portfolio, next to the Gurus', '你的组合，与大佬放在一起看'),
        const SizedBox(height: 8),
        copy(
          'Shared positions are a starting point for research, not an endorsement.',
          '共同持仓是研究入口，不是投资背书。',
          size: 12,
        ),
        const SizedBox(height: 12),
        for (final c in asList(g['comparisons']).take(3))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: GuruAvatar(
              guru: {
                'id': c['guruId'],
                'name': c['name'],
                'avatarUrl': c['avatar'],
              },
              palette: p,
              size: 38,
            ),
            title: Text(text(c['name']), style: heading(16)),
            subtitle: copy(
              '${c['sharedCount']} shared holdings · Weight overlap ${percent(c['overlap'])}',
              '${c['sharedCount']} 项共同持仓 · 权重重合 ${percent(c['overlap'])}',
              size: 12,
            ),
            trailing: Icon(Icons.chevron_right, color: p.accent),
            onTap: () => setState(() {
              manager = text(c['guruId']);
              tab = 'gurus';
            }),
          ),
        if (asList(g['comparisons']).isEmpty)
          copy('No comparable disclosed book at the cutoff.', '截止日没有可比较的披露组合。'),
      ]),
      if (nullableNumber(g['reconciliation']) != null &&
          number(g['reconciliation']).abs() > 1) ...[
        const SizedBox(height: 18),
        panel([
          title('Reconciliation needs review', '需要核对的净值差额', 17),
          const SizedBox(height: 8),
          copy(
            'Holdings less broker-reported NAV: ${amount(g['reconciliation'])}. Fees, accruals or missing positions can explain a difference; they are not silently balanced.',
            '持仓合计减券商报告净值：${amount(g['reconciliation'])}。费用、应计项目或持仓缺失可能造成差异，不会自动抹平。',
          ),
        ]),
      ],
    ];
  }

  Widget valueRow(String en, String zh, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(child: copy(en, zh)),
        const SizedBox(width: 12),
        Text(
          value,
          style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
  Widget allocationRow(String name, double weight, {bool logo = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            if (logo) ...[
              StockLogo(ticker: name, palette: p, size: 26),
              const SizedBox(width: 8),
            ],
            Expanded(
              flex: 3,
              child: Text(
                name,
                style: TextStyle(color: p.text, fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: weight.clamp(0, 1),
                  minHeight: 6,
                  backgroundColor: p.border,
                  color: p.accent,
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 52,
              child: Text(
                percent(weight),
                textAlign: TextAlign.right,
                style: TextStyle(color: p.text, fontSize: 13),
              ),
            ),
          ],
        ),
      );

  String statusLabel(String status) => switch (status) {
    'covered' => w('Published model', '平台模型'),
    'outside_model_scope' => w('Outside equity model', '非股票多头模型范围'),
    'currency_mismatch' => w('Currency mismatch', '币种不匹配'),
    'units_or_fx_unverified' => w('Check units / FX', '核对股数 / 汇率'),
    'identity_unresolved' => w('Unresolved security', '证券身份待核对'),
    'report_date_missing' => w('Report date missing', '缺少报告日期'),
    _ => w('No model at cutoff', '截止日无模型'),
  };
  Widget holdings(Map<String, dynamic> g) {
    return portfolioHoldingsTable(g);
  }

  Widget holdingRow(Map<String, dynamic> r) {
    final model = asMap(r['model']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: p.border),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                StockLogo(ticker: text(r['ticker']), palette: p, size: 34),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(text(r['ticker']), style: heading(18)),
                      Text(
                        text(r['name']),
                        style: TextStyle(color: p.muted, fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Text(amount(r['value']), style: heading(18)),
              ],
            ),
            const SizedBox(height: 12),
            if (r['reportDate'] != null)
              copy(
                'Account ${hideAmounts ? '••••' : r['accountNumber']} · Report ${r['reportDate']}',
                '账户 ${hideAmounts ? '••••' : r['accountNumber']} · 报告 ${r['reportDate']}',
                size: 12,
              ),
            Wrap(
              spacing: 22,
              runSpacing: 12,
              children: [
                smallMetric(
                  'Units',
                  '股数',
                  hideAmounts
                      ? '••••'
                      : nullableNumber(r['quantity']) == null
                      ? '—'
                      : formatNumber(number(r['quantity'])),
                ),
                smallMetric('Net weight', '净持仓权重', percent(r['netWeight'])),
                smallMetric(
                  'Report price',
                  '报告价格',
                  amount(r['price'], text(r['currency'])),
                ),
                smallMetric(
                  'Published value',
                  '平台估值',
                  amount(model['fairValue'], text(model['currency'])),
                ),
                smallMetric('Model gap', '估值价差', percent(r['modelGap'])),
                smallMetric(
                  'Net-value impact',
                  '净持仓影响',
                  percent(r['contribution']),
                ),
              ],
            ),
            const SizedBox(height: 10),
            portfolioGuruEvidence(r),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  statusLabel(text(r['modelStatus'])),
                  style: TextStyle(
                    color: r['modelStatus'] == 'covered'
                        ? p.accent
                        : p.secondary,
                    fontSize: 12,
                  ),
                ),
                if (model['date'] != null)
                  copy(
                    'Model ${model['date']}',
                    '模型 ${model['date']}',
                    size: 12,
                  ),
                if (r['kind'] == 'equity')
                  TextButton(
                    onPressed: () =>
                        widget.onCompany(text(r['ticker']), 'overview'),
                    child: Text(w('Research →', '研究 →')),
                  ),
                if (r['modelStatus'] == 'covered')
                  TextButton(
                    onPressed: () => widget.onCompany(
                      text(model['modelTicker'] ?? r['ticker']),
                      'value',
                    ),
                    child: Text(w('Test my valuation →', '检验我的估值 →')),
                  ),
              ],
            ),
            if (model['modelTicker'] != null)
              copy(
                'Uses the ${model['modelTicker']} economic per-share model with this holding’s own price. Voting-rights differences are not valued.',
                '使用 ${model['modelTicker']} 每股经济价值模型，价格仍为本持仓自身价格；未对投票权差异单独估值。',
                size: 12,
              ),
          ],
        ),
      ),
    );
  }

  Widget smallMetric(String en, String zh, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      copy(en, zh, size: 11),
      const SizedBox(height: 4),
      Text(
        value,
        style: TextStyle(
          color: p.text,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );

  Widget gurus(Map<String, dynamic> g) {
    final comparisons = asList(g['comparisons']);
    final selected =
        comparisons.where((r) => r['guruId'] == manager).firstOrNull ??
        comparisons.firstOrNull;
    return panel([
      title('How different is your portfolio?', '你的组合与大佬有何不同？'),
      const SizedBox(height: 10),
      copy(
        'Compare long-equity allocations, then investigate the differences. This is not a copy-trading signal.',
        '对比股票多头配置，再研究差异，不是跟单信号。',
      ),
      const SizedBox(height: 18),
      if (selected == null)
        copy('No Guru filings available at this cutoff.', '截止日没有可用的大佬披露。')
      else ...[
        DropdownButtonFormField<String>(
          key: ValueKey(
            'portfolio-manager-${selected['guruId']}-$selectedCurrency-${widget.asOf}',
          ),
          initialValue: text(selected['guruId']),
          isExpanded: true,
          decoration: InputDecoration(labelText: w('Compare with', '对比对象')),
          items: comparisons
              .map(
                (r) => DropdownMenuItem(
                  value: text(r['guruId']),
                  child: Row(
                    children: [
                      GuruAvatar(
                        guru: {
                          'id': r['guruId'],
                          'name': r['name'],
                          'avatarUrl': r['avatar'],
                        },
                        palette: p,
                        size: 28,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          text(r['name']),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
          onChanged: (v) => setState(() {
            manager = v ?? '';
            comparisonLimit = 20;
          }),
        ),
        const SizedBox(height: 14),
        copy(
          'Positions ${selected['reportDate']} · Public ${selected['availableAt']}',
          '持仓日期 ${selected['reportDate']} · 公开日期 ${selected['availableAt']}',
          size: 12,
        ),
        if (selected['complete'] != true) ...[
          const SizedBox(height: 10),
          tag(
            'Historical extract only · full-book overlap unavailable',
            '仅有历史摘录 · 无完整组合重合率',
            color: p.secondary,
          ),
        ],
        const SizedBox(height: 20),
        Wrap(
          spacing: 30,
          runSpacing: 14,
          children: [
            smallMetric(
              'Shared holdings',
              '共同持仓',
              '${selected['sharedCount']}',
            ),
            smallMetric(
              'Your weight in shared names',
              '你持有共同股票的权重',
              percent(selected['sharedUserWeight']),
            ),
            smallMetric(
              'Weight overlap · Σ min',
              '权重重合 · Σ 最小权重',
              percent(selected['overlap']),
            ),
          ],
        ),
        const SizedBox(height: 12),
        copy(
          'Your denominator: priced long equities. Guru denominator: the complete disclosed common-long book. Missing historical holdings are not assumed absent.',
          '你的分母：可计价股票多头。大佬分母：完整披露普通股多头。不会把历史摘录里未出现的股票视为零持仓。',
          size: 12,
        ),
        const SizedBox(height: 18),
        for (final r in asList(selected['differences']).take(comparisonLimit))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              children: [
                StockLogo(ticker: text(r['ticker']), palette: p, size: 28),
                const SizedBox(width: 10),
                Expanded(child: Text(text(r['ticker']), style: heading(15))),
                Expanded(
                  child: smallMetric('Yours', '你', percent(r['userWeight'])),
                ),
                Expanded(
                  child: smallMetric('Guru', '大佬', percent(r['guruWeight'])),
                ),
                Expanded(
                  child: smallMetric(
                    'Difference',
                    '差异',
                    percent(r['difference']),
                  ),
                ),
                IconButton(
                  tooltip: w('Research ${r['ticker']}', '研究 ${r['ticker']}'),
                  onPressed: () =>
                      widget.onCompany(text(r['ticker']), 'overview'),
                  icon: Icon(Icons.chevron_right, color: p.accent),
                ),
              ],
            ),
          ),
        if (asList(selected['differences']).length > comparisonLimit)
          TextButton(
            onPressed: () => setState(() => comparisonLimit += 20),
            child: Text(w('Show 20 more differences', '再显示 20 项差异')),
          ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: () => widget.onGuru(
              text(selected['guruId']),
              text(selected['accession']),
            ),
            child: Text(w('Open manager’s quarterly holdings →', '查看大佬季度持仓 →')),
          ),
        ),
      ],
    ]);
  }
}
