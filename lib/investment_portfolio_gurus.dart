part of 'main.dart';

// The API supplies one common disclosed quarter and exact security matches.
// No private amounts/quantities enter this public-evidence component.
extension _PortfolioGuruEvidence on _PortfolioResearchPanelState {
  Widget portfolioGuruButton(Map<String, dynamic> position) {
    if (position['kind'] != 'equity') return const SizedBox.shrink();
    return IconButton(
      key: ValueKey(
        'portfolio-guru-open-${position['id'] ?? position['ticker']}',
      ),
      tooltip: w('Guru filing evidence', '大佬持仓证据'),
      icon: Icon(Icons.groups_outlined, color: p.accent, size: 20),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: p.panel,
          title: Text(
            '${position['ticker']} · ${w('Guru filing evidence', '大佬持仓证据')}',
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
      ),
    );
  }

  String guruQuarter(dynamic date) {
    final d = DateTime.tryParse(text(date));
    return d == null ? '—' : '${d.year} Q${(d.month + 2) ~/ 3}';
  }

  String guruAction(String action) => switch (action) {
    'new' => w('New position', '新建仓'),
    'increased' => w('Added', '加仓'),
    'reduced' => w('Reduced', '减仓'),
    'sold_out' => w('Exited', '清仓'),
    'unchanged' => w('Unchanged', '未变'),
    _ => w('Change unavailable', '变动未知'),
  };

  String guruWeight(dynamic value) =>
      number(value) > 0 && number(value) < .001 ? '<0.1%' : percent(value);

