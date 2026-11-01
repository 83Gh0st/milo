import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart' show genImageKey, genImageProvider, visualProvider;
import '../ui/theme.dart';
import 'panel.dart';

/// What a panel interaction may do. The app wires these to the same paths
/// the chat thread uses (ask = a user turn, speak = TTS, openScreen =
/// validated navigation, showImage = the explainer picture fetch). The panel
/// never invents its own side effects.
class PanelCallbacks {
  const PanelCallbacks({required this.ask, required this.speak, required this.openScreen, required this.showImage, required this.generateImage});
  final void Function(String text) ask;
  final void Function(String text) speak;
  final void Function(String screen) openScreen;
  final Future<void> Function(String concept) showImage;
  final Future<void> Function(String prompt) generateImage;
}

/// The live activity panel: renders the validated tree, or nothing when no
/// panel is active. Static widgets only (no ambient animation); every control
/// is a real button/checkbox/radio with semantics.
class PanelView extends ConsumerWidget {
  const PanelView({super.key, required this.panel, required this.cb, this.companionHeader});
  final PanelState panel;
  final PanelCallbacks cb;
  final Widget? companionHeader;

  Map<String, dynamic>? _find(String id) {
    Map<String, dynamic>? walk(Map<String, dynamic> n) {
      if (n['id'] == id) return n;
      if (n['children'] is List) {
        for (final c in n['children'] as List) {
          final hit = walk(c as Map<String, dynamic>);
          if (hit != null) return hit;
        }
      }
      return null;
    }

    final root = panel.root;
    return root == null ? null : walk(root);
  }

  /// What "speak this" voices for a node: its own text, or the most useful
  /// nearby text (current step, selected choice, first undone item).
  String _speakText(PanelNotifier not, Map<String, dynamic> n) {
    switch (n['type']) {
      case 'text':
        return '${n['text']}';
      case 'card':
        return '${n['title'] ?? ''}';
      case 'button':
        return '${n['label']}';
      case 'progress':
        return '${n['label'] ?? ''}';
      case 'image':
        return '${n['concept']}';
      case 'choices':
        final sel = not.answerOf(n['id'] as String);
        final opts = (n['options'] as List).cast<Map<String, dynamic>>();
        final hit = opts.where((o) => o['id'] == sel).firstOrNull;
        return '${(hit ?? opts.first)['label']}';
      case 'checklist':
        final items = (n['items'] as List).cast<Map<String, dynamic>>();
        final open = items.where((i) => !not.isDone(i['id'] as String)).firstOrNull;
        return '${(open ?? items.first)['text']}';
      case 'steps':
        final steps = (n['steps'] as List).cast<Map<String, dynamic>>();
        final cur = steps.where((s) => s['id'] == n['current']).firstOrNull;
        final s = cur ?? steps.first;
        return '${s['text']}${s['detail'] != null ? '. ${s['detail']}' : ''}';
      case 'list':
        return (n['items'] as List).cast<Map<String, dynamic>>().map((i) => i['text']).join('. ');
      default:
        return '';
    }
  }

  void _runAction(WidgetRef ref, Map<String, dynamic> a, [Map<String, dynamic>? self]) {
    final not = ref.read(panelProvider.notifier);
    switch (a['action']) {
      case 'check':
        not.toggle(a['target'] as String);
      case 'answer':
        if (a['option'] != null) {
          not.answer(a['target'] as String, a['option'] as String);
        } else {
          not.recordAction('answer:${a['target']}');
        }
      case 'next':
        not.recordAction('next');
        cb.ask('Continue.');
      case 'ask':
        not.recordAction('ask');
        cb.ask(a['prompt'] as String);
      case 'speak':
        not.recordAction('speak');
        final t = a['target'] != null ? _find(a['target'] as String) : self;
        final text = t == null ? '' : _speakText(not, t);
        if (text.isNotEmpty) cb.speak(text);
      case 'open_screen':
        cb.openScreen(a['screen'] as String);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = panel.root;
    if (root == null) return const SizedBox.shrink();
    final not = ref.read(panelProvider.notifier);
    final speakNode = panel.speak != null ? _find(panel.speak!) : null;
    return Container(margin: const EdgeInsets.symmetric(vertical: 6), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: T.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (panel.mode == 'celebration')
            const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 0), child: Row(children: [Icon(Icons.celebration_outlined, color: T.amber), SizedBox(width: 8), Text('Well done!', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))])),
          if (companionHeader != null) companionHeader!,
          Align(alignment: Alignment.centerRight, child: IconButton(tooltip: 'Close activity', icon: const Icon(Icons.close, size: 20, color: T.mute), onPressed: () => not.clear())),
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: _NodeView(node: root, panel: panel, view: this, ref: ref)),
          if (speakNode != null && _speakText(not, speakNode).isNotEmpty)
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: FilledButton.tonalIcon(onPressed: () { not.recordAction('speak'); cb.speak(_speakText(not, speakNode)); }, icon: const Icon(Icons.volume_up_outlined), label: const Text('Listen'))),
          const SizedBox(height: 8),
        ]));
  }
}

