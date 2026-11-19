part of 'main.dart';

// The same fiscal period may have several published nodes. Only the exact
// endpoint selected by the quarter API may populate a timeline preview.
Map<String, dynamic> earningsBookObservation(
  List<Map<String, dynamic>> history,
  Map<String, dynamic> quarter,
  String asOf,
) {
  for (final r in history.reversed) {
    final date = text(r['availableAt']);
    if (r['period'] == quarter['period'] &&
        date == quarter['availableAt'] &&
        DateTime.tryParse(date) != null &&
        date.compareTo(asOf) <= 0) {
      return r;
    }
  }
  return {};
}

extension _EarningsQuarterBook on _EarningsResearchPanelState {
  double get quarterWidth =>
      160 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.6);

  void revealQuarter() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !quarterScroll.hasClients) return;
      final rows = asList(data?['periods']);
      final index = rows.indexWhere((r) => r['period'] == requested);
      if (index < 0) return;
      final left = index * (quarterWidth + 8);
      final right = left + quarterWidth;
      final view = quarterScroll.position.viewportDimension;
      final current = quarterScroll.offset;
      if (left < current || right > current + view) {
        quarterScroll.jumpTo(
          (left < current ? left : right - view).clamp(
            0.0,
            quarterScroll.position.maxScrollExtent,
          ),
        );
      }
    });
  }

  void moveQuarterBook(bool older) {
    if (!quarterScroll.hasClients) return;
    final distance = quarterScroll.position.viewportDimension * .8;
    unawaited(
      quarterScroll.animateTo(
        (quarterScroll.offset + (older ? distance : -distance)).clamp(
          0.0,
          quarterScroll.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      ),
    );
  }

  Widget bookTitle(String en, String zh, {double size = 18}) => Text(
    w(en, zh),
    style: TextStyle(
      color: p.text,
      fontSize: size,
      fontWeight: FontWeight.w700,
    ),
  );

  Widget bookHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        bookTitle('Quarterly research', '季度研究', size: 23),
        const SizedBox(height: 5),
        caption(
          'Choose a quarter. See what changed. Read what management said.',
          '选一个季度，看业绩变化，再读管理层怎么说。',
        ),
      ],
    ),
  );

  Widget quarterBook() {
    final rows = asList(data?['periods']);
    final years = rows
        .map((r) => text(r['period']).split('-').first)
        .toSet()
        .toList();
    final year = requested.split('-').first;
    return Container(
      key: const ValueKey('earnings-quarter-book'),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      decoration: BoxDecoration(
        color: p.background.withValues(alpha: .4),
        border: Border.symmetric(horizontal: BorderSide(color: p.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (_, b) {
              final controls = Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: 116,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('earnings-quarter-$requested'),
                      initialValue: years.contains(year) ? year : null,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: w('Jump to year', '跳至年份'),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        for (final y in years)
                          DropdownMenuItem(value: y, child: Text(y)),
                      ],
                      onChanged: (y) {
                        if (y != null) {
                          unawaited(
                            load(
                              text(
                                rows.firstWhere(
                                  (r) => text(r['period']).startsWith('$y-'),
                                )['period'],
                              ),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: requested == text(rows.first['period'])
                        ? null
                        : () => load(),
                    child: Text(w('Latest', '最新')),
                  ),
                  IconButton(
                    tooltip: w('Show newer quarters', '查看较新季度'),
                    onPressed: () => moveQuarterBook(false),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    tooltip: w('Show older quarters', '查看更早季度'),
                    onPressed: () => moveQuarterBook(true),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              );
              final heading = bookTitle(
                '1  Choose a quarter',
                '1  选择季度',
                size: 14,
              );
              return b.maxWidth > 620
                  ? Row(
                      children: [
                        Expanded(child: heading),
                        controls,
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [heading, const SizedBox(height: 12), controls],
                    );
            },
          ),
          const SizedBox(height: 12),
          Scrollbar(
            controller: quarterScroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              key: const ValueKey('earnings-quarter-scroll'),
              controller: quarterScroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final q in rows)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: quarterTile(q),
                    ),
                ],
              ),
            ),
          ),
          caption(
            '${rows.length} fiscal quarters · Newest first · Select a card to read below',
            '${rows.length} 个财季 · 最新在前 · 点击季度卡查看下方详情',
          ),
        ],
      ),
    );
  }

  Widget quarterTile(Map<String, dynamic> q) {
    final selected = q['period'] == requested;
    final observation = earningsBookObservation(widget.history, q, widget.asOf);
    final metrics = asMap(observation['metrics']);
    final label = text(q['period']).replaceFirst('-', ' ');
    return SizedBox(
      width: quarterWidth,
      child: Semantics(
        selected: selected,
        child: Material(
          color: selected ? p.accent.withValues(alpha: .12) : p.panel,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            key: ValueKey('earnings-select-${q['period']}'),
            borderRadius: BorderRadius.circular(6),
            onTap: () {
              if (!selected || failed) unawaited(load(text(q['period'])));
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: selected ? p.accent : p.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: selected ? p.accent : p.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(Icons.check_circle, size: 16, color: p.accent),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    w(
                      'Published ${text(q['availableAt'], '—')}',
                      '披露 ${text(q['availableAt'], '—')}',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 11),
                  ),
                  const SizedBox(height: 12),
                  miniObservation(
                    w('Revenue YoY', '收入同比'),
                    percentage(metrics['revenueGrowth']),
                  ),
                  const SizedBox(height: 6),
                  miniObservation(
                    w('FCF margin', '现金流率'),
                    percentage(metrics['fcfMargin']),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget miniObservation(String label, String value) => Row(
    children: [
      Expanded(
        child: Text(label, style: TextStyle(color: p.muted, fontSize: 11)),
      ),
      const SizedBox(width: 4),
      Text(
        value,
        style: TextStyle(
          color: p.text,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    ],
  );

  Widget quarterReading(Map<String, dynamic> row) {
    final qa = asList(row['qa']), guidance = asList(row['guidance']);
    final rows = asList(data?['periods']);
    final index = rows.indexWhere((r) => r['period'] == requested);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: bookTitle(
                  '2  Read ${requested.replaceFirst('-', ' ')}',
                  '2  阅读 ${requested.replaceFirst('-', ' ')}',
                  size: 18,
                ),
              ),
              IconButton(
                tooltip: w('Previous quarter', '上一季度'),
                onPressed: index >= 0 && index + 1 < rows.length
                    ? () => load(text(rows[index + 1]['period']))
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: w('Next quarter', '下一季度'),
                onPressed: index > 0
                    ? () => load(text(rows[index - 1]['period']))
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              caption(
                'Period ended ${text(row['periodEnd'], '—')}',
                '报告期末 ${text(row['periodEnd'], '—')}',
              ),
              caption(
                'Published ${text(row['availableAt'], '—')}',
                '披露日期 ${text(row['availableAt'], '—')}',
              ),
              if (asMap(row['coverage'])['callDate'] != null)
                caption(
                  'Call ${asMap(row['coverage'])['callDate']}',
                  '电话会 ${asMap(row['coverage'])['callDate']}',
                ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final t in [
                ('recap', 'Results & changes', '业绩与变化', Icons.bar_chart),
                (
                  'guidance',
                  'Guidance · ${guidance.length}',
                  '管理层指引 · ${guidance.length}',
                  Icons.format_quote,
                ),
                (
                  'qa',
                  'Call Q&A · ${qa.length}',
                  '电话会问答 · ${qa.length}',
                  Icons.question_answer_outlined,
                ),
              ])
                ChoiceChip(
                  key: ValueKey('earnings-tab-${t.$1}'),
                  avatar: Icon(
                    t.$4,
                    size: 16,
                    color: tab == t.$1 ? p.accent : p.muted,
                  ),
                  label: Text(w(t.$2, t.$3)),
                  selected: tab == t.$1,
                  onSelected: (_) => selectReadingTab(t.$1),
                ),
            ],
          ),
          const SizedBox(height: 18),
          if (tab == 'recap') quarterRecap(row),
          if (tab == 'guidance') ...[
            bookTitle('What is management expecting next?', '管理层对接下来有什么预期？'),
            const SizedBox(height: 5),
            caption(
              'Statements from this quarter; their targets may refer to later periods. Not every statement is a model input.',
              '本季管理层表述，目标可能指向未来期间；并非每条都被模型采纳。',
            ),
            if (asMap(row['guidanceAudit'])['status'] == 'review_required')
              caption(
                'This quarter has source or model-reference audit issues. Stored originals are retained; the published valuation is not recertified.',
                '此季度有来源或模型引用审计问题。保留原文供核对，平台估值尚未重新认证。',
              ),
            if (guidance.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: caption(
                  'No guidance evidence is attached to this quarter. This does not prove management gave no guidance.',
                  '此季度未附指引证据，不代表管理层没有发布指引。',
                ),
              ),
            for (final (i, g) in guidance.indexed) quote(g, i),
          ],
          if (tab == 'qa') ...[
            bookTitle('What did analysts challenge?', '分析师追问了什么？'),
            const SizedBox(height: 6),
            Text(
              coverageText(asMap(row['coverage'])),
              style: TextStyle(color: p.muted, fontSize: 13, height: 1.5),
            ),
            if (Uri.tryParse(text(asMap(row['coverage'])['url']))?.scheme ==
                'https')
              Align(
                alignment: Alignment.centerLeft,
                child: sourceButton(text(asMap(row['coverage'])['url'])),
              ),
            if (qa.isEmpty)
              TextButton(
                onPressed: () => selectReadingTab('guidance'),
                child: Text(w('Read available guidance', '查看已有指引')),
              ),
            for (final (i, q) in qa.indexed) question(q, i, requested),
            if (qa.isNotEmpty)
              caption(
                'Stored extracts, not the full transcript. Q&A does not enter your DCF automatically.',
                '已存摘录，并非完整逐字稿。问答不会自动进入你的 DCF。',
              ),
          ],
          if (widget.onOpenValuation != null) ...[
            const SizedBox(height: 18),
            Divider(height: 1, color: p.border),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (_, b) {
                final heading = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    bookTitle(
                      '3  Put the evidence into your assumptions',
                      '3  用证据检验自己的假设',
                      size: 14,
                    ),
                    const SizedBox(height: 4),
                    caption(
                      'Opens your ${widget.asOf} valuation. Browsing quarters changes nothing in it.',
                      '进入截止 ${widget.asOf} 的估值。浏览历史季度不会修改其中的假设。',
                    ),
                  ],
                );
                final action = FilledButton.icon(
                  key: const ValueKey('earnings-open-valuation'),
                  onPressed: widget.onOpenValuation,
                  icon: const Icon(Icons.arrow_forward, size: 16),
                  label: Text(w('Open valuation', '打开估值')),
                );
                return b.maxWidth > 700
                    ? Row(
                        children: [
                          Expanded(child: heading),
                          const SizedBox(width: 16),
                          action,
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [heading, const SizedBox(height: 10), action],
                      );
              },
            ),
          ],
        ],
      ),
    );
  }

  String metricLabel(String key) => switch (key) {
    'revenueGrowth' => w('Revenue YoY', '收入同比'),
    'operatingMargin' => w('Operating margin', '营业利润率'),
    'fcfMargin' => w('FCF margin', '自由现金流率'),
    _ => w('Capex / revenue', '资本开支 / 收入'),
  };

  Widget quarterRecap(Map<String, dynamic> row) {
    final metrics = asList(row['metrics']);
    final model = asMap(row['model']);
    final currency = text(row['currency']);
    final table = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bookTitle('What changed this quarter?', '本季发生了什么变化？', size: 17),
        const SizedBox(height: 12),
        Table(
          columnWidths: const {
            0: FlexColumnWidth(1.6),
            1: FlexColumnWidth(),
            2: FlexColumnWidth(),
            3: FlexColumnWidth(),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder(horizontalInside: BorderSide(color: p.border)),
          children: [
            TableRow(
              children: [
                metricCell(w('Metric', '指标'), header: true),
                metricCell(w('Prior', '上期'), header: true, end: true),
                metricCell(w('This quarter', '本季'), header: true, end: true),
                metricCell(w('Δ pp', '变动 (百分点)'), header: true, end: true),
              ],
            ),
            for (final m in metrics)
              TableRow(
                children: [
                  metricCell(metricLabel(text(m['key']))),
                  metricCell(
                    percentage(m['previous']),
                    end: true,
                    color: p.muted,
                  ),
                  metricCell(percentage(m['value']), end: true, strong: true),
                  metricCell(
                    m['delta'] == null
                        ? '—'
                        : '${number(m['delta']) >= 0 ? '+' : ''}${(number(m['delta']) * 100).toStringAsFixed(2)}',
                    end: true,
                    color: m['key'] == 'capexIntensity' || m['delta'] == null
                        ? p.muted
                        : number(m['delta']) < 0
                        ? p.secondary
                        : p.accent,
                  ),
                ],
              ),
          ],
        ),
        const SizedBox(height: 10),
        caption(
          'Versus ${row['previousPeriod'] ?? '—'}. Revenue growth is quarterly YoY; margins and capex are TTM. pp = percentage points.',
          '对比 ${row['previousPeriod'] ?? '—'}。收入为单季度同比，利润率和资本开支采用 TTM。pp 为百分点。',
        ),
      ],
    );
    final side = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.background.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          caption('PUBLISHED VALUE / SHARE', '平台估值 / 股', color: p.accent),
          const SizedBox(height: 8),
          Text(
            money(model['value'], currency),
            style: TextStyle(
              color: p.text,
              fontSize: 30,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          caption(
            'Previous ${money(model['previous'], currency)} · Change ${money(model['delta'], currency)}',
            '上期 ${money(model['previous'], currency)} · 变化 ${money(model['delta'], currency)}',
          ),
          const SizedBox(height: 14),
          bookTitle('Worth a closer look', '值得进一步追问', size: 14),
          const SizedBox(height: 6),
          diligenceQuestion(metrics),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () => selectReadingTab('guidance'),
            icon: const Icon(Icons.format_quote, size: 16),
            label: Text(w('Read management guidance', '阅读管理层指引')),
          ),
          caption(
            'Model-node comparison, not a causal call-impact estimate or your personal DCF.',
            '模型节点对比，不是电话会影响归因，也不是你的个人 DCF。',
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (_, b) => b.maxWidth >= 820
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: table),
                const SizedBox(width: 24),
                Expanded(flex: 2, child: side),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [table, const SizedBox(height: 18), side],
            ),
    );
  }

  Widget diligenceQuestion(List<Map<String, dynamic>> metrics) {
    final cash = metrics.where((m) => m['key'] == 'fcfMargin').firstOrNull;
    final delta = nullableNumber(cash?['delta']);
    if (delta == null) {
      return caption(
        'Cash-conversion comparison is incomplete. Check the filings before extrapolating growth.',
        '现金转化对比数据不完整。外推增长前，先核对财报。',
      );
    }
    return delta < 0
        ? caption(
            'FCF margin fell. Does management explain the working-capital or investment spending behind it?',
            '自由现金流率下降。管理层是否解释了营运资本或投资支出的影响？',
          )
        : caption(
            'FCF margin held up or improved. Is that repeatable, or did timing help this period?',
            '自由现金流率持平或改善。这能否持续，还是受本期收付款时点影响？',
          );
  }

  Widget metricCell(
    String value, {
    bool header = false,
    bool end = false,
    bool strong = false,
    Color? color,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 3),
    child: Text(
      value,
      textAlign: end ? TextAlign.end : TextAlign.start,
      style: TextStyle(
        color: color ?? (header ? p.muted : p.text),
        fontSize: header ? 11 : 13,
        fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
      ),
    ),
  );
}
