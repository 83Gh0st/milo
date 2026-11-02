import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../contracts/brain_contract.dart';
import '../contracts/events.dart';
import '../net/api.dart';
import '../core/safety.dart';
import '../core/pocket_brain.dart';
import '../voice/normalize.dart';
import '../voice/voice_output.dart';
import 'emotion.dart';
import 'greetings.dart';
import 'react.dart';
import 'sounds.dart';
import 'v2/look.dart';

/// Turn-taking states: idle → listening → endpointing → thinking → speaking
/// → waiting. `endpointing` (partials paused, final not yet here) looks like
/// listening; it exists so the turn table is explicit and testable.
enum CState { idle, greeting, listening, endpointing, thinking, speaking, waiting, celebrating, calm }
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

/// Ranks an on-device TTS voice for Milo: the saved choice wins, then the
/// current language, then English, then a warm feminine voice. No platform
/// ships a true child voice; this picks the closest honest option.
int voiceScore(Map<String, String> v, String lang, String? preferred) {
  var s = 0;
  final loc = (v['locale'] ?? '').toLowerCase().replaceAll('_', '-'), ln = lang.toLowerCase();
  if (preferred != null && preferred.isNotEmpty && v['name'] == preferred) s += 100;
  if (loc == ln || (ln.isNotEmpty && loc.startsWith('$ln-'))) { s += 10; } else if (loc.startsWith('en')) { s += 3; }
  final n = (v['name'] ?? '').toLowerCase();
  if (n.contains('child') || n.contains('kid')) { s += 6; }
  else if (n.contains('female') || n.contains('feminine') || n.contains('woman') || n.contains('girl') || n.contains('samantha') || n.contains('zira')) { s += 2; }
  if (n.contains('male') || n.contains('masculine') || n.contains('david')) s -= 1;
  return s;
}

Map<String, String>? pickVoice(List<Map<String, String>> voices, String lang, String? preferred) {
  Map<String, String>? best;
  var bestScore = -999;
  for (final v in voices) {
    final s = voiceScore(v, lang, preferred);
    if (s > bestScore) { bestScore = s; best = v; }
  }
  return best;
}

