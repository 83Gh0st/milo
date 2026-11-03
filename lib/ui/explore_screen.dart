import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import 'screen.dart';
import 'theme.dart';

class ExploreScreen extends ConsumerWidget {
  const ExploreScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final off = ref.watch(ladderProvider) != Ladder.full;
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (off) const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('You are offline. Hosted AI (chat, drawing, voice, outlines) needs internet - everything marked Works offline still works.', style: TextStyle(color: T.mute, fontSize: 13))),
      RowCard(icon: Icons.auto_awesome_outlined, title: 'Draw a picture', subtitle: off ? 'Needs internet' : 'Ask Milo to draw, then tap Create', color: 2, onTap: () => ref.read(tabProvider.notifier).state = 2),
      RowCard(icon: Icons.menu_book_outlined, title: 'Understand', subtitle: off ? 'Saved explanations and read aloud' : 'Read, listen, learn', tag: const Tag('Works offline'), onTap: () => openScreen('understand')),
      RowCard(icon: Icons.chat_bubble_outline, title: 'Express', subtitle: 'Talk, type, communicate', color: 1, tag: const Tag('Works offline'), onTap: () => openScreen('express')),
      RowCard(icon: Icons.check_circle_outline, title: 'Do things', subtitle: 'Plan, organise, get it done', color: 3, tag: const Tag('Works offline'), onTap: () => openScreen('do')),
      RowCard(icon: Icons.extension_outlined, title: 'Learn', subtitle: 'Short playful activities', color: 2, tag: const Tag('Works offline'), onTap: () => openScreen('learn')),
      RowCard(icon: Icons.favorite_border, title: 'Check in', subtitle: 'How are you feeling? (optional)', color: 1, onTap: () => openScreen('checkin')),
      RowCard(icon: Icons.bedtime_outlined, title: 'Break time', subtitle: 'Breathe, rest, come back', color: 0, onTap: () => openScreen('break')),
    ]);
  }
}
