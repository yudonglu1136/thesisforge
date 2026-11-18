part of 'main.dart';

// Everything in this inspector comes from the completed run, never the current
// controls or a fresh company request. Zero target weight is not missing data.
class StrategySnapshotInspector extends StatelessWidget {
  const StrategySnapshotInspector({
    super.key,
    required this.event,
    required this.rules,
    required this.managers,
    required this.palette,
    required this.asOf,
    required this.onCompany,
  });

  final Map<String, dynamic> event, rules;
  final List<Map<String, dynamic>> managers;
  final Palette palette;
  final String asOf;
  final ValueChanged<String> onCompany;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    String w(String en, String zh) => context.tr(zh, en);
    String pct(dynamic v) => nullableNumber(v) == null
        ? '—'
        : '${(number(v) * 100).toStringAsFixed(1)}%';
    String price(dynamic v) =>
        nullableNumber(v) == null ? '—' : 'USD ${number(v).toStringAsFixed(2)}';
    TextStyle style([double size = 13, bool bold = false, Color? color]) =>
        TextStyle(
          color: color ?? p.text,
          fontSize: size,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          height: 1.4,
        );
    String managerName(dynamic id) {
      final matched = managers.where((m) => m['id'] == id).firstOrNull;
      return guruDisplayName(
        matched ?? {'id': id, 'name': id},
        context.language,
      );
    }
    Widget note(String en, String zh, {Color? color}) =>
        Text(w(en, zh), style: style(12, false, color ?? p.muted));
    final positions = asList(event['positions']);
    // Put actionable valuation exclusions first without mutating run evidence.
    final excluded = [...asList(event['exclusions'])]
      ..sort((a, b) {
        final category = (a['status'] == 'expensive' ? 0 : 1).compareTo(
          b['status'] == 'expensive' ? 0 : 1,
        );
        return category != 0
            ? category
            : text(a['ticker']).compareTo(text(b['ticker']));
      });
    final skipped = asList(event['managerExclusions']);
    final stocks = positions.where((h) => h['kind'] == 'stock').toList();
    final full = rules['excludedAllocation'] == 'fully_invested';
    final multiple = nullableNumber(event['leverage']) ?? 1;
    final expensive = excluded.where((h) => h['status'] == 'expensive').length;
    final cutoff = text(event['decisionDate'], '—');
    final maxPremium = pct(rules['maxPremium']);

