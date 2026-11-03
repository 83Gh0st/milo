import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/ai_provider.dart';
import '../core/providers.dart';
import '../net/api.dart';
import 'privacy_screens.dart';
import 'screen.dart';
import 'theme.dart';

/// Wireframe 10.2: settings and counts only. Never conversation text.
class TrustedScreen extends ConsumerWidget {
  const TrustedScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    return MiloScreen(title: 'Trusted adult', body: ListView(padding: const EdgeInsets.all(16), children: [
      const Center(child: Icon(Icons.lock, color: T.pri, size: 34)), const Center(child: Padding(padding: EdgeInsets.all(8), child: Text('Grown-up area', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)))),
      RowCard(icon: Icons.grid_view, title: 'Words and symbols', subtitle: 'Add, edit, order', onTap: () => go(const WordsEditor())),
      RowCard(icon: Icons.menu_book_outlined, title: 'Reading support', subtitle: 'Text size, font, spacing, contrast', color: 1, onTap: () => openScreen('accessibility')),
      RowCard(icon: Icons.cloud_outlined, title: 'Cloud and privacy', subtitle: 'Cloud on or off, memory', color: 2, onTap: () => go(const LedgerScreen())),
      RowCard(icon: Icons.key_outlined, title: 'AI connections', subtitle: 'Choose which AI Milo uses', color: 3, onTap: () => go(const ProviderKeyScreen())),
      RowCard(icon: Icons.bedtime_outlined, title: 'Gentle time limits', subtitle: d.breakNudgeMin == 0 ? 'Off' : 'Break nudge every ${d.breakNudgeMin} min', color: 3, onTap: () => go(const TimeLimits())),
      RowCard(icon: Icons.insights, title: 'Weekly summary', subtitle: 'Progress only, no chats', onTap: () => go(const WeeklySummary())),
      RowCard(icon: Icons.phone_outlined, title: 'Trusted contacts', subtitle: 'Used by the Help me sheet', color: 1, onTap: () => go(const Contacts())),
      const SizedBox(height: 12), BigButton('Lock', () => Navigator.pop(context), kind: BK.outline),
    ]));
  }
}

class WordsEditor extends ConsumerStatefulWidget { const WordsEditor({super.key}); @override ConsumerState<WordsEditor> createState() => _WEState(); }
class _WEState extends ConsumerState<WordsEditor> {
  final emoji = TextEditingController(text: '⭐'), label = TextEditingController();
  Uint8List? art;
  bool artBusy = false;
  String artErr = '';
  @override
  void dispose() { emoji.dispose(); label.dispose(); super.dispose(); }

  Future<List<Map<String, Object?>>> _all() async {
    final db = ref.read(dbProvider);
    final tiles = await db.tiles();
    for (final t in tiles) { t['art'] = await db.tileArt(t['id'] as String); }
    return tiles;
  }

  Future<void> _draw() async {
    if (label.text.trim().isEmpty) { setState(() => artErr = 'Type the word first.'); return; }
    if (artBusy) return;
    setState(() { artBusy = true; artErr = ''; });
    try {
      final pic = await ref.read(apiProvider).generateImage('A simple flat friendly AAC symbol for: ${label.text.trim()}');
      if (pic.lengthInBytes > 2000000) throw ApiError('too_large');
      if (mounted) setState(() => art = pic);
    } catch (e) {
      if (mounted) setState(() => artErr = e is ApiError && e.code == 'offline' ? 'Drawing needs the internet. The word still saves.' : 'Milo could not draw that. The word still saves.');
    } finally { if (mounted) setState(() => artBusy = false); }
  }

