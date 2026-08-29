import 'dart:math' as math;

import '../models/instrument.dart';
import '../models/note_event.dart';

/// Cost weights for the fingering search. Mirrors `backend/fretboard.py`.
class FingeringConfig {
  const FingeringConfig({
    this.maxFret,
    this.moveCost = 0.50,
    this.stretch = 4,
    this.jumpPenalty = 0.90,
    this.stringCost = 0.15,
    this.fastCrossPenalty = 0.50,
    this.fastCrossSec = 0.12,
    this.timeRef = 0.35,
    this.minTimeWeight = 0.20,
    this.fretCost = 0.04,
    this.openStringBonus = -0.50,
    this.comfortFret = 12,
    this.highFretPenalty = 0.08,
    this.handWindowSec = 0.75,
  });

  final int? maxFret;
  final double moveCost;
  final int stretch;
  final double jumpPenalty;
  final double stringCost;
  final double fastCrossPenalty;
  final double fastCrossSec;
  final double timeRef;
  final double minTimeWeight;
  final double fretCost;
  final double openStringBonus;
  final int comfortFret;
  final double highFretPenalty;
  final double handWindowSec;
}

/// Playing [pos] with the fretting hand anchored at [anchor] since [since].
class _HandState {
  const _HandState(this.pos, this.anchor, this.since);

  final FretPosition pos;
  final int anchor; // 0 == no anchor established yet
  final double since;
}

/// Chooses a string and fret for every note so the fretting hand travels as
/// little as possible.
///
/// A pitch does not identify a place on the neck — E2 sits at string 0 fret 12,
/// string 1 fret 7 or string 2 fret 2 — and picking naively produces tab that
/// is correct on paper and unplayable in practice. A Viterbi pass over the
/// sequence balances a per-note position cost (prefer low frets and open
/// strings) against a travel cost between neighbours, weighted by the time
/// available to make the move: fast passages get forced into one hand position,
/// slow ones are free to relocate.
///
/// Open strings inherit the hand anchor instead of resetting it, so a run like
/// *fret 7 -> open D -> A2* is costed on where the hand really is.
///
/// The Python backend already runs this and writes the result into the JSON;
/// this port is the fallback for files that lack `string`/`fret`.
class FretboardMapper {
  FretboardMapper(this.instrument, [this.config = const FingeringConfig()]);

  final Instrument instrument;
  final FingeringConfig config;

  double _timeWeight(double gap) =>
      math.min(1.0, math.max(config.minTimeWeight, config.timeRef / math.max(gap, 1e-3)));

  double _positionCost(FretPosition pos) {
    var cost = config.fretCost * pos.fret;
    if (pos.fret == 0) cost += config.openStringBonus;
    if (pos.fret > config.comfortFret) {
      cost += config.highFretPenalty * (pos.fret - config.comfortFret);
    }
    return cost;
  }

  double _travelCost(_HandState prev, FretPosition curr, double now, double dt) {
    // Crossing strings is a picking-hand problem, costed against the note gap.
    final crossed = (curr.string - prev.pos.string).abs();
    var cost = config.stringCost * crossed * _timeWeight(dt);
    if (crossed >= 2 && dt < config.fastCrossSec) {
      cost += config.fastCrossPenalty;
    }

    if (curr.fret == 0 || prev.anchor == 0) return cost;

    // Moving the hand is costed against the time since the anchor was set,
    // which exceeds `dt` when open strings intervene: the hand is free to
    // travel while they ring.
    final distance = (curr.fret - prev.anchor).abs().toDouble();
    final weight = _timeWeight(now - prev.since);
    cost += config.moveCost * distance * weight;
    if (distance > config.stretch) {
      cost += config.jumpPenalty * (distance - config.stretch) * weight;
    }
    return cost;
  }

