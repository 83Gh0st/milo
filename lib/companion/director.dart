import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../contracts/brain_contract.dart';
import '../contracts/events.dart';
import '../core/safety.dart';
import '../core/pocket_brain.dart';
import 'emotion.dart';

enum CState { idle, greeting, listening, thinking, speaking, waiting, celebrating, calm }
enum Presence { stage, buddy, chip, hidden }
enum Profile { playful, friendly, discreet }

class ProfileCfg {
  final double amp, bias, ceil; // motion amplitude, baseline mood blend, max emotion intensity
  final String base, greet, gesture;
  const ProfileCfg(this.amp, this.bias, this.ceil, this.base, this.greet, this.gesture);
}
const kProfiles = {
  Profile.playful: ProfileCfg(1, .5, 1, 'happy', 'Hi! I’m Milo, your AI friend. Ready to play with words?', 'wave'),
  Profile.friendly: ProfileCfg(.75, .3, .8, 'happy', 'Hi, I’m Milo, an AI companion. What shall we do?', 'nod'),
  Profile.discreet: ProfileCfg(.45, .6, .5, 'calm', 'Hello. I’m Milo, an AI companion.', 'none'),
};

class Spring {
  double x, v = 0, t, k, c;
  Spring(this.k, this.c, [double x0 = 0]) : x = x0, t = x0;
  void step(double dt) { v += (-k * (x - t) - c * v) * dt; x += v * dt; }
}
class Clip { final String n; final double d; final int side; double t = 0; int hops = 0; Clip(this.n, this.d, this.side); }
class Part { String ch; double x, y, vx, vy, age = 0, life; Part(this.ch, this.x, this.y, this.vx, this.vy, this.life); }
class Ch { double ar = 0, al = 0, tilt = 0, dip = 0, zoom = 0, jig = 0, eyes = 0, yawn = 0, lean = 0; }
class _Frame extends ChangeNotifier { void ping() => notifyListeners(); }

/// The single writer of the companion's state (doc 5.7). Everything else sends events.
/// Life Stack per frame: L0 physics, L1 ambient, L2 attention, L3 emotion, L4 gestures, L5 speech, L6 reactions.
class Director extends ChangeNotifier {
  final frame = _Frame(); // repaint channel (60 fps); the Director itself only notifies on UI-visible changes
  final _r = math.Random();
  double clock = 0;
  final sq = Spring(160, 12), hop = Spring(220, 13), lean = Spring(90, 9);
  final eyeX = Spring(300, 22), eyeY = Spring(300, 22), headX = Spring(45, 8), headY = Spring(45, 8);
  final armL = Spring(140, 11, .45), armR = Spring(140, 11, .45);
  final s1 = Spring(90, 5.5), s2 = Spring(90, 5.5), s3 = Spring(90, 5.5);
  Face face = faces['sleepy']!;
  String emo = 'sleepy';
  double inten = 1, _hold = 1;
  double br = 0, _bp = 0, bf = 1, _bl = 0, _nb = 2, pulse = 0, mouth = 0, _nf = 6, _nw = 2, _nj = .5;
  bool _dbl = false, vis = false;
  String _lastFid = '';
  final _fidAt = <String, double>{}, _gAt = <String, double>{};
  Offset _wander = Offset.zero, _jit = Offset.zero;
  Offset? touch, content, miloCenter;
  double touchUntil = 0, contentUntil = 0, screenW = 400, _tilt = 0, _dragLean = 0, _pl = 0, _lastShake = -9;
  final clips = <Clip>[];
  final parts = <Part>[];
  Ch ch = Ch();

