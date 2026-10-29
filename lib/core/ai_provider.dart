import '../data/db.dart';

/// Who Milo thinks with. One explicit choice, stored in the existing
/// `ai.family_key` setting (`family` = the family's own providers, anything
/// else = Milo hosted): no migration, no new keys, sync-safe (the setting
/// syncs with the rest of settings, the keys themselves never touch the
/// phone — they stay sealed on the server behind the sync vault).
enum AiChoice { miloHosted, family }

/// Reads the current choice. Defaults to Milo hosted.
Future<AiChoice> aiChoice(MiloDb db) async =>
    (await db.get('ai.family_key'))?.isNotEmpty == true
        ? AiChoice.family
        : AiChoice.miloHosted;

/// Stores the choice. Switching to family with no saved connection is
/// refused by the UI, never here: this stays a plain setter so tests and
/// tools can drive it.
Future<void> setAiChoice(MiloDb db, AiChoice c) =>
    db.put('ai.family_key', c == AiChoice.family ? 'family' : '');

/// One honest line per choice for settings surfaces.
String aiChoiceWords(AiChoice c) => switch (c) {
      AiChoice.miloHosted:
        'Milo hosted — Milo’s server does the thinking. '
            'Works without sync.',
      AiChoice.family:
        'Family AI — your own provider accounts, billed by '
            'your providers. Needs sync.',
    };