    String reason(dynamic status) => switch (text(status)) {
      'below_top_n' => w(
        'Qualified, but below the factor Top N cutoff',
        '符合条件，但未进入四因子前 N 名',
      ),
      'expensive' => w('Above valuation limit', '超过估值上限'),
      'no_model' => w('No usable model at the time', '当时没有可用估值模型'),
      'stale_model' => w('Model older than 550 days', '模型已超过 550 天'),
      'comparison_price_missing' => w(
        'Decision-date price missing',
        '缺少决策日比较价格',
      ),
      'currency_unverified' => w(
        'Price and model currencies not comparable',
        '价格与模型币种不可比',
      ),
      'execution_unavailable' => w(
        'Execution price or security identity unverified',
        '执行价格或证券身份未核验',
      ),
      'corporate_action_cash' => w('Acquisition settled in cash', '收购已转为现金'),
      _ => w('Exclusion needs source review', '剔除原因需要来源核查'),
    };
    String managerReason(dynamic code) => switch (text(code)) {
      'manager_history_unavailable' => w('No public filing yet', '当时尚无公开申报'),
      'stale_manager_filing' => w('Filing too old', '申报过旧'),
      'insufficient_top_n_extract' => w('Incomplete Top N book', 'Top N 持仓不完整'),
      'manager_identity_mismatch' => w('Filer identity unverified', '申报主体尚未核验'),
      _ => w('Original filing not verified', '原始申报尚未核验'),
    };
    Widget guruNames(List<dynamic> ids) => Wrap(
      spacing: 10,
      runSpacing: 6,
      children: [
        for (final id in ids)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GuruAvatar(
                guru: {'id': id, 'avatarUrl': '/guru-avatars/$id.png'},
                palette: p,
                size: 20,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(managerName(id), style: style(11, false, p.muted)),
              ),
            ],
          ),
      ],
    );
    Widget card(
      String title,
      String subtitle,
      List<Widget> children, {
      Color? color,
    }) => Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: style(18, true, color)),
          const SizedBox(height: 5),
          Text(subtitle, style: style(12, false, p.muted)),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
    Widget values(Map<String, dynamic> h) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 22,
        runSpacing: 8,
        children: [
          if (h['valuationLink'] != null)
            note(
              'Company model: ${h['modelTicker']} · ${h['ticker']} own share-class price',
              '公司模型：${h['modelTicker']} · 使用 ${h['ticker']} 本类股份价格',
            ),
          for (final metric in [
            (w('Decision price', '决策价格'), price(h['price'])),
            (w('Model value', '模型估值'), price(h['fairValue'])),
            (w('Premium', '溢价'), pct(h['premium'])),
          ])
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(metric.$1, style: style(11, false, p.muted)),
                Text(metric.$2, style: style(13, true)),
              ],
            ),
        ],
      ),
    );
    final heldCard = card(
      w('Stocks held · ${stocks.length}', '调仓后持仓 · ${stocks.length} 只股票'),
      w(
        'Final target weights, including the CTA sleeve.',
        '展示最终目标权重，包含 CTA 配置。',
      ),
      [
        for (final h in positions) ...[
          Row(
            children: [
              StockLogo(ticker: text(h['ticker']), palette: p, size: 32),
              const SizedBox(width: 10),
              Expanded(child: Text(text(h['ticker']), style: style(16, true))),
              Text(pct(h['weight']), style: style(19, true, p.accent)),
            ],
          ),
          if (text(h['issuer']).isNotEmpty)
            Text(text(h['issuer']), style: style(12, false, p.muted)),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: number(h['weight']).clamp(0.0, 1.0),
            minHeight: 4,
            color: h['kind'] == 'cta' ? p.secondary : p.accent,
            backgroundColor: p.border,
          ),
          if (multiple > 1)
            note(
              'Exposure / equity ${pct(h['exposureWeight'])}',
              '敞口 / 净资产 ${pct(h['exposureWeight'])}',
            ),
          if (h['kind'] == 'cta') ...[
            const SizedBox(height: 8),
            note('Managed futures allocation', '管理期货配置'),
          ] else ...[
            if (!['QQQ', 'SPY', 'SCHD'].contains(h['ticker']) &&
                rules['valuationEnabled'] == true)
              values(h),
            if (['QQQ', 'SPY', 'SCHD'].contains(h['ticker']))
              note(
                'Index ETF · company valuation filter not applied',
                '指数 ETF · 不适用个股估值过滤',
              ),
            for (final component in asMap(h['components']).entries)
              note(
                '${strategyComponentName(context, component.key)} · ${pct(component.value)} of portfolio',
                '${strategyComponentName(context, component.key)} · 占组合 ${pct(component.value)}',
              ),
            if (h['modelDate'] != null)
              note('Model date: ${h['modelDate']}', '模型日期：${h['modelDate']}'),
            if (h['managers'] is List) guruNames(h['managers'] as List),
            if (!['QQQ', 'SPY', 'SCHD'].contains(h['ticker']))
              TextButton(
                onPressed: () => onCompany(text(h['ticker'])),
                child: Text(w('Open company research →', '打开公司研究 →')),
              ),
          ],
          Divider(color: p.border, height: 24),
        ],
      ],
      color: p.accent,
    );
    final filteredCard = card(
      w('Filtered stocks · ${excluded.length}', '被过滤 · ${excluded.length} 只股票'),
      w(
        '$expensive above the valuation limit · ${excluded.length - expensive} other exclusions',
        '$expensive 只超过估值上限 · ${excluded.length - expensive} 只因其他原因剔除',
      ),
      [
        if (excluded.isEmpty)
          note(
            'No candidate stocks were filtered at this rebalance.',
            '本次调仓没有候选股票被过滤。',
          ),
        for (final h in excluded) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StockLogo(ticker: text(h['ticker']), palette: p, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      text(h['ticker']).isEmpty
                          ? text(h['cusip'], '—')
                          : text(h['ticker']),
                      style: style(16, true),
                    ),
                    Text(
                      reason(h['status']),
                      style: style(13, true, p.secondary),
                    ),
                  ],
                ),
              ),
              Text('0%', style: style(15, true, p.muted)),
            ],
          ),
          if (h['status'] == 'expensive') ...[
            const SizedBox(height: 8),
            Text(
              pct(h['premium']) == maxPremium
                  ? w(
                      'Premium exceeds $maxPremium by less than 0.1 percentage point',
                      '溢价超过 $maxPremium，上限差额不足 0.1 个百分点',
                    )
                  : w(
                      '${pct(h['premium'])} premium > $maxPremium allowed',
                      '当时溢价 ${pct(h['premium'])} > 允许上限 $maxPremium',
                    ),
              style: style(14, true, p.secondary),
            ),
          ],
          if (h['price'] != null ||
              h['fairValue'] != null ||
              h['premium'] != null)
            values(h),
          if (h['priceDate'] != null || h['modelDate'] != null)
            note(
              'Price date: ${text(h['priceDate'], '—')} · Model date: ${text(h['modelDate'], '—')}',
              '价格日期：${text(h['priceDate'], '—')} · 模型日期：${text(h['modelDate'], '—')}',
            ),
          if (h['managers'] is List) ...[
            const SizedBox(height: 8),
            guruNames(h['managers'] as List),
          ],
          if (text(h['ticker']).isNotEmpty)
            TextButton(
              onPressed: () => onCompany(text(h['ticker'])),
              child: Text(w('Inspect company →', '查看公司 →')),
            ),
          Divider(color: p.border, height: 24),
        ],
        if (skipped.isNotEmpty) ...[
          Text(
            w(
              'Unavailable Guru books · ${skipped.length}',
              '未纳入的大师申报 · ${skipped.length}',
            ),
            style: style(15, true),
          ),
          const SizedBox(height: 5),
          note(
            'Counted separately: an unavailable book is not a known list of rejected stocks.',
            '单独统计：申报缺失并不代表已知哪些股票被剔除。',
          ),
          for (final m in skipped)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  guruNames([m['guruId']]),
                  Text(
                    managerReason(m['code']),
                    style: style(12, false, p.secondary),
                  ),
                  if (m['firstStoredPublicDate'] != null)
                    note(
                      'First public filing ${m['firstStoredPublicDate']}',
                      '首次公开申报 ${m['firstStoredPublicDate']}',
                    ),
                ],
              ),
            ),
        ],
      ],
      color: p.secondary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w('What happened on ${event['date']}?', '${event['date']} 调仓发生了什么？'),
          style: style(22, true),
        ),
        const SizedBox(height: 8),
        note(
          'Decision information through $cutoff · Next rebalance / test end: ${event['throughDate']}',
          '决策数据截至 $cutoff · 下次调仓 / 回测结束：${event['throughDate']}',
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          width: double.infinity,
          decoration: BoxDecoration(
            color: p.accent.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                rules['valuationEnabled'] == true
                    ? w(
                        'This run: exclude price / fair value − 1 > $maxPremium',
                        '本次回测规则：剔除 股价 / 公允价值 − 1 > $maxPremium',
                      )
                    : w('This run: valuation filter off', '本次回测规则：未启用估值过滤'),
                style: style(14, true),
              ),
              const SizedBox(height: 6),
              if (number(
                    asMap(asMap(rules['equityMix'])['weights'])['factors'],
                  ) >
                  0) ...[
                Text(
                  strategyFactorSummary(context, asMap(rules['equityMix'])),
                  style: style(12, false, p.accent),
                ),
                const SizedBox(height: 8),
              ],
              note(
                rules['ctaPolicy'] != null
                    ? 'Actual post-trade allocation: equities ${pct(event['stockWeight'])} · CTA ${pct(event['ctaWeight'])} · cash ${pct(event['cashWeight'])}. CTA trades scale the existing equity basket; stock weights drift between equity-selection dates.'
                    : rules['equityMix'] != null
                    ? 'Equities ${pct(event['stockWeight'])} · CTA ${pct(event['ctaWeight'])} · Cash ${pct(event['cashWeight'])}. Each source keeps its configured budget; eligible stocks split that source equally and overlapping positions are combined.'
                    : full
                    ? '${stocks.length} eligible stocks share ${pct(event['stockWeight'])} equally. CTA ${pct(event['ctaWeight'])} · Cash ${pct(event['cashWeight'])}. Excluded slots are redistributed, not kept as cash.'
                    : 'Final allocation: stocks ${pct(event['stockWeight'])} · CTA ${pct(event['ctaWeight'])} · Cash ${pct(event['cashWeight'])}. Allocation follows this run’s saved policy.',
                rules['ctaPolicy'] != null
                    ? '成交后实际配置：股票及指数 ${pct(event['stockWeight'])} · CTA ${pct(event['ctaWeight'])} · 现金 ${pct(event['cashWeight'])}。CTA 调仓按当时比例缩放股票篮子，股票权重在选股调仓之间漂移。'
                    : rules['equityMix'] != null
                    ? '股票及指数 ${pct(event['stockWeight'])} · CTA ${pct(event['ctaWeight'])} · 现金 ${pct(event['cashWeight'])}。各来源保留配置比例，来源内可买股票等权，重复持仓合并。'
                    : full
                    ? '${stocks.length} 只可买股票等分 ${pct(event['stockWeight'])}。CTA ${pct(event['ctaWeight'])} · 现金 ${pct(event['cashWeight'])}。被剔除的份额重新分配，不留现金。'
                    : '最终配置：股票 ${pct(event['stockWeight'])} · CTA ${pct(event['ctaWeight'])} · 现金 ${pct(event['cashWeight'])}。按本次回测保存的分配规则执行。',
              ),
              if (event['ctaEvent'] != null) ...[
                const SizedBox(height: 8),
                Text(
                  strategyCtaReason(
                    context,
                    asMap(event['ctaEvent'])['reason'],
                  ),
                  style: style(14, true, p.accent),
                ),
                note(
                  'Equity selection evidence remains dated ${event['equityDecisionDate']}.',
                  '股票筛选证据仍截至 ${event['equityDecisionDate']}。',
                ),
              ],
              if (multiple > 1)
                note(
                  'Target exposure ${multiple.toStringAsFixed(2)}× · Borrowing ${pct(event['borrowedWeight'])} of equity at 4% / year.',
                  '目标敞口 ${multiple.toStringAsFixed(2)}× · 借款占净资产 ${pct(event['borrowedWeight'])}，年利率 4%。',
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth >= 880
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: heldCard),
                    const SizedBox(width: 16),
                    Expanded(child: filteredCard),
                  ],
                )
              : Column(
                  children: [
                    heldCard,
                    const SizedBox(height: 16),
                    filteredCard,
                  ],
                ),
        ),
        const SizedBox(height: 12),
        note(
          'Post-rebalance simulated targets, not brokerage holdings. Weights drift between rebalances. Missing values are not zero.',
          '这是调仓后的模拟目标持仓，不是券商账户持仓；权重在两次调仓之间漂移。缺失数据不等于零。',
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          key: ValueKey('snapshot-sources-${event['date']}'),
          title: Text(
            w('Filings behind this snapshot', '这张快照的申报来源'),
            style: style(14),
          ),
          children: [
            for (final f in asList(event['filings']))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(managerName(f['guruId']), style: style(13, true)),
                subtitle: SelectableText(
                  w(
                    'Report ${f['reportDate']} · Public ${f['publicDate']}\n${f['accession'] ?? ''}',
                    '报告期 ${f['reportDate']} · 公开日 ${f['publicDate']}\n${f['accession'] ?? ''}',
                  ),
                  style: style(12, false, p.muted),
                ),
              ),
          ],
        ),
        note(
          'Company research opens at workspace cutoff $asOf. Browsing snapshots does not change the run or its historical inputs.',
          '公司研究使用工作区截止日 $asOf。翻阅快照不会改变本次回测及其历史输入。',
        ),
      ],
    );
  }
}