  // UI-visible state
  CState state = CState.idle;
  String caption = 'Tap me to say hi!';
  List<String> choices = [];
  Presence presence = Presence.stage;
  Presence? presenceOverride;
  int tab = 0;
  Profile profile = Profile.playful;
  bool quiet = false, reactions = true, voiceOn = true, forceReduce = false, reduce = false, breathing = false;
  String voice = 'Friendly';
  Color color = const Color(0xFF8E9BFF);
  int paceSecs = 3;
  void Function(String)? onOpenScreen;
  Future<void> Function(String)? router; // set by the app: Core router (safety -> memory -> local -> cloud -> pocket brain)
  void Function()? persist;
  void Function(String)? onHighlight, onGaze, onSaid;
  void Function(Map<String, dynamic>)? onMemoryProposal;
  void Function(String, Map<String, dynamic>)? onUnderstand;
  bool preReader = false, supportActive = false, highContrast = false, haptics = true, captions = true, largeText = false;
  double textScale = 1.0, lineSpacing = 1.5;
  String font = 'Lexend';
  int breakNudgeMin = 0;
  double _presetRate = .475, _paceRate = 1;
  String lang = 'en';
  bool ttsReady = true, greetings = true, offlineForced = false;
  double voiceSpeed = 1.0;

  // speech
  FlutterTts? _tts;
  bool _speaking = false, _aac = false, _gotP = false;
  int _gen = 0, _turn = 0;
  List<RegExpMatch> _words = [];
  void Function(int)? _onWord;
  Timer? _nudge;
  double _lastNudge = -999;

  bool get speaking => _speaking;
  double get amp => kProfiles[profile]!.amp * (presence == Presence.chip ? .35 : 1);
  bool get inhale => math.cos(_bp) > 0;
  String get fx => quiet ? '' : (inten > .5 ? faces[emo]!.fx : faces[kProfiles[profile]!.base]!.fx);
  double _rnd(double a, double b) => a + _r.nextDouble() * (b - a);
  void set(void Function() f) { f(); notifyListeners(); persist?.call(); }
  void _set(CState s) { if (state != s) { state = s; notifyListeners(); } }
  void _cap(String s) { caption = s; notifyListeners(); }

  Future<void> init() async {
    try {
      _tts = FlutterTts();
      await _tts!.awaitSpeakCompletion(true);
      _tts!.setProgressHandler((String t, int s, int e, String w) {
        _gotP = true;
        final i = _words.indexWhere((m) => m.end > s);
        _pulseWord(i < 0 ? 0 : i);
      });
      await applyVoice();
      try { final v = await _tts!.getVoices; ttsReady = (v as List?)?.isNotEmpty ?? true; } catch (_) {}
    } catch (_) { _tts = null; ttsReady = false; } // no TTS engine: visual-only level of the offline ladder
    try { accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen(_onAccel, onError: (_) {}); } catch (_) {}
    Timer(const Duration(milliseconds: 900), () { if (emo == 'sleepy') emote('happy', i: .7, hold: 3); }); // wake up
  }

  Future<void> applyVoice() async {
    final v = {'Friendly': [1.15, .475], 'Calm': [1.0, .425], 'Energetic': [1.25, .525], 'Device': [1.0, .5]}[voice] ?? [1.15, .475];
    _presetRate = v[1];
    try { await _tts?.setPitch(v[0]); await _tts?.setSpeechRate(v[1]); } catch (_) {}
  }