  Widget portfolioGuruEvidence(
    Map<String, dynamic> position, {
    VoidCallback? beforeNavigate,
  }) {
    if (position['kind'] != 'equity') return const SizedBox.shrink();
    final activity = asMap(position['guruActivity']);
    if (activity['status'] == 'outside_scope') return const SizedBox.shrink();
    final rows = asList(activity['rows']);
    final ticker = text(position['ticker']);
    final quarter = guruQuarter(activity['reportDate']);
    final adds = rows
        .where((m) => ['new', 'increased'].contains(m['action']))
        .toList();
    final trims = rows
        .where((m) => ['reduced', 'sold_out'].contains(m['action']))
        .toList();
    final other = rows
        .where(
          (m) => ![
            'new',
            'increased',
            'reduced',
            'sold_out',
          ].contains(m['action']),
        )
        .toList();
    final balance = switch (activity['balance']) {
      'more_adds' => w('More adding than reducing', '加仓人数更多'),
      'more_trims' => w('More reducing than adding', '减仓人数更多'),
      'balanced' => w('Equal numbers adding and reducing', '加减仓人数相同'),
      'no_changes' => w('No reported share changes', '未见报告股数变动'),
      _ => w('Share-change comparison incomplete', '股数变动对比不完整'),
    };
    final coverage = w(
      '${activity['reportedManagers'] ?? 0} / ${activity['eligibleManagers'] ?? 0} covered Gurus filed · ${activity['extractedBooks'] ?? 0} partial books. Exact share class only.',
      '覆盖范围内 ${activity['reportedManagers'] ?? 0} / ${activity['eligibleManagers'] ?? 0} 位大佬已披露 · ${activity['extractedBooks'] ?? 0} 份为部分持仓。仅匹配同一股票类别。',
    );
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            copy(
              activity['status'] == 'no_matches'
                  ? 'Guru activity · $quarter · No matching holding or exit in the covered filings.'
                  : activity['status'] == 'identity_unresolved'
                  ? 'Guru activity · Security identity needs review; no ownership inferred.'
                  : 'Guru activity unavailable for this cutoff.',
              activity['status'] == 'no_matches'
                  ? '大佬动向 · $quarter · 覆盖的披露中未匹配到持仓或清仓记录。'
                  : activity['status'] == 'identity_unresolved'
                  ? '大佬动向 · 证券身份待核对，未推断持有人。'
                  : '该截止日暂无大佬动向数据。',
              size: 12,
            ),
            if (activity['reportDate'] != null)
              Text(coverage, style: TextStyle(color: p.muted, fontSize: 11)),
          ],
        ),
      );
    }
    return ExpansionTile(
      key: PageStorageKey('portfolio-gurus-${position['id'] ?? ticker}'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      iconColor: p.accent,
      collapsedIconColor: p.accent,
      title: Text(
        w('Guru activity · $quarter', '大佬动向 · $quarter'),
        style: heading(14),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                Text(
                  w(
                    '${activity['holders']} holders',
                    '${activity['holders']} 位持有',
                  ),
                  style: TextStyle(color: p.text, fontSize: 12),
                ),
                Text(
                  w(
                    '${activity['adds']} added / new',
                    '${activity['adds']} 位加仓 / 新建',
                  ),
                  style: TextStyle(color: p.accent, fontSize: 12),
                ),
                Text(
                  w(
                    '${activity['trims']} reduced / exited',
                    '${activity['trims']} 位减仓 / 清仓',
                  ),
                  style: TextStyle(color: p.negative, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '$balance · ${w('by manager count, not net buying value', '按人数比较，非资金净流入')}',
              style: TextStyle(color: p.muted, fontSize: 11),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                for (final m in rows.take(3))
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GuruAvatar(
                        guru: {
                          'id': m['guruId'],
                          'name': m['name'],
                          'avatarUrl': m['avatar'],
                        },
                        palette: p,
                        size: 22,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        text(m['name']),
                        style: TextStyle(color: p.muted, fontSize: 11),
                      ),
                    ],
                  ),
                Text(
                  w('See all ${rows.length} →', '查看全部 ${rows.length} 位 →'),
                  style: TextStyle(color: p.accent, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
      children: [
        Text(coverage, style: TextStyle(color: p.muted, fontSize: 11)),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (_, constraints) {
            final sections = [
              guruActivityGroup(
                adds,
                w('Added & new', '加仓与新建'),
                p.accent,
                beforeNavigate: beforeNavigate,
              ),
              guruActivityGroup(
                trims,
                w('Reduced & exited', '减仓与清仓'),
                p.negative,
                beforeNavigate: beforeNavigate,
              ),
            ];
            return constraints.maxWidth < 700
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      sections[0],
                      const SizedBox(height: 12),
                      sections[1],
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: sections[0]),
                      const SizedBox(width: 20),
                      Expanded(child: sections[1]),
                    ],
                  );
          },
        ),
        if (other.isNotEmpty) ...[
          const SizedBox(height: 12),
          guruActivityGroup(
            other,
            w('Other holders · unchanged / unknown', '其他持有人 · 未变 / 未知'),
            p.muted,
            beforeNavigate: beforeNavigate,
          ),
          if (number(activity['unknown']) > 0 ||
              number(activity['extractedBooks']) > 0 ||
              number(activity['reportedManagers']) <
                  number(activity['eligibleManagers']))
            copy(
              'Partial comparison · ${activity['unknown'] ?? 0} unknown changes · ${activity['extractedBooks'] ?? 0} partial books · ${activity['reportedManagers']} / ${activity['eligibleManagers']} Gurus filed',
              '部分对比 · ${activity['unknown'] ?? 0} 项变动未知 · ${activity['extractedBooks'] ?? 0} 份部分持仓 · ${activity['reportedManagers']} / ${activity['eligibleManagers']} 位已披露',
              size: 11,
            ),
        ],
        const SizedBox(height: 10),
        copy(
          'Reported 13F share changes, not real-time trades. Splits and other corporate actions may affect changes. Missing records are not treated as exits.',
          '依据 13F 报告股数变化，并非实时交易；拆股等公司行动可能影响变动，缺失记录不作为清仓。',
          size: 11,
        ),
        if (number(activity['identityConflicts']) > 0)
          copy(
            '${activity['identityConflicts']} identity conflicts excluded.',
            '${activity['identityConflicts']} 项身份冲突已排除。',
            size: 11,
          ),
      ],
    );
  }

  Widget guruActivityGroup(
    List<Map<String, dynamic>> rows,
    String label,
    Color color, {
    VoidCallback? beforeNavigate,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '$label · ${rows.length}',
        style: heading(13).copyWith(color: color),
      ),
      if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: copy(
            'None in the available comparison.',
            '可用对比中暂无记录。',
            size: 12,
          ),
        ),
      for (final m in rows)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton(
            onPressed: text(m['accession']).isEmpty
                ? null
                : () {
                    beforeNavigate?.call();
                    widget.onGuru(text(m['guruId']), text(m['accession']));
                  },
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.all(10),
              alignment: Alignment.centerLeft,
            ),
            child: Row(
              children: [
                GuruAvatar(
                  guru: {
                    'id': m['guruId'],
                    'name': m['name'],
                    'avatarUrl': m['avatar'],
                  },
                  palette: p,
                  size: 30,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        text(m['name']),
                        style: TextStyle(color: p.text, fontSize: 13),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${guruAction(text(m['action']))} · ${w('Guru weight', '大佬持仓权重')} ${guruWeight(m['weight'])}',
                        style: TextStyle(color: color, fontSize: 11),
                      ),
                      if (m['shareChange'] != null)
                        Text(
                          '${w('Reported shares', '报告股数变化')} ${portfolioRateLabel(m['shareChange'])}',
                          style: TextStyle(color: p.muted, fontSize: 11),
                        ),
                      Text(
                        '${w('Filed', '披露于')} ${m['availableAt'] ?? '—'}',
                        style: TextStyle(color: p.muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: p.muted, size: 16),
              ],
            ),
          ),
        ),
    ],
  );
}
