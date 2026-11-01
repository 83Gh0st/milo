import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/director.dart';
import '../contracts/brain_contract.dart';
import '../contracts/events.dart';
import '../data/db.dart';
import '../data/secure_store.dart';
import '../genui/panel.dart';
import '../net/api.dart';
import '../net/voice.dart';
import '../sync/sync_service.dart';
import 'ai_provider.dart';
import 'memory.dart';
import 'payload.dart';
import 'pocket_brain.dart';
import 'safety.dart';
import '../ui/screen.dart' show openScreen;

final storeProvider = Provider<SecureStore>((_) => throw UnimplementedError('override in main'));
final dbProvider = Provider<MiloDb>((_) => throw UnimplementedError('override in main'));
final Provider<MiloApi> apiProvider = Provider((ref) {
  final api = MiloApi(ref.read(dbProvider), ref.read(storeProvider));
  api.vaultAuth = () async {
    // Family-keyed inference only when the trusted adult chose family AI AND sync (the family identity) is on.
    if (await aiChoice(ref.read(dbProvider)) != AiChoice.family) return {};
    return await ref.read(syncProvider).vaultHeaders() ?? {};
  };
  return api;
});
final voiceProvider = Provider((ref) => VoiceClient(ref.read(apiProvider)));
final memoryProvider = ChangeNotifierProvider((ref) => MemoryManager(ref.read(dbProvider)));
final tabProvider = StateProvider<int>((_) => 0);

/// Tab index scope for MiloView gaze registration (null outside tabs).
/// Shell overrides this per tab so only the visible tab's Milo aims gaze.
final miloScopeProvider = Provider<int?>((_) => null);

/// Chat thread lives in memory only: conversations are not saved unless the person asks Milo to remember.
class ChatMsg { final bool milo; final String text; final List<String> steps; final String? imageB64; const ChatMsg(this.milo, this.text, {this.steps = const [], this.imageB64}); }
class ChatNotifier extends StateNotifier<List<ChatMsg>> {
  ChatNotifier() : super(const []);
  void user(String t) => state = [...state, ChatMsg(false, t)];
  void userPhoto(String imageB64) => state = [...state, ChatMsg(false, '', imageB64: imageB64)];
  void said(String t) { if (state.isNotEmpty && state.last.milo && state.last.steps.isEmpty) { state = [...state.sublist(0, state.length - 1), ChatMsg(true, '${state.last.text}\n$t')]; } else { state = [...state, ChatMsg(true, t)]; } }
  void addSteps(List<String> steps) => state = [...state, ChatMsg(true, '', steps: steps)];
  void clear() => state = const [];
}
/// A word the brain asked to look up: UnderstandScreen picks it up once, then clears it.
final lookupWordProvider = StateProvider<String>((_) => '');
/// Text shared from another app (plan 7.13): UnderstandScreen picks it up once, then clears it.
final sharedTextProvider = StateProvider<String>((_) => '');
final chatProvider = StateNotifierProvider<ChatNotifier, List<ChatMsg>>((_) => ChatNotifier());
final expressTextProvider = StateProvider<String>((_) => '');
final syncProvider = Provider((ref) => SyncService(ref.read(dbProvider), ref.read(apiProvider), ref.read(storeProvider)));

// ---- context chips: exactly what is sent ----
class ChipsNotifier extends StateNotifier<List<ChipItem>> {
  ChipsNotifier() : super(const []);
  void put(ChipItem c) => state = [for (final x in state) if (x.kind != c.kind) x, c];
  void remove(ChipItem c) => state = [for (final x in state) if (x != c) x];
  void clearKind(String k) => state = [for (final x in state) if (x.kind != k) x];
}
final chipsProvider = StateNotifierProvider<ChipsNotifier, List<ChipItem>>((_) => ChipsNotifier());