  // ───────────────────────── per-frame update ─────────────────────────
  void tick(double dt) {
    dt = dt.clamp(0.0, 0.033).toDouble();
    clock += dt;
    final cfg = kProfiles[profile]!;
    final rm = reduce || forceReduce, aac = _aac, a = amp;
    final still = quiet || aac || breathing; // blink and breathe only

    // L3 emotion: rises ~1.5 s, half-life 8 s back to the profile baseline
    _hold -= dt;
    if (_hold < 0) inten *= math.pow(.5, dt / 8).toDouble();
    final baseF = faces[cfg.base]!;
    final base = Face.lerp(faces['calm']!, baseF, cfg.bias, baseF);
    final te = quiet ? 'calm' : emo;
    final tgt = Face.lerp(base, faces[te]!, quiet ? 0 : inten, faces[inten > .5 ? te : cfg.base]!);
    face = Face.lerp(face, tgt, 1 - math.exp(-3 * dt), tgt);

    // L0 breathing (slower and deeper during a break)
    _bp += dt * math.pi * 2 * (breathing ? .125 : .2 + .15 * face.arousal);
    br = math.sin(_bp);

    // L1 ambient: blinks every 2-6 s (12% double), micro eye movement, fidgets
    if (clock > _nb) { _bl = .001; _nb = clock + _rnd(2, 6); _dbl = _r.nextDouble() < .12; }
    if (_bl > 0) { _bl += dt; if (_bl > .16) { if (_dbl) { _dbl = false; _bl = .001; } else { _bl = 0; } } }
    bf = _bl > 0 ? 1 - math.sin(math.pi * (_bl / .16).clamp(0.0, 1.0)) : 1.0;
    if (clock > _nw) { _wander = Offset(_rnd(-.5, .5), _rnd(-.3, .25)); _nw = clock + _rnd(2, 5); }
    if (clock > _nj) { _jit = Offset(_rnd(-.05, .05), _rnd(-.05, .05)); _nj = clock + _rnd(.4, 1.2); }
    if (!still && state == CState.idle && presence != Presence.hidden && clock > _nf) _fidget();

    // L4 gestures + L5 speech performance
    ch = Ch();
    if (still) { clips.clear(); } else { for (final c in clips) { c.t += dt; _clip(c, ch, a, rm); } clips.removeWhere((c) => c.t >= c.d); }
    pulse *= math.exp(-dt * 9);
    mouth = aac ? 0 : math.max(face.mouth, math.max(pulse * .85, ch.yawn * .95));
    if (_speaking && !aac) ch.dip += pulse * 2;

    // L2 attention: touch > content > mic > person > wander. Eyes lead, head follows (spring lag).
    final g = still ? Offset.zero : _gaze();
    final range = rm ? .4 : 1.0;
    eyeX.t = g.dx * range; eyeY.t = g.dy * range;
    headX.t = g.dx * 6 * range; headY.t = g.dy * 3 * range + ch.dip * a;

    // L0 physics targets
    final tiltDev = (reactions && profile != Profile.discreet && !rm) ? _tilt : 0.0;
    armR.t = .45 + ch.ar * a + (_speaking && !aac ? pulse * .25 : 0);
    armL.t = .45 + ch.al * a;
    lean.t = (ch.tilt + ch.lean) * a + tiltDev + _dragLean;
    final droop = math.max(0.0, -face.perk), sw = math.sin(clock * 1.3) * .05 * (still ? .3 : 1);
    s1.t = droop * .5 + sw; s2.t = droop * .7; s3.t = droop * .9;
    final dl = (lean.x - _pl) / math.max(dt, 1e-3);
    _pl = lean.x;
    s1.v -= dl * .06; s2.v -= dl * .08; // sprout trails the body
    s1.v += hop.v * .0006; s2.v += hop.v * .0008;
    if (rm) { hop.x = 0; hop.v = 0; sq.x = 0; sq.v = 0; }
    sq.t = rm ? 0 : (-hop.v * .0004).clamp(-.1, .1).toDouble();
    for (final s in [sq, hop, lean, eyeX, eyeY, headX, headY, armL, armR, s1, s2, s3]) { s.step(dt); }
    if (hop.x > 0) { hop.x = 0; if (hop.v > 0) hop.v = 0; }

    for (final p in parts) { p.age += dt; p.x += p.vx * dt; p.y += p.vy * dt; }
    parts.removeWhere((p) => p.age > p.life);
    frame.ping();
  }

  Offset _gaze() {
    if (touch != null && clock < touchUntil) return touch!;
    if (content != null && clock < contentUntil) return content!;
    if (state == CState.listening) return const Offset(0, .4);
    if (emo == 'thinking' && inten > .4) return const Offset(-.6, -.7);
    return _wander + _jit;
  }

  static const _dur = {'wave': 1.2, 'nod': .6, 'shrug': .9, 'point': 1.0, 'lean_in': 1.0, 'think': 1.6, 'celebrate': 2.2, 'giggle': .9,
    'yawn': 2.0, 'stretch': 1.8, 'hum': 1.5, 'dizzy': 1.2, 'pet': 1.5};