  Widget _thumb(Object? bytes, String em) => bytes is Uint8List
      ? ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(bytes, width: 44, height: 44, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Text(em, style: const TextStyle(fontSize: 26))))
      : Text(em, style: const TextStyle(fontSize: 26));

  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider);
    return MiloScreen(title: 'Edit board', body: FutureBuilder(future: _all(), builder: (_, s) {
      final tiles = s.data ?? [];
      return ListView(padding: const EdgeInsets.all(16), children: [
        const Section('Add a tile'),
        Row(children: [SizedBox(width: 70, child: TextField(controller: emoji, style: const TextStyle(fontSize: 28))), const SizedBox(width: 8), Expanded(child: TextField(key: const Key('tileLabel'), controller: label, decoration: const InputDecoration(hintText: 'Word, e.g. Grandma'))),
          IconButton.filled(onPressed: () async { if (label.text.trim().isEmpty) return; await db.addTile(emoji.text.trim().isEmpty ? '⭐' : emoji.text.trim(), label.text.trim(), art: art); label.clear(); art = null; setState(() {}); }, icon: const Icon(Icons.add))]),
        const SizedBox(height: 8),
        Row(children: [
          if (art != null) ...[_thumb(art, '⭐'), const SizedBox(width: 8),
            IconButton(tooltip: 'Remove picture', icon: const Icon(Icons.close), onPressed: () => setState(() => art = null))],
          Expanded(child: artBusy
              ? const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator())
              : BigButton(art == null ? 'Draw a picture (AI)' : 'Draw again', _draw, kind: BK.soft)),
        ]),
        if (artErr.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(artErr, style: const TextStyle(color: T.coral))),
        if (art != null) const Padding(padding: EdgeInsets.only(top: 4), child: Text('AI-drawn. Look at it before saving - you decide.', style: TextStyle(fontSize: 12, color: T.mute))),
        const Section('Your tiles'),
        for (final t in tiles) Card(child: ListTile(leading: _thumb(t['art'], '${t['emoji']}'), title: Text('${t['label']}'), trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async { await db.deleteTile(t['id'] as String); setState(() {}); }))),
        const SizedBox(height: 10),
        Row(children: [Expanded(child: BigButton('Export', () => Clipboard.setData(ClipboardData(text: jsonEncode([for (final t in tiles) {'emoji': t['emoji'], 'label': t['label']}]))), kind: BK.soft)), const SizedBox(width: 10),
          Expanded(child: BigButton('Paste board', () async { final d = await Clipboard.getData('text/plain'); try { for (final t in jsonDecode(d?.text ?? '[]') as List) { await db.addTile('${t['emoji']}', '${t['label']}'); } setState(() {}); } catch (_) {} }, kind: BK.outline))]),
        const Padding(padding: EdgeInsets.all(12), child: Text('Tile positions never change unless you change them. Pictures stay on this phone and are never synced or exported.', style: TextStyle(fontSize: 12, color: T.mute))),
      ]);
    }));
  }
}

class TimeLimits extends ConsumerWidget {
  const TimeLimits({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    return MiloScreen(title: 'Gentle time limits', body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Milo can offer a break after a long session. It is only a suggestion and never locks anything.', style: TextStyle(fontSize: 16)), const SizedBox(height: 12),
      RadioGroup<int>(groupValue: d.breakNudgeMin, onChanged: (v) => d.set(() => d.breakNudgeMin = v ?? 0), child: Column(children: [
        for (final m in [0, 10, 20, 30]) Card(child: RadioListTile<int>(value: m, title: Text(m == 0 ? 'Off' : 'Every $m minutes'))),
      ])),
    ]));
  }
}

class WeeklySummary extends ConsumerWidget {
  const WeeklySummary({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.read(dbProvider);
    return MiloScreen(title: 'Weekly summary', body: FutureBuilder(future: Future.wait([db.counts(), db.counts(days: 3650), db.flag('progress.enabled', def: true), db.flag('checkin.counts')]), builder: (_, s) {
      if (!s.hasData) return const SizedBox();
      final w = s.data![0] as Map<String, int>, all = s.data![1] as Map<String, int>, on = s.data![2] as bool, checkins = s.data![3] as bool;
      Widget row(String e, String l, int n) => Card(child: ListTile(leading: Text(e, style: const TextStyle(fontSize: 26)), title: Text(l), trailing: Text('$n', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))));
      List<Widget> rows(Map<String, int> c) => [row('📖', 'Things read', c['read'] ?? 0), row('✅', 'Steps done', c['step'] ?? 0), row('🏁', 'Plans finished', c['task'] ?? 0), row('💬', 'Messages spoken', c['spoken'] ?? 0), row('🙋', 'Times asked for help', c['help'] ?? 0),
        if (checkins) row('💚', 'Mood check-ins', c['checkin'] ?? 0)];
      return ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Counts only. Never messages, never transcripts.', style: TextStyle(color: T.mute)),
        _SwitchRow('Show progress to the child', on, (v) async { await db.putFlag('progress.enabled', v); (context as Element).markNeedsBuild(); }),
        _SwitchRow('Count mood check-ins', checkins, (v) async { await db.putFlag('checkin.counts', v); (context as Element).markNeedsBuild(); }),
        const Section('This week'),
        if (w.values.every((n) => n == 0)) const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('A quiet week. Milo never keeps score - these counts only show what was used.', style: TextStyle(fontSize: 15)))),
        ...rows(w),
        const Section('All time so far'),
        ...rows(all)]);
    }));
  }
}