// ---- offline ladder (doc 4.5) ----
enum Ladder { full, cloudOff, offline, resting }
class LadderNotifier extends StateNotifier<Ladder> {
  Timer? _t;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  LadderNotifier(this.db, this.api) : super(Ladder.full) {
    refresh();
    if (Director.messengerOk) { try { _sub = Connectivity().onConnectivityChanged.listen((_) => refresh()); } catch (_) {} }
    _t = Timer.periodic(const Duration(seconds: 90), (_) { if (state != Ladder.full) refresh(); });
  }
  @override
  void dispose() { _t?.cancel(); _sub?.cancel(); super.dispose(); }
  final MiloDb db;
  final MiloApi api;
  int _gen = 0; // a refresh that started before a failed()/ok() must not clobber it
  Future<void> refresh() async {
    final g = _gen;
    Ladder next;
    if (await db.flag('offline.forced')) { next = Ladder.offline; } else if (!await db.flag('cloud.enabled')) { next = Ladder.cloudOff; } else {
      final r = await Connectivity().checkConnectivity();
      if (r.contains(ConnectivityResult.none)) { next = Ladder.offline; } else { next = await api.healthy() ? Ladder.full : Ladder.resting; }
    }
    if (g == _gen) state = next;
  }
  void failed(String code) { _gen++; state = (code == 'budget_exhausted' || code == 'rate_limited' || code == 'timeout') ? Ladder.resting : Ladder.offline; }
  void ok() { _gen++; state = Ladder.full; }
}
final ladderProvider = StateNotifierProvider<LadderNotifier, Ladder>((ref) => LadderNotifier(ref.read(dbProvider), ref.read(apiProvider)));

/// Phase 0 connection check for the About row. Refresh to re-run.
final connectionCheckProvider = FutureProvider<ConnStatus>((ref) => ref.read(apiProvider).connectionCheck());

// ---- Explainer pictures (concept -> PNG bytes), fetched on demand, memory-only ----
class VisualNotifier extends StateNotifier<Map<String, Uint8List>> {
  VisualNotifier() : super(const {});
  void put(String concept, Uint8List png) => state = {...state, concept: png};
  void clear() => state = const {};
}
final visualProvider = StateNotifierProvider<VisualNotifier, Map<String, Uint8List>>((_) => VisualNotifier());

// ---- Sync status: null when fine, a short generic message otherwise (never content) ----
final syncBannerProvider = StateProvider<String?>((_) => null);

/// Maps a sync failure to safe UI text. Sync paused by offline mode or a
/// disabled cloud needs no banner: the ladder banner already says that.
String? syncBannerFor(Object e) => e is CloudDisabled ? null : 'Couldn’t sync just now.';

// ---- Understand result ----
class UState {
  final bool loading;
  final List<String> keyPoints;
  final String simple;
  final List<Map<String, String>> vocab;
  final Map<String, dynamic>? check;
  const UState({this.loading = false, this.keyPoints = const [], this.simple = '', this.vocab = const [], this.check});
  Map<String, dynamic> toJson() => {'kp': keyPoints, 'simple': simple, 'vocab': vocab, 'check': check};
  static UState fromJson(Map<String, dynamic> j) => UState(keyPoints: [for (final x in j['kp'] as List) '$x'], simple: '${j['simple']}',
      vocab: [for (final v in j['vocab'] as List) {'word': '${v['word']}', 'meaning': '${v['meaning']}'}], check: j['check'] as Map<String, dynamic>?);
  UState copy({bool? loading, List<String>? keyPoints, String? simple, List<Map<String, String>>? vocab, Map<String, dynamic>? check}) =>
      UState(loading: loading ?? this.loading, keyPoints: keyPoints ?? this.keyPoints, simple: simple ?? this.simple, vocab: vocab ?? this.vocab, check: check ?? this.check);
}
class UnderstandNotifier extends StateNotifier<UState> {
  UnderstandNotifier() : super(const UState());
  void start() => state = const UState(loading: true);
  void done() => state = state.copy(loading: false);
  void load(String json) => state = UState.fromJson(jsonDecode(json) as Map<String, dynamic>);
  void add(String type, Map<String, dynamic> d) {
    switch (type) {
      case 'key_point': state = state.copy(keyPoints: [...state.keyPoints, '${d['text']}']);
      case 'simple': state = state.copy(simple: '${d['text']}');
      case 'vocab': state = state.copy(vocab: [...state.vocab, {'word': '${d['word']}', 'meaning': '${d['meaning']}'}]);
      case 'check': state = state.copy(check: d);
    }
  }
}
final understandProvider = StateNotifierProvider<UnderstandNotifier, UState>((_) => UnderstandNotifier());

