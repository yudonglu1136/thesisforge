part of 'main.dart';

// Chart contract: 8 fiscal-quarter model observations, latest at cutoff.
// Indexed line (first = 100), straight segments, no smoothing or price series.
// Teal = model value; focused labelled y-axis. Exact dated values below.
class SteadyValueChart extends StatefulWidget {
  const SteadyValueChart({
    super.key,
    required this.points,
    required this.palette,
  });
  final List<Map<String, dynamic>> points;
  final Palette palette;
  @override
  State<SteadyValueChart> createState() => _SteadyValueChartState();
}

class _SteadyValueChartState extends State<SteadyValueChart> {
  int selected = 7;
  Palette get p => widget.palette;
  String w(String en, String zh) => context.tr(zh, en);
  String amount(Map<String, dynamic> point) =>
      '${currencySymbol(text(point['currency']))}${number(point['fairValue']).toStringAsFixed(2)}';
  @override
  void didUpdateWidget(covariant SteadyValueChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.points != widget.points) selected = widget.points.length - 1;
  }

  @override
  Widget build(BuildContext context) {
    final points = widget.points;
    if (points.length < 2 ||
        points.any((x) => (nullableNumber(x['fairValue']) ?? 0) <= 0)) {
      return Text(w('Comparable history unavailable', '缺少同口径历史'));
    }
    final indices = points
        .map(
          (x) =>
              number(x['fairValue']) / number(points.first['fairValue']) * 100,
        )
        .toList();
    final selectedPoint = points[selected.clamp(0, points.length - 1)];
    final bottom = math.min(
      95.0,
      (indices.reduce(math.min) / 5).floorToDouble() * 5 - 5,
    );
    final top = math.max(
      110.0,
      (indices.reduce(math.max) / 5).ceilToDouble() * 5 + 5,
    );
    final axisStyle = TextStyle(color: p.muted, fontSize: 10.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          w('Fair value path · first quarter = 100', '估值路径 · 首季 = 100'),
          style: TextStyle(color: p.muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 170,
          child: Row(
            children: [
              SizedBox(
                width: 34,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(top.toStringAsFixed(0), style: axisStyle),
                    Text(
                      ((top + bottom) / 2).toStringAsFixed(0),
                      style: axisStyle,
                    ),
                    Text(bottom.toStringAsFixed(0), style: axisStyle),
                  ],
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (_, box) => Semantics(
                    label: w(
                      'Quarterly model value. Select a quarter below for its exact value.',
                      '季度模型估值。选择下方季度查看准确数值。',
                    ),
                    child: GestureDetector(
                      onTapDown: (event) => setState(
                        () => selected =
                            ((event.localPosition.dx / box.maxWidth) *
                                    (points.length - 1))
                                .round()
                                .clamp(0, points.length - 1),
                      ),
                      child: CustomPaint(
                        size: Size(box.maxWidth, 170),
                        painter: _SteadyValuePainter(
                          indices,
                          selected,
                          bottom,
                          top,
                          p,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(text(points.first['period']), style: axisStyle),
            Text(text(points.last['period']), style: axisStyle),
          ],
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < points.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    key: ValueKey('value-quarter-$i'),
                    label: Text(
                      text(points[i]['period']),
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: i == selected,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => selected = i),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${selectedPoint['period']} · ${amount(selectedPoint)} · ${w('Available', '披露可见日')} ${selectedPoint['date']}',
          key: const ValueKey('value-quarter-detail'),
          style: TextStyle(color: p.text, fontSize: 12, height: 1.5),
        ),
        ExpansionTile(
          key: const ValueKey('value-quarter-table'),
          tilePadding: EdgeInsets.zero,
          title: Text(
            w('All 8 quarterly values', '查看 8 季完整数值'),
            style: TextStyle(fontSize: 12, color: p.muted),
          ),
          children: [
            for (var i = 0; i < points.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${points[i]['period']}\n${points[i]['date']}',
                        style: TextStyle(
                          fontSize: 11,
                          color: p.muted,
                          height: 1.5,
                        ),
                      ),
                    ),
                    Text(
                      amount(points[i]),
                      style: TextStyle(fontSize: 13, color: p.text),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 68,
                      child: Text(
                        i == 0
                            ? '—'
                            : '${((number(points[i]['fairValue']) / number(points[i - 1]['fairValue']) - 1) * 100).toStringAsFixed(2)}%',
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 11, color: p.muted),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _SteadyValuePainter extends CustomPainter {
  _SteadyValuePainter(
    this.values,
    this.selected,
    this.bottom,
    this.top,
    this.palette,
  );
  final List<double> values;
  final int selected;
  final double bottom, top;
  final Palette palette;
  @override
  void paint(Canvas canvas, Size size) {
    Offset point(int i) => Offset(
      6 + (size.width - 12) * i / (values.length - 1),
      4 + (size.height - 8) * (1 - (values[i] - bottom) / (top - bottom)),
    );
    final grid = Paint()
      ..color = palette.border
      ..strokeWidth = 1;
    for (final y in [4.0, size.height / 2, size.height - 4]) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final path = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(point(i).dx, point(i).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = palette.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    for (var i = 0; i < values.length; i++) {
      if (i == selected) {
        canvas.drawCircle(
          point(i),
          8,
          Paint()..color = palette.accent.withValues(alpha: .2),
        );
      }
      canvas.drawCircle(
        point(i),
        i == selected ? 4.5 : 3,
        Paint()..color = palette.accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SteadyValuePainter old) =>
      old.values != values ||
      old.selected != selected ||
      old.palette != palette;
}