class _SwitchRow extends StatelessWidget { const _SwitchRow(this.t, this.v, this.f); final String t; final bool v; final void Function(bool) f; @override Widget build(BuildContext c) => Card(child: SwitchListTile(title: Text(t), value: v, onChanged: f)); }

/// Phase 3 AI connections (trusted adults only): the family picks which AI
/// Milo thinks with - Meta, OpenAI, Anthropic, or a custom/local endpoint.
/// Keys are sent once over TLS, stored encrypted on the Milo server, and never
/// kept on this phone. Needs sync on: the sync vault is the family identity.
/// Honest limit: a ChatGPT/Claude/Meta *app* login is not API access; the
/// family needs its own API key, billed to its own account.
const kConnProviders = [('meta', 'Meta (recommended)'), ('openai', 'OpenAI'), ('anthropic', 'Anthropic'), ('custom', 'Custom or local')];
const kRouteCaps = [('brain', 'Thinking + chat'), ('understand', 'Reading help'), ('plan', 'Step-by-step plans'), ('story', 'Stories'), ('visual', 'Pictures'), ('stt', 'Voice in'), ('segment', 'Object outlines')];
const kCheckNames = {
  'chat': 'Chat',
  'json_schema': 'Structured replies',
  'vision': 'Pictures',
  'audio_in': 'Voice in',
  'tts': 'Voice out',
  'image_entitled': 'Makes pictures',
  'voice_entitled': 'Hears voice',
  'sam_entitled': 'Outlines objects',
  'wonder_entitled': 'Long stories',
};
const kRoleLabels = {'chat': 'Thinking', 'image': 'Pictures', 'voice': 'Voice', 'segment': 'Outlines', 'longform': 'Long-form'};
/// What Milo itself can do through each BYOK provider (adapter-level, not
/// vendor marketing: only Meta's adapter implements pictures and voice).
const kProviderCapsNote = {
  'meta': 'Thinking, pictures, voice and object outlines from one key.',
  'openai': 'Thinking and reading. Milo can’t make pictures or hear voice with OpenAI yet.',
  'anthropic': 'Thinking and reading. Milo can’t make pictures or hear voice with Anthropic yet.',
  'custom': 'Thinking and reading through your address.',
};

String connWords(Object e) {
  if (e is! ApiError) return 'Something went wrong.';
  const m = {'offline': 'No connection to the Milo server.', 'timeout': 'That took too long.', 'rate_limited': 'Too many tries - wait a minute.',
    'policy_ack_required': 'Please confirm the data note first.', 'key_too_short': 'That key looks too short.', 'key_required': 'A key is needed for this provider.',
    'bad_base_url': 'That address is not allowed.', 'base_url_required': 'Custom needs an address.', 'model_not_allowed': 'That model is not allowed.',
    'model_required': 'Pick a model first.', 'no_connection': 'Connect this provider first.', 'no_connections': 'Connect a provider first.',
    'auth_failed': 'That key was refused. Check it and try again.', 'unreachable': 'That address did not answer.', 'model_not_found': 'That model was not found there.',
    'quota': 'That account is out of credit.', 'content_filtered': 'The provider refused that test.',
    'vault_unavailable': 'This server keeps no vault: sync and family AI are unavailable here. Milo hosted still works.',
    'http_503': 'The server is resting or unavailable. Try again in a bit.',
    'no_family_key': 'No usable family key. Re-enter the key for this provider.',
    'family_key_unreadable': 'The saved key cannot be read. Remove it and enter it again.',
    'bad_vault_credentials': 'Sync sign-in failed. Turn sync off and on again in Data and privacy.',
    'unsupported_capability': 'This provider cannot do that job. Pick another route or provider.'};
  return m[e.code] ?? m[e.detail?['error']] ?? 'Could not reach the server.';
}

/// Latest successful probe date (YYYY-MM-DD) across the saved models, or
/// null when this provider was saved but never tested. A saved key alone
/// is never shown as working.
String? testedOn(Object? caps) {
  String? best;
  for (final e in (caps is Map ? caps.values : const [])) {
    final t = e is Map ? e['tested_at'] : null;
    if (t is String && t.length >= 10 && (best == null || t.compareTo(best) > 0)) best = t;
  }
  return best == null ? null : best.substring(0, 10);
}