/// Delivery tone per emotion: warm by default, playful only when the feeling
/// already is, calm and gentle when the child struggles or is distressed.
String? toneForEmotion(String emo) => const {
  'encouraging': 'warm', 'happy': 'warm', 'proud': 'warm', 'curious': 'warm',
  'playful': 'playful', 'excited': 'playful', 'surprised': 'playful',
  'concerned': 'gentle', 'calm': 'calm', 'sleepy': 'calm', 'thinking': 'calm', 'listening': 'calm',
}[emo];

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
  double micLevel = 0; // 0..1 live microphone amplitude while listening (decays in tick); never stored
  double _lastAlive = 0; // clock time of the last interaction; long untouched idles drift drowsy
  String? _sayTone; // delivery tone for the sentences currently streaming
  double _presetPitch = 1.15;
  List<Map<String, String>> ttsVoices = []; // on-device voices, best first
  String ttsVoice = '', ttsLocale = ''; // saved TTS voice choice (empty = platform default)
  StreamSubscription? _accel;

  /// The person (or Milo's own speech) did something: Milo is awake.
  void markActive() { _lastAlive = clock; }
  String _lastFid = '';
  final _fidAt = <String, double>{}, _gAt = <String, double>{};
  Offset _wander = Offset.zero, _jit = Offset.zero;
  Offset? touch, content, miloCenter;
  double _lastInlineAt = -99;
  /// Gaze registration (L7): inline Milos always win; the buddy overlay only
  /// aims gaze when no inline Milo registered in the last second.
  void registerMilo(Offset c, bool inline) { if (inline) { miloCenter = c; _lastInlineAt = clock; } else if (clock - _lastInlineAt > 1.0) { miloCenter = c; } }
  double touchUntil = 0, contentUntil = 0, screenW = 400, _tilt = 0, _dragLean = 0, _pl = 0, _lastShake = -9;
  final clips = <Clip>[];
  final parts = <Part>[];
  Ch ch = Ch();

  // UI-visible state
  CState state = CState.idle;
  String caption = 'Tap me to say hi!';
  List<String> choices = [];
  final Set<String> peeked = {}; // dock collapsed per screen kind (persisted as local.peeked, never synced)
  Presence presence = Presence.stage;
  Presence? presenceOverride;
  int tab = 0;
  Profile profile = Profile.playful;
  bool quiet = false, reactions = true, voiceOn = true, forceReduce = false, reduce = false, breathing = false;
  String voiceStyle = 'Friendly';
  Color color = const Color(0xFF149E87); // brand default: deep teal (wardrobe keeps periwinkle as an option)
  int paceSecs = 3;
  void Function(String)? onOpenScreen;
  Future<void> Function(String)? router; // set by the app: Core router (safety -> memory -> local -> cloud -> pocket brain)
  void Function()? persist;
  void Function(String)? onHighlight, onGaze, onSaid;
  void Function(String)? onReadAloud, onLookupWord; // read-only tools: set by the reader / app wiring
  void Function(List<String>)? onSteps;
  Future<void> Function(String)? onShowImage; // set by the app: fetches the explainer picture into visualProvider
  int breakSecs = 300; // break-screen countdown; a validated set_timer action may change it
  bool ignoreTaps = false, leftHanded = false;
  bool scanMode = false; // switch/scanning access (plan P2): highlight auto-advances, any tap selects
  int scanMs = 1200; // highlight dwell per step, 400..3000
  double _lastTap = -99;
  void Function(Map<String, dynamic>)? onMemoryProposal;
  void Function(String, Map<String, dynamic>)? onUnderstand;
  void Function(Map<String, dynamic>)? onUiSpec; // generative panel: set by the app, validated again client-side
  bool preReader = false, supportActive = false, highContrast = false, haptics = true, captions = true, largeText = false;
  double textScale = 1.0, lineSpacing = 1.5;
  String font = 'Lexend';
  int breakNudgeMin = 0;
  double _presetRate = .475, _paceRate = 1;
  String lang = 'en';
  bool ttsReady = true, greetings = true, offlineForced = false;
  bool met = false; // the spoken introduction played (persisted). Taps and launches never replay it.
  double voiceSpeed = 1.0;
  VoiceEngineMode voiceEngine = VoiceEngineMode.auto; // online-voice setting (platform until a real sink ships)
  bool clearSpeech = false; // dyslexic-reader option: slightly slower, extra-careful delivery
  VoiceRouter voice = VoiceRouter(platform: PlatformVoice(), neural: NeuralVoice(sink: NoopAudioSink())); // non-final test seam: tests substitute fake outputs
  double _mouthLevel = 0; // neural envelope feed (0 when platform speaks); decays every tick
  double _partialAt = -1; // clock of the last STT partial; listening → endpointing after a 1.5 s pause
  double _listenSince = -1; // clock when listening started; attenLive self-exits after 25 s (no stuck Listening)
  StreamSubscription? _voiceSub;
  double motionGain = 1.0; // Milo Lab slider only; 1.0 = shipped behaviour (never persisted)
  MiloLook look = MiloLook.a; // active 2A direction (persisted); the human picks A/B/C
  bool legacyRenderer = false; // Lab-only: compare with the pre-Phase-2 painter (never persisted)
  final sounds = MiloSounds();
  bool soundOn = true;
  double soundVol = .8;
  double moodBase = 0; // slow mood baseline, nudged by emote(), blended into the base face
  int daysTogether = 0; // days since first launch (no streak language anywhere)
  String _pendingAsk = ''; // original query while the thinking ladder offers the offline fallback
  double _antic = 0; // speech anticipation: 150 ms breath + lean before audio starts

  // speech
  bool _speaking = false, _aac = false, _gotP = false;
  bool _speechStarted = false; // set by the first real audio signal (platform started/word event or neural envelope); the mouth never moves before it
  int _gen = 0, _turn = 0;
  List<RegExpMatch> _words = [];
  void Function(int)? _onWord;
  Timer? _nudge;
  double _lastNudge = -999;

  bool get speaking => _speaking;
  bool get aac => _aac; // the v2 renderer gates idle motion on this (never animate over AAC speech)
  double get amp => kProfiles[profile]!.amp * (presence == Presence.chip ? .35 : 1) * motionGain;
  bool get inhale => math.cos(_bp) > 0;
  String get fx => quiet ? '' : (inten > .5 ? faces[emo]!.fx : faces[kProfiles[profile]!.base]!.fx);
  double _rnd(double a, double b) => a + _r.nextDouble() * (b - a);
  void set(void Function() f) { f(); notifyListeners(); persist?.call(); }
  void _set(CState s) { if (state != s) { state = s; notifyListeners(); } }
  void _cap(String s) { caption = s; notifyListeners(); }

  /// True when platform channels can work. The sensors/connectivity plugins
  /// throw *asynchronous* binding errors without one, which try/catch cannot
  /// see (plain unit tests, exotic platforms). Probe instead of catching.
  static bool get messengerOk { try { ServicesBinding.instance; return true; } catch (_) { return false; } }

  Future<void> init() async {
    await voice.platform.init();
    // Voice progress events are subscribed per speak() call (_watchVoice), so
    // a previous utterance's late callbacks can never move a newer request's
    // mouth. There is no permanent subscription here on purpose.
    if (!voice.platform.ready) ttsReady = false; // no TTS engine: visual-only level of the offline ladder
    await refreshVoices();
    if (messengerOk) { try { _accel = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen(_onAccel, onError: (_) {}); } catch (_) {} }
    Timer(const Duration(milliseconds: 900), () { if (emo == 'sleepy') { emote('happy', i: .7, hold: 3); _sfx('wake'); } }); // wake up
    MiloReact.handler = _onReact;
  }

  bool _disposed = false;
  @override
  void dispose() {
    if (_disposed) return; // Riverpod auto-disposes the notifier AND runs ref.onDispose: both land here
    _disposed = true;
    if (identical(MiloReact.handler, _onReact)) MiloReact.handler = null;
    _accel?.cancel();
    _nudge?.cancel();
    _voiceSub?.cancel();
    cancelSpeech();
    unawaited(voice.dispose());
    frame.dispose();
    super.dispose();
  }

  Future<void> applyVoice() async {
    final v = {'Friendly': [1.15, .475], 'Calm': [1.0, .425], 'Energetic': [1.25, .525], 'Device': [1.0, .5]}[voiceStyle] ?? [1.15, .475];
    _presetPitch = (v[0] as num).toDouble();
    _presetRate = (v[1] as num).toDouble();
    await voice.platform.applyVoice(
        lang: ttsLocale.isNotEmpty ? ttsLocale : lang, voice: ttsVoice, locale: ttsLocale.isNotEmpty ? ttsLocale : lang, pitch: _presetPitch, rate: _presetRate);
  }

  /// Lists the phone's real TTS voices (best first), keeps the saved choice
  /// when it still exists, and applies everything. Empty list with no engine
  /// error means "default voice only": still usable, said honestly in the UI.
  Future<void> refreshVoices() async {
    try {
      final got = await voice.platform.getVoices();
      ttsReady = got == null ? true : got.isNotEmpty;
      final all = got ?? [];
      all.sort((a, b) => voiceScore(b, lang, ttsVoice.isEmpty ? null : ttsVoice).compareTo(voiceScore(a, lang, ttsVoice.isEmpty ? null : ttsVoice)));
      ttsVoices = all.take(8).toList();
      if (ttsVoice.isNotEmpty && !ttsVoices.any((m) => m['name'] == ttsVoice)) {
        ttsVoice = ''; ttsLocale = ''; // saved voice is gone (OS update): fall through to a fresh pick
      }
      final pick = pickVoice(ttsVoices, lang, ttsVoice.isEmpty ? null : ttsVoice);
      if (pick != null && ttsVoice.isEmpty) { ttsVoice = pick['name']!; ttsLocale = pick['locale']!; persist?.call(); }
      await applyVoice();
      notifyListeners();
    } catch (_) {}
  }

  /// Trusted choice from the voice list: persists, applies, and previews.
  Future<void> selectVoice(String name, String locale) async {
    set(() { ttsVoice = name; ttsLocale = locale; });
    await applyVoice();
    await speak('Hello, I’m Milo.', tone: 'warm');
  }

  void setVoiceEngine(VoiceEngineMode m) => set(() { voiceEngine = m; voice.mode = m; });

  /// Short fixed lines worth caching after first synthesis: instant next
  /// time, and playable offline. Mock placeholder audio is never cached.
  static const kFixedVoiceLines = ['Well done!', 'Try again — you can do it.', 'Take your time. I’m right here.', 'Good morning!', 'Good night.'];

  /// Downloads the fixed lines for offline use. Returns [done, total];
  /// failures are counted in the total but never throw.
  Future<(int, int)> cacheFixedLines({void Function(int done, int total)? onProgress}) async {
    final lines = [...greetingPool(profile, lang).take(4), ...kFixedVoiceLines];
    final pace = voiceSpeed * (clearSpeech ? .9 : 1);
    var done = 0;
    for (final l in lines) {
      if (await voice.neural.prefetch(l, lang: lang, profile: VoiceRouter.voiceIdFor(lang), pace: pace)) done++;
      onProgress?.call(done, lines.length);
    }
    return (done, lines.length);
  }

  // ───────────────────────── per-frame update ─────────────────────────
  void tick(double dt) {
    dt = dt.clamp(0.0, 0.033).toDouble();
    clock += dt;
    final cfg = kProfiles[profile]!;
    final rm = reduce || forceReduce, aac = _aac, a = amp;
    final still = quiet || aac || breathing; // blink and breathe only

    // L3 emotion: rises ~1.5 s, half-life 8 s back to the profile baseline.
    // Untouched for two minutes while truly idle, Milo drifts drowsy (smooth:
    // the same lerp) and wakes the instant anything happens.
    _hold -= dt;
    if (_hold < 0) inten *= math.pow(.5, dt / 8).toDouble();
    final drowsy = state == CState.idle && !_speaking && clock - _lastAlive > 120;
    final baseF = faces[cfg.base]!;
    final base = Face.lerp(faces['calm']!, baseF, cfg.bias, baseF);
    final moody = Face.lerp(base, faces[moodBase >= 0 ? 'happy' : 'calm']!, moodBase.abs(), base); // slow mood continuity
    final te = quiet ? 'calm' : drowsy ? 'sleepy' : emo;
    final double di = quiet ? 0 : drowsy ? .6 : inten; // drowsy reads even after the last feeling faded
    final tgt = Face.lerp(moody, faces[te]!, di, faces[di > .5 ? te : cfg.base]!);
    face = Face.lerp(face, tgt, 1 - math.exp(-3 * dt), tgt);

    // L0 breathing (slower and deeper during a break)
    _bp += dt * math.pi * 2 * (breathing ? .125 : .2 + .15 * face.arousal);
    br = math.sin(_bp);

    // L1 ambient: blinks every 2-6 s (12% double), micro eye movement, fidgets
    if (clock > _nb) { _bl = .001; _nb = clock + _rnd(2, 6) * (state == CState.idle && !_speaking && clock - _lastAlive > 120 ? 1.8 : 1); _dbl = _r.nextDouble() < .12; }
    if (_bl > 0) { _bl += dt; if (_bl > .16) { if (_dbl) { _dbl = false; _bl = .001; } else { _bl = 0; } } }
    bf = _bl > 0 ? 1 - math.sin(math.pi * (_bl / .16).clamp(0.0, 1.0)) : 1.0;
    if (clock > _nw) { _wander = Offset(_rnd(-.5, .5), _rnd(-.3, .25)); _nw = clock + _rnd(2, 5); }
    if (clock > _nj) { _jit = Offset(_rnd(-.05, .05), _rnd(-.05, .05)); _nj = clock + _rnd(.4, 1.2); }
    if (!still && state == CState.idle && presence != Presence.hidden && clock > _nf) _fidget(rm);
    if (state == CState.listening && _partialAt >= 0 && clock - _partialAt > 1.5) _set(CState.endpointing); // partials paused: still attentive, about to think
    if (attenLive && _listenSince >= 0 && clock - _listenSince > 25) { relax(); _partialAt = -1; _listenSince = -1; _set(CState.idle); } // server went quiet: never stuck

    // L4 gestures + L5 speech performance
    ch = Ch();
    if (_antic > 0 && !still) { _antic -= dt; ch.dip += 2 * a; ch.zoom += .02 * a; } // breath + lean before speaking
    if (still) { clips.clear(); } else { for (final c in clips) { c.t += dt; _clip(c, ch, a, rm); } clips.removeWhere((c) => c.t >= c.d); }
    pulse *= math.exp(-dt * 9);
    _mouthLevel *= math.exp(-dt * 10); // neural envelope decays between 50 ms feeds; silence shuts the mouth
    micLevel *= math.exp(-dt * 5); // live mic amplitude decays between audio chunks
    mouth = aac ? 0 : math.max(face.mouth, math.max(pulse * .85, math.max(ch.yawn * .95, _mouthLevel)));
    if (_speaking && !aac) ch.dip += pulse * 2;

    // L2 attention: touch > content > mic > person > wander. Eyes lead, head follows (spring lag).
    final g = still ? Offset.zero : _gaze();
    final range = rm ? .4 : 1.0;
    eyeX.t = g.dx * range; eyeY.t = g.dy * range;
    headX.t = g.dx * 6 * range;
    headY.t = g.dy * 3 * range + ch.dip * a + (attenLive ? micLevel * 4 * range : 0); // the head rides the voice while listening

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

  /// Actively attending to the person's voice (listening or endpointing):
  /// gaze, head-ride, rings and the chat live-dot all follow this.
  bool get attenLive => state == CState.listening || state == CState.endpointing;

  /// An STT partial arrived: stay in `listening` while words keep coming.
  void notePartial() { if (state == CState.listening) _partialAt = clock; }

  Offset _gaze() {
    if (touch != null && clock < touchUntil) return touch!;
    if (content != null && clock < contentUntil) return content!;
    if (attenLive) return const Offset(0, .4);
    if (emo == 'thinking' && inten > .4) return const Offset(-.6, -.7);
    return _wander + _jit;
  }

  static const _dur = {'wave': 1.2, 'nod': .6, 'shrug': .9, 'point': 1.0, 'lean_in': 1.0, 'think': 1.6, 'celebrate': 2.2, 'giggle': .9,
    'yawn': 2.0, 'stretch': 1.8, 'hum': 1.5, 'dizzy': 1.2, 'pet': 1.5,
    'tilt_head': 1.0, 'clap': 1.1, 'lean_back': 1.2, 'thinking_hmm': 1.8, 'soft_sigh': 1.6, 'peek': 1.2};
  static List<String> get clipNames => _dur.keys.toList(); // Milo Lab buttons; single source is _dur

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
      case 'giggle': h.jig += math.sin(s * 34) * .03 * e; h.tilt += math.sin(s * 20) * .05 * e; // body shake only: the mouth never moves without speech audio
      case 'yawn': h.yawn = e;
      case 'stretch': h.ar += 2.3 * e; h.al += 2.3 * e; h.zoom += .05 * e;
      case 'hum':
        h.tilt += math.sin(s * 3) * .06 * e; // sway only: humming has no voice audio, so the mouth stays shut
        if (c.hops == 0 && s > .3) { c.hops = 1; _burst('♪', 2); }
      case 'dizzy': h.tilt += math.sin(s * 14) * .18 * e * (1 - p);
      case 'pet': h.eyes = math.min(1.0, e * 2.5); h.zoom -= .02 * e;
      case 'tilt_head': h.tilt += .22 * e * c.side; h.dip += 1.5 * e;
      case 'clap': h.ar += 1.1 * e + math.sin(s * 22) * .3 * e; h.al += 1.1 * e + math.sin(s * 22) * .3 * e; h.dip += 1 * e;
      case 'lean_back': h.zoom -= .05 * e; h.dip -= 4 * e; h.tilt -= .05 * e;
      case 'thinking_hmm': h.al += 1.6 * e; h.tilt += .1 * e; // pose only: the mouth stays shut until speech audio starts
      case 'soft_sigh': h.yawn = e * .4; h.dip += 2 * e; h.zoom -= .02 * e;
      case 'peek': h.lean += .08 * e * c.side; h.dip += 2 * e; h.zoom += .03 * e;
    }
  }

  void _burst(String ch, int n) {
    if (presence == Presence.hidden) return;
    for (var i = 0; i < n; i++) { parts.add(Part(ch, _rnd(-45, 45), _rnd(-165, -120), _rnd(-18, 18), _rnd(-55, -25), 1.3)); }
  }

  /// Idle library (spec 2D): 20 context-aware micro-behaviours. The gaze-only
  /// subset runs for Discreet and reduced motion; the full set otherwise.
  /// Weighted (glances dominate), never twice in a row, never the same
  /// within 60 s, never during AAC speech or quiet mode (caller gates that).
  static const idleGaze = ['look', 'glance_far', 'look_up', 'slow_blink', 'settle', 'look_behind'];
  static const idleFull = [...idleGaze, 'sway', 'stretch', 'yawn', 'hum', 'sprout_wiggle', 'sprout_boing',
    'foot_shuffle', 'lean_side', 'peek', 'deep_breath', 'tiny_nod', 'hop_tiny', 'giggle_soft', 'gaze_sparkle'];

  void _fidget(bool rm) {
    _nf = clock + _rnd(12, 25);
    final pool = (profile == Profile.discreet || rm) ? idleGaze : idleFull;
    final opts = <String>[];
    for (final n in pool) {
      if (n == _lastFid || clock - (_fidAt[n] ?? -99) < 60) continue;
      final w = n == 'look' || n == 'glance_far' ? 3 : 1;
      for (var i = 0; i < w; i++) { opts.add(n); }
    }
    if (opts.isEmpty) return;
    final n = opts[_r.nextInt(opts.length)];
    _lastFid = n; _fidAt[n] = clock;
    _doFidget(n);
  }

  /// One idle behaviour's action (the Lab fires these directly too).
  void _doFidget(String n) {
    switch (n) {
      case 'look': _wander = Offset(_rnd(-.9, .9), _rnd(-.4, .3)); _nw = clock + 2;
      case 'glance_far': _wander = Offset(_rnd(-1, 1), _rnd(-.6, .4)); _nw = clock + 2.5;
      case 'look_up': _wander = const Offset(0, -.8); _nw = clock + 2;
      case 'look_behind': _wander = Offset(_r.nextBool() ? 1 : -1, 0); _nw = clock + 1.5;
      case 'slow_blink': _nb = clock;
      case 'settle': sq.v -= 1;
      case 'sway': lean.v += _rnd(-2, 2);
      case 'lean_side': lean.v += 3 * (_r.nextBool() ? 1 : -1);
      case 'sprout_wiggle': s1.v += 4; s2.v += 5;
      case 'sprout_boing': s1.v += 7; s2.v += 9; _burst('✦', 2); _sfx('sprout_boing');
      case 'foot_shuffle': hop.v -= 60;
      case 'hop_tiny': hop.v -= 130;
      case 'tiny_nod': clips.add(Clip('nod', _dur['nod']!, 1));
      case 'gaze_sparkle': _wander = Offset(_rnd(-.5, .5), _rnd(-.3, .2)); _nw = clock + 2; _burst('✦', 2);
      case 'deep_breath': clips.add(Clip('soft_sigh', _dur['soft_sigh']!, 1));
      case 'giggle_soft': clips.add(Clip('giggle', _dur['giggle']!, 1));
      case 'stretch': case 'yawn': case 'hum': case 'peek': clips.add(Clip(n, _dur[n]!, 1));
    }
  }

  /// Lab-only: fire one idle behaviour now (same action the idle loop uses).
  void debugFidget(String n) { if (idleFull.contains(n)) _doFidget(n); }

  // ───────────────────────── events in ─────────────────────────
  void emote(String n, {double i = .8, double hold = 4, bool force = false}) {
    if (!faces.containsKey(n) || (quiet && !force)) return;
    emo = n; inten = math.min(i, kProfiles[profile]!.ceil); _hold = hold;
    moodBase = (moodBase + (faces[n]?.valence ?? 0) * .02).clamp(-.3, .3).toDouble();
    if (const ['excited', 'proud', 'playful'].contains(n) && inten > .5 && !_aac && !quiet) _burst('✦', 5);
    if (n == 'encouraging' && inten > .4 && !quiet) _burst('♥', 3);
  }
  void relax() => _hold = 0;

  void gesture(String n, {bool force = false}) {
    if (_aac || quiet || breathing) return; // never animate over AAC speech
    if (!force && clock - (_gAt[n] ?? -99) < 20) return; // same gesture not within 20 s
    _gAt[n] = clock;
    clips.add(Clip(n, _dur[n] ?? 1, (miloCenter?.dx ?? 0) > screenW / 2 ? -1 : 1));
    final s = _sfxFor(n);
    if (s != null) _sfx(s);
  }

  static const _sfxMap = {'wave': 'whoosh', 'celebrate': 'success', 'giggle': 'tap_giggle', 'hum': 'hum',
    'yawn': 'yawn', 'thinking_hmm': 'think_hmm', 'soft_sigh': 'aww', 'peek': 'sparkle', 'pet': 'aww'};
  static String? _sfxFor(String n) => _sfxMap[n];

  void _sfx(String n) {
    sounds.enabled = soundOn;
    sounds.volume = soundVol;
    unawaited(sounds.play(n, quiet: quiet, aac: _aac, presence: presence.name));
  }

  /// The offline-fallback choice offered by the thinking ladder. Handled
  /// locally by [choose]; never sent to the brain as a query.
  static const kOfflineChoice = 'Use offline basics';

  // L6 reactions from the shared widgets (spec 2D): rate-limited, presence-
  // aware (gaze-only in Chip, silent in Hidden), never over AAC speech.
  final _reactAt = <ReactKind, double>{};
  void _onReact(ReactEvent e) {
    markActive();
    if (_aac || quiet || !reactions || presence == Presence.hidden) return;
    const gap = {ReactKind.pressDown: .3, ReactKind.focus: 2.0, ReactKind.typed: 4.0, ReactKind.sent: 1.0, ReactKind.scroll: .6, ReactKind.stepDone: 3.0, ReactKind.navigating: 1.0};
    if (clock - (_reactAt[e.kind] ?? -99) < gap[e.kind]!) return;
    _reactAt[e.kind] = clock;
    final gazeOnly = presence == Presence.chip || profile == Profile.discreet || reduce || forceReduce;
    switch (e.kind) {
      case ReactKind.pressDown:
        if (e.at != null) pointerAt(e.at!); // eyes snap; a tiny lean on press
        if (!gazeOnly) { sq.v -= 1.2; _nb = clock; }
      case ReactKind.focus:
        if (e.at != null) lookAtGlobal(e.at!, secs: 3);
        if (!gazeOnly) lean.v += .4;
      case ReactKind.typed:
        if (e.at != null) lookAtGlobal(e.at!, secs: 2);
        if (!gazeOnly) lean.v += .3;
      case ReactKind.sent:
        if (!gazeOnly) gesture('nod');
      case ReactKind.scroll:
        touch = Offset(0, (e.data * -.0004).clamp(-.8, .8).toDouble()); touchUntil = clock + .6; // eyes follow the fling
      case ReactKind.stepDone:
        emote('proud', i: .6, hold: 2);
        if (!gazeOnly) gesture('nod', force: true);
      case ReactKind.navigating:
        _wander = Offset(e.data.clamp(-1.0, 1.0).toDouble() * .8, 0); _nw = clock + 1.5; // look toward the destination
    }
  }

  /// Speech-to-text phrase endpoint (a pause in the partial transcript):
  /// Milo nods, mirroring a listening person.
  void phraseNod() { if (state == CState.listening && !_aac && !quiet) gesture('nod'); }

  /// One path for every choice tap (chat chips and dock chips): ladder
  /// offers are handled locally, everything else is asked.
  void choose(String c) {
    if (c == kOfflineChoice) { useOfflineFallback(); return; }
    if (c == 'Keep waiting') { choices = []; _cap('…'); notifyListeners(); return; }
    ask(c);
  }

  Future<void> useOfflineFallback() async {
    choices = []; notifyListeners();
    await perform(validateTurn(pocketBrain(_pendingAsk, profile.name)));
  }

  Offset _norm(Offset p) {
    final c = miloCenter ?? Offset(screenW / 2, 300);
    return Offset(((p.dx - c.dx) / 200).clamp(-1.0, 1.0).toDouble(), ((p.dy - c.dy) / 200).clamp(-1.0, 1.0).toDouble());
  }
  void pointerAt(Offset global) { markActive(); touch = _norm(global); touchUntil = clock + 2.5; }
  void lookAtGlobal(Offset global, {double secs = 1.2}) { content = _norm(global); contentUntil = clock + secs; }

  // L6 reactions (local, no AI, <100 ms). Tapping Milo has one predictable,
  // silent action, matching the "Tap to wave hello" label: while Milo speaks
  // it barges in to listen; otherwise a blink and a small bounce — never
  // speech, so accidental taps stay silent and returning users are never
  // re-introduced to. Speech belongs to deliberate flows (chat, voice,
  // read-aloud) and the one-time introduction. The mouth moves only with
  // real TTS audio.
  void tapMilo() {
    markActive();
    if (_speaking && !_aac) { // barge-in
      cancelSpeech(); _turn++;
      emote('listening', i: .9, hold: 8, force: true); _set(CState.listening); _cap('I’m listening. Type or tap what you want.');
      Timer(const Duration(seconds: 8), () { if (state == CState.listening) { relax(); _set(CState.idle); } });
      return;
    }
    if (_aac || !reactions || quiet) return;
    if (ignoreTaps && clock - _lastTap < .6) return; // tremor: taps within half a second count once
    _lastTap = clock;
    if (haptics) HapticFeedback.lightImpact();
    _nb = clock; // blink
    if (profile == Profile.discreet) return; // eyes only
    sq.v -= 2.2; // small bounce; no mouth movement without speech
  }

  /// Silent hello for app launches: a small wave, no speech. Presence is
  /// acknowledged; familiarity is assumed, never announced.
  void helloMotion() {
    markActive();
    if (!reactions || _aac || profile == Profile.discreet) return;
    gesture('wave');
    emote('happy', i: .6, hold: 2);
  }
  void petMilo() {
    markActive();
    if (!reactions || quiet || _aac || profile == Profile.discreet) return;
    HapticFeedback.mediumImpact(); clips.add(Clip('pet', 1.5, 1)); emote('happy', i: 1, hold: 2.5, force: true); _sfx('aww');
  }
  void sproutTap() {
    markActive();
    if (!reactions || quiet || _aac || profile == Profile.discreet) return;
    s1.v += 7; s2.v += 9; _burst('✦', 3); _sfx('sprout_boing');
  }
  void dragTo(Offset n) { markActive(); touch = n; touchUntil = clock + 1.5; _dragLean = n.dx * .05; }
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
  void setTab(int i) { if (i != tab) MiloReact.navigating(i > tab ? 1 : -1); tab = i; presence = presenceOverride ?? _auto(); emote('curious', i: .5, hold: 2); _sfx('page'); notifyListeners(); }
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

  /// Per-speak voice-event subscription. The captured [gen] makes stale
  /// platform callbacks (a previous utterance's late word event arriving
  /// during a newer request) harmless: they are dropped.
  Future<void> _watchVoice(int gen) async {
    await _voiceSub?.cancel();
    _voiceSub = voice.platform.events.listen((e) {
      if (gen != _gen || !_speaking) return;
      if (e.kind == VoiceEventKind.started || e.kind == VoiceEventKind.word) _speechStarted = true;
      if (e.kind != VoiceEventKind.word) return;
      _gotP = true;
      final i = _words.indexWhere((m) => m.end > e.charOffset);
      _pulseWord(i < 0 ? 0 : i);
    });
  }

  void _est(int gen, int i, double rate) { // fallback timing when the TTS engine gives no word callbacks
    if (gen != _gen || _gotP || !_speechStarted || i >= _words.length) return; // never pulse before real audio starts
    _pulseWord(i);
    Future.delayed(Duration(milliseconds: ((120 + _words[i].group(0)!.length * 55) / rate).round()), () => _est(gen, i + 1, rate));
  }

  /// Delivery tone: [pitch, rate] multipliers around the voice preset.
  /// Small on purpose: warmth comes from the voice and the words, not falsetto.
  static const _tones = {'playful': [1.06, 1.1], 'warm': [1.0, 1.0], 'calm': [.95, .88], 'gentle': [.92, .8]};

  /// Neural lip-sync feed: amplitude 0..1 from the audio envelope. Sets the
  /// mouth directly and rides the speech pulse (no viseme flip, no word
  /// callback — neural engines supply no word timings). Ignored for AAC and
  /// whenever no speech is active. A non-silent level counts as proof that
  /// real audio started.
  void feedMouth(double level) {
    if (!_speaking || _aac) return;
    _mouthLevel = level.clamp(0.0, 1.0).toDouble();
    if (_mouthLevel > 0.02) _speechStarted = true;
    pulse = math.max(pulse, _mouthLevel * .9);
  }

  /// Speech lifecycle. Invariants (see docs/VOICE_CHECKLIST.md):
  /// - Empty text never enters the speaking state.
  /// - Any previous speech is stopped first: requests never overlap.
  /// - The mouth moves only after real audio started ([_speechStarted]);
  ///   failure, cancellation or interruption shuts it and returns to the
  ///   state the turn was in ([CState.listening] when listening, else idle).
  /// - A superseded request never touches state owned by a newer one.
  Future<void> speak(String text, {void Function(int)? onWord, bool aac = false, double rate = 1, String? tone}) async {
    markActive();
    // Read-aloud speaks the ORIGINAL text (highlight indices must match it
    // exactly); everything else gets normalised + sentence-split per profile.
    final norm = onWord == null ? normalizeForSpeech(text, lang) : text;
    if (norm.trim().isEmpty) return; // nothing to say: never enter the speaking state
    final parts = onWord == null
        ? splitSentences(norm, const {Profile.playful: 10, Profile.friendly: 14, Profile.discreet: 20}[profile]!)
        : [(text: norm, wordOffset: 0)];
    if (parts.isEmpty) return;
    final gen = ++_gen;
    // Claim the speaking state synchronously (before the first await) so
    // envelope feeds for this generation are accepted the moment speak()
    // is called. The stop + gen check below still serialize overlaps, and
    // the mouth itself only moves on genuine audio signals (started/word
    // events or non-silent envelope feeds), never on the claim alone.
    _words = RegExp(r'\S+').allMatches(norm).toList();
    _onWord = onWord;
    _gotP = false;
    _speechStarted = false;
    _speaking = true;
    _aac = aac;
    if (aac) clips.clear(); // AAC speech stays neutral: clarity first, no performance
    final fallback = (state == CState.listening || state == CState.endpointing) ? CState.listening : CState.idle;
    _set(CState.speaking);
    var stopped = true;
    try {
      await voice.stopNow(); // no overlapping speech: the previous utterance ends before this one starts
    } catch (_) {
      stopped = false;
    }
    if (gen != _gen) return; // superseded while stopping: the newer request owns everything
    if (!stopped) { _cleanupSpeech(fallback); return; } // stop failed: fail closed, never stuck speaking
    await _watchVoice(gen); // stale platform callbacks for [gen] only; older utterances are dropped
    if (gen != _gen) return;
    _antic = aac || quiet ? 0 : .15;
    final t0 = DateTime.now(), est = _words.length * 330;
    Future.delayed(const Duration(milliseconds: 450), () => _est(gen, 0, rate));
    final tp = (!aac && tone != null) ? (_tones[tone] ?? [1.0, 1.0]) : [1.0, 1.0];
    String? notice;
    var heard = true;
    if (voiceOn) {
      final pace = (voiceSpeed * rate * (tp[1] as num) * _paceRate * (clearSpeech ? .9 : 1)).toDouble();
      try {
        notice = await voice.speakAll(parts,
            pitch: (_presetPitch * (tp[0] as num)).clamp(.5, 1.6).toDouble(),
            rate: _presetRate * pace, pace: pace,
            lang: lang, tone: aac ? null : tone, readAloud: onWord != null, aac: aac,
            onMouth: (v) { if (gen == _gen) feedMouth(v); }, // stale envelope feeds are dropped
            onSentence: (s) async { if (s.trim().endsWith('!') && !aac && gen == _gen) gesture('nod'); });
      } on VoiceCancelled {
        return; // barge-in / turn change: the newer request owns state and cleanup
      } on VoicePlayFailed {
        heard = false; // nothing was heard: shut the mouth, return to the turn state, speak no notice over silence
      } catch (_) {
        heard = false;
      }
    }
    if (gen != _gen) return; // superseded: the newer request owns state
    if (!heard) { _cleanupSpeech(fallback); return; }
    final el = DateTime.now().difference(t0).inMilliseconds;
    if (el < est * .5) await Future.delayed(Duration(milliseconds: (est * .7 - el).round())); // visual-only: keep caption up
    if (gen != _gen) return;
    if (notice != null && voiceOn) {
      try {
        await voice.platform.speakSentence(
            notice == 'online_voice_unavailable' ? 'My online voice is not set up yet, so I’ll use my phone voice.' : 'My online voice cut out, so I’ll use my phone voice.',
            pitch: _presetPitch, rate: _presetRate * voiceSpeed);
      } catch (_) {} // the notice is best-effort: the turn already succeeded
      if (gen != _gen) return;
    }
    _gen++;
    _speaking = false;
    _aac = false;
    _onWord = null;
    _mouthLevel = 0;
    _speechStarted = false;
    _nb = clock;
    sq.v -= 1.5;
    if (state == CState.speaking) _set(CState.idle); // settle after speaking
  }

  /// Shared failure cleanup: mouth shut, speech flags cleared, state back to
  /// the turn's resting state. The generation is bumped so late timers and
  /// callbacks from the failed request are dropped.
  void _cleanupSpeech(CState fallback) {
    _gen++;
    _speaking = false;
    _aac = false;
    _onWord = null;
    _mouthLevel = 0;
    pulse = 0;
    _speechStarted = false;
    _nb = clock;
    if (state == CState.speaking) _set(fallback);
  }

  Future<void> speakAac(String text) { _turn++; choices = []; return speak(text, aac: true); }

  /// Stops all speech output now. Safe to call when idle, disposed, or
  /// mid-turn; also returns a stuck speaking state to idle (callers that own
  /// the next state — barge-in, ask, breathing — set it right after).
  void cancelSpeech() {
    _gen++;
    _speaking = false;
    _aac = false;
    _mouthLevel = 0;
    pulse = 0;
    _speechStarted = false;
    _onWord = null;
    if (state == CState.speaking) _set(CState.idle);
    unawaited(voice.stopNow());
  }

  /// Language-screen speaker preview: a short greeting in that language's
  /// voice, then the saved voice is restored. Only en/hi/ml have a reviewed
  /// translation; other languages preview the voice with the English sample.
  static const _previews = {'en': 'Hello! I’m Milo.', 'hi': 'नमस्ते! मैं मीलो हूँ।', 'ml': 'ഹലോ! ഞാൻ മിലോ ആണ്.'};
  Future<void> previewLang(String code) async {
    await voice.platform.applyVoice(lang: code, voice: '', locale: '', pitch: _presetPitch, rate: _presetRate);
    await speak(_previews[code] ?? _previews['en']!, tone: 'warm');
    await applyVoice();
  }

  // ───────────────────────── brain loop ─────────────────────────
  Future<void> ask(String text) async {
    markActive();
    final id = ++_turn;
    cancelSpeech(); choices = []; supportActive = false; _pendingAsk = text;
    _set(CState.thinking); emote('thinking', i: .8, hold: 60, force: true); gesture('think', force: true); _cap('…');
    unawaited(_ladder(id)); // honest escalation while the answer is slow; any turn change cancels it
    if (router != null) { // body already reacted; the router decides local vs cloud
      try { await router!(text); } catch (_) { if (id == _turn || _turn > id) await perform(validateTurn(pocketBrain(text, profile.name))); }
      return;
    }
    await Future.delayed(const Duration(milliseconds: 650));
    if (id != _turn) return;
    await perform(validateTurn(pocketBrain(text, profile.name)));
  }

  /// Thinking ladder (plan 4.4): 0-1.5 s the thinking face stands; 1.5-5 s a
  /// soft "hmm"; past 5 s the honest keep-waiting-or-offline offer, once.
  Future<void> _ladder(int id) async {
    await Future.delayed(const Duration(milliseconds: 1500));
    if (id != _turn || state != CState.thinking) return;
    gesture('thinking_hmm', force: true);
    await Future.delayed(const Duration(milliseconds: 3500));
    if (id != _turn || state != CState.thinking) return;
    _cap('Still thinking — keep waiting, or use offline basics?');
    choices = ['Keep waiting', kOfflineChoice]; notifyListeners();
    speak('This is taking a while. You can keep waiting, or ask me something I know offline.', tone: 'calm');
  }

  /// Streaming performance: body event first (Milo reacts), then sentences are spoken as they arrive.
  Future<void> performStream(Stream<BrainEvent> events) async {
    final id = ++_turn;
    final q = <String>[];
    var busy = false, wait = false;
    Future<void> pump() async {
      if (busy) return;
      busy = true;
      while (q.isNotEmpty && id == _turn) { final s = q.removeAt(0); _cap(s); onSaid?.call(s); await speak(s, tone: _sayTone); }
      busy = false;
    }
    await for (final e in events) {
      if (id != _turn) return;
      final d = e.data;
      switch (e.type) {
        case 'risk': if (d['level'] != 'none') { await performSupport(); return; }
        case 'body':
          final em = d['emotion'];
          if (em is Map) { emote('${em['name']}', i: (em['intensity'] as num?)?.toDouble() ?? .6, hold: 6, force: true); _sayTone = toneForEmotion('${em['name']}'); }
          if (d['gesture'] is String) gesture(d['gesture'] as String, force: true);
          final g = d['gaze'];
          if (g is Map && '${g['id']}'.isNotEmpty) onGaze?.call('${g['id']}');
          _paceRate = d['pace'] == 'slow' ? .8 : 1;
        case 'say': q.add('${d['text']}'); unawaited(pump());
        case 'ui':
          if (d['action'] == 'offer_choices') { choices = [for (final c in d['choices'] as List) '$c']; notifyListeners(); gesture('nod'); }
          if (d['action'] == 'open_screen') onOpenScreen?.call('${d['screen']}');
          if (d['action'] == 'highlight') onHighlight?.call('${d['span']}');
          if (d['action'] == 'show_image') unawaited(onShowImage?.call('${d['concept']}') ?? Future.value());
          if (d['action'] == 'set_timer' && d['seconds'] is int) { breakSecs = (d['seconds'] as int).clamp(5, 3600).toInt(); notifyListeners(); }
          if (d['action'] == 'read_aloud') onReadAloud?.call('${d['span']}');
          if (d['action'] == 'break_into_steps' && d['steps'] is List) onSteps?.call([for (final s in d['steps'] as List) '$s']);
          if (d['action'] == 'lookup_word') onLookupWord?.call('${d['word']}');
        case 'memory': onMemoryProposal?.call(d);
        case 'key_point' || 'simple' || 'vocab' || 'check': onUnderstand?.call(e.type, d);
        case 'ui_spec': onUiSpec?.call(d);
        case 'error': throw StreamError('${d['code']}');
        case 'done': wait = d['followup'] == 'wait';
      }
    }
    while ((busy || q.isNotEmpty) && id == _turn) { await Future.delayed(const Duration(milliseconds: 80)); }
    if (id != _turn) return;
    _paceRate = 1; _sayTone = null; relax();
    _set(wait || choices.isNotEmpty ? CState.waiting : CState.idle);
    if (wait || choices.isNotEmpty) _armNudge();
  }

  void setListening(bool on) {
    markActive();
    if (on) { cancelSpeech(); _turn++; _partialAt = -1; _listenSince = clock; emote('listening', i: .9, hold: 60, force: true); _set(CState.listening); _sfx('mic_on'); } else { relax(); _partialAt = -1; _listenSince = -1; _set(CState.idle); _sfx('mic_off'); }
  }

  /// Hand-written support flow (doc 6.5): calm, one caring sentence, ask about a trusted grown-up, big buttons. Never generated.
  Future<void> performSupport() async { cancelSpeech(); await perform(Safety.supportTurn(lang)); }

  void loadSettings(Map<String, String> s) {
    profile = Profile.values.firstWhere((p) => p.name == s['profile'], orElse: () => Profile.friendly);
    presenceOverride = Presence.values.where((p) => p.name == s['presence']).firstOrNull;
    voiceStyle = s['voice'] ?? 'Friendly';
    final c = int.tryParse(s['color'] ?? ''); if (c != null) color = Color(c);
    quiet = s['quiet'] == '1'; reactions = s['reactions'] != '0'; voiceOn = s['voiceOn'] != '0'; forceReduce = s['reduce'] == '1';
    paceSecs = int.tryParse(s['pace'] ?? '') ?? 3; preReader = s['prereader'] == '1'; lang = s['lang'] ?? 'en';
    highContrast = s['hc'] == '1'; haptics = s['haptics'] != '0'; captions = s['captions'] != '0'; textScale = double.tryParse(s['tscale'] ?? '') ?? 1.0;
    lineSpacing = double.tryParse(s['lspace'] ?? '') ?? 1.5; font = s['font'] ?? 'Lexend'; breakNudgeMin = int.tryParse(s['breaknudge'] ?? '') ?? 0; greetings = s['greetings'] != '0'; voiceSpeed = double.tryParse(s['vspeed'] ?? '') ?? 1.0; offlineForced = s['offline.forced'] == '1'; ignoreTaps = s['ignoretaps'] == '1'; leftHanded = s['lefthand'] == '1'; ttsVoice = s['tts.voice'] ?? ''; ttsLocale = s['tts.locale'] ?? ''; met = s['met'] == '1';
    presence = presenceOverride ?? _auto();
    look = MiloLook.values.where((l) => l.name == s['look']).firstOrNull ?? MiloLook.a;
    moodBase = (double.tryParse(s['mood'] ?? '') ?? 0).clamp(-.3, .3).toDouble();
    soundOn = s['sound'] != '0'; soundVol = double.tryParse(s['svol'] ?? '') ?? .8;
    voiceEngine = VoiceEngineMode.values.where((m) => m.name == s['vengine']).firstOrNull ?? VoiceEngineMode.auto;
    voice.mode = voiceEngine;
    clearSpeech = s['clear'] == '1';
    scanMode = s['scan'] == '1'; scanMs = (int.tryParse(s['scanms'] ?? '') ?? 1200).clamp(400, 3000).toInt();
    final installDay = int.tryParse(s['install.day'] ?? '');
    daysTogether = installDay == null ? 0 : (DateTime.now().difference(DateTime(2026, 1, 1)).inDays - installDay).clamp(0, 9999).toInt();
    peeked.clear(); peeked.addAll((s['local.peeked'] ?? '').split(',').where((k) => k.isNotEmpty));
    applyVoice();
    notifyListeners();
  }
  Map<String, String> toSettings() => {'profile': profile.name, 'presence': presenceOverride?.name ?? 'auto', 'voice': voiceStyle, 'color': '${color.toARGB32()}',
    'quiet': quiet ? '1' : '0', 'reactions': reactions ? '1' : '0', 'voiceOn': voiceOn ? '1' : '0', 'reduce': forceReduce ? '1' : '0', 'pace': '$paceSecs', 'prereader': preReader ? '1' : '0', 'lang': lang, 'hc': highContrast ? '1' : '0', 'haptics': haptics ? '1' : '0', 'captions': captions ? '1' : '0', 'tscale': '$textScale', 'lspace': '$lineSpacing', 'font': font, 'breaknudge': '$breakNudgeMin', 'greetings': greetings ? '1' : '0', 'vspeed': '$voiceSpeed', 'offline.forced': offlineForced ? '1' : '0', 'ignoretaps': ignoreTaps ? '1' : '0', 'lefthand': leftHanded ? '1' : '0', 'tts.voice': ttsVoice, 'tts.locale': ttsLocale, 'local.peeked': peeked.join(','),
    'look': look.name, 'mood': '$moodBase', 'install.day': '${DateTime.now().difference(DateTime(2026, 1, 1)).inDays - daysTogether}', 'sound': soundOn ? '1' : '0', 'svol': '$soundVol',
    'vengine': voiceEngine.name, 'clear': clearSpeech ? '1' : '0', 'scan': scanMode ? '1' : '0', 'scanms': '$scanMs', 'met': met ? '1' : '0'};

  /// Body first (emotion + gesture), then words, sentence by sentence.
  Future<void> perform(BrainTurn t) async {
    final id = ++_turn;
    if (t.risk != 'none') supportActive = true;
    emote(t.emotion, i: t.intensity, hold: 6, force: t.risk != 'none');
    if (t.gesture != null) gesture(t.gesture!, force: true);
    choices = t.choices; notifyListeners();
    if (t.openScreen != null) onOpenScreen?.call(t.openScreen!);
    if (t.highlight != null) onHighlight?.call(t.highlight!);
    if (t.showImage != null) unawaited(onShowImage?.call(t.showImage!) ?? Future.value());
    if (t.timerSeconds != null) { breakSecs = t.timerSeconds!; notifyListeners(); }
    if (t.readAloud != null) onReadAloud?.call(t.readAloud!);
    if (t.steps.isNotEmpty) onSteps?.call(t.steps);
    if (t.lookupWord != null) onLookupWord?.call(t.lookupWord!);
    if (t.choices.isNotEmpty) gesture('nod'); // acknowledgement: Milo nods as it offers choices
    final tone = toneForEmotion(t.emotion);
    for (final s in t.say) {
      if (id != _turn) return;
      _cap(s); onSaid?.call(s);
      await speak(s, tone: tone);
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

  /// The spoken introduction, played once per lifetime (persisted [met]).
  /// First onboarding completion and the settings replay action are the only
  /// callers; taps and launches use the silent [helloMotion] instead. Marked
  /// met only after the line is delivered, so an interrupted intro replays.
  /// First-launch migration for users who onboarded before the met flag
  /// existed: they are returning users — familiar, silently.
  void adoptReturning(Map<String, String> s) {
    if (s['onboarded'] == '1' && s['met'] != '1') set(() => met = true);
  }

  Future<void> greet() async {
    if (quiet || !greetings) return;
    if (met) return;
    final c = kProfiles[profile]!;
    _set(CState.greeting);
    if (c.gesture != 'none') gesture(c.gesture, force: true);
    emote('happy', i: .9);
    final line = greetingFor(profile, lang, DateTime.now(), daysTogether, screenKind);
    _cap(line);
    await speak(line, tone: 'warm');
    _set(CState.idle);
    set(() => met = true);
  }

  /// Celebration scaled to the person's presentation profile (doc 5.4).
  void celebrate({bool goal = false}) {
    if (quiet) return;
    HapticFeedback.lightImpact();
    if (goal) _sfx('success');
    switch (profile) {
      case Profile.playful: emote('excited', i: 1, hold: 3, force: true); gesture(goal ? 'celebrate' : 'nod', force: true); if (goal) _burst('✦', 8);
      case Profile.friendly: emote('proud', i: .8, hold: 3, force: true); gesture(goal ? 'celebrate' : 'nod', force: true);
      case Profile.discreet: emote('proud', i: .4, hold: 2, force: true);
    }
    if (goal) { _set(CState.celebrating); Timer(const Duration(milliseconds: 2400), () { if (state == CState.celebrating) _set(CState.idle); }); }
  }
}