  void _clip(Clip c, Ch h, double a, bool rm) {
    final p = (c.t / c.d).clamp(0.0, 1.0).toDouble(), e = math.sin(math.pi * p), s = c.t;
    switch (c.n) {
      case 'wave': h.ar += 1.75 * e + math.sin(s * 16) * .35 * e; h.tilt += .06 * e;
      case 'nod': h.dip += math.sin(p * math.pi * 2) * 5;
      case 'shrug': h.ar += .8 * e; h.al += .8 * e; h.tilt += math.sin(p * math.pi * 2) * .06; h.dip -= 2 * e;
      case 'point': if (c.side > 0) { h.ar += 1.5 * e; } else { h.al += 1.5 * e; } h.lean += .04 * e * c.side;
      case 'lean_in': h.zoom += .07 * e; h.dip += 3 * e;
      case 'think': h.al += 1.6 * e; h.tilt += .1 * e;
      case 'celebrate':
        h.ar += 2.1 * e + math.sin(s * 12) * .25 * e; h.al += 2.1 * e + math.sin(s * 12 + 1) * .25 * e;
        if (c.hops < 3 && s > c.hops * .55) { c.hops++; if (!rm) hop.v = -330 * a; _burst('✦', 4); }
      case 'giggle': h.jig += math.sin(s * 34) * .03 * e; h.tilt += math.sin(s * 20) * .05 * e; if (math.sin(s * 24) > 0) pulse = math.max(pulse, .7 * e);
      case 'yawn': h.yawn = e;
      case 'stretch': h.ar += 2.3 * e; h.al += 2.3 * e; h.zoom += .05 * e;
      case 'hum':
        if (math.sin(s * 10) > 0) pulse = math.max(pulse, .5);
        h.tilt += math.sin(s * 3) * .06 * e;
        if (c.hops == 0 && s > .3) { c.hops = 1; _burst('♪', 2); }
      case 'dizzy': h.tilt += math.sin(s * 14) * .18 * e * (1 - p);
      case 'pet': h.eyes = math.min(1.0, e * 2.5); h.zoom -= .02 * e;
    }
  }

  void _burst(String ch, int n) {
    if (presence == Presence.hidden) return;
    for (var i = 0; i < n; i++) { parts.add(Part(ch, _rnd(-45, 45), _rnd(-165, -120), _rnd(-18, 18), _rnd(-55, -25), 1.3)); }
  }

  void _fidget() {
    _nf = clock + _rnd(12, 25);
    final pool = profile == Profile.discreet ? ['look'] : ['look', 'yawn', 'stretch', 'hum'];
    final opts = pool.where((n) => n != _lastFid && clock - (_fidAt[n] ?? -99) > 60).toList(); // never twice in a row
    if (opts.isEmpty) return;
    final n = opts[_r.nextInt(opts.length)];
    _lastFid = n; _fidAt[n] = clock;
    if (n == 'look') { _wander = Offset(_rnd(-.9, .9), _rnd(-.4, .3)); _nw = clock + 2; } else { clips.add(Clip(n, _dur[n]!, 1)); }
  }

  // ───────────────────────── events in ─────────────────────────
  void emote(String n, {double i = .8, double hold = 4, bool force = false}) {
    if (!faces.containsKey(n) || (quiet && !force)) return;
    emo = n; inten = math.min(i, kProfiles[profile]!.ceil); _hold = hold;
    if (const ['excited', 'proud', 'playful'].contains(n) && inten > .5 && !_aac && !quiet) _burst('✦', 5);
    if (n == 'encouraging' && inten > .4 && !quiet) _burst('♥', 3);
  }
  void relax() => _hold = 0;

  void gesture(String n, {bool force = false}) {
    if (_aac || quiet || breathing) return; // never animate over AAC speech
    if (!force && clock - (_gAt[n] ?? -99) < 20) return; // same gesture not within 20 s
    _gAt[n] = clock;
    clips.add(Clip(n, _dur[n] ?? 1, (miloCenter?.dx ?? 0) > screenW / 2 ? -1 : 1));
  }

  Offset _norm(Offset p) {
    final c = miloCenter ?? Offset(screenW / 2, 300);
    return Offset(((p.dx - c.dx) / 200).clamp(-1.0, 1.0).toDouble(), ((p.dy - c.dy) / 200).clamp(-1.0, 1.0).toDouble());
  }
  void pointerAt(Offset global) { touch = _norm(global); touchUntil = clock + 2.5; }
  void lookAtGlobal(Offset global, {double secs = 1.2}) { content = _norm(global); contentUntil = clock + secs; }