class ProviderKeyScreen extends ConsumerStatefulWidget { const ProviderKeyScreen({super.key}); @override ConsumerState<ProviderKeyScreen> createState() => _PKState(); }
class _PKState extends ConsumerState<ProviderKeyScreen> {
  bool? syncOn, useFamily;
  Map<String, dynamic>? conns;
  Map<String, String?> primary = {}, fallback = {};
  Map<String, List<ConnModel>> metaRoles = {}; // Meta suite models by role, for capability-correct route options
  bool busy = false;
  String? error;

  @override
  void initState() { super.initState(); _load(); }

  List<Map<String, dynamic>> get _list => [for (final c in (conns?['connections'] as List?) ?? []) Map<String, dynamic>.from(c as Map)];
  Map<String, dynamic>? _conn(String p) { for (final c in _list) { if (c['provider'] == p) return c; } return null; }

  Future<void> _load() async {
    final sync = ref.read(syncProvider), db = ref.read(dbProvider), api = ref.read(apiProvider);
    final on = await sync.enabled;
    if (!mounted) return;
    setState(() => syncOn = on);
    if (!on) return;
    final vh = await sync.vaultHeaders();
    if (vh == null || !mounted) return;
    try {
      final st = await api.listConnections(vh['X-Vault-Id']!, vh['X-Vault-Key']!);
      var flag = await aiChoice(db) == AiChoice.family ? 'family' : '';
      if (((st['connections'] as List?) ?? []).isEmpty && flag.isNotEmpty) {
        await setAiChoice(db, AiChoice.miloHosted); // last key gone: family mode would fail every turn; hosted still works
        flag = '';
      }
      if (!mounted) return;
      final routes = Map<String, dynamic>.from(st['routes'] as Map? ?? {});
      for (final (cap, _) in kRouteCaps) {
        final es = [for (final e in (routes[cap] as List?) ?? []) Map<String, dynamic>.from(e as Map)];
        primary[cap] = es.isEmpty ? null : '${es[0]['provider']}/${es[0]['model']}';
        fallback[cap] = es.length < 2 ? null : '${es[1]['provider']}/${es[1]['model']}';
      }
      Map<String, List<ConnModel>> roles = {};
      final listed = [for (final c in (st['connections'] as List?) ?? []) Map<String, dynamic>.from(c as Map)];
      if (listed.any((c) => c['provider'] == 'meta')) {
        try {
          final mm = await api.connectionModels(vh['X-Vault-Id']!, vh['X-Vault-Key']!, 'meta');
          for (final m in mm.models) {
            final k = m.role ?? '';
            roles[k] = [...roles[k] ?? const [], m];
          }
        } catch (_) {} // offline or unlisted: dropdowns fall back to provider defaults
      }
      if (!mounted) return;
      setState(() { conns = st; metaRoles = roles; useFamily = flag.isNotEmpty; error = null; });
    } catch (e) { if (mounted) setState(() => error = connWords(e)); }
  }

  Future<void> _open(String provider) async {
    final vh = (await ref.read(syncProvider).vaultHeaders())!;
    if (!mounted) return;
    await showModalBottomSheet(context: context, isScrollControlled: true, builder: (c) =>
        Padding(padding: MediaQuery.of(c).viewInsets, child: _ConnSheet(provider: provider, existing: _conn(provider),
            api: ref.read(apiProvider), vid: vh['X-Vault-Id']!, vkey: vh['X-Vault-Key']!)));
    _load();
  }

