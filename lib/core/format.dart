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