  // L6 reactions (local, no AI, <100 ms)
  void tapMilo() {
    if (_speaking && !_aac) { // barge-in
      cancelSpeech(); _turn++;
      emote('listening', i: .9, hold: 8, force: true); _set(CState.listening); _cap('I’m listening. Type or tap what you want.');
      Timer(const Duration(seconds: 8), () { if (state == CState.listening) { relax(); _set(CState.idle); } });
      return;
    }
    if (_aac || !reactions || quiet) return;
    if (haptics) HapticFeedback.lightImpact();
    _nb = clock; // blink
    if (profile == Profile.discreet) return; // eyes only
    gesture('giggle', force: true); sq.v -= 2.2;
  }
  void petMilo() {
    if (!reactions || quiet || _aac || profile == Profile.discreet) return;
    HapticFeedback.mediumImpact(); clips.add(Clip('pet', 1.5, 1)); emote('happy', i: 1, hold: 2.5, force: true);
  }
  void sproutTap() {
    if (!reactions || quiet || _aac || profile == Profile.discreet) return;
    s1.v += 7; s2.v += 9; _burst('✦', 3);
  }
  void dragTo(Offset n) { touch = n; touchUntil = clock + 1.5; _dragLean = n.dx * .05; }
  void endDrag() => _dragLean = 0;

  void _onAccel(AccelerometerEvent e) {
    _tilt = (-e.x / 9.8).clamp(-1.0, 1.0).toDouble() * .12; // Milo leans with gravity
    final m = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    if (m > 26 && clock - _lastShake > 3 && profile == Profile.playful && reactions && !quiet && !_aac) {
      _lastShake = clock; gesture('dizzy', force: true);
      Future.delayed(const Duration(milliseconds: 1100), () => gesture('giggle', force: true));
    }
  }

  // presence
  Presence _auto() => tab == 0 ? (profile == Profile.discreet ? Presence.buddy : Presence.stage) : (screenKind == 'express' ? Presence.chip : Presence.buddy);
  String screenKind = '';
  void setScreenKind(String k) { if (screenKind != k) { screenKind = k; if (presenceOverride == null) { presence = _auto(); notifyListeners(); } } }
  void setTab(int i) { tab = i; presence = presenceOverride ?? _auto(); emote('curious', i: .5, hold: 2); notifyListeners(); }
  void setPresence(Presence? p) { presenceOverride = p; presence = p ?? _auto(); notifyListeners(); persist?.call(); }
  void setProfile(Profile p) { profile = p; if (presenceOverride == null) presence = _auto(); notifyListeners(); persist?.call(); }

  void setBreathing(bool on) {
    breathing = on;
    if (on) {
      cancelSpeech(); _turn++; emote('calm', i: 1, hold: 1e9, force: true); _set(CState.calm);
      speak('Take your time. I’m right here.');
    } else { relax(); _set(CState.idle); }
    notifyListeners();
  }

  // ───────────────────────── speech (L5) ─────────────────────────
  void _pulseWord(int i) { pulse = 1; vis = !vis; _onWord?.call(i); }

  void _est(int gen, int i, double rate) { // fallback timing when the TTS engine gives no word callbacks
    if (gen != _gen || _gotP || i >= _words.length) return;
    _pulseWord(i);
    Future.delayed(Duration(milliseconds: ((120 + _words[i].group(0)!.length * 55) / rate).round()), () => _est(gen, i + 1, rate));
  }

  Future<void> speak(String text, {void Function(int)? onWord, bool aac = false, double rate = 1}) async {
    final gen = ++_gen;
    _words = RegExp(r'\S+').allMatches(text).toList(); _onWord = onWord; _gotP = false; _speaking = true; _aac = aac;
    if (aac) clips.clear();
    _set(CState.speaking);
    final t0 = DateTime.now(), est = _words.length * 330;
    Future.delayed(const Duration(milliseconds: 450), () => _est(gen, 0, rate));
    if (voiceOn && _tts != null) { try { await _tts!.setSpeechRate(_presetRate * _paceRate * voiceSpeed); await _tts!.speak(text); } catch (_) {} }
    final el = DateTime.now().difference(t0).inMilliseconds;
    if (gen == _gen && el < est * .5) await Future.delayed(Duration(milliseconds: (est * .7 - el).round())); // visual-only: keep caption up
    if (gen == _gen) { _gen++; _speaking = false; _aac = false; _onWord = null; _nb = clock; if (state == CState.speaking) _set(CState.idle); }
  }