  /// Fills in `string` and `fret` on every note, in place.
  void assign(List<NoteEvent> notes) {
    if (notes.isEmpty) return;

    final candidates = [
      for (final note in notes)
        instrument.positionsFor(note.midi, maxFret: config.maxFret)
    ];

    final states = List<List<_HandState>>.generate(notes.length, (_) => const []);
    final costs = List<List<double>>.generate(notes.length, (_) => const []);
    final back = List<List<int>>.generate(notes.length, (_) => const []);
    final pred = List<int>.filled(notes.length, -1);
    var previous = -1;

    for (var i = 0; i < notes.length; i++) {
      final options = candidates[i];
      if (options.isEmpty) {
        previous = -1; // unplayable note: start a fresh segment after it
        continue;
      }
      final note = notes[i];

      if (previous < 0) {
        states[i] = [for (final p in options) _HandState(p, p.fret, note.start)];
        costs[i] = [for (final p in options) _positionCost(p)];
        back[i] = List<int>.filled(options.length, -1);
        pred[i] = -1;
        previous = i;
        continue;
      }

      final dt = math.max(note.start - notes[previous].start, 0.0);
      final prior = states[previous];
      final priorCosts = costs[previous];
      final rowStates = <_HandState>[];
      final rowCost = <double>[];
      final rowBack = <int>[];

      for (final pos in options) {
        if (pos.fret > 0) {
          // A fretted note pins the anchor, so every incoming path collapses
          // into one state: keep the cheapest predecessor.
          var best = double.infinity;
          var bestK = 0;
          for (var k = 0; k < prior.length; k++) {
            final total = priorCosts[k] + _travelCost(prior[k], pos, note.start, dt);
            if (total < best) {
              best = total;
              bestK = k;
            }
          }
          rowStates.add(_HandState(pos, pos.fret, note.start));
          rowCost.add(best + _positionCost(pos));
          rowBack.add(bestK);
        } else {
          // An open note inherits the anchor, so keep the cheapest path per
          // distinct incoming anchor. Bounded by the candidate count of the
          // last fretted note, so the state list stays tiny.
          final bestByAnchor = <int, int>{};
          final bestCost = <int, double>{};
          for (var k = 0; k < prior.length; k++) {
            final total = priorCosts[k] + _travelCost(prior[k], pos, note.start, dt);
            final anchor = prior[k].anchor;
            if (!bestCost.containsKey(anchor) || total < bestCost[anchor]!) {
              bestCost[anchor] = total;
              bestByAnchor[anchor] = k;
            }
          }
          final openCost = _positionCost(pos);
          bestByAnchor.forEach((anchor, k) {
            rowStates.add(_HandState(pos, anchor, prior[k].since));
            rowCost.add(bestCost[anchor]! + openCost);
            rowBack.add(k);
          });
        }
      }

      states[i] = rowStates;
      costs[i] = rowCost;
      back[i] = rowBack;
      pred[i] = previous;
      previous = i;
    }

    // Backward pass, once per segment.
    final chosen = List<FretPosition?>.filled(notes.length, null);
    for (var end = notes.length - 1; end >= 0; end--) {
      if (candidates[end].isEmpty || chosen[end] != null) continue;
      final row = costs[end];
      var k = 0;
      for (var j = 1; j < row.length; j++) {
        if (row[j] < row[k]) k = j;
      }
      var i = end;
      while (i >= 0 && k >= 0) {
        chosen[i] = states[i][k].pos;
        final nextK = back[i][k];
        i = pred[i];
        k = nextK;
      }
    }

    for (var i = 0; i < notes.length; i++) {
      notes[i].string = chosen[i]?.string;
      notes[i].fret = chosen[i]?.fret;
    }
  }

  /// Tags each note with the lowest fret its neighbourhood needs, which the UI
  /// uses to draw the hand box and to scroll the neck.
  ///
  /// Open strings are excluded: they are reachable from anywhere and would drag
  /// every box down to fret 0.
  void annotateHandPositions(List<NoteEvent> notes) {
    final window = config.handWindowSec;
    final fretted = notes.where((n) => (n.fret ?? 0) > 0).toList();
    if (fretted.isEmpty) {
      for (final note in notes) {
        note.hand = 0;
      }
      return;
    }

    var lo = 0;
    var hi = 0;
    var last = fretted.first.fret!;
    for (final note in notes) {
      while (lo < fretted.length && fretted[lo].start < note.start - window) {
        lo++;
      }
      while (hi < fretted.length && fretted[hi].start <= note.start + window) {
        hi++;
      }
      if (lo < hi) {
        var lowest = fretted[lo].fret!;
        for (var i = lo + 1; i < hi; i++) {
          lowest = math.min(lowest, fretted[i].fret!);
        }
        last = lowest;
      }
      note.hand = last;
    }
  }
}
