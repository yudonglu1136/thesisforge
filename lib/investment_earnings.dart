part of 'main.dart';

// Isolated read-only quarter state: never changes the personal DCF or cutoff.
class EarningsResearchPanel extends StatefulWidget {
  const EarningsResearchPanel({
    super.key,
    required this.api,
    required this.ticker,
    required this.asOf,
    required this.palette,
    this.history = const [],
    this.onOpenValuation,
  });
  final ApiClient api;
  final String ticker, asOf;
  final Palette palette;
  final List<Map<String, dynamic>> history;
  final VoidCallback? onOpenValuation;
  @override
  State<EarningsResearchPanel> createState() => _EarningsResearchPanelState();
}

class _EarningsResearchPanelState extends State<EarningsResearchPanel> {
  Map<String, dynamic>? data;
  String requested = '', tab = 'recap';
  bool loading = true, failed = false;
  int serial = 0;
  final quarterScroll = ScrollController();
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  void selectReadingTab(String next) => setState(() => tab = next);
  @override
  void dispose() {
    quarterScroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant EarningsResearchPanel old) {
    super.didUpdateWidget(old);
    if (old.ticker != widget.ticker || old.asOf != widget.asOf) {
      data = null;
      requested = '';
      tab = 'recap';
      unawaited(load());
    }
  }

  Future<void> load([String period = '']) async {
    final current = ++serial;
    setState(() {
      loading = true;
      failed = false;
      requested = period;
    });
    try {
      final r = await widget.api
          .getJson(
            '/api/investment/research/${Uri.encodeComponent(widget.ticker)}/earnings?asOf=${widget.asOf}${period.isEmpty ? '' : '&period=${Uri.encodeComponent(period)}'}',
          )
          .timeout(const Duration(seconds: 12));
      if (!mounted || current != serial) return;
      if (r['ticker'] != widget.ticker ||
          r['asOf'] != widget.asOf ||
          r['periods'] is! List ||
          (period.isNotEmpty && asMap(r['selected'])['period'] != period)) {
        throw StateError('earnings_identity_mismatch');
      }
      setState(() {
        data = r;
        requested = text(asMap(r['selected'])['period']);
        loading = false;
      });
      revealQuarter();
    } catch (_) {
      if (mounted && current == serial) {
        setState(() {
          loading = false;
          failed = true;
        });
      }
    }
  }

