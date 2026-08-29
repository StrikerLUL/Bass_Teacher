import 'dart:async';

import 'package:media_kit/media_kit.dart';

import 'playback_clock.dart';

/// Plays the bass stem and the backing track as two independent voices so
/// either can be muted or soloed without re-rendering audio.
///
/// Two engines playing one song will drift, so the backing track (or the bass,
/// when it is alone) acts as the leader: it drives [clock], and the follower is
/// nudged back whenever it slips past [_maxDriftMs]. Mute is volume, never
/// pause, so silencing a stem cannot desynchronise it.
///
/// With no stems at all the class stays silent and [clock] free-runs, which is
/// what lets the visualiser demo before any audio has been processed.
class StemPlayer {
  StemPlayer(this.clock);

  static const int _maxDriftMs = 80;
  static const List<double> speeds = [0.5, 0.65, 0.8, 0.9, 1.0];

  final PlaybackClock clock;

  Player? _bass;
  Player? _backing;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _driftTimer;

  double _bassVolume = 1.0;
  double _backingVolume = 1.0;
  bool _bassMuted = false;
  bool _soloBass = false;

  bool get hasAudio => _bass != null || _backing != null;
  bool get hasBass => _bass != null;
  bool get hasBacking => _backing != null;
  double get bassVolume => _bassVolume;
  double get backingVolume => _backingVolume;
  bool get bassMuted => _bassMuted;
  bool get soloBass => _soloBass;

  Player? get _leader => _backing ?? _bass;
  Player? get _follower => _backing == null ? null : _bass;

  Iterable<Player> get _players =>
      [_bass, _backing].whereType<Player>();

  Future<void> load({
    String? bassPath,
    String? backingPath,
    double fallbackDuration = 0,
  }) async {
    await _teardown();

    if (bassPath != null) _bass = Player();
    if (backingPath != null) _backing = Player();

    await Future.wait<void>([
      if (_bass != null) _bass!.open(Media(bassPath!), play: false),
      if (_backing != null) _backing!.open(Media(backingPath!), play: false),
    ]);
    await _applyVolumes();
    await setRate(clock.rate);

    final leader = _leader;
    if (leader == null) {
      clock.duration = fallbackDuration;
      return;
    }

    _subscriptions.add(leader.stream.position.listen(
      (d) => clock.syncTo(d.inMicroseconds / 1e6),
    ));
    _subscriptions.add(leader.stream.duration.listen((d) {
      if (d > Duration.zero) clock.duration = d.inMicroseconds / 1e6;
    }));
    _subscriptions.add(leader.stream.completed.listen((done) {
      if (done) pause();
    }));

    if (_follower != null) {
      _driftTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _correctDrift(),
      );
    }
  }

  void _correctDrift() {
    final leader = _leader;
    final follower = _follower;
    if (leader == null || follower == null || !clock.isPlaying) return;

    final drift = leader.state.position - follower.state.position;
    if (drift.abs().inMilliseconds > _maxDriftMs) {
      follower.seek(leader.state.position);
    }
  }

  Future<void> play() async {
    await Future.wait<void>([for (final p in _players) p.play()]);
    clock.setPlaying(true);
  }

  Future<void> pause() async {
    clock.setPlaying(false);
    await Future.wait<void>([for (final p in _players) p.pause()]);
  }

  Future<void> togglePlay() => clock.isPlaying ? pause() : play();

  Future<void> seek(double seconds) async {
    clock.seekTo(seconds);
    final target = Duration(microseconds: (clock.position * 1e6).round());
    await Future.wait<void>([for (final p in _players) p.seek(target)]);
  }

  /// mpv applies pitch correction to rate changes, so half speed stays in tune —
  /// which is what makes slow practice usable.
  Future<void> setRate(double rate) async {
    clock.setRate(rate);
    await Future.wait<void>([for (final p in _players) p.setRate(rate)]);
  }

  Future<void> setBassMuted(bool muted) {
    _bassMuted = muted;
    return _applyVolumes();
  }

  Future<void> setSoloBass(bool solo) {
    _soloBass = solo;
    return _applyVolumes();
  }

  Future<void> setBassVolume(double volume) {
    _bassVolume = volume.clamp(0.0, 1.0);
    return _applyVolumes();
  }

  Future<void> setBackingVolume(double volume) {
    _backingVolume = volume.clamp(0.0, 1.0);
    return _applyVolumes();
  }

  Future<void> _applyVolumes() async {
    final bassLevel = _bassMuted ? 0.0 : _bassVolume;
    final backingLevel = _soloBass ? 0.0 : _backingVolume;
    await Future.wait<void>([
      if (_bass != null) _bass!.setVolume(bassLevel * 100),
      if (_backing != null) _backing!.setVolume(backingLevel * 100),
    ]);
  }

  Future<void> _teardown() async {
    _driftTimer?.cancel();
    _driftTimer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    final old = _players.toList();
    _bass = null;
    _backing = null;
    for (final player in old) {
      await player.dispose();
    }
  }

  Future<void> dispose() => _teardown();
}
