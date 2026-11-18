part of 'main.dart';

// Display helpers never promote raw 13F changes into split-adjusted trades.
String disclosedShareCount(dynamic value, {bool signed = false}) {
  final n = nullableNumber(value);
  if (n == null) return '—';
  final sign = signed && n > 0 ? '+' : '';
  if (n.abs() >= 1e9) return '$sign${(n / 1e9).toStringAsFixed(2)}B';
  if (n.abs() >= 1e6) return '$sign${(n / 1e6).toStringAsFixed(2)}M';
  if (n.abs() >= 1e3) return '$sign${(n / 1e3).toStringAsFixed(2)}K';
  return '$sign${formatNumber(n)}';
}

List<Map<String, dynamic>> orderedDisclosedHolders(
  List<Map<String, dynamic>> rows,
  String query,
) {
  final needle = query.trim().toLowerCase();
  return rows
      .where(
        (r) => '${r['name']} ${r['guruId']}'.toLowerCase().contains(needle),
      )
      .toList()
    ..sort((a, b) {
      final left = nullableNumber(a['shares']),
          right = nullableNumber(b['shares']);
      if (left == null && right != null) return 1;
      if (left != null && right == null) return -1;
      return (right ?? 0).compareTo(left ?? 0) != 0
          ? (right ?? 0).compareTo(left ?? 0)
          : text(a['name']).compareTo(text(b['name']));
    });
}

extension _ResearchHolderDesk on _InvestmentWorkspaceState {
  Map<String, dynamic> holderIdentity(Map<String, dynamic> g) => {
    'id': g['guruId'],
    'name': g['name'],
    'avatarUrl': g['avatar'] ?? '/guru-avatars/${g['guruId']}.png',
  };

  Widget holderAvatar(Map<String, dynamic> g, double size) => Semantics(
    image: true,
    label: w('${text(g['name'])} portrait', '${text(g['name'])} 头像'),
    child: GuruAvatar(guru: holderIdentity(g), palette: p, size: size),
  );

  Future<void> openHolderGuru(Map<String, dynamic> g) async {
    if (!await allowLeaveDraft() || !mounted) return;
    final symbol = ticker;
    if (opportunityReturnDate.isNotEmpty) {
      asOf = opportunityReturnDate;
      opportunityReturnDate = '';
    }
    discoveryTab = 'managers';
    navigate('discover');
    await loadGuru(
      text(g['guruId']),
      filingId: text(g['accession']),
      holdingTicker: symbol,
    );
  }