  Widget caption(String en, String zh, {Color? color}) => Text(
    w(en, zh),
    style: TextStyle(color: color ?? p.muted, fontSize: 12, height: 1.5),
  );
  String percentage(dynamic v) => nullableNumber(v) == null
      ? '—'
      : '${(number(v) * 100).toStringAsFixed(2)}%';
  String money(dynamic v, String currency) => nullableNumber(v) == null
      ? '—'
      : '${currencySymbol(currency)}${number(v).toStringAsFixed(2)}';
  String coverageText(Map<String, dynamic> c) => switch (text(c['status'])) {
    'has_qa' => w(
      'Stored analyst questions and management answers.',
      '已存分析师提问与管理层回答。',
    ),
    'locked_preview' => w(
      'Only a locked preview is stored for this quarter; Q&A is unavailable.',
      '此季度仅有锁定预览，问答尚不可用。',
    ),
    'partial_transcript' => w(
      'The stored transcript is incomplete; no reliable Q&A is available.',
      '逐字稿不完整，尚无可靠问答。',
    ),
    'no_segments' => w(
      'The call record exists, but transcript text is missing.',
      '已有电话会记录，但缺少逐字稿正文。',
    ),
    'qa_parse_miss' => w(
      'The stored text could not be safely paired into analyst questions and management answers.',
      '现有文本尚未可靠配对为分析师问题与管理层回答。',
    ),
    'identity_mismatch' => w(
      'The stored call does not match this company and fiscal quarter.',
      '已存电话会与此公司或财季不匹配。',
    ),
    'unavailable_at_cutoff' => w(
      'No dated call evidence is available by the selected cutoff.',
      '所选截止日前暂无可验证日期的电话会证据。',
    ),
    _ => w(
      'No Q&A transcript is stored for this fiscal quarter. Guidance and reported results remain available below.',
      '此财季尚未存入电话会问答；仍可查看指引与已披露业绩。',
    ),
  };
  Widget sourceButton(String url) => OutlinedButton.icon(
    onPressed: Uri.tryParse(url)?.scheme == 'https'
        ? () => openBrowserPath(url)
        : null,
    icon: const Icon(Icons.open_in_new, size: 15),
    label: Text(w('Open call source', '打开电话会来源')),
  );
  @override
  Widget build(BuildContext context) {
    final row = asMap(data?['selected']);
    return Container(
      key: const ValueKey('earnings-research'),
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          bookHeader(),
          if (asList(data?['periods']).isNotEmpty) quarterBook(),
          if (loading)
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                children: [
                  const LinearProgressIndicator(),
                  const SizedBox(height: 10),
                  caption('Loading quarter research…', '正在读取季度研究…'),
                ],
              ),
            ),
          if (failed)
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  caption(
                    'Quarter research could not be loaded. Your valuation and saved hypotheses are unchanged.',
                    '季度研究加载失败。你的估值和已存假设未改动。',
                  ),
                  TextButton.icon(
                    key: const ValueKey('earnings-retry'),
                    onPressed: () => load(requested),
                    icon: const Icon(Icons.refresh),
                    label: Text(w('Retry quarter', '重试此季度')),
                  ),
                ],
              ),
            ),
          if (!loading && !failed && row.isEmpty)
            Padding(
              padding: const EdgeInsets.all(22),
              child: caption(
                'No quarterly research is stored for this company at the selected cutoff.',
                '所选截止日前未存入此公司的季度研究。',
              ),
            ),
          if (!loading && !failed && row.isNotEmpty) quarterReading(row),
        ],
      ),
    );
  }

  Widget quote(Map<String, dynamic> g, int i) => Container(
    margin: const EdgeInsets.only(top: 18),
    padding: const EdgeInsets.only(left: 16),
    decoration: BoxDecoration(
      border: Border(left: BorderSide(color: p.accent, width: 2)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (g['disposition'] != null)
          caption(
            g['disposition'] == 'quantified_evidence'
                ? 'Quantified excerpt · ${g['targetYear'] ?? 'target year unresolved'} · not automatically a model input'
                : 'Research context only · not an approved company forecast',
            g['disposition'] == 'quantified_evidence'
                ? '量化证据 · ${g['targetYear'] ?? '目标年份未明确'} · 不自动作为模型输入'
                : '仅供研究参考 · 不是已采纳的公司预测',
          ),
        if (context.isChinese && text(g['excerptZh']).isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: caption(
              'Original English transcript excerpt',
              '以下为英文电话会原话摘录',
            ),
          ),
        SelectableText(
          text(
            context.isChinese && text(g['excerptZh']).isNotEmpty
                ? g['excerptZh']
                : g['excerpt'],
          ),
          style: TextStyle(color: p.text, fontSize: 14, height: 1.6),
        ),
        const SizedBox(height: 8),
        Text(
          '${localizeExecutiveSpeaker(text(g['speaker']), context.language)} · ${text(g['observedAt'])}',
          style: TextStyle(color: p.muted, fontSize: 12),
        ),
        if (Uri.tryParse(text(g['url']))?.scheme == 'https')
          TextButton.icon(
            onPressed: () => openBrowserPath(text(g['url'])),
            icon: const Icon(Icons.open_in_new, size: 14),
            label: Text(w('Open evidence', '打开证据')),
          ),
      ],
    ),
  );

  Widget question(Map<String, dynamic> q, int i, String period) {
    final zh = context.isChinese;
    final translated =
        text(q['questionZh']).isNotEmpty && text(q['answerZh']).isNotEmpty;
    final title = text(q[zh && translated ? 'questionZh' : 'question']);
    final answer = text(q[zh && translated ? 'answerZh' : 'answer']);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
          key: ValueKey('earnings-question-$period-$i'),
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          leading: Text(
            '${i + 1}'.padLeft(2, '0'),
            style: TextStyle(
              color: p.accent,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          title: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: p.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (zh && !translated)
                  caption(
                    'Original-language excerpt; verified translation is not stored.',
                    '以下为原文，尚未存入经核验的译文。',
                  ),
                SelectableText(
                  title,
                  style: TextStyle(
                    color: p.text,
                    fontSize: 14,
                    height: 1.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                caption(
                  'Asked by ${text(q['askedBy'])} · ${text(q['callDate'])}',
                  '提问人 ${text(q['askedByZh'], text(q['askedBy']))} · ${text(q['callDate'])}',
                ),
                const SizedBox(height: 18),
                caption('MANAGEMENT ANSWER', '管理层回答', color: p.accent),
                const SizedBox(height: 8),
                SelectableText(
                  answer,
                  style: TextStyle(color: p.text, fontSize: 14, height: 1.7),
                ),
                if (Uri.tryParse(text(q['url']))?.scheme == 'https')
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => openBrowserPath(text(q['url'])),
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: Text(w('Open source', '打开来源')),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
