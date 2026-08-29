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

  /// Stems can be pushed past unity so the bass can sit above the band.
  /// mpv refuses volume over 100% until `volume-max` is raised, which is done
  /// per player in [_unlockGain].
  static const double maxGain = 2.0;

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
    await Future.wait<void>([for (final p in _players) _unlockGain(p)]);
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
    // Without a bass stem there is nothing to solo, and engaging it would
    // silence the backing for no reason.
    _soloBass = solo && hasBass;
    return _applyVolumes();
  }

  Future<void> setBassVolume(double volume) {
    _bassVolume = volume.clamp(0.0, maxGain);
    return _applyVolumes();
  }

  Future<void> setBackingVolume(double volume) {
    _backingVolume = volume.clamp(0.0, maxGain);
    return _applyVolumes();
  }

  /// Raise the bass over the band and pull the band back, in one action.
  Future<void> boostBass() {
    _bassMuted = false;
    _bassVolume = 1.6;
    _backingVolume = 0.45;
    return _applyVolumes();
  }

  Future<void> resetMix() {
    _bassMuted = false;
    _soloBass = false;
    _bassVolume = 1.0;
    _backingVolume = 1.0;
    return _applyVolumes();
  }

  /// What you can currently hear, for the UI to show.
  String get mixDescription {
    if (!hasAudio) return 'No audio loaded';
    if (_soloBass) return 'Bass only';
    if (_bassMuted) {
      return hasBacking ? 'Backing only — play the bass yourself' : 'Silent';
    }
    if (!hasBacking) return 'Bass only';
    if (_bassVolume > _backingVolume * 1.15) return 'Bass forward';
    if (_backingVolume > _bassVolume * 1.15) return 'Backing forward';
    return 'Bass + backing';
  }

  /// Solo wins over mute, the way a mixing desk behaves.
  ///
  /// Treating them as two independent switches let both be engaged at once:
  /// mute the bass, then hit Solo bass, and every stem was silenced with no
  /// obvious way back. Soloing the bass now un-mutes it.
  /// Pure so the interaction between mute, solo and the two gains can be
  /// tested without an audio engine.
  static ({double bass, double backing}) mixLevels({
    required bool soloBass,
    required bool bassMuted,
    double bassVolume = 1.0,
    double backingVolume = 1.0,
  }) {
    if (soloBass) return (bass: bassVolume, backing: 0.0);
    return (bass: bassMuted ? 0.0 : bassVolume, backing: backingVolume);
  }

  Future<void> _applyVolumes() async {
    final levels = mixLevels(
      soloBass: _soloBass,
      bassMuted: _bassMuted,
      bassVolume: _bassVolume,
      backingVolume: _backingVolume,
    );
    final bassLevel = levels.bass;
    final backingLevel = levels.backing;
    await Future.wait<void>([
      if (_bass != null) _bass!.setVolume((bassLevel * 100).clamp(0, maxGain * 100)),
      if (_backing != null)
        _backing!.setVolume((backingLevel * 100).clamp(0, maxGain * 100)),
    ]);
  }

  /// mpv clamps volume at 100% unless `volume-max` says otherwise. Failing to
  /// raise it is not fatal: the mix still works, it just cannot exceed unity.
  Future<void> _unlockGain(Player player) async {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('volume-max', '${(maxGain * 100).round()}');
    } catch (_) {
      // older mpv, or a backend without the property - ignore
    }
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