class _NodeView extends StatelessWidget {
  const _NodeView({required this.node, required this.panel, required this.view, required this.ref});
  final Map<String, dynamic> node;
  final PanelState panel;
  final PanelView view;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final not = ref.read(panelProvider.notifier);
    final t = node['type'] as String;
    final main = switch (t) {
      'text' => Text('${node['text']}', style: const TextStyle(fontSize: 16, height: 1.4)),
      'divider' => const Divider(height: 24),
      'progress' => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (node['label'] != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('${node['label']}', style: const TextStyle(fontWeight: FontWeight.w700))),
          ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(value: (node['value'] as num).toDouble(), minHeight: 10, backgroundColor: T.line, color: T.pri)),
        ]),
      'button' => FilledButton.tonal(onPressed: () => view._runAction(ref, (node['action'] as Map).cast<String, dynamic>(), node), child: Text('${node['label']}')),
      'image' => _PanelImage(concept: node['concept'] as String, showImage: view.cb.showImage),
      'genimage' => _PanelGenImage(prompt: node['prompt'] as String, alt: node['alt'] as String, generateImage: view.cb.generateImage),
      'checklist' => Column(children: [
          // Own transparent Material per tile: the card is an opaque
          // DecoratedBox, which would hide ink splashes (debug assertion)
          // if the tiles painted on a farther Material ancestor.
          for (final i in (node['items'] as List).cast<Map<String, dynamic>>())
            Material(type: MaterialType.transparency, child: CheckboxListTile(value: not.isDone(i['id'] as String), activeColor: T.pri, controlAffinity: ListTileControlAffinity.leading, contentPadding: EdgeInsets.zero, dense: true,
                title: Text('${i['text']}', style: const TextStyle(fontSize: 16)), onChanged: (_) => not.toggle(i['id'] as String))),
        ]),
      'choices' => RadioGroup<String>(
          groupValue: not.answerOf(node['id'] as String),
          onChanged: (v) { if (v != null) not.answer(node['id'] as String, v); },
          child: Column(children: [
            for (final o in (node['options'] as List).cast<Map<String, dynamic>>())
              Material(type: MaterialType.transparency, child: RadioListTile<String>(value: o['id'] as String, activeColor: T.pri, contentPadding: EdgeInsets.zero, dense: true,
                  title: Text('${o['label']}', style: const TextStyle(fontSize: 16)))),
          ]),
        ),
      'steps' => Column(children: [
          for (var i = 0; i < (node['steps'] as List).length; i++)
            Builder(builder: (_) {
              final s = (node['steps'] as List)[i] as Map<String, dynamic>;
              final cur = s['id'] == node['current'];
              return Container(width: double.infinity, margin: const EdgeInsets.symmetric(vertical: 3), padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: cur ? T.priSoft : T.bg, borderRadius: BorderRadius.circular(14), border: cur ? Border.all(color: T.pri) : null),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${i + 1}. ${s['text']}', style: TextStyle(fontSize: 16, fontWeight: cur ? FontWeight.w800 : FontWeight.w600)),
                    if (s['detail'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('${s['detail']}', style: const TextStyle(fontSize: 14, color: T.mute))),
                  ]));
            }),
        ]),
      'list' => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final i in (node['items'] as List).cast<Map<String, dynamic>>())
            Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('•  ', style: TextStyle(fontSize: 16, color: T.pri)), Expanded(child: Text('${i['text']}', style: const TextStyle(fontSize: 16)))])),
        ]),
      'card' => _PanelCard(node: node, panel: panel, view: view, ref: ref),
      _ => const SizedBox.shrink(), // unreachable: the validator only passes the 11 known types
    };
    final acts = (node['actions'] as List?) ?? const [];
    if (acts.isEmpty || t == 'button') return main; // buttons carry their action in the tap itself
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      main,
      Wrap(spacing: 4, children: [for (final a in acts.cast<Map>()) _ActionChip(action: a.cast<String, dynamic>(), self: node, view: view, ref: ref)]),
    ]);
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.action, required this.self, required this.view, required this.ref});
  final Map<String, dynamic> action;
  final Map<String, dynamic> self;
  final PanelView view;
  final WidgetRef ref;
  @override
  Widget build(BuildContext context) {
    final (icon, tip) = switch (action['action']) {
      'speak' => (Icons.volume_up_outlined, 'Read this aloud'),
      'ask' => (Icons.chat_bubble_outline, 'Ask about this'),
      'open_screen' => (Icons.open_in_new_outlined, 'Open'),
      'check' => (Icons.check_circle_outline, 'Tick off'),
      'answer' => (Icons.how_to_vote_outlined, 'Choose'),
      _ => (Icons.play_arrow_outlined, 'Next'),
    };
    return IconButton(tooltip: tip, iconSize: 22, color: T.pri, icon: Icon(icon), onPressed: () => view._runAction(ref, action, self));
  }
}