  Future<void> _saveRoutes() async {
    for (final (cap, label) in kRouteCaps) {
      if ((primary[cap]?.endsWith('/') ?? false) || (fallback[cap]?.endsWith('/') ?? false)) {
        setState(() => error = 'Pick a model for $label first: open the provider, then Find models.');
        return;
      }
    }
    setState(() { busy = true; error = null; });
    try {
      final vh = (await ref.read(syncProvider).vaultHeaders())!;
      Map<String, String> e(String v) { final i = v.indexOf('/'); return {'provider': v.substring(0, i), 'model': v.substring(i + 1)}; }
      final routes = {for (final (cap, _) in kRouteCaps) if (primary[cap] != null) cap: [e(primary[cap]!), if (fallback[cap] != null) e(fallback[cap]!)]};
      await ref.read(apiProvider).putRoutes(vh['X-Vault-Id']!, vh['X-Vault-Key']!, routes);
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved. Milo now uses your choices.')));
    } catch (e) { if (mounted) setState(() => error = connWords(e)); }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider);
    String label(String p, String m) => '$p/${m.isEmpty ? '(model not set)' : m}';
    // One Meta key, right model per job: each row offers the provider
    // defaults plus the Meta suite members whose role fits the capability
    // (long-form Wonder only on Plans and Stories, never ordinary chat).
    const capRoles = {'brain': ['chat'], 'understand': ['chat'], 'plan': ['chat', 'longform'], 'story': ['chat', 'longform'], 'visual': ['image'], 'stt': ['voice'], 'segment': ['segment']};
    List<({String value, String label})> optsFor(String cap) {
      final out = [(value: 'mock/mock', label: 'mock/mock (Offline demo)'),
        for (final c in _list) (value: '${c['provider']}/${c['default_model']}', label: label('${c['provider']}', '${c['default_model']}'))];
      for (final r in capRoles[cap] ?? const <String>[]) {
        for (final m in metaRoles[r] ?? const <ConnModel>[]) {
          final v = 'meta/${m.id}';
          if (out.any((o) => o.value == v)) continue;
          out.add((value: v, label: 'meta/${m.id} (${m.name})'));
        }
      }
      return out;
    }
    String? valid(String cap, String? v) => v != null && optsFor(cap).any((o) => o.value == v) ? v : null;
    return MiloScreen(title: 'AI connections', body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Milo can think with your own AI account instead of the shared one. Use is billed to your account by your provider. A key is sent once over an encrypted connection, stored encrypted on the Milo server, and never kept on this phone. A ChatGPT or Claude app login is not enough - you need an API key from your provider.', style: TextStyle(fontSize: 15)),
      const SizedBox(height: 12),
      if (syncOn == false) ...[const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Turn on sync first, in Data and privacy. The sync vault identifies your family.', style: TextStyle(fontSize: 16)))),
        BigButton('Back', () => Navigator.pop(context), kind: BK.soft)]
      else if (syncOn == null || useFamily == null || conns == null) ...[const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))]
      else ...[
        const Section('Who does Milo think with?'),
        Card(child: SwitchListTile(title: const Text('Our family AI', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(useFamily! ? 'On: Milo bills your accounts' : 'Off: Milo hosted does the thinking (recommended, no sync needed)'),
            value: useFamily!, onChanged: _list.isEmpty && useFamily == false ? null : (v) async { await setAiChoice(db, v ? AiChoice.family : AiChoice.miloHosted); setState(() => useFamily = v); })),
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(
            useFamily! ? 'Milo is thinking with: ${primary['brain'] ?? 'your saved providers (pick routes below)'}.' : 'Milo is thinking with: Milo hosted.',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)))),
        const _HostedStatus(),
        const Section('My API keys (BYOK)'),
        for (final (id, name) in kConnProviders)
          Card(child: ListTile(leading: Icon(_conn(id) == null ? Icons.key_off : Icons.key, color: T.pri),
              title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(_conn(id) == null ? 'Not connected' : 'Key ${_conn(id)!['hint']} · ${_conn(id)!['default_model']}\n${(() { final t = testedOn(_conn(id)!['caps']); return t == null ? 'Saved - not tested yet' : 'Tested $t'; })()}'),
              trailing: const Icon(Icons.chevron_right), onTap: () => _open(id))),
        const Section('Use for'),
        for (final (cap, capLabel) in kRouteCaps) Card(child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(capLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
          DropdownButtonFormField<String>(isExpanded: true, decoration: const InputDecoration(labelText: 'First choice'), initialValue: valid(cap, primary[cap]),
              items: [for (final o in optsFor(cap)) DropdownMenuItem(value: o.value, child: Text(o.label, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => primary[cap] = v)),
          DropdownButtonFormField<String>(isExpanded: true, decoration: const InputDecoration(labelText: 'If that fails'), initialValue: valid(cap, fallback[cap]),
              items: [for (final o in optsFor(cap)) DropdownMenuItem(value: o.value, child: Text(o.label, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => fallback[cap] = v)),
        ]))),
        const SizedBox(height: 6),
        BigButton(busy ? 'Working…' : 'Save choices', busy ? null : _saveRoutes),
        if (error != null) Padding(padding: const EdgeInsets.all(12), child: Text(error!, style: const TextStyle(color: T.coral))),
      ],
    ]));
  }
}