// ---- Core router: safety -> memory commands -> local intents -> cloud -> pocket brain (doc 6.1) ----
class CoreRouter {
  CoreRouter(this.ref);
  final Ref ref;
  final _recent = <Map<String, String>>[];
  static final _local = RegExp(r"\b(read to me|help me say|do steps|take a break|breathe|talk to someone|thank|someone is here|not right now)\b|^(hi|hello|hey)\b");
  static String? strategyOf(String t) => const {'easier words': 'simpler', 'show a picture': 'picture', 'give an example': 'example', 'make it shorter': 'short', 'simplify': 'simpler', 'examples': 'example', 'explain': 'default'}[t.toLowerCase().trim()];

  Future<Map<String, dynamic>> _body(String text, String activity, Director d, {bool dropDocument = false}) async {
    final db = ref.read(dbProvider);
    final chips = [for (final c in ref.read(chipsProvider)) if (!(dropDocument && c.kind == 'document')) c];
    return buildBrainBody(text: text, activity: activity, presentation: d.profile.name, lang: d.lang, support: await db.support(), chips: chips,
        memories: await ref.read(memoryProvider).forRequest(activity), name: await db.flag('cloud.name') ? await db.get('name') : null, recent: _recent,
        uiContext: ref.read(panelProvider).snapshot());
  }

  Future<void> handle(String text, Director d) async {
    final db = ref.read(dbProvider), mem = ref.read(memoryProvider);
    if (Safety.isCrisis(text)) { await d.performSupport(); return; } // local, before anything else
    final cmd = parseMemory(text);
    if (cmd != null) { await _memory(cmd, d); return; }
    final doc = ref.read(chipsProvider).where((c) => c.kind == 'document').toList();
    final strat = strategyOf(text);
    if (strat != null && doc.isNotEmpty) { await explain(d, doc.first.text, strategy: strat); return; }
    if (_local.hasMatch(text.toLowerCase().replaceAll('’', "'"))) { await d.perform(validateTurn(pocketBrain(text, d.profile.name))); return; }
    d.onMemoryProposal = mem.propose;
    try {
      final activity = const ['home', 'understand', 'express', 'do'].elementAtOrNull(d.tab) ?? 'chat';
      await d.performStream(ref.read(apiProvider).brainTurn(await _body(text, activity == 'home' ? 'chat' : activity, d)));
      ref.read(ladderProvider.notifier).ok();
      _recent..add({'role': 'user', 'text': text})..add({'role': 'milo', 'text': d.caption});
      if (_recent.length > 6) _recent.removeRange(0, _recent.length - 6);
      await db.progress('message');
    } on CloudDisabled { await d.perform(validateTurn(pocketBrain(text, d.profile.name, cloud: 'off'))); }
    on ApiError catch (e) { await _cloudFailed(e.code, text, d); }
    on StreamError catch (e) { await _cloudFailed(e.code, text, d); }
    catch (_) { ref.read(ladderProvider.notifier).failed('offline'); await d.perform(validateTurn(pocketBrain(text, d.profile.name, cloud: 'offline'))); }
  }

  /// One mapping for REST and stream failures: the ladder and the pocket
  /// fallback always agree about what happened.
  Future<void> _cloudFailed(String code, String text, Director d) async {
    ref.read(ladderProvider.notifier).failed(code);
    final cloud = code == 'budget_exhausted' || code == 'rate_limited' ? 'resting' : code == 'timeout' ? 'timeout' : code == 'auth_failed' || code == 'http_401' || code == 'quota' || code == 'model_not_found' ? 'key' : 'offline';
    await d.perform(validateTurn(pocketBrain(text, d.profile.name, cloud: cloud)));
  }

  Future<void> _memory(MemCmd c, Director d) async {
    final mem = ref.read(memoryProvider);
    switch (c.kind) {
      case 'remember': mem.proposeLocal(c.arg!);
      case 'forget_last': mem.askForgetLast(); if (mem.pending == null) { await d.perform(const BrainTurn(emotion: 'calm', say: ['I have nothing new to forget.'])); }
      case 'forget_all': mem.askForgetAll();
      case 'pause': await mem.setPaused(true); await d.perform(const BrainTurn(emotion: 'calm', say: ['Okay. I’m not remembering new things.']));
      case 'resume': await mem.setPaused(false); await d.perform(const BrainTurn(emotion: 'happy', say: ['Okay. I can remember again.']));
      case 'list': openScreen('memory'); await d.perform(const BrainTurn(emotion: 'curious', say: ['Here is everything I remember.']));
    }
  }

