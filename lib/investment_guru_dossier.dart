part of 'main.dart';

class GuruResearchDossier extends StatefulWidget {
  const GuruResearchDossier({
    super.key,
    required this.detail,
    required this.selectedQuarter,
    required this.selectedHolding,
    required this.trajectoryMetric,
    required this.asOf,
    required this.palette,
    required this.onBack,
    required this.onSelectQuarter,
    required this.onSelectHolding,
    required this.onSelectTrajectoryMetric,
    required this.onResearchCompany,
    required this.onOpenTerminal,
    this.onFollow,
  });

  final Map<String, dynamic> detail;
  final String selectedQuarter;
  final String selectedHolding;
  final String trajectoryMetric;
  final String asOf;
  final Palette palette;
  final VoidCallback onBack;
  final ValueChanged<String> onSelectQuarter;
  final ValueChanged<String> onSelectHolding;
  final ValueChanged<String> onSelectTrajectoryMetric;
  final void Function(String ticker, Map<String, dynamic> evidence)
  onResearchCompany;
  final VoidCallback onOpenTerminal;
  final VoidCallback? onFollow;

  @override
  State<GuruResearchDossier> createState() => _GuruResearchDossierState();
}

class _GuruResearchDossierState extends State<GuruResearchDossier> {
  String btWindow = '5Y';
  String btRightTab = 'contributors';
  int? hoveredCurveIndex;
  bool showAllHoldings = false;

  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);

  String fmtPct(dynamic v, {bool signed = false, int digits = 1}) {
    final n = nullableNumber(v);
    if (n == null || !n.isFinite) return '—';
    final prefix = signed && n > 0 ? '+' : '';
    return '$prefix${(n * 100).toStringAsFixed(digits)}%';
  }

  String fmtCompactUsd(dynamic v, {bool signed = false}) {
    final n = nullableNumber(v);
    if (n == null || !n.isFinite) return '—';
    final prefix = n < 0 ? '-' : (signed && n > 0 ? '+' : '');
    final abs = n.abs();
    if (abs >= 1e9) return '$prefix\$${(abs / 1e9).toStringAsFixed(2)}B';
    if (abs >= 1e6) return '$prefix\$${(abs / 1e6).toStringAsFixed(1)}M';
    if (abs >= 1e3) return '$prefix\$${(abs / 1e3).toStringAsFixed(0)}K';
    return '$prefix\$${abs.toStringAsFixed(0)}';
  }

  Map<String, dynamic> get guru => asMap(widget.detail['guru']);
  List<Map<String, dynamic>> get history => asList(widget.detail['history']);
  Map<String, dynamic> get styleProfile => asMap(widget.detail['styleProfile']);
  Map<String, dynamic> get backtest => asMap(widget.detail['backtest']);

  Map<String, dynamic> get filing =>
      history
          .where((h) => h['accessionNumber'] == widget.selectedQuarter)
          .firstOrNull ??
      asMap(widget.detail['latest']);

  Widget _panel(
    List<Widget> children, {
    EdgeInsets padding = const EdgeInsets.all(18),
    Key? key,
    Color? borderColor,
  }) => Container(
    key: key,
    margin: const EdgeInsets.only(bottom: 16),
    padding: padding,
    decoration: BoxDecoration(
      color: p.panel,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: borderColor ?? p.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  String _concentrationLabel(String tier) => switch (tier) {
    'ultra_concentrated' => w('Ultra-concentrated', '极致集中型'),
    'concentrated' => w('High-conviction concentrated', '核心集中型'),
    'diversified_systematic' => w('Broad systematic', '广泛分散 / 量化'),
    _ => w('Balanced portfolio', '均衡配置型'),
  };

  String _turnoverLabel(String tier) => switch (tier) {
    'low_turnover' => w('Low-turnover compounder', '低换手长线复利'),
    'moderate_turnover' => w('Moderate rebalancing', '中频均衡调仓'),
    'active_rotation' => w('Active tactical rotation', '高频主动轮动'),
    _ => w('13F institutional filer', '13F 申报机构'),
  };

  Color _actionColor(String? action) => switch (action) {
    'new' || 'increased' => const Color(0xFF20C997),
    'reduced' => const Color(0xFFF5A623),
    'sold_out' => p.negative,
    _ => p.muted,
  };

  String _actionText(String? action) => switch (action) {
    'new' => w('New', '新建仓'),
    'increased' => w('Added', '加仓'),
    'reduced' => w('Trimmed', '减仓'),
    'sold_out' => w('Exited', '清仓'),
    'unchanged' => w('Unchanged', '持仓未变'),
    _ => w('Held', '持有'),
  };

  @override
  Widget build(BuildContext context) {
    final f = filing;
    final sourceError = f['status'] == 'source_error';
    final comparisonError = f['comparisonStatus'] == 'previous_source_error';
    final errorCodes = f['sourceErrorCodes'] is List
        ? f['sourceErrorCodes'] as List
        : const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTopNav(),
        const SizedBox(height: 8),
        _buildIdentityBanner(f, sourceError),
        _buildQuarterMetricsBar(f, sourceError, comparisonError),
        if (sourceError || comparisonError)
          _buildErrorNotice(f, sourceError, errorCodes),
        if (!sourceError) ...[
          _buildSystematicInsights(f, comparisonError),
          if (backtest['status'] == 'ready') _buildBacktestSection(),
          if (!comparisonError) _buildKeyMovesAndScaleSection(f),
          if (comparisonError) _buildBookScaleAndSectorsOnly(f),
          _buildHoldingsAndTrajectorySection(f, comparisonError),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Text(
            w(
              'Form 13F discloses U.S. long-equity positions with up to a 45-day lag and omits shorts, cash, non-U.S. shares, and intra-quarter trades. Share changes require corporate-action verification and do not establish live trading intent.',
              'Form 13F 仅披露美股多头持仓（最长滞后 45 天），不含空头、现金、非美股及季内交易。申报股数变化可能受拆合股等公司行动影响，不构成实时交易信号。',
            ),
            style: TextStyle(color: p.muted, fontSize: 11.5, height: 1.4),
          ),
        ),
      ],
    );
  }

  Widget _buildTopNav() => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 12,
    runSpacing: 8,
    children: [
      TextButton.icon(
        onPressed: widget.onBack,
        icon: const Icon(Icons.arrow_back, size: 18),
        label: Text(w('All managers', '全部经理')),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (widget.onFollow != null)
            OutlinedButton.icon(
              onPressed: widget.onFollow,
              icon: Icon(
                guru['followed'] == true ? Icons.check : Icons.add,
                size: 16,
              ),
              label: Text(
                guru['followed'] == true
                    ? w('Following', '已关注')
                    : w('Follow', '关注'),
              ),
            ),
          OutlinedButton.icon(
            onPressed: widget.onOpenTerminal,
            icon: Icon(Icons.science_outlined, size: 16, color: p.accent),
            label: Text(
              w('Open full backtest terminal', '打开完整回测终端'),
              style: TextStyle(color: p.accent, fontSize: 12.5),
            ),
          ),
        ],
      ),
    ],
  );

  Widget _buildIdentityBanner(Map<String, dynamic> f, bool sourceError) {
    final structure = asMap(guru['capitalStructure']);
    final capLabel = w(
      text(structure['label'], ''),
      text(structure['labelZh'], ''),
    );
    final concTier = text(styleProfile['concentrationTier']);
    final turnTier = text(styleProfile['turnoverTier']);
    final avgTurnover = nullableNumber(styleProfile['avgQuarterlyTurnover']);
    final top5 = nullableNumber(f['top5Weight']) ??
        nullableNumber(styleProfile['latestTop5Weight']);
    final roleText = text(guru['role']);
    final thesisTag = text(guru['thesisTag']);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          GuruAvatar(
            guru: {...guru, 'avatarUrl': guru['avatar']},
            palette: p,
            size: 62,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      text(guru['name']),
                      style: TextStyle(
                        color: p.text,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                    if (text(guru['chineseName']).isNotEmpty &&
                        LanguageScope.of(context) == AppLanguage.zh)
                      Text(
                        '(${text(guru['chineseName'])})',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    text(guru['entityName']),
                    if (roleText.isNotEmpty &&
                        roleText != text(guru['entityName']))
                      roleText,
                    if (thesisTag.isNotEmpty) thesisTag,
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(color: p.muted, fontSize: 13),
                ),
                if (!sourceError) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (capLabel.isNotEmpty)
                        _dnaPill(Icons.account_balance_outlined, capLabel, p.accent),
                      if (concTier.isNotEmpty)
                        _dnaPill(
                          Icons.pie_chart_outline,
                          top5 != null
                              ? '${_concentrationLabel(concTier)} · Top5 ${fmtPct(top5, digits: 1)}'
                              : _concentrationLabel(concTier),
                          const Color(0xFF20C997),
                        ),
                      if (turnTier.isNotEmpty && turnTier != 'unclassified')
                        _dnaPill(
                          Icons.autorenew,
                          avgTurnover != null
                              ? '${_turnoverLabel(turnTier)} · ${w('Qtr turnover', '季换手')} ${fmtPct(avgTurnover, digits: 1)}'
                              : _turnoverLabel(turnTier),
                          const Color(0xFFF5A623),
                        ),
                      _dnaPill(
                        Icons.history_edu_outlined,
                        w(
                          '${history.length} filings tracked',
                          '已追踪 ${history.length} 个季度',
                        ),
                        p.muted,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dnaPill(IconData icon, String label, Color tint) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: tint.withValues(alpha: .11),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: tint.withValues(alpha: .32)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: tint),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tint == p.muted ? p.text : tint,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildQuarterMetricsBar(
    Map<String, dynamic> f,
    bool sourceError,
    bool comparisonError,
  ) {
    final val = nullableNumber(f['reported13fValue']);
    final valDelta = nullableNumber(f['valueChange']);
    final valDeltaPct = nullableNumber(f['valueChangePct']);
    final top5 = nullableNumber(f['top5Weight']);
    final hhi = nullableNumber(f['concentrationHhi']);
    final mc = asMap(f['moveCounts']);
    final hasMoves = !sourceError && !comparisonError && mc.isNotEmpty;

    Widget kpi(String labelEn, String labelZh, String mainVal, {String? sub, Color? subColor}) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              w(labelEn, labelZh),
              style: TextStyle(color: p.muted, fontSize: 11.5),
            ),
            const SizedBox(height: 3),
            Text(
              mainVal,
              style: TextStyle(
                color: p.text,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -.3,
              ),
            ),
            if (sub != null && sub.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                sub,
                style: TextStyle(
                  color: subColor ?? p.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        );

    final validQuarterValue = history.any(
      (h) => text(h['accessionNumber']) == widget.selectedQuarter,
    )
        ? widget.selectedQuarter
        : (history.isNotEmpty ? text(history.last['accessionNumber']) : null);

    return _panel([
      Wrap(
        spacing: 26,
        runSpacing: 14,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (history.isNotEmpty)
            SizedBox(
              width: 225,
              child: DropdownButtonFormField<String>(
                key: ValueKey('filing-${widget.selectedQuarter}'),
                initialValue: validQuarterValue,
                isExpanded: true,
                dropdownColor: p.panel,
                decoration: InputDecoration(
                  labelText: w('Reported quarter', '申报季度'),
                  isDense: true,
                ),
                items: history.reversed
                    .map(
                      (h) => DropdownMenuItem(
                        value: text(h['accessionNumber']),
                        child: Text(
                          '${h['quarterLabel']} · ${h['filingDate']}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) widget.onSelectQuarter(v);
                },
              ),
            ),
          kpi(
            'Reported 13F value',
            '13F 信息表价值',
            sourceError || val == null ? '—' : fmtCompactUsd(val),
            sub: !sourceError && valDelta != null
                ? '${w('QoQ', '环比')} ${fmtCompactUsd(valDelta, signed: true)}${valDeltaPct != null ? ' (${fmtPct(valDeltaPct, signed: true)})' : ''}'
                : null,
            subColor: valDelta == null
                ? null
                : (valDelta >= 0 ? const Color(0xFF20C997) : p.negative),
          ),
          kpi(
            'Reported positions',
            '申报持仓数',
            sourceError ? '—' : text(f['positionCount'], '—'),
            sub: !sourceError && f['bookScope'] == 'full_book'
                ? w('Complete 13F book', '完整 13F 持仓表')
                : (!sourceError ? w('Reported extract', '主要持仓摘录') : null),
          ),
          if (!sourceError && top5 != null)
            kpi(
              'Top 5 concentration',
              '前五大重仓集中度',
              fmtPct(top5, digits: 1),
              sub: hhi != null ? 'HHI ${hhi.toStringAsFixed(3)}' : null,
            ),
          if (hasMoves)
            kpi(
              'Quarter operations',
              '本季调仓动作',
              '${number(mc['newPositions']).round() + number(mc['increasedPositions']).round()} ${w('Buy', '加/新')} · ${number(mc['reducedPositions']).round() + number(mc['soldOutPositions']).round()} ${w('Sell', '减/清')}',
              sub: w(
                '${number(mc['newPositions']).round()} new · ${number(mc['increasedPositions']).round()} add · ${number(mc['reducedPositions']).round()} trim · ${number(mc['soldOutPositions']).round()} exit',
                '${number(mc['newPositions']).round()} 新建 · ${number(mc['increasedPositions']).round()} 加仓 · ${number(mc['reducedPositions']).round()} 减仓 · ${number(mc['soldOutPositions']).round()} 清仓',
              ),
            ),
          kpi(
            'Public filing date',
            '公开披露日期',
            text(f['filingDate'], '—'),
            sub: w(
              'Period end ${text(f['reportDate'], '—')}',
              '报告期末 ${text(f['reportDate'], '—')}',
            ),
          ),
        ],
      ),
    ]);
  }

  Widget _buildErrorNotice(
    Map<String, dynamic> f,
    bool sourceError,
    List errorCodes,
  ) => _panel(
    borderColor: p.secondary.withValues(alpha: .55),
    [
      Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: p.secondary, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              sourceError
                  ? w('This filing needs source review', '这份申报需要核查来源')
                  : w('Quarterly changes are unavailable', '本季度仓位变化暂不可用'),
              style: TextStyle(
                color: p.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        !sourceError
            ? w(
                'The current holdings are available, but the previous quarter has a source error. New, added, reduced and exited positions are not inferred.',
                '当期持仓可查看，但上一季度存在来源错误，因此不推断新建、加仓、减仓或清仓。',
              )
            : errorCodes.contains('reported_value_error')
            ? w(
                'The original filing contains an inconsistent reported value. Holdings, amounts and position history for this quarter are withheld pending source review.',
                '原始申报的市值存在不一致。本季度的持仓、金额和仓位轨迹暂不展示，待核查来源。',
              )
            : errorCodes.contains('invalid_13f_identifier')
            ? w(
                'The original filing contains invalid security identifiers. Holdings, amounts and position history for this quarter are withheld pending source review.',
                '原始申报包含无效的证券标识。本季度的持仓、金额和仓位轨迹暂不展示，待核查来源。',
              )
            : w(
                'The source filing cannot be verified. Holdings, amounts and position history for this quarter are withheld pending source review.',
                '原始申报暂无法核实。本季度的持仓、金额和仓位轨迹暂不展示，待核查来源。',
              ),
        style: TextStyle(color: p.muted, fontSize: 13, height: 1.4),
      ),
      if (sourceError) ...[
        const SizedBox(height: 6),
        Text(
          w(
            'This is a data gap, not an empty portfolio or an exit. Choose another reported quarter above.',
            '这是数据缺口，不代表空仓或清仓。可在上方选择其他申报季度。',
          ),
          style: TextStyle(color: p.muted, fontSize: 12.5),
        ),
      ],
      const SizedBox(height: 6),
      Text(
        w(
          'Report ${text(f['reportDate'])} · Filing ${text(f['accessionNumber'])}',
          '报告期 ${text(f['reportDate'])} · 申报编号 ${text(f['accessionNumber'])}',
        ),
        style: TextStyle(color: p.muted, fontSize: 11.5),
      ),
    ],
  );

  Widget _buildSystematicInsights(
    Map<String, dynamic> f,
    bool comparisonError,
  ) {
    final holdings = asList(f['topHoldings']);
    final buys = asList(f['keyBuys']);
    final sells = asList(f['keySells']);
    final mc = asMap(f['moveCounts']);
    final windows = asMap(backtest['windows']);
    final w10 = asMap(windows['10Y']);
    final w5 = asMap(windows['5Y']);

    final bullets = <(IconData, Color, String)>[];

    // 1. Portfolio Anchor & Concentration Insight
    if (holdings.isNotEmpty) {
      final top3 = holdings.take(3).toList();
      final top3Sum = top3.fold<double>(
        0,
        (s, h) => s + (nullableNumber(h['pctPortfolio']) ?? 0),
      );
      final names = top3
          .map(
            (h) =>
                '${text(h['ticker'])} (${fmtPct(h['pctPortfolio'], digits: 1)})',
          )
          .join('、');
      bullets.add((
        Icons.workspace_premium_outlined,
        p.accent,
        w(
          'Core Anchor: Top ${top3.length} positions — $names — represent ${fmtPct(top3Sum, digits: 1)} of the disclosed book (${text(f['positionCount'], '${holdings.length}')} total positions).',
          '核心重仓锚定：前 ${top3.length} 大持仓 $names 合计占披露组合 ${fmtPct(top3Sum, digits: 1)}（共 ${text(f['positionCount'], '${holdings.length}')} 只持仓）。',
        ),
      ));
    }

    // 2. Key Quarter Directional Move Insight
    if (!comparisonError && (buys.isNotEmpty || sells.isNotEmpty || mc.isNotEmpty)) {
      final addN =
          number(mc['newPositions']).round() +
          number(mc['increasedPositions']).round();
      final trimN =
          number(mc['reducedPositions']).round() +
          number(mc['soldOutPositions']).round();
      final leadBuy = buys.firstOrNull;
      final leadSell = sells.firstOrNull;

      String moveEn, moveZh;
      if (addN == 0 && trimN == 0) {
        moveEn =
            '${text(f['quarterLabel'], text(f['reportDate']))} Discipline: Zero reported share changes across the entire disclosed book.';
        moveZh =
            '${text(f['quarterLabel'], text(f['reportDate']))} 调仓定性：当季全部持仓股数保持不变，零调仓锁仓持有。';
      } else if (addN > trimN && leadBuy != null) {
        moveEn =
            '${text(f['quarterLabel'])} Net Accumulation ($addN buys vs $trimN sells): Led by ${_actionText(text(leadBuy['action']))} in ${leadBuy['ticker']} (${leadBuy['changePct'] != null ? fmtPct(leadBuy['changePct'], signed: true) : fmtCompactUsd(leadBuy['value'])}, now ${fmtPct(leadBuy['weight'])} of book).';
        moveZh =
            '${text(f['quarterLabel'])} 偏向积极加仓（$addN 加/新 vs $trimN 减/清）：核心动作为 ${_actionText(text(leadBuy['action']))} ${leadBuy['ticker']}（${leadBuy['changePct'] != null ? '股数 ${fmtPct(leadBuy['changePct'], signed: true)}' : fmtCompactUsd(leadBuy['value'])}，现占组合 ${fmtPct(leadBuy['weight'])}）。';
      } else if (trimN > addN && leadSell != null) {
        moveEn =
            '${text(f['quarterLabel'])} Profit-Taking / Trimming ($trimN sells vs $addN buys): Largest reduction in ${leadSell['ticker']} (${leadSell['changePct'] != null ? fmtPct(leadSell['changePct'], signed: true) : _actionText(text(leadSell['action']))}${leadSell['valueChange'] != null ? ', ${fmtCompactUsd(leadSell['valueChange'], signed: true)}' : ''}).';
        moveZh =
            '${text(f['quarterLabel'])} 偏向兑现收缩（$trimN 减/清 vs $addN 加/新）：最大减持动作为 ${leadSell['ticker']}（${leadSell['changePct'] != null ? '股数 ${fmtPct(leadSell['changePct'], signed: true)}' : _actionText(text(leadSell['action']))}${leadSell['valueChange'] != null ? '，市值变动 ${fmtCompactUsd(leadSell['valueChange'], signed: true)}' : ''}）。';
      } else {
        moveEn =
            '${text(f['quarterLabel'])} Portfolio Rotation ($addN buys / $trimN sells): Added ${leadBuy?['ticker'] ?? '—'} while trimming ${leadSell?['ticker'] ?? '—'}.';
        moveZh =
            '${text(f['quarterLabel'])} 结构性换仓（$addN 加/新 vs $trimN 减/清）：重点增配 ${leadBuy?['ticker'] ?? '—'}，同时缩减 ${leadSell?['ticker'] ?? '—'}。';
      }
      bullets.add((
        addN >= trimN ? Icons.trending_up : Icons.tune_rounded,
        addN >= trimN ? const Color(0xFF20C997) : const Color(0xFFF5A623),
        w(moveEn, moveZh),
      ));
    }

    // 3. Backtest Regime & Long-Term Alpha Insight
    if (w10.isNotEmpty || w5.isNotEmpty) {
      final primary = w10.isNotEmpty ? w10 : w5;
      final label = w10.isNotEmpty ? '10Y' : '5Y';
      final cagr = nullableNumber(primary['cagr']);
      final exCagr = nullableNumber(primary['excessCagr']);
      final topWinner = asList(
        asMap(primary['attribution'])['topContributors'],
      ).firstOrNull;
      if (cagr != null && exCagr != null) {
        final otherNote = w10.isNotEmpty && w5.isNotEmpty
            ? w(
                ' (5Y CAGR: ${fmtPct(w5['cagr'])}, excess ${fmtPct(w5['excessCagr'], signed: true)})',
                '（近 5 年年化 ${fmtPct(w5['cagr'])}，超额 ${fmtPct(w5['excessCagr'], signed: true)}）',
              )
            : '';
        final winnerNote = topWinner != null
            ? w(
                '; #1 cumulative driver: ${topWinner['ticker']} (${fmtPct(topWinner['totalContributionPct'], signed: true)} contribution).',
                '；头号累计收益功臣为 ${topWinner['ticker']}（累计贡献 ${fmtPct(topWinner['totalContributionPct'], signed: true)}）。',
              )
            : '.';
        bullets.add((
          Icons.show_chart_rounded,
          exCagr >= 0 ? const Color(0xFF20C997) : p.secondary,
          w(
            '$label Audited 13F Simulation: ${fmtPct(cagr)} annualized return (${fmtPct(exCagr, signed: true)}/yr vs SPY)$otherNote$winnerNote',
            '$label 13F 跟踪回测表现：年化复合收益 ${fmtPct(cagr)}（对比 SPY 年化超额 ${fmtPct(exCagr, signed: true)}）$otherNote$winnerNote',
          ),
        ));
      }
    }

    // 4. Current Valuation Safety-Margin Insight
    final modeled = holdings
        .where((h) => nullableNumber(h['modelGap']) != null)
        .toList();
    if (modeled.isNotEmpty) {
      modeled.sort(
        (a, b) => number(b['modelGap']).compareTo(number(a['modelGap'])),
      );
      final cheapest = modeled.first;
      final richest = modeled.last;
      final cheapGap = number(cheapest['modelGap']);
      bullets.add((
        Icons.balance_outlined,
        cheapGap >= 0 ? const Color(0xFF20C997) : p.muted,
        w(
          'Valuation Lens (as of ${widget.asOf}): Among ${modeled.length} modeled holdings, ${cheapest['ticker']} has the highest model/price gap (${fmtPct(cheapGap, signed: true)})${modeled.length > 1 ? ', while ${richest['ticker']} is at ${fmtPct(richest['modelGap'], signed: true)}.' : '.'}',
          '当前估值透视（截至 ${widget.asOf}）：在已覆盖模型的 ${modeled.length} 只持仓中，${cheapest['ticker']} 模型估值安全边际相对最高（${fmtPct(cheapGap, signed: true)}）${modeled.length > 1 ? '，${richest['ticker']} 为 ${fmtPct(richest['modelGap'], signed: true)}。' : '。'}',
        ),
      ));
    }

    if (bullets.isEmpty) return const SizedBox.shrink();

    return _panel(
      key: const ValueKey('guru-systematic-insights'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      borderColor: p.accent.withValues(alpha: .30),
      [
        Row(
          children: [
            Icon(Icons.auto_awesome_outlined, size: 17, color: p.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                w('Systematic Dossier Insights', '系统化核心投研洞察'),
                style: TextStyle(
                  color: p.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < bullets.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(bullets[i].$1, size: 15, color: bullets[i].$2),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  bullets[i].$3,
                  style: TextStyle(color: p.text, fontSize: 12.5, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildBacktestSection() {
    final windows = asMap(backtest['windows']);
    final availableKeys = [
      for (final k in ['1Y', '3Y', '5Y', '10Y'])
        if (asMap(windows[k]).isNotEmpty) k,
    ];
    if (availableKeys.isEmpty) return const SizedBox.shrink();
    final activeKey = availableKeys.contains(btWindow)
        ? btWindow
        : (availableKeys.contains('5Y') ? '5Y' : availableKeys.last);
    final win = asMap(windows[activeKey]);
    final curve = asList(win['curve']);
    final attr = asMap(win['attribution']);
    final isProxy = win['kind'] == 'proxy' || win['status'] == 'proxy_ready';

    final totalRet = nullableNumber(win['totalReturn']);
    final benchRet = nullableNumber(win['benchmarkTotalReturn']);
    final cagr = nullableNumber(win['cagr']);
    final benchCagr = nullableNumber(win['benchmarkCagr']);
    final exCagr = nullableNumber(win['excessCagr']);
    final sharpe = nullableNumber(win['sharpe']);
    final mdd = nullableNumber(win['maxDrawdown']);
    final benchMdd = nullableNumber(win['benchmarkMaxDrawdown']);
    final winQ = nullableNumber(attr['winQuarters'])?.round();
    final totalQ = nullableNumber(attr['totalQuarters'])?.round();
    final winRate = nullableNumber(attr['quarterlyWinRate']);

    final activePtIdx = curve.isEmpty
        ? null
        : (hoveredCurveIndex ?? (curve.length - 1)).clamp(0, curve.length - 1);
    final activePt = activePtIdx != null ? curve[activePtIdx] : null;

    return _panel(
      key: const ValueKey('guru-dossier-backtest'),
      [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.query_stats, size: 18, color: const Color(0xFF20C997)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        w(
                          '13F Copy-Simulation Backtest & Attribution (vs SPY)',
                          '13F 披露跟踪回测走势与超额归因（基准 SPY）',
                        ),
                        style: TextStyle(
                          color: p.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  w(
                    'Executed strictly on first market session after public SEC 13F acceptance · ${text(win['startDate'])} → ${text(win['endDate'])}${isProxy ? ' · Top-60 public-sleeve proxy' : ''}',
                    '严格按 SEC 13F 公开披露后首个交易日收盘调仓回测 · ${text(win['startDate'])} → ${text(win['endDate'])}${isProxy ? ' · 公开多头代理口径' : ''}',
                  ),
                  style: TextStyle(color: p.muted, fontSize: 11.5),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final k in availableKeys)
                  ChoiceChip(
                    key: ValueKey('guru-bt-window-$k'),
                    label: Text(k, style: const TextStyle(fontSize: 12)),
                    selected: activeKey == k,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() {
                      btWindow = k;
                      hoveredCurveIndex = null;
                    }),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (_, c) {
            final cols = c.maxWidth >= 920
                ? 5
                : (c.maxWidth >= 560 ? 3 : 2);
            final wTile = (c.maxWidth - (cols - 1) * 10) / cols;
            final metrics = [
              _btMetricBox(
                w('Cumulative return', '区间累计收益'),
                fmtPct(totalRet, signed: true),
                'SPY ${fmtPct(benchRet, signed: true)}',
                valueColor: (totalRet ?? 0) >= 0
                    ? const Color(0xFF20C997)
                    : p.negative,
              ),
              _btMetricBox(
                w('Annualized (CAGR)', '年化复合收益'),
                fmtPct(cagr, signed: true),
                'SPY ${fmtPct(benchCagr, signed: true)}',
              ),
              _btMetricBox(
                w('Excess Alpha / yr', '年化超额 Alpha'),
                exCagr != null
                    ? fmtPct(exCagr, signed: true)
                    : fmtPct(win['excessTotalReturn'], signed: true),
                exCagr != null
                    ? w('vs SPY annualized', '相对 SPY 年化超额')
                    : w('vs SPY total', '相对 SPY 区间超额'),
                valueColor:
                    (exCagr ?? number(win['excessTotalReturn'])) >= 0
                    ? const Color(0xFF20C997)
                    : p.negative,
              ),
              _btMetricBox(
                w('Sharpe & Win rate', '夏普与季度胜率'),
                sharpe != null ? sharpe.toStringAsFixed(2) : '—',
                winRate != null && winQ != null && totalQ != null
                    ? w(
                        'Beat SPY $winQ/$totalQ qtrs (${fmtPct(winRate, digits: 0)})',
                        '跑赢 SPY $winQ/$totalQ 季 (${fmtPct(winRate, digits: 0)})',
                      )
                    : 'SPY ${nullableNumber(win['benchmarkSharpe'])?.toStringAsFixed(2) ?? '—'}',
              ),
              _btMetricBox(
                w('Max drawdown', '区间最大回撤'),
                fmtPct(mdd),
                'SPY ${fmtPct(benchMdd)}',
                valueColor: p.negative,
              ),
            ];
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final m in metrics) SizedBox(width: wTile, child: m),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (_, c) {
            final chartSide = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (activePt != null)
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      Text(
                        text(activePt['d']),
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${text(guru['name'])}: ${fmtPct(number(activePt['v']) - 1, signed: true)}',
                        style: const TextStyle(
                          color: Color(0xFF20C997),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'SPY: ${fmtPct(number(activePt['b']) - 1, signed: true)}',
                        style: TextStyle(
                          color: p.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${w('Spread', '超额差')}: ${fmtPct(number(activePt['v']) - number(activePt['b']), signed: true)}',
                        style: TextStyle(
                          color:
                              number(activePt['v']) >= number(activePt['b'])
                              ? const Color(0xFF20C997)
                              : p.negative,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 215,
                  child: LayoutBuilder(
                    builder: (_, cc) {
                      void scrub(double dx) {
                        if (curve.isEmpty) return;
                        const leftPad = 48.0;
                        final wPlot = math.max(1.0, cc.maxWidth - leftPad - 8);
                        final frac = ((dx - leftPad) / wPlot).clamp(0.0, 1.0);
                        final idx = (frac * (curve.length - 1)).round().clamp(
                          0,
                          curve.length - 1,
                        );
                        if (hoveredCurveIndex != idx) {
                          setState(() => hoveredCurveIndex = idx);
                        }
                      }

                      return MouseRegion(
                        onHover: (e) => scrub(e.localPosition.dx),
                        onExit: (_) =>
                            setState(() => hoveredCurveIndex = null),
                        child: GestureDetector(
                          onTapDown: (e) => scrub(e.localPosition.dx),
                          onHorizontalDragUpdate: (e) =>
                              scrub(e.localPosition.dx),
                          child: CustomPaint(
                            painter: _GuruEquityCurvePainter(
                              curve: curve,
                              palette: p,
                              activeIndex: activePtIdx,
                            ),
                            size: Size.infinite,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );

            final attrSide = _buildAttributionPanel(attr);

            if (c.maxWidth >= 900) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 6, child: chartSide),
                  const SizedBox(width: 20),
                  Container(width: 1, height: 245, color: p.border),
                  const SizedBox(width: 20),
                  Expanded(flex: 5, child: attrSide),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                chartSide,
                const SizedBox(height: 16),
                Divider(height: 1, color: p.border),
                const SizedBox(height: 14),
                attrSide,
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _btMetricBox(
    String label,
    String value,
    String sub, {
    Color? valueColor,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: p.card.withValues(alpha: .48),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: p.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 11),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: valueColor ?? p.text,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          sub,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: p.muted, fontSize: 10.5),
        ),
      ],
    ),
  );

  Widget _buildAttributionPanel(Map<String, dynamic> attr) {
    final topWinners = asList(attr['topContributors']);
    final topLosers = asList(attr['bottomContributors']);
    final quarters = asList(attr['quarters']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            Text(
              w('Performance attribution', '收益来源与历季胜负归因'),
              style: TextStyle(
                color: p.text,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            Wrap(
              spacing: 6,
              children: [
                ChoiceChip(
                  label: Text(
                    w('Stock drivers', '核心贡献股'),
                    style: const TextStyle(fontSize: 11),
                  ),
                  selected: btRightTab == 'contributors',
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) =>
                      setState(() => btRightTab = 'contributors'),
                ),
                ChoiceChip(
                  label: Text(
                    w('By quarter', '历季表现'),
                    style: const TextStyle(fontSize: 11),
                  ),
                  selected: btRightTab == 'quarters',
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => btRightTab = 'quarters'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (btRightTab == 'contributors')
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 205),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (topWinners.isNotEmpty) ...[
                    Text(
                      w('Top wealth creators (cumulative)', '区间核心盈利贡献股'),
                      style: const TextStyle(
                        color: Color(0xFF20C997),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final c in topWinners.take(4))
                      _contributorRow(c, positive: true),
                  ],
                  if (topLosers.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      w('Main detractors', '区间主要拖累股'),
                      style: TextStyle(
                        color: p.negative,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final c in topLosers.take(3))
                      _contributorRow(c, positive: false),
                  ],
                ],
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 205),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: math.min(quarters.length, 10),
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: p.border.withValues(alpha: .5)),
              itemBuilder: (_, i) {
                final q = quarters[i];
                final pRet = number(q['portfolioReturn']);
                final bRet = number(q['benchmarkReturn']);
                final ex = number(q['excessReturn']);
                final lead = asList(q['topWinners']).firstOrNull;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 66,
                        child: Text(
                          text(q['label']),
                          style: TextStyle(
                            color: p.text,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${fmtPct(pRet, signed: true)} vs SPY ${fmtPct(bRet, signed: true)}${lead != null ? ' · #1 ${lead['ticker']}' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 11),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color:
                              (ex >= 0 ? const Color(0xFF20C997) : p.negative)
                                  .withValues(alpha: .14),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          fmtPct(ex, signed: true),
                          style: TextStyle(
                            color: ex >= 0
                                ? const Color(0xFF20C997)
                                : p.negative,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _contributorRow(Map<String, dynamic> c, {required bool positive}) {
    final sym = text(c['ticker']);
    final contrib = number(c['totalContributionPct']);
    final tone = positive ? const Color(0xFF20C997) : p.negative;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => widget.onSelectHolding(sym),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            StockLogo(ticker: sym, palette: p, size: 20),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                '$sym · ${w('${c['quartersHeld']} qtrs', '持有 ${c['quartersHeld']} 季')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              fmtPct(contrib, signed: true),
              style: TextStyle(
                color: tone,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyMovesAndScaleSection(Map<String, dynamic> f) {
    final buys = asList(f['keyBuys']);
    final sells = asList(f['keySells']);

    final movesCard = _panel(
      key: const ValueKey('guru-dossier-moves'),
      [
        Row(
          children: [
            const Icon(Icons.swap_horiz_rounded, size: 18, color: Color(0xFFF5A623)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                w(
                  'Key Quarterly Operations (${text(f['quarterLabel'], text(f['reportDate']))})',
                  '当季关键调仓操作（${text(f['quarterLabel'], text(f['reportDate']))}）',
                ),
                style: TextStyle(
                  color: p.text,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (buys.isEmpty && sells.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              w(
                'No reported share additions, reductions, or exits in this filing.',
                '该季度申报中无新建、加仓、减仓或清仓变动。',
              ),
              style: TextStyle(color: p.muted, fontSize: 12.5),
            ),
          )
        else
          LayoutBuilder(
            builder: (_, c) {
              final buyCol = _movesListColumn(
                title: w(
                  'New & Increased (${buys.length})',
                  '新建仓与加仓（${buys.length}）',
                ),
                items: buys,
                tint: const Color(0xFF20C997),
                emptyCopy: w('No new or increased positions', '当季无新建或加仓'),
              );
              final sellCol = _movesListColumn(
                title: w(
                  'Reduced & Exited (${sells.length})',
                  '减仓与清仓（${sells.length}）',
                ),
                items: sells,
                tint: const Color(0xFFF5A623),
                emptyCopy: w('No reductions or exits', '当季无减仓或清仓'),
              );
              if (c.maxWidth >= 600) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: buyCol),
                    const SizedBox(width: 16),
                    Expanded(child: sellCol),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [buyCol, const SizedBox(height: 14), sellCol],
              );
            },
          ),
      ],
    );

    final scaleCard = _buildScaleAndSectorPanel(f);

    return LayoutBuilder(
      builder: (_, c) {
        if (c.maxWidth >= 980) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 6, child: movesCard),
              const SizedBox(width: 16),
              Expanded(flex: 5, child: scaleCard),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [movesCard, scaleCard],
        );
      },
    );
  }

  Widget _buildBookScaleAndSectorsOnly(Map<String, dynamic> f) =>
      _buildScaleAndSectorPanel(f);

  Widget _movesListColumn({
    required String title,
    required List<Map<String, dynamic>> items,
    required Color tint,
    required String emptyCopy,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title,
        style: TextStyle(
          color: tint,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 6),
      if (items.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(emptyCopy, style: TextStyle(color: p.muted, fontSize: 12)),
        )
      else
        for (final m in items.take(6)) _moveItemTile(m),
    ],
  );

  Widget _moveItemTile(Map<String, dynamic> m) {
    final sym = text(m['ticker']);
    final act = text(m['action']);
    final tint = _actionColor(act);
    final chgPct = nullableNumber(m['changePct']);
    final valDelta = nullableNumber(m['valueChange']);
    final weight = nullableNumber(m['weight']);

    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: () {
        if (act == 'sold_out') {
          widget.onResearchCompany(sym, {
            'guruId': guru['id'],
            'name': guru['name'],
            'accession': filing['accessionNumber'],
            'reportDate': filing['reportDate'],
            'availableAt': filing['filingDate'],
          });
        } else {
          widget.onSelectHolding(sym);
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: p.card.withValues(alpha: .42),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: p.border.withValues(alpha: .7)),
        ),
        child: Row(
          children: [
            StockLogo(ticker: sym, palette: p, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          sym,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.text,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: tint.withValues(alpha: .15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _actionText(act),
                          style: TextStyle(
                            color: tint,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    act == 'sold_out'
                        ? w('100% exited from 13F book', '已从 13F 持仓清仓退出')
                        : '${w('Book weight', '现占组合')} ${fmtPct(weight)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.muted, fontSize: 10.5),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  act == 'new'
                      ? w('Initiated', '新开仓')
                      : act == 'sold_out'
                      ? '-100%'
                      : fmtPct(chgPct, signed: true),
                  style: TextStyle(
                    color: tint,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (valDelta != null)
                  Text(
                    fmtCompactUsd(valDelta, signed: true),
                    style: TextStyle(color: p.muted, fontSize: 10.5),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScaleAndSectorPanel(Map<String, dynamic> f) {
    final validHist = history
        .where(
          (h) =>
              h['status'] != 'source_error' &&
              nullableNumber(h['reported13fValue']) != null,
        )
        .toList();
    final recent12 = validHist.length > 12
        ? validHist.sublist(validHist.length - 12)
        : validHist;
    final maxAum = recent12.fold<double>(
      1,
      (mx, h) => math.max(mx, number(h['reported13fValue'])),
    );
    final sectors = asList(f['sectors'])
        .where((s) => text(s['sector']) != 'Unclassified')
        .take(5)
        .toList();

    return _panel([
      Text(
        w('13F Book Trajectory & Sector Mix', '历史 13F 规模演变与行业配置'),
        style: TextStyle(
          color: p.text,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 10),
      if (recent12.isNotEmpty) ...[
        Text(
          w(
            'Reported 13F equity value across recent ${recent12.length} filings',
            '近 ${recent12.length} 个季度 13F 申报总市值趋势',
          ),
          style: TextStyle(color: p.muted, fontSize: 11),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 82,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final q in recent12)
                Expanded(
                  child: Tooltip(
                    message:
                        '${q['quarterLabel']}: ${fmtCompactUsd(q['reported13fValue'])} · ${q['positionCount'] ?? '—'} ${w('positions', '只持仓')}',
                    child: GestureDetector(
                      onTap: () =>
                          widget.onSelectQuarter(text(q['accessionNumber'])),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              height: math.max(
                                6.0,
                                (number(q['reported13fValue']) / maxAum) * 60.0,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    q['accessionNumber'] ==
                                        f['accessionNumber']
                                    ? p.accent
                                    : p.accent.withValues(alpha: .32),
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              text(q['quarterLabel']).length >= 7
                                  ? text(q['quarterLabel']).substring(2)
                                  : text(q['quarterLabel']),
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: TextStyle(
                                color:
                                    q['accessionNumber'] ==
                                        f['accessionNumber']
                                    ? p.text
                                    : p.muted,
                                fontSize: 8.5,
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
      ],
      if (sectors.isNotEmpty) ...[
        const SizedBox(height: 14),
        Text(
          w('Modeled sector allocation', '已识别行业权重分布'),
          style: TextStyle(color: p.muted, fontSize: 11),
        ),
        const SizedBox(height: 6),
        for (final sec in sectors)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        text(sec['sector']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.text, fontSize: 11.5),
                      ),
                    ),
                    Text(
                      fmtPct(sec['weight'], digits: 1),
                      style: TextStyle(
                        color: p.text,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2.5),
                  child: LinearProgressIndicator(
                    value: number(sec['weight']).clamp(0.0, 1.0).toDouble(),
                    minHeight: 5,
                    backgroundColor: p.border.withValues(alpha: .5),
                    valueColor: AlwaysStoppedAnimation<Color>(p.accent),
                  ),
                ),
              ],
            ),
          ),
      ],
    ]);
  }

  Widget _buildHoldingsAndTrajectorySection(
    Map<String, dynamic> f,
    bool comparisonError,
  ) {
    final holdings = asList(f['topHoldings']);
    final visibleHoldings = showAllHoldings || holdings.length <= 15
        ? holdings
        : holdings.take(15).toList();
    final qPerf = asMap(
      asMap(backtest['quarterReturnByReportDate'])[text(f['reportDate'])],
    );
    final qTickerPerf = asMap(qPerf['byTicker']);

    final holdingsPanel = _panel([
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                w('What did they own?', '他们持有哪些股票？'),
                style: TextStyle(
                  color: p.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                w(
                  'Select a stock to trace its multi-quarter position & valuation.',
                  '点击任意持仓查看多季度加减仓轨迹、当季表现与模型估值。',
                ),
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: 12),
      for (var idx = 0; idx < visibleHoldings.length; idx++)
        _buildHoldingRow(
          visibleHoldings[idx],
          rank: idx + 1,
          comparisonError: comparisonError,
          postFilingPerf: asMap(
            qTickerPerf[text(visibleHoldings[idx]['ticker'])],
          ),
        ),
      if (holdings.length > 15)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () =>
                setState(() => showAllHoldings = !showAllHoldings),
            child: Text(
              showAllHoldings
                  ? w('Show top 15', '收起至前 15 大持仓')
                  : w(
                      'Show all ${holdings.length} holdings',
                      '展开全部 ${holdings.length} 只持仓',
                    ),
            ),
          ),
        ),
    ]);

    final trajectoryPanel = _buildHoldingTrajectory(f);

    return LayoutBuilder(
      builder: (_, c) {
        if (c.maxWidth < 880) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [holdingsPanel, trajectoryPanel],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 6, child: holdingsPanel),
            const SizedBox(width: 18),
            Expanded(flex: 5, child: trajectoryPanel),
          ],
        );
      },
    );
  }

  Widget _buildHoldingRow(
    Map<String, dynamic> h, {
    required int rank,
    required bool comparisonError,
    required Map<String, dynamic> postFilingPerf,
  }) {
    final sym = text(h['ticker']);
    final isSelected = sym == widget.selectedHolding;
    final weight = nullableNumber(h['pctPortfolio']);
    final val = nullableNumber(h['value']);
    final act = text(h['action']);
    final chgPct = nullableNumber(h['changePct']);
    final modelGap = nullableNumber(h['modelGap']);
    final postRet = nullableNumber(postFilingPerf['returnPct']);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => widget.onSelectHolding(sym),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: isSelected ? p.accent.withValues(alpha: .10) : null,
          border: Border(
            left: BorderSide(
              color: isSelected ? p.accent : Colors.transparent,
              width: 3,
            ),
            bottom: BorderSide(color: p.border.withValues(alpha: .55)),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '$rank',
                style: TextStyle(
                  color: rank <= 3 ? p.accent : p.muted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            StockLogo(ticker: sym, palette: p, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        sym,
                        style: TextStyle(
                          color: p.text,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (!comparisonError &&
                          {'new', 'increased', 'reduced'}.contains(act))
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: _actionColor(act).withValues(alpha: .15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            act == 'new'
                                ? w('New', '新建')
                                : '${_actionText(act)}${chgPct != null ? ' ${fmtPct(chgPct, signed: true, digits: 0)}' : ''}',
                            style: TextStyle(
                              color: _actionColor(act),
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      if (modelGap != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color:
                                (modelGap >= 0
                                        ? const Color(0xFF20C997)
                                        : p.muted)
                                    .withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${w('Val gap', '估值差')} ${fmtPct(modelGap, signed: true, digits: 0)}',
                            style: TextStyle(
                              color: modelGap >= 0
                                  ? const Color(0xFF20C997)
                                  : p.muted,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      text(h['issuer']),
                      if (text(h['sector']).isNotEmpty) text(h['sector']),
                      if (postRet != null)
                        '${w('Qtr', '披露后')} ${fmtPct(postRet, signed: true)}',
                    ].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  fmtPct(weight, digits: 2),
                  style: TextStyle(
                    color: p.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (val != null)
                  Text(
                    fmtCompactUsd(val),
                    style: TextStyle(color: p.muted, fontSize: 10.5),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHoldingTrajectory(Map<String, dynamic> f) {
    final points = <Map<String, dynamic>>[];
    for (final histF in history) {
      if (text(histF['filingDate']).compareTo(text(f['filingDate'])) > 0) {
        continue;
      }
      final row = [
        ...asList(histF['topHoldings']),
        ...asList(histF['largestChanges']),
      ].where((h) => h['ticker'] == widget.selectedHolding && (h['holdingBucket'] == 'common_long' || text(h['id']).endsWith('-COMMON'))).firstOrNull;
      points.add({
        'quarter': histF['quarterLabel'],
        'date': histF['filingDate'],
        'holding': histF['status'] == 'source_error' ? null : row,
        'sourceError': histF['status'] == 'source_error',
      });
    }
    final visible = points.reversed.take(12).toList().reversed.toList();
    final field = widget.trajectoryMetric == 'weight'
        ? 'pctPortfolio'
        : widget.trajectoryMetric == 'value'
        ? 'value'
        : 'shares';
    var maxValue = 0.0;
    for (final pt in visible) {
      final v = number(asMap(pt['holding'])[field]);
      if (v > maxValue) maxValue = v;
    }
    final current = asList(
      f['topHoldings'],
    ).where((h) => h['ticker'] == widget.selectedHolding).firstOrNull;

    final marketPrice = nullableNumber(current?['marketPrice']);
    final fairValue = nullableNumber(current?['fairValue']);
    final modelGap = nullableNumber(current?['modelGap']);

    return _panel([
      Row(
        children: [
          StockLogo(ticker: widget.selectedHolding, palette: p, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              w(
                '${widget.selectedHolding} · position history',
                '${widget.selectedHolding} · 仓位轨迹',
              ),
              style: TextStyle(
                color: p.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      if (marketPrice != null || fairValue != null) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: p.card.withValues(alpha: .48),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.border),
          ),
          child: Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              if (marketPrice != null)
                Text(
                  '${w('Price', '现价')} \$${marketPrice.toStringAsFixed(2)}',
                  style: TextStyle(color: p.text, fontSize: 12),
                ),
              if (fairValue != null)
                Text(
                  '${w('Model value', '模型价值')} \$${fairValue.toStringAsFixed(2)}',
                  style: TextStyle(
                    color: p.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (modelGap != null)
                Text(
                  '${w('Model / price − 1', '估值空间')}: ${fmtPct(modelGap, signed: true)}',
                  style: TextStyle(
                    color: modelGap >= 0
                        ? const Color(0xFF20C997)
                        : p.negative,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final metric in [
            ('shares', 'Shares', '股数'),
            ('weight', 'Weight', '权重'),
            ('value', 'Value', '申报市值'),
          ])
            ChoiceChip(
              label: Text(w(metric.$2, metric.$3)),
              selected: widget.trajectoryMetric == metric.$1,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => widget.onSelectTrajectoryMetric(metric.$1),
            ),
        ],
      ),
      const SizedBox(height: 14),
      if (visible.isEmpty)
        Text(
          w('No comparable reported observations.', '暂无可比较的申报记录。'),
          style: TextStyle(color: p.muted, fontSize: 12.5),
        ),
      for (final point in visible)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.5),
          child: Row(
            children: [
              SizedBox(
                width: 74,
                child: Text(
                  text(point['quarter']),
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
              ),
              Expanded(
                child: nullableNumber(asMap(point['holding'])[field]) == null
                    ? Text(
                        point['sourceError'] == true
                            ? w('Source unavailable', '来源不可用')
                            : w('Not in extract', '摘录未包含'),
                        style: TextStyle(color: p.muted, fontSize: 12),
                      )
                    : LinearProgressIndicator(
                        value: maxValue > 0
                            ? (number(asMap(point['holding'])[field]) /
                                      maxValue)
                                  .clamp(0.0, 1.0)
                                  .toDouble()
                            : 0,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                        color: p.accent,
                        backgroundColor: p.border,
                      ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 82,
                child: Text(
                  nullableNumber(asMap(point['holding'])[field]) == null
                      ? '—'
                      : field == 'pctPortfolio'
                      ? fmtPct(asMap(point['holding'])[field], digits: 2)
                      : field == 'value'
                      ? fmtCompactUsd(asMap(point['holding'])[field])
                      : formatNumber(number(asMap(point['holding'])[field])),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 12),
      Text(
        w(
          'Up to 12 filings through the selected filing. Bars show reported observations, not a return curve.',
          '显示截至所选披露的最近 12 份申报，柱状图代表申报持仓规模，而非收益曲线。',
        ),
        style: TextStyle(color: p.muted, fontSize: 11.5),
      ),
      const SizedBox(height: 14),
      FilledButton.icon(
        onPressed: current == null
            ? null
            : () => widget.onResearchCompany(widget.selectedHolding, {
                'guruId': guru['id'],
                'name': guru['name'],
                'accession': f['accessionNumber'],
                'reportDate': f['reportDate'],
                'availableAt': f['filingDate'],
              }),
        icon: const Icon(Icons.arrow_forward, size: 16),
        label: Text(
          w(
            'Research ${widget.selectedHolding}',
            '研究 ${widget.selectedHolding}',
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text(
        w(
          'Valuation uses data available at ${widget.asOf}, not the manager’s purchase-date value.',
          '估值使用 ${widget.asOf} 前可用公开数据，而非基金经理建仓日估值。',
        ),
        style: TextStyle(color: p.muted, fontSize: 11),
      ),
    ]);
  }
}

class _GuruEquityCurvePainter extends CustomPainter {
  _GuruEquityCurvePainter({
    required this.curve,
    required this.palette,
    required this.activeIndex,
  });

  final List<Map<String, dynamic>> curve;
  final Palette palette;
  final int? activeIndex;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 48.0;
    const bottomPad = 22.0;
    const topPad = 8.0;
    final rect = Rect.fromLTRB(
      leftPad,
      topPad,
      size.width - 8,
      size.height - bottomPad,
    );
    if (rect.width <= 0 || rect.height <= 0 || curve.length < 2) return;

    var minY = double.infinity, maxY = -double.infinity;
    for (final pt in curve) {
      final v = number(pt['v']);
      final b = number(pt['b']);
      minY = math.min(minY, math.min(v, b));
      maxY = math.max(maxY, math.max(v, b));
    }
    if (!minY.isFinite || !maxY.isFinite) return;
    final span = math.max(0.08, maxY - minY);
    final lo = minY - span * 0.08;
    final hi = maxY + span * 0.08;

    double xAt(int i) =>
        rect.left + (i / math.max(1, curve.length - 1)) * rect.width;
    double yAt(double val) =>
        rect.bottom - ((val - lo) / (hi - lo)) * rect.height;

    // Grid lines & Y-axis cumulative % labels
    for (var g = 0; g <= 3; g++) {
      final frac = g / 3;
      final val = lo + frac * (hi - lo);
      final y = yAt(val);
      canvas.drawLine(
        Offset(rect.left, y),
        Offset(rect.right, y),
        Paint()
          ..color = palette.border.withValues(alpha: .5)
          ..strokeWidth = 1,
      );
      final pctVal = (val - 1) * 100;
      final lbl = '${pctVal >= 0 ? '+' : ''}${pctVal.toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(
          text: lbl,
          style: TextStyle(color: palette.muted, fontSize: 9.5),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: leftPad - 6);
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }

    // Benchmark path (dashed slate)
    final benchPath = Path();
    final guruPath = Path();
    for (var i = 0; i < curve.length; i++) {
      final x = xAt(i);
      final yb = yAt(number(curve[i]['b']));
      final yv = yAt(number(curve[i]['v']));
      if (i == 0) {
        benchPath.moveTo(x, yb);
        guruPath.moveTo(x, yv);
      } else {
        benchPath.lineTo(x, yb);
        guruPath.lineTo(x, yv);
      }
    }

    // Area fill under Guru curve
    const guruColor = Color(0xFF20C997);
    final areaPath = Path.from(guruPath)
      ..lineTo(xAt(curve.length - 1), rect.bottom)
      ..lineTo(xAt(0), rect.bottom)
      ..close();
    canvas.drawPath(
      areaPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            guruColor.withValues(alpha: .22),
            guruColor.withValues(alpha: .0),
          ],
        ).createShader(rect),
    );

    canvas.drawPath(
      benchPath,
      Paint()
        ..color = palette.muted.withValues(alpha: .65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    canvas.drawPath(
      guruPath,
      Paint()
        ..color = guruColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.3,
    );

    // Active crosshair & dots
    if (activeIndex != null &&
        activeIndex! >= 0 &&
        activeIndex! < curve.length) {
      final ax = xAt(activeIndex!);
      final ayV = yAt(number(curve[activeIndex!]['v']));
      final ayB = yAt(number(curve[activeIndex!]['b']));
      canvas.drawLine(
        Offset(ax, rect.top),
        Offset(ax, rect.bottom),
        Paint()
          ..color = palette.text.withValues(alpha: .24)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(Offset(ax, ayB), 3.5, Paint()..color = palette.muted);
      canvas.drawCircle(Offset(ax, ayV), 4.5, Paint()..color = guruColor);
    }

    // X-axis start, middle, end dates
    for (final idx in {0, (curve.length / 2).floor(), curve.length - 1}) {
      final rawD = text(curve[idx]['d']);
      final shortD = rawD.length >= 7 ? rawD.substring(0, 7) : rawD;
      final tp = TextPainter(
        text: TextSpan(
          text: shortD,
          style: TextStyle(color: palette.muted, fontSize: 9.5),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = (xAt(idx) - tp.width / 2)
          .clamp(
            rect.left,
            math.max(rect.left, rect.right - tp.width),
          )
          .toDouble();
      tp.paint(canvas, Offset(dx, rect.bottom + 5));
    }
  }

  @override
  bool shouldRepaint(covariant _GuruEquityCurvePainter old) =>
      old.curve != curve ||
      old.palette != palette ||
      old.activeIndex != activeIndex;
}
