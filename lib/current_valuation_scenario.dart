part of 'main.dart';

bool isCurrentOnlyValuation(Map<String, dynamic> detail) {
  final quality = asMap(detail['dataQuality']);
  return quality['currentOnly'] == true ||
      quality['valuationCoverageKind'] == 'current_only';
}

// Dated scenario coverage must not look like a missing chart or a historical
// backtest. Forecast rows and a financing-stress null are never plotted as history.
class CurrentValuationScenarioCard extends StatelessWidget {
  const CurrentValuationScenarioCard({
    super.key,
    required this.detail,
    required this.palette,
  });
  final Map<String, dynamic> detail;
  final Palette palette;

  @override
  Widget build(BuildContext context) {
    final details = asMap(detail['currentScenarioDetails']);
    final assumptions = asMap(details['analystAssumptions']);
    final fx = asMap(details['fx']);
    final currency = text(detail['currency']);
    final scenarios = asList(detail['scenarios']);
    final date = text(asMap(detail['latest'])['valuationAnchorDate']);
    String percent(dynamic raw) {
      final value = nullableNumber(raw);
      return value == null ? '—' : '${(value * 100).toStringAsFixed(2)}%';
    }

    String scenarioLabel(String id) => switch (id.toLowerCase()) {
      'base' => context.tr('基准', 'Base'),
      'upside' => context.tr('上行', 'Upside'),
      'downside' => context.tr('下行', 'Downside'),
      'bull' => context.tr('乐观情景', 'Bull'),
      'bear' => context.tr('悲观情景', 'Bear'),
      _ => context.tr('情景', 'Scenario'),
    };
    return Container(
      key: const ValueKey('current-valuation-scenario'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.tr(
              '当期情景 · 不含历史估值',
              'Current scenario · no historical valuations',
            ),
            style: TextStyle(
              color: palette.accent,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            date.isEmpty
                ? context.tr('日期未提供', 'Date unavailable')
                : formatDate(date),
            style: TextStyle(color: palette.muted, fontSize: 11),
          ),
          const SizedBox(height: 12),
          for (final scenario in scenarios) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    scenarioLabel(text(scenario['scenarioId'])),
                    style: TextStyle(color: palette.text),
                  ),
                ),
                Flexible(
                  child: Text(
                    nullableNumber(scenario['fairValue']) == null
                        ? context.tr('无有效目标价', 'No valid target')
                        : formatCurrencyValue(
                            number(scenario['fairValue']),
                            currency,
                          ),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: palette.accent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            if (number(scenario['fundingDeficitMxnM']) > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${context.tr('需额外融资', 'Additional funding needed')}: MXN ${formatMillions(nullableNumber(scenario['fundingDeficitMxnM']))}',
                  style: TextStyle(color: palette.secondary, fontSize: 11),
                ),
              ),
            const SizedBox(height: 10),
          ],
          Divider(color: palette.border),
          if (nullableNumber(assumptions['keMxn']) != null) ...[
            Text(
              '${context.tr('股权资本成本（MXN）', 'Cost of equity (MXN)')}: ${percent(assumptions['keMxn'])}',
              style: TextStyle(color: palette.text, fontSize: 12),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            '${context.tr('每份股权终值增长率', 'Terminal growth per claim')}: ${percent(assumptions['terminalPerCurrentClaimGrowth'])}',
            style: TextStyle(color: palette.text, fontSize: 12),
          ),
          if (nullableNumber(fx['mxnPerUsd']) != null) ...[
            const SizedBox(height: 6),
            Text(
              '${context.tr('汇率 MXN/USD', 'FX MXN/USD')}: ${nullableNumber(fx['mxnPerUsd'])!.toStringAsFixed(4)}',
              style: TextStyle(color: palette.text, fontSize: 12),
            ),
          ],
          for (final warning in asList(detail['warningTranslations'])) ...[
            const SizedBox(height: 10),
            Text(
              context.tr(
                text(warning['zh'], text(warning['en'])),
                text(warning['en'], text(warning['zh'])),
              ),
              style: TextStyle(color: palette.muted, fontSize: 11, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}