  /// Understand: the saved explanation first (instant, free, works offline),
  /// then Spark for anything new. [imageB64] is a resized, EXIF-free JPEG;
  /// the person's text chip stays local for photos. The reading screen owns
  /// [Director.onHighlight]; this method must not clobber it.
  Future<void> explain(Director d, String text, {String strategy = 'default', String? imageB64}) async {
    final db = ref.read(dbProvider), api = ref.read(apiProvider), ust = ref.read(understandProvider.notifier);
    final hash = c.sha256.convert(utf8.encode(imageB64 ?? text)).toString();
    ust.start();
    d.onUnderstand = ust.add;
    d.onMemoryProposal = ref.read(memoryProvider).propose;
    final hit = await db.cacheGet(hash, strategy, d.lang);
    if (hit != null) {
      ust.load(hit);
      await db.progress('read');
      await d.perform(const BrainTurn(emotion: 'happy', say: ['I remember this one.']));
      return;
    }
    try {
      final body = {...await _body('Please help me understand this.', 'understand', d, dropDocument: true),
        'content_text': imageB64 == null ? (text.length > 6000 ? text.substring(0, 6000) : text) : null, 'image_b64': imageB64, 'strategy': strategy}..removeWhere((k, v) => v == null);
      await d.performStream(api.understand(body));
      ust.done();
      await db.cachePut(hash, strategy, d.lang, jsonEncode(ref.read(understandProvider).toJson()));
      ref.read(ladderProvider.notifier).ok();
      await db.progress('read');
    } catch (e) {
      // Same-strategy cache already missed above; fall back to the default-strategy copy if one exists.
      final cached = await db.cacheGet(hash, 'default', d.lang);
      if (e is ApiError) ref.read(ladderProvider.notifier).failed(e.code);
      if (e is StreamError) ref.read(ladderProvider.notifier).failed(e.code);
      if (cached != null) { ust.load(cached); await d.perform(const BrainTurn(emotion: 'calm', say: ['Here is the explanation I saved earlier.'])); }
      else {
        ust.done();
        if (e is CloudDisabled) { await d.perform(validateTurn(pocketBrain('', d.profile.name, cloud: 'off'))); }
        // A blind model is not a broken network: say what is actually wrong.
        else if (imageB64 != null && ((e is StreamError && e.code == 'unsupported_capability') || (e is ApiError && e.code == 'unsupported_capability'))) { await d.perform(const BrainTurn(emotion: 'calm', say: ['This model cannot look at pictures. A trusted adult can pick one that can, in AI connections.'])); }
        else { openScreen('unreachable'); }
      }
    }
  }
}
final routerProvider = Provider((ref) => CoreRouter(ref));

final directorProvider = ChangeNotifierProvider<Director>((ref) {
  final db = ref.read(dbProvider);
  final d = Director();
  d.router = (t) => ref.read(routerProvider).handle(t, d);
  d.persist = () { final m = d.toSettings(); for (final e in m.entries) { db.put(e.key, e.value); } };
  d.onMemoryProposal = ref.read(memoryProvider).propose;
  d.onSaid = (t) => ref.read(chatProvider.notifier).said(t);
  d.onSteps = (s) => ref.read(chatProvider.notifier).addSteps(s);
  d.onUiSpec = (s) => ref.read(panelProvider.notifier).applySpec(s);
  d.onLookupWord = (w) { ref.read(lookupWordProvider.notifier).state = w; openScreen('understand'); };
  d.onShowImage = (c) async {
    if (ref.read(visualProvider).containsKey(c)) return;
    try {
      ref.read(visualProvider.notifier).put(c, await ref.read(apiProvider).visual(c));
    } catch (_) {} // a missing picture never breaks the turn; the reader keeps its placeholder
  };
  ref.listen<Ladder>(ladderProvider, (p, n) { // network status reaches the body: subtle, never alarming
    if (p == n) return;
    if (n == Ladder.full) d.emote('happy', i: .5, hold: 2);
    if (n == Ladder.offline || n == Ladder.cloudOff) d.emote('calm', i: .6, hold: 4);
    if (n == Ladder.resting) d.emote('sleepy', i: .4, hold: 4);
  });
  d.voice.neural.api = ref.read(apiProvider);
  d.voice.neural.cacheGet = db.get;
  d.voice.neural.cachePut = db.put;
  d.voice.onlineAllowed = () => ref.read(ladderProvider) == Ladder.full;
  db.allSettings().then((s) => d.loadSettings(s));
  d.init();
  ref.onDispose(d.dispose);
  return d;
});
