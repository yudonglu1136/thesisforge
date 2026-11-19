part of 'main.dart';

final Expando<Map<String, Map<String, dynamic>>> _researchDividendsCache =
    Expando<Map<String, Map<String, dynamic>>>();

class _SnowballYieldPoint {
  const _SnowballYieldPoint({
    required this.date,
    required this.yieldPct,
    required this.price,
    required this.ttmDps,
  });
  final String date;
  final double yieldPct; // e.g. 0.0298 for 2.98%
  final double price;
  final double ttmDps;
}

class _SnowballYieldChannelChart extends StatefulWidget {
  const _SnowballYieldChannelChart({
    required this.points,
    required this.showPriceOverlay,
    required this.palette,
    required this.language,
  });

  final List<_SnowballYieldPoint> points;
  final bool showPriceOverlay;
  final Palette palette;
  final AppLanguage language;

  @override
  State<_SnowballYieldChannelChart> createState() =>
      _SnowballYieldChannelChartState();
}

class _SnowballYieldChannelChartState
    extends State<_SnowballYieldChannelChart> {
  int? _hoveredIndex;

  void _updateHover(double dx, double width) {
    const left = 54.0;
    final right = widget.showPriceOverlay ? 58.0 : 16.0;
    final plotWidth = math.max(1.0, width - left - right);
    if (widget.points.isEmpty || dx < left || dx > width - right) {
      if (_hoveredIndex != null) setState(() => _hoveredIndex = null);
      return;
    }
    final ratio = ((dx - left) / plotWidth).clamp(0.0, 1.0);
    final idx = (ratio * (widget.points.length - 1)).round().clamp(
      0,
      widget.points.length - 1,
    );
    if (_hoveredIndex != idx) setState(() => _hoveredIndex = idx);
  }

  @override
  Widget build(BuildContext context) {
    final pts = widget.points;
    if (pts.length < 2) {
      return Center(
        child: Text(
          context.tr('暂无足够历史股息率序列', 'Insufficient historical yield points'),
          style: TextStyle(color: widget.palette.muted, fontSize: 12.5),
        ),
      );
    }
    final posYields = pts.map((e) => e.yieldPct).where((v) => v > 0).toList();
    final avgYield = posYields.isEmpty
        ? 0.0
        : posYields.reduce((a, b) => a + b) / posYields.length;
    double stdYield = 0.0;
    if (posYields.length >= 2 && avgYield > 0) {
      final variance =
          posYields
              .map((v) => (v - avgYield) * (v - avgYield))
              .reduce((a, b) => a + b) /
          posYields.length;
      stdYield = math.sqrt(variance);
    }

    return LayoutBuilder(
      builder: (context, bounds) {
        final idx = _hoveredIndex != null && _hoveredIndex! < pts.length
            ? _hoveredIndex
            : null;
        final active = idx != null ? pts[idx] : null;
        final diffVsAvg = active != null && avgYield > 0
            ? (active.yieldPct - avgYield) / avgYield
            : null;
        const left = 54.0;
        final right = widget.showPriceOverlay ? 58.0 : 16.0;
        final plotW = math.max(1.0, bounds.maxWidth - left - right);
        final anchorX = idx == null || pts.length <= 1
            ? left
            : left + (idx / (pts.length - 1)) * plotW;
        final tooltipW = math.min(268.0, bounds.maxWidth - 16);
        final tooltipLeft = (anchorX + 14 + tooltipW <= bounds.maxWidth - 6)
            ? anchorX + 14
            : math.max(6.0, anchorX - tooltipW - 14);

        return MouseRegion(
          onHover: (e) => _updateHover(e.localPosition.dx, bounds.maxWidth),
          onExit: (_) => setState(() => _hoveredIndex = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _updateHover(d.localPosition.dx, bounds.maxWidth),
            onHorizontalDragUpdate: (d) =>
                _updateHover(d.localPosition.dx, bounds.maxWidth),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SnowballYieldChannelPainter(
                      points: pts,
                      avgYield: avgYield,
                      stdYield: stdYield,
                      showPriceOverlay: widget.showPriceOverlay,
                      hoveredIndex: idx,
                      palette: widget.palette,
                      language: widget.language,
                    ),
                  ),
                ),
                if (active != null)
                  Positioned(
                    left: tooltipLeft,
                    top: 10,
                    child: IgnorePointer(
                      child: Container(
                        width: tooltipW,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF13171F),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: widget.palette.border),
                          boxShadow: const [
                            BoxShadow(color: Colors.black54, blurRadius: 10),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              active.date,
                              style: TextStyle(
                                color: widget.palette.text,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  context.tr('TTM 股息率', 'TTM Yield'),
                                  style: TextStyle(
                                    color: widget.palette.muted,
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  '${(active.yieldPct * 100).toStringAsFixed(2)}%',
                                  style: TextStyle(
                                    color: widget.palette.accent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            if (diffVsAvg != null) ...[
                              const SizedBox(height: 3),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    context.tr('对比区间均值', 'vs Period Avg'),
                                    style: TextStyle(
                                      color: widget.palette.muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                  Text(
                                    '${diffVsAvg >= 0 ? '+' : ''}${(diffVsAvg * 100).toStringAsFixed(1)}%',
                                    style: TextStyle(
                                      color: diffVsAvg >= 0
                                          ? const Color(0xFF20C997)
                                          : const Color(0xFFF5A623),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 3),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  context.tr('TTM 每股派息', 'TTM DPS'),
                                  style: TextStyle(
                                    color: widget.palette.muted,
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  '\$${active.ttmDps.toStringAsFixed(active.ttmDps < 1 ? 4 : 2)}',
                                  style: TextStyle(
                                    color: widget.palette.text,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  context.tr('拆股复权股价', 'Split-Adj Price'),
                                  style: TextStyle(
                                    color: widget.palette.muted,
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  '\$${active.price.toStringAsFixed(2)}',
                                  style: TextStyle(
                                    color: const Color(0xFF20C997),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SnowballYieldChannelPainter extends CustomPainter {
  _SnowballYieldChannelPainter({
    required this.points,
    required this.avgYield,
    required this.stdYield,
    required this.showPriceOverlay,
    required this.hoveredIndex,
    required this.palette,
    required this.language,
  });

  final List<_SnowballYieldPoint> points;
  final double avgYield;
  final double stdYield;
  final bool showPriceOverlay;
  final int? hoveredIndex;
  final Palette palette;
  final AppLanguage language;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    const left = 54.0;
    final right = showPriceOverlay ? 58.0 : 16.0;
    const top = 14.0;
    const bottom = 30.0;
    final w = math.max(1.0, size.width - left - right);
    final h = math.max(1.0, size.height - top - bottom);

    var minY = points.map((e) => e.yieldPct).reduce(math.min);
    var maxY = points.map((e) => e.yieldPct).reduce(math.max);
    if (avgYield > 0 && stdYield > 0) {
      minY = math.min(minY, math.max(0.0, avgYield - stdYield * 1.1));
      maxY = math.max(maxY, avgYield + stdYield * 1.1);
    }
    final padY = (maxY - minY) * 0.12;
    minY = math.max(0.0, minY - padY);
    maxY = maxY + (padY > 0 ? padY : 0.01);
    if ((maxY - minY).abs() < 1e-6) maxY = minY + 0.01;

    double xAt(int idx) => left + (idx / (points.length - 1)) * w;
    double yYield(double val) =>
        top + (1.0 - ((val - minY) / (maxY - minY)).clamp(0.0, 1.0)) * h;

    // Horizontal grid & Y-axis yield labels
    final gridPaint = Paint()
      ..color = palette.border.withValues(alpha: .65)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final v = minY + (maxY - minY) * (i / 4);
      final dy = yYield(v);
      canvas.drawLine(Offset(left, dy), Offset(size.width - right, dy), gridPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: '${(v * 100).toStringAsFixed(v * 100 >= 10 ? 1 : 2)}%',
          style: TextStyle(
            color: palette.muted,
            fontSize: 10,
            fontFamilyFallback: kCjkFontFallback,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: left - 6);
      tp.paint(canvas, Offset(left - 6 - tp.width, dy - tp.height / 2));
    }

    // ±1σ Valuation Channel Band & Average Yield Dashed Line
    if (avgYield > 0) {
      if (stdYield > 0) {
        final bandTop = yYield(math.min(maxY, avgYield + stdYield));
        final bandBot = yYield(math.max(minY, avgYield - stdYield));
        canvas.drawRect(
          Rect.fromLTRB(left, bandTop, size.width - right, bandBot),
          Paint()..color = palette.accent.withValues(alpha: .07),
        );
      }
      final avgY = yYield(avgYield);
      final dashPaint = Paint()
        ..color = const Color(0xFFF5A623).withValues(alpha: .78)
        ..strokeWidth = 1.2;
      for (double dx = left; dx < size.width - right; dx += 9) {
        canvas.drawLine(
          Offset(dx, avgY),
          Offset(math.min(dx + 5, size.width - right), avgY),
          dashPaint,
        );
      }
    }

    // Yield Area + Crisp Line
    final linePath = Path();
    final areaPath = Path();
    for (var i = 0; i < points.length; i++) {
      final px = xAt(i);
      final py = yYield(points[i].yieldPct);
      if (i == 0) {
        linePath.moveTo(px, py);
        areaPath.moveTo(px, top + h);
        areaPath.lineTo(px, py);
      } else {
        linePath.lineTo(px, py);
        areaPath.lineTo(px, py);
      }
    }
    areaPath.lineTo(xAt(points.length - 1), top + h);
    areaPath.close();

    final chartRect = Rect.fromLTWH(left, top, w, h);
    canvas.drawPath(
      areaPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.accent.withValues(alpha: .28),
            palette.accent.withValues(alpha: .02),
          ],
        ).createShader(chartRect),
    );
    canvas.drawPath(
      linePath,
      Paint()
        ..color = palette.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.1
        ..strokeJoin = StrokeJoin.round,
    );

    // Optional Secondary Price Overlay
    if (showPriceOverlay) {
      var minP = points.map((e) => e.price).reduce(math.min);
      var maxP = points.map((e) => e.price).reduce(math.max);
      final padP = (maxP - minP) * 0.08;
      minP = math.max(0.0, minP - padP);
      maxP = maxP + (padP > 0 ? padP : 1.0);
      double yPrice(double pVal) =>
          top + (1.0 - ((pVal - minP) / (maxP - minP)).clamp(0.0, 1.0)) * h;

      final pricePath = Path();
      for (var i = 0; i < points.length; i++) {
        final px = xAt(i);
        final py = yPrice(points[i].price);
        if (i == 0) {
          pricePath.moveTo(px, py);
        } else {
          pricePath.lineTo(px, py);
        }
      }
      canvas.drawPath(
        pricePath,
        Paint()
          ..color = const Color(0xFF20C997).withValues(alpha: .82)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
      for (var i = 0; i <= 4; i += 2) {
        final pv = minP + (maxP - minP) * (i / 4);
        final dy = yPrice(pv);
        final tp = TextPainter(
          text: TextSpan(
            text: '\$${pv.toStringAsFixed(pv >= 100 ? 0 : 1)}',
            style: const TextStyle(
              color: Color(0xFF20C997),
              fontSize: 9.5,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: right - 6);
        tp.paint(canvas, Offset(size.width - right + 6, dy - tp.height / 2));
      }
    }

    // X-axis date ticks (up to 5 ticks)
    const tickCount = 5;
    for (var t = 0; t < tickCount; t++) {
      final idx = ((points.length - 1) * t / (tickCount - 1)).round();
      final dx = xAt(idx);
      final rawDate = points[idx].date;
      final labelText = rawDate.length >= 7 ? rawDate.substring(0, 7) : rawDate;
      final tp = TextPainter(
        text: TextSpan(
          text: labelText,
          style: TextStyle(color: palette.muted, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final clampedX = (dx - tp.width / 2).clamp(left, size.width - right - tp.width);
      tp.paint(canvas, Offset(clampedX, top + h + 8));
    }

    // Hover crosshair & dot
    if (hoveredIndex case final idx? when idx >= 0 && idx < points.length) {
      final hx = xAt(idx);
      final hy = yYield(points[idx].yieldPct);
      canvas.drawLine(
        Offset(hx, top),
        Offset(hx, top + h),
        Paint()
          ..color = palette.text.withValues(alpha: .35)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(Offset(hx, hy), 5, Paint()..color = palette.background);
      canvas.drawCircle(Offset(hx, hy), 3.8, Paint()..color = palette.accent);
    }
  }

  @override
  bool shouldRepaint(covariant _SnowballYieldChannelPainter old) =>
      old.points != points ||
      old.avgYield != avgYield ||
      old.showPriceOverlay != showPriceOverlay ||
      old.hoveredIndex != hoveredIndex ||
      old.language != language;
}

class _SnowballPayoutBarItem {
  const _SnowballPayoutBarItem({
    required this.label,
    required this.sublabel,
    required this.amount,
    required this.growth,
    required this.isPartial,
  });
  final String label;
  final String sublabel;
  final double amount;
  final double? growth;
  final bool isPartial;
}

class _SnowballPayoutBarChart extends StatefulWidget {
  const _SnowballPayoutBarChart({
    required this.items,
    required this.palette,
  });

  final List<_SnowballPayoutBarItem> items;
  final Palette palette;

  @override
  State<_SnowballPayoutBarChart> createState() =>
      _SnowballPayoutBarChartState();
}

class _SnowballPayoutBarChartState extends State<_SnowballPayoutBarChart> {
  int? _hovered;

  void _updateHover(double dx, double width) {
    const left = 52.0, right = 14.0;
    final w = math.max(1.0, width - left - right);
    if (widget.items.isEmpty || dx < left || dx > width - right) {
      if (_hovered != null) setState(() => _hovered = null);
      return;
    }
    final idx = (((dx - left) / w) * widget.items.length).floor().clamp(
      0,
      widget.items.length - 1,
    );
    if (_hovered != idx) setState(() => _hovered = idx);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty) {
      return Center(
        child: Text(
          context.tr('暂无派息柱状记录', 'No dividend payout bars available'),
          style: TextStyle(color: widget.palette.muted, fontSize: 12.5),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        final idx = _hovered != null && _hovered! < items.length ? _hovered : null;
        final active = idx != null ? items[idx] : null;
        const left = 52.0, right = 14.0;
        final plotW = math.max(1.0, bounds.maxWidth - left - right);
        final groupW = plotW / items.length;
        final anchorX = idx == null ? left : left + (idx + 0.5) * groupW;
        final tooltipW = math.min(240.0, bounds.maxWidth - 16);
        final tooltipLeft = (anchorX + 12 + tooltipW <= bounds.maxWidth - 6)
            ? anchorX + 12
            : math.max(6.0, anchorX - tooltipW - 12);

        return MouseRegion(
          onHover: (e) => _updateHover(e.localPosition.dx, bounds.maxWidth),
          onExit: (_) => setState(() => _hovered = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _updateHover(d.localPosition.dx, bounds.maxWidth),
            onHorizontalDragUpdate: (d) =>
                _updateHover(d.localPosition.dx, bounds.maxWidth),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SnowballPayoutBarPainter(
                      items: items,
                      hoveredIndex: idx,
                      palette: widget.palette,
                    ),
                  ),
                ),
                if (active != null)
                  Positioned(
                    left: tooltipLeft,
                    top: 10,
                    child: IgnorePointer(
                      child: Container(
                        width: tooltipW,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF13171F),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: widget.palette.border),
                          boxShadow: const [
                            BoxShadow(color: Colors.black54, blurRadius: 10),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              active.label,
                              style: TextStyle(
                                color: widget.palette.text,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (active.sublabel.isNotEmpty)
                              Text(
                                active.sublabel,
                                style: TextStyle(
                                  color: widget.palette.muted,
                                  fontSize: 10,
                                ),
                              ),
                            const SizedBox(height: 5),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  context.tr('每股现金分红', 'Cash Dividend / Sh'),
                                  style: TextStyle(
                                    color: widget.palette.muted,
                                    fontSize: 11,
                                  ),
                                ),
                                Text(
                                  '\$${active.amount.toStringAsFixed(active.amount < 1 ? 4 : 2)}',
                                  style: TextStyle(
                                    color: widget.palette.accent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                            if (active.growth != null) ...[
                              const SizedBox(height: 3),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    context.tr('增长率', 'Growth'),
                                    style: TextStyle(
                                      color: widget.palette.muted,
                                      fontSize: 11,
                                    ),
                                  ),
                                  Text(
                                    '${active.growth! >= 0 ? '+' : ''}${(active.growth! * 100).toStringAsFixed(1)}%',
                                    style: TextStyle(
                                      color: active.growth! >= 0
                                          ? const Color(0xFF20C997)
                                          : const Color(0xFFF5A623),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SnowballPayoutBarPainter extends CustomPainter {
  _SnowballPayoutBarPainter({
    required this.items,
    required this.hoveredIndex,
    required this.palette,
  });

  final List<_SnowballPayoutBarItem> items;
  final int? hoveredIndex;
  final Palette palette;

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty) return;
    const left = 52.0, right = 14.0, top = 16.0, bottom = 32.0;
    final w = math.max(1.0, size.width - left - right);
    final h = math.max(1.0, size.height - top - bottom);
    var maxVal = items.map((e) => e.amount).fold<double>(0.0, math.max) * 1.14;
    if (maxVal <= 0) maxVal = 1.0;

    double yAt(double val) => top + (1.0 - (val / maxVal).clamp(0.0, 1.0)) * h;
    final gridPaint = Paint()..color = palette.border.withValues(alpha: .65);
    for (var i = 0; i <= 4; i++) {
      final v = maxVal * (i / 4);
      final dy = yAt(v);
      canvas.drawLine(Offset(left, dy), Offset(size.width - right, dy), gridPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: '\$${v.toStringAsFixed(maxVal < 1 ? 2 : (maxVal < 5 ? 2 : 1))}',
          style: TextStyle(color: palette.muted, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: left - 6);
      tp.paint(canvas, Offset(left - 6 - tp.width, dy - tp.height / 2));
    }

    final groupW = w / items.length;
    final barW = math.min(44.0, math.max(4.0, groupW * 0.62));
    final labelStep = items.length > 14 ? (items.length / 7).ceil() : 1;

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final gx = left + i * groupW;
      if (hoveredIndex == i) {
        canvas.drawRect(
          Rect.fromLTWH(gx, top, groupW, h),
          Paint()..color = palette.border.withValues(alpha: .18),
        );
      }
      final bx = gx + (groupW - barW) / 2;
      final by = yAt(item.amount);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTRB(bx, by, bx + barW, top + h),
        const Radius.circular(4),
      );
      final isHike = (item.growth ?? 0) > 0.002;
      final baseColor = item.isPartial
          ? palette.accent.withValues(alpha: .35)
          : (isHike ? const Color(0xFF20C997) : palette.accent);
      canvas.drawRRect(rect, Paint()..color = baseColor);
      if (item.isPartial) {
        canvas.drawRRect(
          rect,
          Paint()
            ..color = palette.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      }

      if (i % labelStep == 0 || i == items.length - 1) {
        final tp = TextPainter(
          text: TextSpan(
            text: item.label,
            style: TextStyle(
              color: palette.muted,
              fontSize: items.length > 12 ? 9.5 : 10.5,
              fontFamilyFallback: kCjkFontFallback,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: groupW * labelStep);
        tp.paint(
          canvas,
          Offset(
            (gx + (groupW - tp.width) / 2).clamp(
              left,
              size.width - right - tp.width,
            ),
            top + h + 8,
          ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SnowballPayoutBarPainter old) =>
      old.items != items || old.hoveredIndex != hoveredIndex;
}

extension _InvestmentResearchDividends on _InvestmentWorkspaceState {
  Future<void> loadResearchDividends({bool force = false}) async {
    if (researchDividendsLoading || ticker.isEmpty) return;
    final symbol = ticker, cutoff = asOf, serial = requestSerial;
    final cacheKey = '$symbol|$cutoff';
    final cached = force ? null : _researchDividendsCache[widget.api]?[cacheKey];
    if (cached != null) {
      updateUI(() {
        researchDividendData = cached;
        researchDividendsLoading = false;
        researchDividendsError = null;
      });
      return;
    }
    updateUI(() {
      researchDividendsLoading = true;
      researchDividendsError = null;
    });
    try {
      final value = await widget.api.getJson(
        '/api/investment/research/${Uri.encodeComponent(symbol)}/dividends?asOf=$cutoff',
      );
      if (!mounted || serial != requestSerial || ticker != symbol) return;
      final store = _researchDividendsCache[widget.api] ??=
          <String, Map<String, dynamic>>{};
      if (store.length >= 24) store.remove(store.keys.first);
      store[cacheKey] = value;
      updateUI(() => researchDividendData = value);
    } catch (e) {
      if (mounted && serial == requestSerial && ticker == symbol) {
        updateUI(() => researchDividendsError = e.toString());
      }
    } finally {
      if (mounted && serial == requestSerial && ticker == symbol) {
        updateUI(() => researchDividendsLoading = false);
      }
    }
  }

  String _dividendFreqText(String freq, int perYear) => switch (freq) {
    'monthly' => w('Monthly · 12x/yr', '按月派息 · 每年 12 次'),
    'quarterly' => w('Quarterly · 4x/yr', '按季派息 · 每年 4 次'),
    'semi_annual' => w('Semi-Annual · 2x/yr', '半年派息 · 每年 2 次'),
    'annual' => w('Annual · 1x/yr', '按年派息 · 每年 1 次'),
    'irregular' => w('Variable / Special', '不定期 / 特别股息'),
    _ => w('No regular dividend', '暂无固定派息'),
  };

  (String, Color) _dividendSafetyMeta(String level, bool isReit) =>
      switch (level) {
        'very_safe' => (
          w('Very Safe Cushion', '安全垫极厚'),
          const Color(0xFF20C997),
        ),
        'safe' => (
          isReit
              ? w('Healthy REIT CFO Coverage', 'REIT 经营现金流稳健覆盖')
              : w('Healthy Coverage', '现金流覆盖稳健'),
          const Color(0xFF20C997),
        ),
        'moderate' => (
          w('Moderate Payout', '派息率适中偏高'),
          p.accent,
        ),
        'stretched' => (
          w('High Payout Ratio', '派息率偏紧 (>85%)'),
          const Color(0xFFF5A623),
        ),
        'deficit' => (
          w('Uncovered by FCF', '当期现金流未完全覆盖'),
          const Color(0xFFF5A623),
        ),
        'fund_distribution' => (
          w('ETF / Fund Distribution', 'ETF 基金组合派息'),
          p.accent,
        ),
        _ => (w('Not Applicable', '暂不适用'), p.muted),
      };

  List<_SnowballYieldPoint> _filteredYieldPoints(
    List<Map<String, dynamic>> raw,
    String windowKey,
  ) {
    if (raw.isEmpty) return const [];
    final latestIso = text(raw.last['date'], asOf);
    final latestDt = DateTime.tryParse(latestIso);
    final lookbackDays = switch (windowKey) {
      '1y' => 366,
      '3y' => 1096,
      '5y' => 1827,
      _ => 3660,
    };
    final minDateIso = latestDt == null
        ? ''
        : latestDt
              .subtract(Duration(days: lookbackDays))
              .toIso8601String()
              .substring(0, 10);
    return [
      for (final r in raw)
        if (minDateIso.isEmpty || text(r['date']).compareTo(minDateIso) >= 0)
          _SnowballYieldPoint(
            date: text(r['date']),
            yieldPct: number(r['yield']),
            price: number(r['price']),
            ttmDps: number(r['ttmDps']),
          ),
    ];
  }

  Widget? buildCompactDividendPulseBanner() {
    final div = researchDividendData;
    if (div == null || div['status'] != 'paying') return null;
    final sum = asMap(div['summary']);
    final curYield = nullableNumber(sum['currentYield']) ?? 0;
    if (curYield <= 0) return null;
    final avg5y = nullableNumber(sum['avgYield5y']);
    final cagr5y = nullableNumber(sum['cagr5y']);
    final grown = (nullableNumber(sum['consecutiveYearsGrown']) ?? 0).round();
    final annDps = nullableNumber(sum['annualizedDps']) ?? 0;

    return Container(
      key: const ValueKey('research-dividend-pulse-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 14,
        runSpacing: 8,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.payments_outlined, size: 17, color: p.accent),
                  const SizedBox(width: 7),
                  Text(
                    '${w('Dividend Yield', '股息率 (TTM)')} ${(curYield * 100).toStringAsFixed(2)}%',
                    style: TextStyle(
                      color: p.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              if (avg5y != null && avg5y > 0)
                researchTag(
                  '${w('5Y Avg', '5年均值')} ${(avg5y * 100).toStringAsFixed(2)}%',
                  curYield >= avg5y
                      ? const Color(0xFF20C997)
                      : const Color(0xFFF5A623),
                ),
              if (annDps > 0)
                Text(
                  '${w('Annualized', '年度派息')} \$${annDps.toStringAsFixed(annDps < 1 ? 3 : 2)}/${w('sh', '股')}',
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
              if (cagr5y != null)
                Text(
                  '5Y CAGR ${cagr5y >= 0 ? '+' : ''}${(cagr5y * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    color: cagr5y >= 0 ? const Color(0xFF20C997) : p.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (grown >= 2)
                researchTag(
                  w('$grown yrs consecutive growth', '连续增长 $grown 年'),
                  const Color(0xFF20C997),
                ),
            ],
          ),
          TextButton.icon(
            onPressed: () => selectResearchSection('dividends'),
            icon: const Icon(Icons.insights_rounded, size: 16),
            label: Text(
              w('Historical Yield & Payout Charts →', '查看历史股息率与派息图表 →'),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> buildResearchDividendsHub() {
    if (researchDividendsLoading && researchDividendData == null) {
      return [
        card([
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          label(
            'Loading 10-year historical dividend yield, ex-dividend payouts, and FCF coverage…',
            '正在载入近 10 年历史股息率通道、历次除息派放与现金流覆盖数据…',
          ),
        ]),
      ];
    }
    if (researchDividendsError != null && researchDividendData == null) {
      return [
        card([
          label(
            'Dividend analytics could not be loaded at this cutoff.',
            '当前截止日的股息分析数据暂时无法载入。',
            color: p.secondary,
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => loadResearchDividends(force: true),
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(w('Retry dividend analytics', '重试载入股息数据')),
            ),
          ),
        ]),
      ];
    }

    final data = researchDividendData ?? const <String, dynamic>{};
    final status = text(data['status'], 'no_dividends');
    final isReit = data['isReit'] == true;
    final hasCorp = data['hasCorporateFacts'] == true;
    final sum = asMap(data['summary']);
    final events = asList(data['events']);
    final annuals = asList(data['annualPayouts']);
    final seasonality = asList(data['seasonality']);
    final rawHistory = asList(data['yieldHistory']);

    if (status == 'no_dividends') {
      final netCommon = nullableNumber(sum['ttmNetCommonFinancing']);
      final shareChg = nullableNumber(sum['dilutedSharesGrowth']);
      return [
        card([
          Row(
            children: [
              Icon(Icons.payments_outlined, size: 20, color: p.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  w(
                    '$ticker does not currently pay a cash dividend',
                    '$ticker 当前未派发现金股息（无分红标的）',
                  ),
                  style: deskHeading(18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          label(
            'No cash dividend corporate actions were recorded over the trailing 10-year window through $asOf. Growth companies frequently return capital via share repurchases or reinvest internally.',
            '截至 $asOf 的近 10 年除息记录中，$ticker 未派发现金股息。成长型公司通常将自由现金流用于业务再投资或股票回购。',
            size: 13,
          ),
          if (netCommon != null || shareChg != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: p.card.withValues(alpha: .5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: p.border),
              ),
              child: Wrap(
                spacing: 28,
                runSpacing: 12,
                children: [
                  if (netCommon != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          w(
                            'TTM Net Common Stock Financing / Buybacks',
                            '近12个月普通股净回购/融资现金流',
                          ),
                          style: TextStyle(color: p.muted, fontSize: 11.5),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          formatNumber(netCommon),
                          style: TextStyle(
                            color: netCommon < 0
                                ? const Color(0xFF20C997)
                                : p.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          netCommon < 0
                              ? w('Net cash buyback outflow', '负数代表净现金回购注销')
                              : w('Net share issuance inflow', '正数代表净股权融资流入'),
                          style: TextStyle(color: p.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  if (shareChg != null)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          w('Diluted Share Count YoY', '摊薄总股本同比变化'),
                          style: TextStyle(color: p.muted, fontSize: 11.5),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${shareChg >= 0 ? '+' : ''}${(shareChg * 100).toStringAsFixed(2)}%',
                          style: TextStyle(
                            color: shareChg <= 0
                                ? const Color(0xFF20C997)
                                : const Color(0xFFF5A623),
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ]),
      ];
    }

    final curYield = nullableNumber(sum['currentYield']) ?? 0;
    final fwdYield = nullableNumber(sum['forwardYield']) ?? curYield;
    final avg5y = nullableNumber(sum['avgYield5y']);
    final high5y = nullableNumber(sum['highYield5y']);
    final low5y = nullableNumber(sum['lowYield5y']);
    final vs5y = nullableNumber(sum['yieldVs5yAvgPct']);
    final annDps = nullableNumber(sum['annualizedDps']) ?? 0;
    final ttmDps = nullableNumber(sum['ttmDps']) ?? 0;
    final freq = text(sum['frequency'], 'quarterly');
    final freqPerYr = (nullableNumber(sum['frequencyPerYear']) ?? 4).round();
    final cagr3y = nullableNumber(sum['cagr3y']);
    final cagr5y = nullableNumber(sum['cagr5y']);
    final cagr10y = nullableNumber(sum['cagr10y']);
    final paidYrs = (nullableNumber(sum['consecutiveYearsPaid']) ?? 0).round();
    final grownYrs = (nullableNumber(sum['consecutiveYearsGrown']) ?? 0).round();
    final fcfPayout = nullableNumber(sum['fcfPayoutRatio']);
    final epsPayout = nullableNumber(sum['epsPayoutRatio']);
    final safetyMeta = _dividendSafetyMeta(text(sum['safetyLevel']), isReit);

    Widget scoreTile({
      required IconData icon,
      required String titleEn,
      required String titleZh,
      required String mainValue,
      required String subText,
      Color? mainColor,
      Color? subColor,
      double? progress,
      Color? progressColor,
    }) => Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: p.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  w(titleEn, titleZh),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.muted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            mainValue,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: mainColor ?? p.text,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: subColor ?? p.muted,
              fontSize: 11,
              height: 1.35,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 4.5,
                color: progressColor ?? p.accent,
                backgroundColor: p.border,
              ),
            ),
          ],
        ],
      ),
    );

    final tiles = <Widget>[
      scoreTile(
        icon: Icons.percent_rounded,
        titleEn: 'Dividend Yield (TTM)',
        titleZh: '当前股息率 (TTM)',
        mainValue: '${(curYield * 100).toStringAsFixed(2)}%',
        subText: avg5y != null && vs5y != null
            ? '${w('5Y Avg', '5年均值')} ${(avg5y * 100).toStringAsFixed(2)}% · ${vs5y >= 0 ? '+' : ''}${(vs5y * 100).toStringAsFixed(0)}% ${vs5y >= 0.08 ? w('(High-yield zone)', '(高于均值·高息区)') : (vs5y <= -0.08 ? w('(Below 5Y avg)', '(低于5年均值)') : w('(Near 5Y avg)', '(接近5年均值)'))}'
            : '${w('Forward Yield', '前瞻股息率')} ${(fwdYield * 100).toStringAsFixed(2)}%',
        mainColor: p.accent,
        subColor: vs5y != null
            ? (vs5y >= 0.05
                  ? const Color(0xFF20C997)
                  : (vs5y <= -0.10 ? const Color(0xFFF5A623) : p.muted))
            : p.muted,
      ),
      scoreTile(
        icon: Icons.payments_outlined,
        titleEn: 'Annualized Payout / Share',
        titleZh: '年度每股派息额',
        mainValue: '\$${annDps.toStringAsFixed(annDps < 1 ? 4 : 2)}',
        subText:
            '${_dividendFreqText(freq, freqPerYr)} · TTM \$${ttmDps.toStringAsFixed(ttmDps < 1 ? 4 : 2)}',
      ),
      scoreTile(
        icon: Icons.trending_up_rounded,
        titleEn: '5Y Dividend Growth (CAGR)',
        titleZh: '5年股息复合增速',
        mainValue: cagr5y == null
            ? (cagr3y == null
                  ? '—'
                  : '${cagr3y >= 0 ? '+' : ''}${(cagr3y * 100).toStringAsFixed(1)}%')
            : '${cagr5y >= 0 ? '+' : ''}${(cagr5y * 100).toStringAsFixed(1)}%',
        subText: [
          if (cagr3y != null)
            '3Y ${cagr3y >= 0 ? '+' : ''}${(cagr3y * 100).toStringAsFixed(1)}%',
          if (cagr10y != null)
            '10Y ${cagr10y >= 0 ? '+' : ''}${(cagr10y * 100).toStringAsFixed(1)}%',
          if (cagr3y == null && cagr10y == null)
            w('Split-adjusted per-share basis', '拆股复权每股口径'),
        ].join(' · '),
        mainColor: (cagr5y ?? cagr3y ?? 0) > 0
            ? const Color(0xFF20C997)
            : p.text,
      ),
      scoreTile(
        icon: Icons.workspace_premium_outlined,
        titleEn: 'Dividend Track Record',
        titleZh: '连续派息与增长纪录',
        mainValue: grownYrs >= 1
            ? w('$grownYrs Yrs Growth', '连续增长 $grownYrs 年')
            : w('$paidYrs+ Yrs Paid', '连续派息 $paidYrs 年'),
        subText: w(
          'Paid $paidYrs consecutive yrs in 10Y window',
          '近10年窗口内连续派息 $paidYrs 年',
        ),
        mainColor: grownYrs >= 5 ? const Color(0xFF20C997) : p.text,
      ),
      scoreTile(
        icon: Icons.shield_outlined,
        titleEn: isReit
            ? 'CFO Payout & Safety'
            : (hasCorp ? 'FCF & EPS Payout Ratio' : 'Distribution Profile'),
        titleZh: isReit
            ? '经营现金流派息率与安全度'
            : (hasCorp ? '自由现金流派息率与安全垫' : '基金派息属性'),
        mainValue: fcfPayout != null
            ? '${(fcfPayout * 100).toStringAsFixed(1)}%'
            : (epsPayout != null
                  ? '${(epsPayout * 100).toStringAsFixed(1)}%'
                  : (hasCorp ? '—' : 'ETF')),
        subText: [
          safetyMeta.$1,
          if (epsPayout != null && fcfPayout != null)
            '${w('EPS Payout', '盈利派息率')} ${(epsPayout * 100).toStringAsFixed(1)}%',
        ].join(' · '),
        mainColor: safetyMeta.$2,
        subColor: safetyMeta.$2,
        progress: (fcfPayout ?? epsPayout) != null && (fcfPayout ?? epsPayout)! > 0
            ? (fcfPayout ?? epsPayout)!
            : null,
        progressColor: safetyMeta.$2,
      ),
      scoreTile(
        icon: Icons.event_available_outlined,
        titleEn: 'Latest Ex-Dividend',
        titleZh: '最近除息日与派放节奏',
        mainValue: text(sum['latestExDate'], '—'),
        subText: [
          if (nullableNumber(sum['latestAmount']) != null)
            '${w('Last', '最近单次')} \$${number(sum['latestAmount']).toStringAsFixed(number(sum['latestAmount']) < 1 ? 4 : 2)}',
          if (text(sum['estimatedNextExDate']).isNotEmpty)
            '${w('Est. next', '按规律预计下次')} ~${text(sum['estimatedNextExDate']).substring(0, 7)}',
        ].join(' · '),
      ),
    ];

    final yieldPts = _filteredYieldPoints(rawHistory, researchDividendYieldWindow);

    final payoutBars = researchDividendBarMode == 'events'
        ? [
            for (final ev in events.take(24).toList().reversed)
              _SnowballPayoutBarItem(
                label: text(ev['exDate']).length >= 7
                    ? text(ev['exDate']).substring(2, 7)
                    : text(ev['exDate']),
                sublabel: '${w('Ex-Date', '除息日')} ${text(ev['exDate'])}',
                amount: number(ev['amount']),
                growth: nullableNumber(ev['changePct']),
                isPartial: false,
              ),
          ]
        : [
            for (final yr in annuals)
              _SnowballPayoutBarItem(
                label: text(yr['label'], '${yr['year']}'),
                sublabel: yr['isPartialYear'] == true
                    ? w(
                        'Year-to-date (${yr['payoutCount']} payouts)',
                        '本年至今已除息 ${yr['payoutCount']} 次（未满全年）',
                      )
                    : w(
                        '${yr['payoutCount']} ex-dividend payouts',
                        '全年共派息 ${yr['payoutCount']} 次',
                      ),
                amount: number(yr['dps']),
                growth: nullableNumber(yr['yoyGrowth']),
                isPartial: yr['isPartialYear'] == true,
              ),
          ];

    // Coverage series (FCF/CFO per share vs EPS vs DPS) for corporate issuers
    final coverageYears = annuals
        .where(
          (r) =>
              r['isPartialYear'] != true &&
              (nullableNumber(r['fcfPerShare']) != null ||
                  nullableNumber(r['eps']) != null),
        )
        .toList();

    const monthNamesZh = [
      '1月',
      '2月',
      '3月',
      '4月',
      '5月',
      '6月',
      '7月',
      '8月',
      '9月',
      '10月',
      '11月',
      '12月',
    ];
    const monthNamesEn = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    return [
      if (status == 'suspended')
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF5A623).withValues(alpha: .1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFFF5A623).withValues(alpha: .35),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: Color(0xFFF5A623),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  w(
                    'Historical dividends exist, but no recent regular dividend was observed within the normal cadence window up to $asOf.',
                    '该公司历史上曾派发股息，但截至 $asOf 的常规周期内未观察到最新派息（可能已暂停或改为不定期派息）。',
                  ),
                  style: TextStyle(color: p.text, fontSize: 12.5),
                ),
              ),
            ],
          ),
        ),
      // 1. 6-Card Snowball Scorecard
      LayoutBuilder(
        key: const ValueKey('research-dividend-scorecard'),
        builder: (_, bounds) {
          final cols = bounds.maxWidth >= 1040
              ? 3
              : (bounds.maxWidth >= 600 ? 2 : 1);
          final tileW = (bounds.maxWidth - (cols - 1) * 12) / cols;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final t in tiles) SizedBox(width: tileW, child: t),
            ],
          );
        },
      ),
      const SizedBox(height: 16),

      // 2. Historical Dividend Yield Valuation Channel Chart
      card([
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 10,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label(
                  'HISTORICAL DIVIDEND YIELD CHANNEL',
                  '历史股息率通道与估值锚',
                  size: 10,
                  color: p.accent,
                ),
                const SizedBox(height: 4),
                Text(
                  w(
                    'Historical Yield vs Multi-Year Average Band',
                    '历史股息率走势与均值通道',
                  ),
                  style: deskHeading(19),
                ),
                const SizedBox(height: 3),
                label(
                  high5y != null && low5y != null
                      ? '5Y Yield Range: ${(low5y * 100).toStringAsFixed(2)}% – ${(high5y * 100).toStringAsFixed(2)}% · Dashed amber line marks period mean; shaded band marks ±1σ.'
                      : 'Dashed amber line marks period mean yield; shaded band marks ±1σ range.',
                  high5y != null && low5y != null
                      ? '近5年股息率高低区间：${(low5y * 100).toStringAsFixed(2)}% – ${(high5y * 100).toStringAsFixed(2)}% · 橙色虚线为区间均值，阴影带为 ±1σ 常态通道（股息率处于高位往往对应股价性价比区间）。'
                      : '橙色虚线为区间平均股息率，阴影带为 ±1σ 常态波动区间。',
                  size: 11.5,
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final win in [
                  ('1y', '1Y', '近1年'),
                  ('3y', '3Y', '近3年'),
                  ('5y', '5Y', '近5年'),
                  ('10y', '10Y', '近10年'),
                ])
                  ChoiceChip(
                    key: ValueKey('dividend-yield-window-${win.$1}'),
                    label: Text(w(win.$2, win.$3)),
                    selected: researchDividendYieldWindow == win.$1,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => updateUI(
                      () => researchDividendYieldWindow = win.$1,
                    ),
                  ),
                FilterChip(
                  key: const ValueKey('dividend-yield-price-overlay'),
                  label: Text(w('Overlay Price', '叠加股价')),
                  selected: researchDividendShowPrice,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) =>
                      updateUI(() => researchDividendShowPrice = v),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          key: const ValueKey('research-dividend-yield-chart'),
          height: 300,
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
          decoration: BoxDecoration(
            color: p.card.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: _SnowballYieldChannelChart(
            points: yieldPts,
            showPriceOverlay: researchDividendShowPrice,
            palette: p,
            language: context.language,
          ),
        ),
      ]),
      const SizedBox(height: 16),

      // 3. Dividend Payout & Growth Bar Chart
      card([
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 10,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label(
                  'DIVIDEND PAYOUT & GROWTH',
                  '股息派放与历年增长趋势',
                  size: 10,
                  color: p.accent,
                ),
                const SizedBox(height: 4),
                Text(
                  w(
                    'Cash Dividends Paid Per Share',
                    '历年每股分红与单次除息派放柱状图',
                  ),
                  style: deskHeading(19),
                ),
                const SizedBox(height: 3),
                label(
                  'Green bars highlight dividend increases. Split-adjusted USD/share so historical stock splits never distort growth.',
                  '绿色柱体代表较上期提息增长；全部采用拆股复权后每股美元口径，消除拆股造成的跳变失真。',
                  size: 11.5,
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  key: const ValueKey('dividend-bar-mode-annual'),
                  label: Text(w('Annual Total', '按年度汇总')),
                  selected: researchDividendBarMode == 'annual',
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) =>
                      updateUI(() => researchDividendBarMode = 'annual'),
                ),
                ChoiceChip(
                  key: const ValueKey('dividend-bar-mode-events'),
                  label: Text(w('Every Payout', '每次除息明细')),
                  selected: researchDividendBarMode == 'events',
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) =>
                      updateUI(() => researchDividendBarMode = 'events'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          key: const ValueKey('research-dividend-payout-chart'),
          height: 275,
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
          decoration: BoxDecoration(
            color: p.card.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: p.border),
          ),
          child: _SnowballPayoutBarChart(items: payoutBars, palette: p),
        ),
      ]),

      // 4. Corporate Cash Flow & Earnings Coverage Chart
      if (coverageYears.length >= 2) ...[
        const SizedBox(height: 16),
        card([
          label(
            'PAYOUT COVERAGE & SAFETY CUSHION',
            '现金流与盈利派息覆盖图',
            size: 10,
            color: p.accent,
          ),
          const SizedBox(height: 4),
          Text(
            isReit
                ? w(
                    'Operating Cash Flow / Share vs EPS vs Dividend / Share',
                    '每股经营现金流 vs 稀释 EPS vs 每股派息',
                  )
                : w(
                    'Free Cash Flow / Share vs EPS vs Dividend / Share',
                    '每股自由现金流 (FCF) vs 稀释 EPS vs 每股派息',
                  ),
            style: deskHeading(19),
          ),
          const SizedBox(height: 3),
          label(
            'Compares annual per-share cash generation and GAAP earnings directly against cash dividends paid.',
            '直观对比每年每股创造的自由现金流、每股收益与每股现金派息，检验分红可持续性。',
            size: 11.5,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _legendDot(
                const Color(0xFF20C997),
                isReit
                    ? w('CFO / Share', '每股经营现金流')
                    : w('FCF / Share', '每股自由现金流'),
              ),
              _legendDot(p.accent, w('Diluted EPS', '稀释每股收益 (EPS)')),
              _legendDot(const Color(0xFFF5A623), w('Dividend / Share', '每股派息 (DPS)')),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('research-dividend-coverage-chart'),
            height: 280,
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            decoration: BoxDecoration(
              color: p.card.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: p.border),
            ),
            child: _ResearchFinancialBarChart(
              periods: [for (final r in coverageYears) text(r['label'])],
              details: [
                for (final r in coverageYears)
                  [
                    if (nullableNumber(r['fcfPayoutRatio']) != null)
                      '${isReit ? w('CFO Payout', 'CFO派息率') : w('FCF Payout', 'FCF派息率')} ${(number(r['fcfPayoutRatio']) * 100).toStringAsFixed(1)}%',
                    if (nullableNumber(r['epsPayoutRatio']) != null)
                      '${w('EPS Payout', '盈利派息率')} ${(number(r['epsPayoutRatio']) * 100).toStringAsFixed(1)}%',
                  ].join(' · '),
              ],
              series: [
                _ResearchFinancialSeries(
                  keyName: 'fcfps',
                  label: isReit
                      ? w('CFO / Share', '每股经营现金流')
                      : w('FCF / Share', '每股自由现金流'),
                  color: const Color(0xFF20C997),
                  values: [
                    for (final r in coverageYears)
                      nullableNumber(r['fcfPerShare']),
                  ],
                  yoy: [
                    for (final _ in coverageYears)
                      (value: null, reason: 'not_shown'),
                  ],
                  qoq: [
                    for (final _ in coverageYears)
                      (value: null, reason: 'not_shown'),
                  ],
                ),
                _ResearchFinancialSeries(
                  keyName: 'eps',
                  label: w('Diluted EPS', '稀释 EPS'),
                  color: p.accent,
                  values: [
                    for (final r in coverageYears) nullableNumber(r['eps']),
                  ],
                  yoy: [
                    for (final _ in coverageYears)
                      (value: null, reason: 'not_shown'),
                  ],
                  qoq: [
                    for (final _ in coverageYears)
                      (value: null, reason: 'not_shown'),
                  ],
                ),
                _ResearchFinancialSeries(
                  keyName: 'dps',
                  label: w('Dividend / Share', '每股派息'),
                  color: const Color(0xFFF5A623),
                  values: [
                    for (final r in coverageYears) nullableNumber(r['dps']),
                  ],
                  yoy: [
                    for (final r in coverageYears)
                      (
                        value: nullableNumber(r['yoyGrowth']),
                        reason: nullableNumber(r['yoyGrowth']) != null
                            ? 'available'
                            : 'missing_comparable_period',
                      ),
                  ],
                  qoq: [
                    for (final _ in coverageYears)
                      (value: null, reason: 'quarterly_only'),
                  ],
                ),
              ],
              muted: p.muted,
              textColor: p.text,
              grid: p.border,
            ),
          ),
        ]),
      ],

      // 5. 12-Month Payout Seasonality Calendar + Ex-Dividend History Table
      const SizedBox(height: 16),
      card([
        label(
          'PAYOUT CALENDAR & EX-DIVIDEND LEDGER',
          '派息月份日历与历次除息明细',
          size: 10,
          color: p.accent,
        ),
        const SizedBox(height: 4),
        Text(
          w(
            '12-Month Distribution Seasonality & Ex-Date History',
            '全年派息月份规律与历史除息台账',
          ),
          style: deskHeading(19),
        ),
        const SizedBox(height: 12),
        if (seasonality.length == 12) ...[
          LayoutBuilder(
            key: const ValueKey('research-dividend-seasonality'),
            builder: (_, bounds) {
              final cols = bounds.maxWidth >= 860
                  ? 12
                  : (bounds.maxWidth >= 520 ? 6 : 4);
              final cellW = (bounds.maxWidth - (cols - 1) * 8) / cols;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < 12; i++)
                    Builder(
                      builder: (_) {
                        final m = seasonality[i];
                        final active = m['active'] == true;
                        final amt = nullableNumber(m['latestAmount']);
                        return Container(
                          width: cellW,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: active
                                ? const Color(0xFF20C997).withValues(alpha: .13)
                                : p.card.withValues(alpha: .35),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: active
                                  ? const Color(0xFF20C997)
                                        .withValues(alpha: .55)
                                  : p.border,
                            ),
                          ),
                          child: Column(
                            children: [
                              Text(
                                w(monthNamesEn[i], monthNamesZh[i]),
                                style: TextStyle(
                                  color: active ? p.text : p.muted,
                                  fontSize: 11.5,
                                  fontWeight: active
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                active && amt != null
                                    ? '\$${amt.toStringAsFixed(amt < 1 ? 3 : 2)}'
                                    : '—',
                                style: TextStyle(
                                  color: active
                                      ? const Color(0xFF20C997)
                                      : p.muted.withValues(alpha: .5),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
        ],
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            key: const ValueKey('research-dividend-events-table'),
            headingRowHeight: 38,
            dataRowMinHeight: 40,
            dataRowMaxHeight: 44,
            columns: [
              DataColumn(label: Text(w('Ex-Dividend Date', '除息日'))),
              DataColumn(
                label: Text(w('Amount (USD/sh)', '每股派息 (USD)')),
                numeric: true,
              ),
              DataColumn(
                label: Text(w('vs Prior Payout', '较上次变动')),
                numeric: true,
              ),
              DataColumn(
                label: Text(w('Split-Adj Price', '除息日复权股价')),
                numeric: true,
              ),
              DataColumn(
                label: Text(w('Annualized Yield', '当期年化股息率')),
                numeric: true,
              ),
            ],
            rows: [
              for (final ev in events.take(24)) _buildDividendEventRow(ev),
            ],
          ),
        ),
        const SizedBox(height: 8),
        label(
          'Source: Sharadar corporate actions (ex-dividend dates, split-adjusted USD/share) & split-adjusted closes through $asOf.',
          '数据口径：Sharadar 除息公告（拆股复权每股美元）及截至 $asOf 的复权收盘价；预计下次除息月份仅按历史周期推算，不代表董事会正式宣告。',
          size: 10.5,
        ),
      ]),
    ];
  }

  DataRow _buildDividendEventRow(Map<String, dynamic> ev) {
    final amt = number(ev['amount']);
    final chg = nullableNumber(ev['changePct']);
    final exPrice = nullableNumber(ev['priceOnExDate']);
    final exYld = nullableNumber(ev['annualizedYieldOnExDate']);
    return DataRow(
      cells: [
        DataCell(
          Text(
            text(ev['exDate']),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        DataCell(
          Text(
            '\$${amt.toStringAsFixed(amt < 1 ? 4 : 3)}',
            style: TextStyle(color: p.text, fontWeight: FontWeight.w700),
          ),
        ),
        DataCell(
          Text(
            chg == null || chg.abs() < 0.0005
                ? '—'
                : '${chg >= 0 ? '+' : ''}${(chg * 100).toStringAsFixed(1)}%',
            style: TextStyle(
              color: chg == null || chg.abs() < 0.0005
                  ? p.muted
                  : (chg > 0
                        ? const Color(0xFF20C997)
                        : const Color(0xFFF5A623)),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        DataCell(
          Text(exPrice == null ? '—' : '\$${exPrice.toStringAsFixed(2)}'),
        ),
        DataCell(
          Text(
            exYld == null ? '—' : '${(exYld * 100).toStringAsFixed(2)}%',
            style: TextStyle(color: p.accent),
          ),
        ),
      ],
    );
  }

  Widget _legendDot(Color c, String textLabel) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 6),
      Text(textLabel, style: TextStyle(color: p.muted, fontSize: 11.5)),
    ],
  );
}