/// Read-only status of the Milo-hosted path: which gateway provider build is
/// answering and whether its budget is spent. Display only - it never claims
/// AI works; a real turn or Test connection proves that.
class _HostedStatus extends ConsumerWidget {
  const _HostedStatus();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final check = ref.watch(connectionCheckProvider);
    Widget line(String s) => Text(s, style: const TextStyle(fontSize: 13, color: T.mute));
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Hosted by Milo - Muse Spark', style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text('One hosted connection routes every job automatically - no key or model picking. Needs internet; the board still works offline.', style: TextStyle(fontSize: 13, color: T.mute)),
      const SizedBox(height: 6),
      ...check.when(
        data: (s) => [
          line(s.provider == null ? 'Unreachable right now.' : s.provider == 'modal' ? 'Answering via Milo hosted (Muse Spark).${s.budgetOk == true ? '' : ' Daily budget used - resting.'}' : 'Answering via ${s.provider}.${s.budgetOk == true ? '' : ' Daily budget used - resting.'}'),
          line('${s.demoEnabled == null ? '' : s.demoEnabled! ? 'Demo access on (key stays on the server). ' : 'Demo access off. '}${s.capabilities.isEmpty ? '' : capabilitySummary(s.capabilities)}'),
        ],
        loading: () => [line('Checking…')],
        error: (_, __) => [line('Unreachable right now.')],
      ),
    ])));
  }
}

class _ConnSheet extends StatefulWidget {
  const _ConnSheet({required this.provider, required this.existing, required this.api, required this.vid, required this.vkey});
  final String provider, vid, vkey;
  final Map<String, dynamic>? existing;
  final MiloApi api;
  @override
  State<_ConnSheet> createState() => _ConnSheetState();
}

class _ConnSheetState extends State<_ConnSheet> {
  final key = TextEditingController(), base = TextEditingController(), model = TextEditingController();
  bool ack = false, busy = false;
  String? error;
  Map<String, dynamic>? probe, _asked;
  final _knownNames = <String, String>{}; // friendly names learned from Find models (ids stay the source of truth)

  @override
  void initState() {
    super.initState();
    base.text = widget.existing?['base_url'] ?? '';
    model.text = widget.existing?['default_model'] ?? '';
  }

  @override
  void dispose() {
    key.dispose();
    base.dispose();
    model.dispose();
    super.dispose();
  }

  Map<String, dynamic> get policy => Map<String, dynamic>.from(widget.existing?['policy'] as Map? ?? _asked ?? {});
  bool get needsAck => policy['needs_ack'] == true;