  Widget disclosedHoldersWorkspace() {
    final all = asList(company?['provenance']);
    final rows = orderedDisclosedHolders(all, holderQuery);
    final selected =
        rows.where((r) => r['guruId'] == researchHolderId).firstOrNull ??
        rows.firstOrNull;
    return Container(
      key: researchHoldersKey,
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.people_outline, color: p.accent, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        w('Who holds $ticker?', '谁持有 $ticker？'),
                        style: deskHeading(22),
                      ),
                    ),
                    researchTag(
                      w('${all.length} disclosed', '${all.length} 家披露机构'),
                      p.muted,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                label(
                  'Compare the reported positions. Inspect the filing. Decide which evidence belongs in your thesis.',
                  '对比申报持仓，核对披露来源，再决定哪些证据值得纳入你的判断。',
                  size: 13,
                ),
              ],
            ),
          ),
          Divider(color: p.border, height: 1),
          if (all.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: label(
                'No matching holding in the available bounded Guru evidence. This does not prove no Guru owns it.',
                '可用的投资大师有限披露记录中没有匹配，不代表没有大师持有。',
                size: 13,
              ),
            )
          else
            LayoutBuilder(
              builder: (_, bounds) {
                final wide =
                    bounds.maxWidth >= 940 &&
                    MediaQuery.textScalerOf(context).scale(1) <= 1.3;
                final roster = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                      child: TextField(
                        key: const ValueKey('holder-search'),
                        controller: holderSearch,
                        onChanged: (v) => updateUI(() => holderQuery = v),
                        style: TextStyle(color: p.text, fontSize: 13),
                        decoration: InputDecoration(
                          hintText: w('Find a manager', '查找基金经理'),
                          prefixIcon: Icon(
                            Icons.search,
                            size: 19,
                            color: p.muted,
                          ),
                          suffixIcon: holderQuery.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: w('Clear manager search', '清除经理搜索'),
                                  icon: const Icon(Icons.close, size: 17),
                                  onPressed: () => updateUI(() {
                                    holderQuery = '';
                                    holderSearch.clear();
                                  }),
                                ),
                          isDense: true,
                          filled: true,
                          fillColor: p.background.withValues(alpha: .35),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide(color: p.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide(color: p.border),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      child: wide
                          ? Row(
                              children: [
                                Expanded(
                                  child: label('MANAGER', '基金经理', size: 10),
                                ),
                                SizedBox(
                                  width: 100,
                                  child: Text(
                                    w('SHARES', '申报股数'),
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      color: p.muted,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 20),
                                SizedBox(
                                  width: 90,
                                  child: Text(
                                    w('BOOK WEIGHT', '披露组合权重'),
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      color: p.muted,
                                      fontSize: 10,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 26),
                              ],
                            )
                          : label(
                              'REPORTED POSITIONS · Select a manager',
                              '申报持仓 · 点击查看经理详情',
                              size: 10,
                            ),
                    ),
                    if (rows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: label(
                          'No managers match your search.',
                          '没有匹配的基金经理。',
                          size: 13,
                        ),
                      ),
                    for (final g in rows) ...[
                      holderRosterRow(
                        g,
                        wide: wide,
                        selected: wide
                            ? text(selected?['guruId']) == text(g['guruId'])
                            : researchHolderId == g['guruId'],
                      ),
                      if (!wide && researchHolderId == g['guruId'])
                        holderDisclosureDetail(g, compact: true),
                    ],
                    Padding(
                      padding: const EdgeInsets.all(18),
                      child: label(
                        'Ordered by reported shares · not an investment ranking',
                        '按申报股数排序 · 不是投资价值排名',
                        size: 11,
                      ),
                    ),
                  ],
                );
                if (!wide) return roster;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: roster),
                    Expanded(
                      flex: 4,
                      child: Container(
                        decoration: BoxDecoration(
                          color: p.background.withValues(alpha: .35),
                          border: Border(left: BorderSide(color: p.border)),
                        ),
                        child: selected == null
                            ? Padding(
                                padding: const EdgeInsets.all(28),
                                child: label(
                                  'Choose a matching manager to inspect the evidence.',
                                  '选择匹配的经理查看证据。',
                                  size: 13,
                                ),
                              )
                            : holderDisclosureDetail(selected),
                      ),
                    ),
                  ],
                );
              },
            ),
          Divider(color: p.border, height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: p.muted, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: label(
                    'Latest available bounded 13F extracts, not a complete ownership register. Disclosures are delayed and do not establish trade dates or investment intent.',
                    '截止日期前最新可得的有限 13F 摘录，并非完整持有人名册。披露有滞后，不代表实际交易日期或投资意图。',
                    size: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget holderRosterRow(
    Map<String, dynamic> g, {
    required bool wide,
    required bool selected,
  }) {
    final original = text(entryEvidence?['guruId']) == text(g['guruId']);
    final linked = sourceGuruIds.contains(text(g['guruId']));
    final shares = nullableNumber(g['shares']);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? p.accent.withValues(alpha: .09) : Colors.transparent,
        child: InkWell(
          key: ValueKey('holder-row-${g['guruId']}'),
          onTap: () => updateUI(
            () => researchHolderId = !wide && selected ? '' : text(g['guruId']),
          ),
          hoverColor: p.accent.withValues(alpha: .05),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  width: 3,
                  color: selected ? p.accent : Colors.transparent,
                ),
                bottom: BorderSide(color: p.border.withValues(alpha: .65)),
              ),
            ),
            child: Row(
              children: [
                holderAvatar(g, wide ? 42 : 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        guruDisplayName(g, context.language),
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        original
                            ? w('Original entry source', '原始研究入口')
                            : linked
                            ? w('Linked to decision', '已选为决策来源')
                            : '${w('Filed', '披露')} ${text(g['availableAt'], '—')}',
                        style: TextStyle(
                          color: original || linked ? p.accent : p.muted,
                          fontSize: 11,
                        ),
                      ),
                      if (!wide) ...[
                        const SizedBox(height: 5),
                        Text(
                          '${context.isChinese ? formatCompactSharesLocalized(g['shares'], AppLanguage.zh) : '${disclosedShareCount(g['shares'])} shares'} · ${pct(g['weight'])} ${w('of book', '组合权重')}',
                          style: TextStyle(color: p.muted, fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                ),
                if (wide) ...[
                  SizedBox(
                    width: 100,
                    child: Tooltip(
                      message: shares == null
                          ? w('Not available', '暂无数据')
                          : '${formatNumber(shares)} ${w('reported shares', '申报股数')}',
                      child: Text(
                        context.isChinese
                            ? (shares == null
                                  ? '—'
                                  : formatCompactSharesLocalized(
                                      shares,
                                      AppLanguage.zh,
                                    ))
                            : disclosedShareCount(shares),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w500,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  SizedBox(
                    width: 90,
                    child: Text(
                      pct(g['weight']),
                      textAlign: TextAlign.right,
                      style: TextStyle(color: p.muted, fontSize: 13),
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                Icon(
                  !wide && selected ? Icons.expand_less : Icons.chevron_right,
                  size: 17,
                  color: selected ? p.accent : p.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget holderDisclosureDetail(
    Map<String, dynamic> g, {
    bool compact = false,
  }) {
    final original = text(entryEvidence?['guruId']) == text(g['guruId']);
    final linked = original || sourceGuruIds.contains(text(g['guruId']));
    final shares = nullableNumber(g['shares']);
    final prior = nullableNumber(g['previousShares']);
    final change = nullableNumber(g['rawReportedChangeShares']);
    final source = Uri.tryParse(text(g['sourceUrl']));
    final usableSource =
        source?.scheme == 'https' && source?.host == 'www.sec.gov';
    return Padding(
      key: ValueKey('holder-detail-${g['guruId']}'),
      padding: EdgeInsets.all(compact ? 20 : 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              holderAvatar(g, 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label(
                      'DISCLOSURE DETAILS',
                      '披露详情',
                      size: 10,
                      color: p.accent,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      guruDisplayName(g, context.language),
                      style: deskHeading(20),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: holderMetric(
                  'Reported shares',
                  '申报股数',
                  shares == null ? '—' : formatNumber(shares),
                  large: true,
                ),
              ),
              const SizedBox(width: 16),
              holderMetric('Book weight', '组合权重', pct(g['weight'])),
            ],
          ),
          const SizedBox(height: 8),
          label(
            'Weight in this manager’s reported long book, not total fund assets.',
            '占该经理披露多头组合的权重，不是基金全部资产的权重。',
            size: 11,
          ),
          const SizedBox(height: 20),
          Divider(color: p.border, height: 1),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: holderMetric(
                  'Prior reported shares',
                  '上次申报股数',
                  prior == null ? '—' : formatNumber(prior),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: holderMetric(
                  'Raw share change',
                  '原始股数变化',
                  change == null
                      ? '—'
                      : '${change > 0 ? '+' : ''}${formatNumber(change)}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: p.secondary.withValues(alpha: .06),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: p.secondary, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: label(
                    'Corporate-action adjustment unverified. Raw changes are not confirmed buys or sells; missing prior shares are not zero.',
                    '尚未核验公司行动调整。原始股数变化不是已确认买卖；缺失的上次股数不视为零。',
                    color: p.secondary,
                    size: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: holderMetric(
                  'Position as of',
                  '持仓截至',
                  text(g['reportDate'], '—'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: holderMetric(
                  'Public filing',
                  '公开披露',
                  text(g['availableAt'], '—'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            key: const ValueKey('holder-source-link'),
            onPressed: usableSource
                ? () => openBrowserPath(source.toString())
                : null,
            icon: const Icon(Icons.open_in_new, size: 15),
            label: Text(w('Open SEC filing', '打开 SEC 披露')),
          ),
          const SizedBox(height: 8),
          button(
            'Explore Guru history',
            '查看投资大师持仓历史',
            () => unawaited(openHolderGuru(g)),
            icon: Icons.arrow_forward,
          ),
          const SizedBox(height: 20),
          Divider(color: p.border, height: 1),
          const SizedBox(height: 14),
          Material(
            color: Colors.transparent,
            child: CheckboxListTile(
              key: ValueKey('holder-link-${g['guruId']}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: linked,
              activeColor: p.accent,
              title: Text(
                original
                    ? w('Original entry source', '原始研究入口')
                    : w('Use in my decision', '用作我的决策来源'),
                style: TextStyle(
                  color: p.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                original
                    ? w(
                        'Kept with your research; cannot be removed here.',
                        '保留你的研究来源，不能在此移除。',
                      )
                    : w(
                        'Applied when you save a decision. Selecting a manager does not place an order.',
                        '保存决策时一并关联，选择经理不会下单。',
                      ),
                style: TextStyle(color: p.muted, fontSize: 11, height: 1.5),
              ),
              onChanged: original
                  ? null
                  : (v) => updateUI(() {
                      if (v == true) {
                        sourceGuruIds.add(text(g['guruId']));
                      } else {
                        sourceGuruIds.remove(text(g['guruId']));
                      }
                    }),
            ),
          ),
        ],
      ),
    );
  }

  Widget holderMetric(
    String en,
    String zh,
    String value, {
    bool large = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      label(en, zh, size: 11),
      const SizedBox(height: 7),
      Text(
        value,
        style: TextStyle(
          color: p.text,
          fontSize: large ? 24 : 15,
          fontWeight: FontWeight.w600,
          letterSpacing: large ? -.6 : 0,
        ),
      ),
    ],
  );
}
