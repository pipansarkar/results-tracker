import 'package:intl/intl.dart';

final _inr = NumberFormat.decimalPattern('en_IN');

/// ₹ crore value, e.g. "₹52,340 Cr" or "₹1.2 L Cr" for very large numbers.
String crore(double? v) {
  if (v == null) return '—';
  if (v.abs() >= 100000) return '₹${(v / 100000).toStringAsFixed(2)} L Cr';
  return '₹${_inr.format(v.round())} Cr';
}

String pct(double? v, {bool signed = true}) {
  if (v == null) return '—';
  final s = v.toStringAsFixed(1);
  return signed && v > 0 ? '+$s%' : '$s%';
}

String num2(double? v) => v == null ? '—' : v.toStringAsFixed(2);

final dayFormat = DateFormat('EEE, d MMM');
final timeFormat = DateFormat('h:mm a');

/// Formats a metric value by unit: '%', 'x', '₹', 'Cr'.
String metricValue(double? v, String unit) {
  if (v == null) return '—';
  return switch (unit) {
    '%' => '${v.toStringAsFixed(1)}%',
    'x' => '${v.toStringAsFixed(v.abs() >= 100 ? 0 : 1)}x',
    '₹' =>
      '₹${v >= 1000 ? NumberFormat.decimalPattern('en_IN').format(v.round()) : v.toStringAsFixed(2)}',
    'Cr' => crore(v),
    'dir' => v > 0 ? 'Raised' : (v < 0 ? 'Cut' : 'Maintained'),
    'tone' => v > 0 ? 'Positive' : (v < 0 ? 'Cautious' : 'Neutral'),
    'days' => '${v.round()}d ago',
    _ => v.toStringAsFixed(2),
  };
}
