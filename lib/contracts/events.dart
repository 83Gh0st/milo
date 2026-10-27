class BrainEvent {
  final String type;
  final Map<String, dynamic> data;
  const BrainEvent(this.type, this.data);
}

/// A typed cloud-stream failure (e.g. `timeout`, `budget_exhausted`) so the
/// router can map it to the offline ladder instead of treating it as unknown.
class StreamError implements Exception {
  final String code;
  const StreamError(this.code);
  @override String toString() => 'StreamError($code)';
}
