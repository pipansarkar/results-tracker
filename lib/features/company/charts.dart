import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';

Widget _bottomLabel(List<String> labels, double v) {
  final i = v.toInt();
  if (i < 0 || i >= labels.length || v != i.toDouble()) {
    return const SizedBox.shrink();
  }
  // "Q2FY27" -> "Q2'27" to fit.
  final l = labels[i].replaceFirst('FY', "'");
  return Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(l, style: const TextStyle(fontSize: 10)),
  );
}

FlTitlesData _titles(List<String> labels) => FlTitlesData(
  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
  leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
  bottomTitles: AxisTitles(
    sideTitles: SideTitles(
      showTitles: true,
      reservedSize: 22,
      interval: 1,
      getTitlesWidget: (v, meta) => _bottomLabel(labels, v),
    ),
  ),
);

class QuarterBarChart extends StatelessWidget {
  const QuarterBarChart({
    super.key,
    required this.labels,
    required this.values,
    this.color,
  });
  final List<String> labels;
  final List<double> values;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: 170,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: BarChart(
          BarChartData(
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: _titles(labels),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                  '${labels[group.x]}\n₹${rod.toY.toStringAsFixed(0)} Cr',
                  const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < values.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: values[i],
                      color: values[i] < 0 ? lossColor : c,
                      width: 16,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class MarginLineChart extends StatelessWidget {
  const MarginLineChart({
    super.key,
    required this.labels,
    required this.ebitda,
    required this.pat,
  });
  final List<String> labels;
  final List<double> ebitda;
  final List<double> pat;

  LineChartBarData _line(List<double> v, Color color) => LineChartBarData(
    spots: [for (var i = 0; i < v.length; i++) FlSpot(i.toDouble(), v[i])],
    isCurved: true,
    color: color,
    barWidth: 2.5,
    dotData: const FlDotData(show: true),
  );

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      children: [
        SizedBox(
          height: 170,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 24, 0),
            child: LineChart(
              LineChartData(
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                titlesData: _titles(labels),
                lineBarsData: [_line(ebitda, primary), _line(pat, gainColor)],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Legend(primary, 'EBITDA margin'),
              const SizedBox(width: 16),
              const _Legend(gainColor, 'Net margin'),
            ],
          ),
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.label);
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(width: 10, height: 10, color: color),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  );
}