class _PanelCard extends StatelessWidget {
  const _PanelCard({required this.node, required this.panel, required this.view, required this.ref});
  final Map<String, dynamic> node;
  final PanelState panel;
  final PanelView view;
  final WidgetRef ref;
  @override
  Widget build(BuildContext context) {
    final kids = [for (final c in (node['children'] as List).cast<Map<String, dynamic>>()) _NodeView(node: c, panel: panel, view: view, ref: ref)];
    final body = node['layout'] == 'row'
        ? Wrap(spacing: 8, runSpacing: 8, children: [for (final k in kids) ConstrainedBox(constraints: const BoxConstraints(minWidth: 120, maxWidth: 220), child: k)])
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final k in kids) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: k)]);
    if (node['layout'] == 'card') {
      return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [if (node['title'] != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${node['title']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))), body])));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [if (node['title'] != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${node['title']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))), body]);
  }
}

class _PanelImage extends ConsumerWidget {
  const _PanelImage({required this.concept, required this.showImage});
  final String concept;
  final Future<void> Function(String) showImage;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(visualProvider)[concept];
    if (bytes != null) return ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(bytes, height: 140, fit: BoxFit.cover, semanticLabel: concept));
    return InkWell(onTap: () => showImage(concept), borderRadius: BorderRadius.circular(12),
        child: Container(height: 120, decoration: BoxDecoration(color: T.bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: T.line)),
            child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.image_outlined, color: T.mute, size: 32), const SizedBox(height: 4), Text('Tap to load: $concept', style: const TextStyle(color: T.mute, fontSize: 13))]))));
  }
}

/// An AI-drawn picture: explicit Create tap (never auto-generated), the bytes
/// once they arrive, and always the AI-made disclosure plus the alt text the
/// model wrote (screen readers get the same words via semanticLabel).
class _PanelGenImage extends ConsumerWidget {
  const _PanelGenImage({required this.prompt, required this.alt, required this.generateImage});
  final String prompt;
  final String alt;
  final Future<void> Function(String) generateImage;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(genImageProvider)[genImageKey(prompt)];
    if (bytes == null) {
      return InkWell(onTap: () => generateImage(prompt), borderRadius: BorderRadius.circular(12),
          child: Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: T.bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: T.line)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.auto_awesome_outlined, color: T.pri, size: 32),
                const SizedBox(height: 8),
                Text(prompt, textAlign: TextAlign.center, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                const Text('Tap to create this picture', style: TextStyle(color: T.pri, fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text('Milo will draw it with AI', style: TextStyle(color: T.mute, fontSize: 12)),
              ])));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(bytes, height: 180, width: double.infinity, fit: BoxFit.cover, semanticLabel: 'AI-made picture. $alt')),
      const SizedBox(height: 6),
      Row(children: [const Icon(Icons.auto_awesome, size: 14, color: T.mute), const SizedBox(width: 4), const Text('AI-made picture', style: TextStyle(color: T.mute, fontSize: 12, fontWeight: FontWeight.w700))]),
      const SizedBox(height: 2),
      Text(alt, style: const TextStyle(color: T.mute, fontSize: 13, height: 1.3)),
    ]);
  }
}
