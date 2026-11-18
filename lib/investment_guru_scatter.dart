part of 'main.dart';

class GuruStudyScatter extends StatelessWidget {
  const GuruStudyScatter({
    super.key,
    required this.rows,
    required this.allRows,
    required this.field,
    required this.palette,
    required this.shortlist,
    required this.inspecting,
    required this.benchmark,
    required this.range,
    required this.onSelect,
  });
  final List<Map<String, dynamic>> rows, allRows;
  final String field, inspecting;
  final Palette palette;
  final List<String> shortlist;
  final Map<String, dynamic> benchmark, range;
  final ValueChanged<String> onSelect;
  String value(dynamic n) => nullableNumber(n) == null
      ? '—'
      : field == 'cagr'
      ? '${(number(n) * 100).toStringAsFixed(2)}%'
      : number(n).toStringAsFixed(2);
  @override
  Widget build(BuildContext context) {
    String w(String en, String zh) => context.tr(zh, en);
    final p = palette,
        strict = rows.where((r) => r['basis'] == 'strict').length,
        proxy = rows.where((r) => r['basis'] == 'proxy').length;
    final scale = GuruScatterScale(
      allRows,
      field,
      nullableNumber(benchmark[field]),
    );
    final points = [...rows]
      ..sort(
        (a, b) =>
            (a['id'] == inspecting
                    ? 2
                    : shortlist.contains(a['id'])
                    ? 1
                    : 0)
                .compareTo(
                  b['id'] == inspecting
                      ? 2
                      : shortlist.contains(b['id'])
                      ? 1
                      : 0,
                ),
      );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                field == 'cagr'
                    ? w('Turnover vs annualized return', '换手率与年化收益')
                    : w('Turnover vs Sharpe', '换手率与夏普'),
                style: TextStyle(
                  color: p.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  legend(
                    w('Cash-preserving · $strict', '未覆盖留现金 · $strict'),
                    false,
                  ),
                  legend(w('Subset proxy · $proxy', '子集代理 · $proxy'), true),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 320,
            child: LayoutBuilder(
              builder: (_, c) {
                final size = Size(c.maxWidth, 320),
                    plot = GuruScatterScale.plot(size);
                final labels =
                    <({Rect rect, Offset point, String label, Color color})>[];
                final highlighted = {
                  ...shortlist,
                  if (inspecting.isNotEmpty) inspecting,
                }.toList();
                for (final id in highlighted) {
                  final r = rows.where((r) => r['id'] == id).firstOrNull;
                  if (r == null ||
                      nullableNumber(r[field]) == null ||
                      nullableNumber(r['annualTurnover']) == null) {
                    continue;
                  }
                  final label = '${r['name']}\n(${value(r[field])})';
                  final measured = TextPainter(
                    text: TextSpan(
                      text: label,
                      style: const TextStyle(fontSize: 12, height: 1.3),
                    ),
                    textDirection: TextDirection.ltr,
                  )..layout(maxWidth: math.min(150, plot.width * .55));
                  final point = scale.position(r, plot),
                      i = highlighted.indexOf(id),
                      width = measured.width,
                      height = measured.height;
                  double x = (point.dx + (i.isEven ? 22 : -width - 20)).clamp(
                    plot.left,
                    plot.right - width,
                  );
                  double y = (point.dy + (i.isEven ? 20 : -55)).clamp(
                    plot.top,
                    plot.bottom - height,
                  );
                  var rect = Rect.fromLTWH(x, y, width, height);
                  for (
                    var attempt = 0;
                    attempt < 5 &&
                        (labels.any((l) => l.rect.inflate(5).overlaps(rect)) ||
                            points.any(
                              (r) =>
                                  r['id'] != id &&
                                  nullableNumber(r[field]) != null &&
                                  rect
                                      .inflate(7)
                                      .contains(scale.position(r, plot)),
                            ));
                    attempt++
                  ) {
                    final previousY = y;
                    y = (y + height + 8).clamp(plot.top, plot.bottom - height);
                    if (y == previousY) {
                      x = (x > plot.center.dx ? plot.left : plot.right - width);
                    }
                    rect = Rect.fromLTWH(x, y, width, height);
                  }
                  labels.add((
                    rect: rect,
                    point: point,
                    label: label,
                    color: id == inspecting
                        ? p.accent
                        : const Color(0xFF72B7FF),
                  ));
                }
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _GuruScatterAxes(
                          scale: scale,
                          palette: p,
                          benchmark: nullableNumber(benchmark[field]),
                          field: field,
                          yTitle: field == 'cagr'
                              ? w('CAGR (%)', '年化收益率 (%)')
                              : w('Sharpe (Rf=0%)', '夏普比率（Rf=0%）'),
                          xTitle: w(
                            'Less trading ←  Annual one-way turnover (%)  → More trading',
                            '低换手 ←  年化单边换手率（%）  → 高换手',
                          ),
                          labels: labels,
                        ),
                      ),
                    ),
                    for (final r in points)
                      if (nullableNumber(r[field]) != null &&
                          nullableNumber(r['annualTurnover']) != null)
                        Positioned(
                          left: scale.position(r, plot).dx - 12,
                          top: scale.position(r, plot).dy - 12,
                          width: 24,
                          height: 24,
                          child: Tooltip(
                            waitDuration: const Duration(milliseconds: 120),
                            textStyle: TextStyle(
                              color: p.text,
                              fontSize: 12,
                              height: 1.4,
                            ),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: p.panel,
                              border: Border.all(color: p.border),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            message:
                                '${guruDisplayName(r, context.language)}\n${w('Annual turnover', '年化换手率')}: ${(number(r['annualTurnover']) * 100).toStringAsFixed(2)}%\n${field == 'cagr' ? w('CAGR', '年化收益') : w('Sharpe', '夏普比率')}: ${value(r[field])}\n${r['basis'] == 'strict' ? w('Cash-preserving', '未覆盖留现金') : w('Subset proxy', '可定价子集代理')}\n${range['start']} — ${range['end']}',
                            child: Semantics(
                              button: true,
                              selected: r['id'] == inspecting,
                              label:
                                  '${guruDisplayName(r, context.language)} · ${field == 'cagr' ? w('CAGR', '年化收益') : w('Sharpe', '夏普比率')} ${value(r[field])}',
                              child: InkResponse(
                                key: ValueKey('study-point-$field-${r['id']}'),
                                onTap: () => onSelect(text(r['id'])),
                                radius: 16,
                                child: CustomPaint(
                                  painter: _GuruStudyDot(
                                    proxy: r['basis'] == 'proxy',
                                    selected:
                                        shortlist.contains(r['id']) ||
                                        r['id'] == inspecting,
                                    color: r['id'] == inspecting
                                        ? p.accent
                                        : shortlist.contains(r['id'])
                                        ? const Color(0xFF72B7FF)
                                        : r['basis'] == 'proxy'
                                        ? const Color(0xFFFFBA69)
                                        : const Color(0xFF70B1F8),
                                    background: p.panel,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget legend(String label, bool proxy) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 12,
        height: 12,
        child: CustomPaint(
          painter: _GuruStudyDot(
            proxy: proxy,
            selected: false,
            color: proxy ? const Color(0xFFFFBA69) : const Color(0xFF70B1F8),
            background: palette.panel,
          ),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(fontSize: 10, color: palette.muted)),
    ],
  );
}

// One fixed X domain for both charts and all UI filters; genuine negatives and
// outliers stay on scale. Percent units are consistently used on the axes.
class GuruScatterScale {
  GuruScatterScale(
    List<Map<String, dynamic>> rows,
    String field,
    double? benchmark,
  ) {
    final xs = rows.map((r) => number(r['annualTurnover']) * 100).toList();
    final ys = [
      for (final r in rows)
        if (nullableNumber(r[field]) != null)
          number(r[field]) * (field == 'cagr' ? 100 : 1),
      if (benchmark != null) benchmark * (field == 'cagr' ? 100 : 1),
    ];
    final maxX = xs.isEmpty ? 100.0 : xs.reduce(math.max);
    final xStep = nice(math.max(1, maxX) / 4);
    xMax = math.max(xStep * 4, (maxX / xStep).ceil() * xStep);
    final low = ys.isEmpty ? 0.0 : math.min(0.0, ys.reduce(math.min)),
        high = ys.isEmpty ? 1.0 : math.max(0.0, ys.reduce(math.max));
    yStep = nice(math.max(.01, high - low) / 4);
    yMin = (low / yStep).floor() * yStep;
    yMax = math.max(yStep, (high / yStep).ceil() * yStep);
    this.field = field;
  }
  late double xMax, yMin, yMax, yStep;
  late String field;
  static double nice(double v) {
    if (v <= 0) return 1;
    final base = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    final n = v / base;
    return (n <= 1
            ? 1
            : n <= 2
            ? 2
            : n <= 4
            ? 4
            : n <= 5
            ? 5
            : 10) *
        base;
  }

  static Rect plot(Size size) => Rect.fromLTRB(
    52,
    16,
    size.width - 12,
    size.height - (size.width < 450 ? 84 : 62),
  );
  Offset position(Map<String, dynamic> r, Rect plot) => Offset(
    plot.left + number(r['annualTurnover']) * 100 / xMax * plot.width,
    plot.bottom -
        (number(r[field]) * (field == 'cagr' ? 100 : 1) - yMin) /
            (yMax - yMin) *
            plot.height,
  );
}

class _GuruStudyDot extends CustomPainter {
  _GuruStudyDot({
    required this.proxy,
    required this.selected,
    required this.color,
    required this.background,
  });
  final bool proxy, selected;
  final Color color, background;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2),
        paint = Paint()..color = color;
    if (selected) {
      canvas.drawCircle(center, 9, Paint()..color = background);
      canvas.drawCircle(
        center,
        8,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    final radius = math.min(5.0, size.width / 2);
    if (proxy) {
      final path = Path()
        ..moveTo(center.dx, center.dy - radius)
        ..lineTo(center.dx + radius, center.dy)
        ..lineTo(center.dx, center.dy + radius)
        ..lineTo(center.dx - radius, center.dy)
        ..close();
      canvas.drawPath(path, paint);
    } else {
      canvas.drawCircle(center, selected ? 4 : 4.5, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GuruStudyDot old) =>
      old.proxy != proxy || old.selected != selected || old.color != color;
}

class _GuruScatterAxes extends CustomPainter {
  _GuruScatterAxes({
    required this.scale,
    required this.palette,
    required this.benchmark,
    required this.field,
    required this.xTitle,
    required this.yTitle,
    required this.labels,
  });
  final GuruScatterScale scale;
  final Palette palette;
  final double? benchmark;
  final String field, xTitle, yTitle;
  final List<({Rect rect, Offset point, String label, Color color})> labels;
  void textAt(
    Canvas canvas,
    String text,
    Offset position, {
    double size = 12,
    Color? color,
    TextAlign align = TextAlign.left,
    double? width,
  }) {
    final t = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color ?? palette.muted,
          fontSize: size,
          height: 1.3,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: width ?? double.infinity);
    t.paint(
      canvas,
      Offset(
        position.dx -
            (align == TextAlign.center
                ? t.width / 2
                : align == TextAlign.right
                ? t.width
                : 0),
        position.dy,
      ),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = GuruScatterScale.plot(size),
        line = Paint()
          ..color = palette.border
          ..strokeWidth = .7;
    for (var i = 0; i <= 4; i++) {
      final x = plot.left + plot.width * i / 4;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), line);
      textAt(
        canvas,
        (scale.xMax * i / 4).toStringAsFixed(0),
        Offset(x, plot.bottom + 10),
        align: TextAlign.center,
      );
    }
    for (
      var v = scale.yMin;
      v <= scale.yMax + scale.yStep / 100;
      v += scale.yStep
    ) {
      final y =
          plot.bottom -
          (v - scale.yMin) / (scale.yMax - scale.yMin) * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), line);
      textAt(
        canvas,
        v.toStringAsFixed(field == 'cagr' ? 0 : 1),
        Offset(plot.left - 12, y - 7),
        align: TextAlign.right,
      );
    }
    if (benchmark != null) {
      final v = benchmark! * (field == 'cagr' ? 100 : 1),
          y =
              plot.bottom -
              (v - scale.yMin) / (scale.yMax - scale.yMin) * plot.height;
      for (var x = plot.left; x < plot.right; x += 5) {
        canvas.drawLine(
          Offset(x, y),
          Offset(math.min(x + 2, plot.right), y),
          Paint()
            ..color = palette.muted
            ..strokeWidth = .9,
        );
      }
      textAt(
        canvas,
        'SPY ${field == 'cagr' ? '${v.toStringAsFixed(2)}%' : v.toStringAsFixed(3)}',
        Offset(plot.right - 3, y - 17),
        align: TextAlign.right,
        size: 10,
      );
    }
    canvas.save();
    canvas.translate(1, plot.center.dy);
    canvas.rotate(-math.pi / 2);
    textAt(canvas, yTitle, Offset.zero, align: TextAlign.center, size: 12);
    canvas.restore();
    // Reserve three readable lines below the numeric ticks on narrow phones.
    textAt(
      canvas,
      size.width < 450
          ? (field.isNotEmpty
                ? xTitle.replaceFirst('  ', '\n').replaceFirst('  ', '\n')
                : xTitle)
          : xTitle,
      Offset(plot.center.dx, plot.bottom + 33),
      align: TextAlign.center,
      size: 12,
      width: plot.width + 40,
    );
    for (final l in labels) {
      final target = Offset(
        l.rect.left + (l.rect.center.dx < l.point.dx ? l.rect.width : 0),
        l.rect.center.dy,
      );
      canvas.drawLine(
        l.point,
        target,
        Paint()
          ..color = l.color
          ..strokeWidth = .8,
      );
      textAt(
        canvas,
        l.label,
        l.rect.topLeft,
        size: 12,
        color: l.color,
        width: l.rect.width,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GuruScatterAxes old) =>
      old.field != field ||
      old.xTitle != xTitle ||
      old.yTitle != yTitle ||
      old.benchmark != benchmark ||
      old.palette.colorBlind != palette.colorBlind ||
      old.scale.xMax != scale.xMax ||
      old.scale.yMin != scale.yMin ||
      old.scale.yMax != scale.yMax ||
      old.labels.length != labels.length;
}