  Future<void> _save() async {
    final k = key.text.trim();
    if (k.isNotEmpty && k.length < 8) { setState(() => error = 'That key looks too short.'); return; }
    if (widget.existing == null && k.isEmpty && widget.provider != 'custom') { setState(() => error = 'Paste a key first.'); return; }
    setState(() { busy = true; error = null; });
    try {
      await widget.api.saveConnection(widget.vid, widget.vkey, widget.provider, apiKey: k,
          baseUrl: base.text.trim(), model: model.text.trim(), ack: ack);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      // First save of an unknown-policy provider: the server sends the policy
      // with the refusal, so the checkbox can appear right here.
      if (e is ApiError && e.detail?['error'] == 'policy_ack_required') _asked = Map<String, dynamic>.from(e.detail!['policy'] as Map? ?? {});
      if (mounted) setState(() => error = connWords(e));
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _models() async {
    final pick = await showDialog<ConnModel>(
        context: context,
        builder: (_) => _ModelDialog(api: widget.api, vid: widget.vid, vkey: widget.vkey, provider: widget.provider, currentId: model.text.trim(), caps: widget.existing?['caps']));
    if (pick != null && mounted) setState(() { model.text = pick.id; _knownNames[pick.id] = pick.name; });
  }

  Future<void> _test() async {
    setState(() { busy = true; error = null; probe = null; });
    try {
      final r = await widget.api.testConnection(widget.vid, widget.vkey, widget.provider, model: model.text.trim());
      if (mounted) setState(() => probe = r);
    } catch (e) { if (mounted) setState(() => error = connWords(e)); }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _remove() async {
    setState(() { busy = true; error = null; });
    try {
      await widget.api.deleteConnection(widget.vid, widget.vkey, widget.provider);
      if (mounted) Navigator.pop(context);
    } catch (e) { if (mounted) setState(() => error = connWords(e)); }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final label = dictLabel(widget.provider);
    return SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      Padding(padding: const EdgeInsets.only(top: 2), child: Text('Through Milo: ${kProviderCapsNote[widget.provider] ?? 'Thinking and reading.'}', style: const TextStyle(fontSize: 12, color: T.mute))),
      if (widget.existing != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Saved · key ${widget.existing!['hint']}${(() { final t = testedOn(widget.existing!['caps']); return t == null ? ' · not tested yet' : ' · tested $t'; })()}', style: const TextStyle(color: T.mute))),
      if (widget.existing == null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(widget.provider == 'meta' ? 'Paste the one Meta key, Save it, then Test connection. It covers chat, pictures, voice and outlines automatically.' : 'Paste the key, Save it, then Test connection.', style: const TextStyle(fontSize: 13, color: T.mute))),
      const SizedBox(height: 12),
      TextField(controller: key, obscureText: true, keyboardType: TextInputType.visiblePassword, enableSuggestions: false, autocorrect: false, decoration: InputDecoration(hintText: widget.existing == null ? 'Paste the API key here' : 'Paste a new key to replace it (leave empty to keep)')),
      if (widget.provider == 'custom' || widget.provider == 'openai') ...[const SizedBox(height: 10),
        TextField(controller: base, decoration: InputDecoration(hintText: widget.provider == 'custom' ? 'Address, e.g. http://100.64.0.5:11434/v1' : 'Address (leave empty for OpenAI)'))],
      const SizedBox(height: 10),
      Card(child: ListTile(
          leading: const Icon(Icons.smart_toy_outlined, color: T.pri),
          title: Text(model.text.trim().isEmpty ? 'No model chosen' : (_knownNames[model.text.trim()] ?? prettyModelId(model.text.trim())), style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: model.text.trim().isEmpty ? null : Text(model.text.trim(), style: const TextStyle(fontSize: 11, color: T.mute)),
          trailing: FilledButton.tonal(onPressed: busy || widget.existing == null ? null : _models, child: const Text('Choose')))),
      ExpansionTile(title: const Text('Advanced: type a model ID', style: TextStyle(fontSize: 14)), children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: TextField(controller: model, onChanged: (_) => setState(() {}), decoration: const InputDecoration(hintText: 'Model, e.g. gpt-4o-mini'))),
      ]),
      if (needsAck || policy.isNotEmpty) ...[const SizedBox(height: 10), Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('How this provider handles data', style: TextStyle(fontWeight: FontWeight.w700)),
        Text(policy['note'] ?? 'The provider decides; Milo sends only what the ledger shows.', style: const TextStyle(fontSize: 13)),
        if (needsAck) CheckboxListTile(title: const Text('I understand my data may train their models', style: TextStyle(fontSize: 14)), value: ack, onChanged: (v) => setState(() => ack = v ?? false), controlAffinity: ListTileControlAffinity.leading),
      ])))],
      const SizedBox(height: 10),
      Row(children: [Expanded(child: FilledButton.tonal(onPressed: busy || widget.existing == null ? null : _test, child: const Text('Test connection'))),
        const SizedBox(width: 8), Expanded(child: FilledButton(onPressed: busy ? null : _save, child: Text(busy ? 'Working…' : 'Save')))]),
      if (probe != null) ...[const SizedBox(height: 8), Card(child: Column(children: [
        for (final e in (probe!['checks'] as Map).entries)
          ListTile(dense: true, leading: Icon('${e.value}'.startsWith('pass') ? Icons.check_circle : '${e.value}'.startsWith('fail') ? Icons.cancel : Icons.remove_circle,
              color: '${e.value}'.startsWith('pass') ? T.mint : '${e.value}'.startsWith('fail') ? T.coral : T.mute),
              title: Text('${kCheckNames[e.key] ?? e.key}'),
              subtitle: '${e.value}'.contains(':') ? Text('${e.value}'.split(':').last) : null),
      ]))],
      if (widget.existing != null) ...[const SizedBox(height: 8), BigButton('Remove this connection', busy ? null : _remove, kind: BK.outline)],
      if (error != null) Padding(padding: const EdgeInsets.all(12), child: Text(error!, style: const TextStyle(color: T.coral))),
    ]));
  }
}

String dictLabel(String id) => switch (id) { 'meta' => 'Meta', 'openai' => 'OpenAI', 'anthropic' => 'Anthropic', 'custom' => 'Custom or local', _ => id };