  Future<void> speakAac(String text) { _turn++; choices = []; return speak(text, aac: true); }
  void cancelSpeech() { _gen++; _speaking = false; _aac = false; try { _tts?.stop(); } catch (_) {} }

  // ───────────────────────── brain loop ─────────────────────────
  Future<void> ask(String text) async {
    final id = ++_turn;
    cancelSpeech(); choices = []; supportActive = false;
    _set(CState.thinking); emote('thinking', i: .8, hold: 60, force: true); gesture('think', force: true); _cap('…');
    if (router != null) { // body already reacted; the router decides local vs cloud
      try { await router!(text); } catch (_) { if (id == _turn || _turn > id) await perform(validateTurn(pocketBrain(text, profile.name))); }
      return;
    }
    await Future.delayed(const Duration(milliseconds: 650));
    if (id != _turn) return;
    await perform(validateTurn(pocketBrain(text, profile.name)));
  }

  /// Streaming performance: body event first (Milo reacts), then sentences are spoken as they arrive.
  Future<void> performStream(Stream<BrainEvent> events) async {
    final id = ++_turn;
    final q = <String>[];
    var busy = false, wait = false;
    Future<void> pump() async {
      if (busy) return;
      busy = true;
      while (q.isNotEmpty && id == _turn) { final s = q.removeAt(0); _cap(s); onSaid?.call(s); await speak(s); }
      busy = false;
    }
    await for (final e in events) {
      if (id != _turn) return;
      final d = e.data;
      switch (e.type) {
        case 'risk': if (d['level'] != 'none') { await performSupport(); return; }
        case 'body':
          final em = d['emotion'];
          if (em is Map) emote('${em['name']}', i: (em['intensity'] as num?)?.toDouble() ?? .6, hold: 6, force: true);
          if (d['gesture'] is String) gesture(d['gesture'] as String, force: true);
          final g = d['gaze'];
          if (g is Map && '${g['id']}'.isNotEmpty) onGaze?.call('${g['id']}');
          _paceRate = d['pace'] == 'slow' ? .8 : 1;
        case 'say': q.add('${d['text']}'); unawaited(pump());
        case 'ui':
          if (d['action'] == 'offer_choices') { choices = [for (final c in d['choices'] as List) '$c']; notifyListeners(); }
          if (d['action'] == 'open_screen') onOpenScreen?.call('${d['screen']}');
          if (d['action'] == 'highlight') onHighlight?.call('${d['span']}');
        case 'memory': onMemoryProposal?.call(d);
        case 'key_point' || 'simple' || 'vocab' || 'check': onUnderstand?.call(e.type, d);
        case 'error': throw Exception('cloud_${d['code']}');
        case 'done': wait = d['followup'] == 'wait';
      }
    }
    while ((busy || q.isNotEmpty) && id == _turn) { await Future.delayed(const Duration(milliseconds: 80)); }
    if (id != _turn) return;
    _paceRate = 1; relax();
    _set(wait || choices.isNotEmpty ? CState.waiting : CState.idle);
    if (wait || choices.isNotEmpty) _armNudge();
  }

  void setListening(bool on) {
    if (on) { cancelSpeech(); _turn++; emote('listening', i: .9, hold: 60, force: true); _set(CState.listening); } else { relax(); _set(CState.idle); }
  }

  /// Hand-written support flow (doc 6.5): calm, one caring sentence, ask about a trusted grown-up, big buttons. Never generated.
  Future<void> performSupport() async { cancelSpeech(); await perform(Safety.supportTurn(lang)); }

