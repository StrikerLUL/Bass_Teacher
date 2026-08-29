import 'instrument.dart';

/// One transcribed note. Times are seconds from the start of the track.
class NoteEvent {
  NoteEvent({
    required this.start,
    required this.end,
    required this.midi,
    this.velocity = 1.0,
    this.string,
    this.fret,
    this.hand,
    this.octaveShift = 0,
  });

  final double start;
  final double end;
  final int midi;
  final double velocity;

  /// Fretboard position. The backend normally supplies these; when a JSON file
  /// omits them, [FretboardMapper] fills them in on load — which is why they
  /// are mutable.
  int? string;
  int? fret;

  /// Lowest fret the surrounding phrase needs, i.e. where the hand should sit.
  int? hand;

  /// Octaves the backend shifted this note by to fit the instrument's range.
  final int octaveShift;

  double get duration => end - start;

  String get name => midiToName(midi);

  bool coversTime(double t) => t >= start && t < end;

  /// 0 at the attack, 1 at the release.
  double progressAt(double t) =>
      duration <= 0 ? 1.0 : ((t - start) / duration).clamp(0.0, 1.0);

  factory NoteEvent.fromJson(Map<String, dynamic> json) => NoteEvent(
        start: (json['start'] as num).toDouble(),
        end: (json['end'] as num).toDouble(),
        midi: (json['midi'] as num).toInt(),
        velocity: (json['velocity'] as num?)?.toDouble() ?? 1.0,
        string: (json['string'] as num?)?.toInt(),
        fret: (json['fret'] as num?)?.toInt(),
        hand: (json['hand'] as num?)?.toInt(),
        octaveShift: (json['octave_shift'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() =>
      '$name @${start.toStringAsFixed(2)}s (string $string, fret $fret)';
}