/// Model picker: friendly names first, technical ids second. Shows the
/// recommended pick, the current selection, verified test results (from the
/// saved probe caps - never assumed), and a refresh action. Failures and
/// empty lists keep manual entry under Advanced; nothing is substituted.
class _ModelDialog extends StatefulWidget {
  const _ModelDialog({required this.api, required this.vid, required this.vkey, required this.provider, required this.currentId, this.caps});
  final MiloApi api;
  final String vid, vkey, provider, currentId;
  final Object? caps;
  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  bool loading = true;
  String? error, source;
  List<ConnModel> models = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final r = await widget.api.connectionModels(widget.vid, widget.vkey, widget.provider);
      if (mounted) setState(() { models = r.models; source = r.source; });
    } catch (e) {
      if (mounted) setState(() => error = connWords(e));
    }
    if (mounted) setState(() => loading = false);
  }

  Map<String, dynamic>? _entry(String id) {
    final c = widget.caps;
    return (c is Map && c[id] is Map) ? Map<String, dynamic>.from(c[id] as Map) : null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [const Expanded(child: Text('Pick a model')), IconButton(tooltip: 'Refresh', onPressed: loading ? null : _load, icon: const Icon(Icons.refresh))]),
      content: SizedBox(
          width: double.maxFinite,
          height: 380,
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
                  ? Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(error!),
                      const SizedBox(height: 8),
                      FilledButton.tonal(onPressed: _load, child: const Text('Try again')),
                      const SizedBox(height: 4),
                      const Text('Or type the model ID under Advanced.', style: TextStyle(fontSize: 12, color: T.mute)),
                    ])
                  : models.isEmpty
                      ? const Text('No models listed. Type the model ID under Advanced, or try Refresh.')
                      : ListView(children: [
                          Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(source == 'live' ? 'Live list from ${dictLabel(widget.provider)}.' : 'Milo’s configured ${dictLabel(widget.provider)} models.',
                                  style: const TextStyle(fontSize: 12, color: T.mute))),
                          for (final m in models)
                            Builder(builder: (_) {
                              final e = _entry(m.id);
                              final tested = e == null ? null : testedOn({m.id: e});
                              final passed = [for (final c in ((e?['checks'] as Map?) ?? {}).entries) if ('${c.value}'.startsWith('pass')) '${c.key}'];
                              final meta = [
                                if (m.recommended) 'Recommended',
                                if (m.id == widget.currentId) 'Current',
                                if (m.role != null) kRoleLabels[m.role] ?? m.role!,
                                if (tested != null) 'Tested $tested' else 'Not tested yet',
                              ].join(' · ');
                              return ListTile(
                                leading: m.recommended ? const Icon(Icons.star_outline, color: T.pri) : null,
                                title: Text(m.name),
                                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(m.id, style: const TextStyle(fontSize: 11, color: T.mute)),
                                  Text(meta, style: const TextStyle(fontSize: 11, color: T.mute)),
                                  if (passed.isNotEmpty)
                                    Wrap(spacing: 4, children: [for (final p in passed) Chip(visualDensity: VisualDensity.compact, label: Text(kCheckNames[p] ?? p, style: const TextStyle(fontSize: 10)))]),
                                ]),
                                trailing: m.id == widget.currentId ? const Icon(Icons.check, color: T.mint) : null,
                                onTap: () => Navigator.pop(context, m),
                              );
                            }),
                        ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

class Contacts extends ConsumerStatefulWidget { const Contacts({super.key}); @override ConsumerState<Contacts> createState() => _ContactsState(); }
class _ContactsState extends ConsumerState<Contacts> {
  final trusted = TextEditingController(), doctor = TextEditingController(), dname = TextEditingController();
  @override
  void initState() { super.initState(); final db = ref.read(dbProvider); db.get('local.trusted_phone').then((v) => trusted.text = v ?? ''); db.get('local.doctor_phone').then((v) => doctor.text = v ?? ''); db.get('local.doctor_name').then((v) => dname.text = v ?? ''); }
  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider);
    return MiloScreen(title: 'Trusted contacts', body: ListView(padding: const EdgeInsets.all(16), children: [
      const Section('Trusted person'), TextField(controller: trusted, keyboardType: TextInputType.phone, onChanged: (v) => db.put('local.trusted_phone', v), decoration: const InputDecoration(hintText: 'Phone number')),
      const Section('Doctor (for the “Call the doctor” plan)'), TextField(controller: dname, onChanged: (v) => db.put('local.doctor_name', v), decoration: const InputDecoration(hintText: 'Name, e.g. Dr. Sharma')),
      const SizedBox(height: 8), TextField(controller: doctor, keyboardType: TextInputType.phone, onChanged: (v) => db.put('local.doctor_phone', v), decoration: const InputDecoration(hintText: 'Phone number')),
      const Padding(padding: EdgeInsets.all(12), child: Text('Numbers stay on this phone and are never sent. Milo only opens your phone app after a tap.', style: TextStyle(fontSize: 12, color: T.mute))),
    ]));
  }
}
