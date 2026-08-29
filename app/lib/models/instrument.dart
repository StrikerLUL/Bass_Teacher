import 'dart:math' as math;

const List<String> kNoteNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
];

const Map<String, int> _letterSemitones = {
  'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11,
};

/// `28 -> "E1"`. MIDI 60 is C4.
String midiToName(int midi) => '${kNoteNames[midi % 12]}${midi ~/ 12 - 1}';

/// `"E1" -> 28`, `"F#2" -> 42`, `"Bb0" -> 22`. Returns null if unparseable.
int? noteNameToMidi(String name) {
  final text = name.trim();
  if (text.isEmpty) return null;
  final semitone = _letterSemitones[text[0].toUpperCase()];
  if (semitone == null) return null;

  var value = semitone;
  var i = 1;
  while (i < text.length && (text[i] == '#' || text[i] == 'b')) {
    value += text[i] == '#' ? 1 : -1;
    i++;
  }
  final octave = int.tryParse(text.substring(i));
  return octave == null ? null : value + (octave + 1) * 12;
}

/// A place on the neck. [string] 0 is always the *lowest pitched* string.
class FretPosition {
  const FretPosition(this.string, this.fret);

  final int string;
  final int fret;

  @override
  String toString() => 'string $string fret $fret';
}

/// Tuning and neck length. Strings are ordered low to high, matching the
/// `tuning_midi` array the backend writes.
class Instrument {
  const Instrument({required this.tuningMidi, this.frets = 24});

  final List<int> tuningMidi;
  final int frets;

  /// Standard 4-string bass: E1 A1 D2 G2.
  static const Instrument bassStandard =
      Instrument(tuningMidi: [28, 33, 38, 43]);

  int get stringCount => tuningMidi.length;

  int get lowestMidi => tuningMidi.reduce(math.min);

  int get highestMidi =>
      tuningMidi.map((open) => open + frets).reduce(math.max);

  List<String> get tuningNames => tuningMidi.map(midiToName).toList();

  int midiAt(int string, int fret) => tuningMidi[string] + fret;

  /// Every playable place for [midi], lowest fret first.
  List<FretPosition> positionsFor(int midi, {int? maxFret}) {
    final limit = maxFret == null ? frets : math.min(maxFret, frets);
    final found = <FretPosition>[];
    for (var string = 0; string < tuningMidi.length; string++) {
      final fret = midi - tuningMidi[string];
      if (fret >= 0 && fret <= limit) found.add(FretPosition(string, fret));
    }
    found.sort((a, b) => a.fret != b.fret
        ? a.fret.compareTo(b.fret)
        : a.string.compareTo(b.string));
    return found;
  }

  factory Instrument.fromJson(Map<String, dynamic> json) {
    // Prefer the explicit MIDI numbers; fall back to parsing the note names.
    final midi = json['tuning_midi'];
    if (midi is List && midi.isNotEmpty) {
      return Instrument(
        tuningMidi: midi.map((v) => (v as num).toInt()).toList(),
        frets: (json['frets'] as num?)?.toInt() ?? 24,
      );
    }
    final names = json['tuning'];
    if (names is List && names.isNotEmpty) {
      final parsed = names
          .map((v) => noteNameToMidi(v.toString()))
          .whereType<int>()
          .toList();
      if (parsed.length == names.length) {
        return Instrument(
          tuningMidi: parsed,
          frets: (json['frets'] as num?)?.toInt() ?? 24,
        );
      }
    }
    return bassStandard;
  }
}