  void loadSettings(Map<String, String> s) {
    profile = Profile.values.firstWhere((p) => p.name == s['profile'], orElse: () => Profile.friendly);
    presenceOverride = Presence.values.where((p) => p.name == s['presence']).firstOrNull;
    voice = s['voice'] ?? 'Friendly';
    final c = int.tryParse(s['color'] ?? ''); if (c != null) color = Color(c);
    quiet = s['quiet'] == '1'; reactions = s['reactions'] != '0'; voiceOn = s['voiceOn'] != '0'; forceReduce = s['reduce'] == '1';
    paceSecs = int.tryParse(s['pace'] ?? '') ?? 3; preReader = s['prereader'] == '1'; lang = s['lang'] ?? 'en';
    highContrast = s['hc'] == '1'; haptics = s['haptics'] != '0'; captions = s['captions'] != '0'; textScale = double.tryParse(s['tscale'] ?? '') ?? 1.0;
    lineSpacing = double.tryParse(s['lspace'] ?? '') ?? 1.5; font = s['font'] ?? 'Lexend'; breakNudgeMin = int.tryParse(s['breaknudge'] ?? '') ?? 0; greetings = s['greetings'] != '0'; voiceSpeed = double.tryParse(s['vspeed'] ?? '') ?? 1.0; offlineForced = s['offline.forced'] == '1';
    presence = presenceOverride ?? _auto();
    applyVoice();
    notifyListeners();
  }
  Map<String, String> toSettings() => {'profile': profile.name, 'presence': presenceOverride?.name ?? 'auto', 'voice': voice, 'color': '${color.value}',
    'quiet': quiet ? '1' : '0', 'reactions': reactions ? '1' : '0', 'voiceOn': voiceOn ? '1' : '0', 'reduce': forceReduce ? '1' : '0', 'pace': '$paceSecs', 'prereader': preReader ? '1' : '0', 'lang': lang, 'hc': highContrast ? '1' : '0', 'haptics': haptics ? '1' : '0', 'captions': captions ? '1' : '0', 'tscale': '$textScale', 'lspace': '$lineSpacing', 'font': font, 'breaknudge': '$breakNudgeMin', 'greetings': greetings ? '1' : '0', 'vspeed': '$voiceSpeed', 'offline': offlineForced ? '1' : '0'};

  /// Body first (emotion + gesture), then words, sentence by sentence.
  Future<void> perform(BrainTurn t) async {
    final id = ++_turn;
    if (t.risk != 'none') supportActive = true;
    emote(t.emotion, i: t.intensity, hold: 6, force: t.risk != 'none');
    if (t.gesture != null) gesture(t.gesture!, force: true);
    choices = t.choices; notifyListeners();
    if (t.openScreen != null) onOpenScreen?.call(t.openScreen!);
    for (final s in t.say) {
      if (id != _turn) return;
      _cap(s); onSaid?.call(s);
      await speak(s);
    }
    if (id != _turn) return;
    relax();
    final wait = t.followup == 'wait' || t.choices.isNotEmpty;
    _set(wait ? CState.waiting : CState.idle);
    if (wait) _armNudge();
  }

  void _armNudge() { // waiting etiquette: one gentle nudge at 2x pace, max one per 5 min, none in chip/discreet
    _nudge?.cancel();
    if (presence == Presence.chip || presence == Presence.hidden || profile == Profile.discreet || clock - _lastNudge < 300) return;
    _nudge = Timer(Duration(seconds: paceSecs * 2), () {
      if (state == CState.waiting && !quiet) { _lastNudge = clock; speak('Take your time. I’m right here.'); }
    });
  }

  Future<void> greet() async {
    if (quiet || !greetings) return;
    final c = kProfiles[profile]!;
    _set(CState.greeting);
    if (c.gesture != 'none') gesture(c.gesture, force: true);
    emote('happy', i: .9);
    _cap(c.greet);
    await speak(c.greet);
    _set(CState.idle);
  }

  /// Celebration scaled to the person's presentation profile (doc 5.4).
  void celebrate({bool goal = false}) {
    if (quiet) return;
    HapticFeedback.lightImpact();
    switch (profile) {
      case Profile.playful: emote('excited', i: 1, hold: 3, force: true); gesture(goal ? 'celebrate' : 'nod', force: true); if (goal) _burst('✦', 8);
      case Profile.friendly: emote('proud', i: .8, hold: 3, force: true); gesture(goal ? 'celebrate' : 'nod', force: true);
      case Profile.discreet: emote('proud', i: .4, hold: 2, force: true);
    }
    if (goal) { _set(CState.celebrating); Timer(const Duration(milliseconds: 2400), () { if (state == CState.celebrating) _set(CState.idle); }); }
  }
}
