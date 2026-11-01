// Offline "Pocket brain": simple local rules that emit the SAME contract JSON
// the cloud brain (Muse Spark via the gateway) will emit later.

/// Maps a cloud failure code to the pocket fallback variant. Pure:
/// unit-tested. Hosted turns time out on Muse Spark; family turns on the
/// family's own provider — the words name who to blame, never the network
/// when the network is fine.
String cloudForFailure(String code, bool hosted) => switch (code) {
      'budget_exhausted' || 'rate_limited' => 'resting',
      'timeout' => hosted ? 'timeout_hosted' : 'timeout',
      'auth_failed' || 'http_401' || 'quota' || 'model_not_found' => 'key',
      _ => 'offline',
    };

Map<String, dynamic> pocketBrain(String raw, String profile, {String cloud = 'off'}) {
  final s = raw.toLowerCase().replaceAll('’', "'");
  Map<String, dynamic> t(String emo, double i, String? g, List<String> say,
          {List<String> ch = const [], String? open, String f = 'wait', String risk = 'none'}) =>
      {'risk': risk, 'emotion': {'name': emo, 'intensity': i}, 'gesture': g, 'say': say, 'followup': f,
       'ui': [if (ch.isNotEmpty) <String, dynamic>{'action': 'offer_choices', 'choices': ch},
              if (open != null) <String, dynamic>{'action': 'open_screen', 'screen': open}]};
  final d = profile == 'discreet', p = profile == 'playful';
  if (RegExp(r"hurt myself|kill myself|want to die|suicid|self.?harm|hurting me|abus").hasMatch(s)) {
    // Hand-written support flow, never generated.
    return t('concerned', .6, null, ['I’m really glad you told me.', 'Is a grown-up or someone you trust nearby?', 'Please tell them now, or call your local emergency number.'],
        ch: ['Yes, someone is here', 'Not right now'], risk: 'crisis');
  }
  if (RegExp(r"someone|grown|trust|not right now").hasMatch(s)) return t('calm', .5, 'nod', ['That is a good idea.', 'I’m right here with you.']);
  if (RegExp(r"\b(hi|hello|hey)\b|good morning").hasMatch(s)) return t('happy', .8, 'wave', [p ? 'Hi! Ready to play with words?' : d ? 'Hello. What would you like to do?' : 'Hi! What shall we do today?'], ch: ['Read to me', 'Help me say something', 'Do steps']);
  if (s.contains('thank')) return t('happy', .7, 'nod', [d ? 'Any time.' : 'You are welcome!'], f: 'none');
  if (RegExp(r"\b(say|speak|board|communicat)").hasMatch(s)) return t('curious', .6, 'lean_in', ['Let us open your board.'], open: 'express', f: 'none');
  if (RegExp(r"plan|steps|routine|get ready|task").hasMatch(s)) return t('curious', .6, 'point', ['Pick a plan. I will go one step at a time.'], open: 'do', f: 'none');
  if (RegExp(r"read|worksheet|explain|understand").hasMatch(s)) return t('curious', .7, 'lean_in', ['I can read it to you and follow along.'], open: 'understand', f: 'none');
  if (RegExp(r"break|tired|breathe|calm down").hasMatch(s)) return t('calm', .8, null, ['Let us slow down together.'], open: 'break', f: 'none');
  if (RegExp(r"sad|upset|worried|scared|bad day|angry").hasMatch(s)) return t('concerned', .6, 'nod', ['That sounds hard. I’m here.', 'What would help a little?'], ch: ['Take a break', 'Breathe with Milo', 'Talk to someone I trust']);
  if (RegExp(r"can't|cannot|don't get|dont get|too hard|confus|stuck").hasMatch(s)) return t('encouraging', .7, 'lean_in', ['That one is tricky.', 'Let us try another way.'], ch: ['Easier words', 'Show a picture', 'Let me try']);
  if (RegExp(r"\bhelp\b").hasMatch(s)) return t('encouraging', .7, 'lean_in', ['I’m here. What would help most?'], ch: ['Read to me', 'Help me say something', 'Do steps']);
  if (RegExp(r"dance|play|fun|game|joke").hasMatch(s)) return t('playful', 1, 'giggle', ['Let us play! Shake the phone or tap me.'], f: 'none');
  if (RegExp(r"who are you|what are you|real|human").hasMatch(s)) return t('calm', .6, 'nod', ['I’m Milo, an AI companion.', 'I’m not a person, but I like helping you.'], f: 'none');
  if (RegExp(r'video|youtube|\bfilm\b|vlog|watch this|watch that').hasMatch(s)) return t('calm', .6, 'nod', ['I can’t watch videos yet.', 'But you can tell me about it, and I’ll help.'], ch: ['Read to me', 'Help me say something']);
  if (RegExp(r'audio file|recording|voice ?note|voicemail|\bmp3\b').hasMatch(s)) return t('calm', .6, 'nod', ['I can hear you when you talk to me.', 'But I can’t play audio files yet.'], ch: ['Read to me', 'Help me say something']);
  // NOTE: memory commands never reach this file (the router handles them first as real database operations).
  return t('curious', .6, 'lean_in', cloud == 'offline'
      ? ['I can’t reach my thinking cloud right now.', 'Your things are safe. Reading aloud and your board still work.']
      : cloud == 'resting'
          ? ['My thinking cloud needs a rest.', 'I can still help with what is on your phone.']
          : cloud == 'timeout'
              ? ['That took too long.', 'Let’s try again in a moment.']
              : cloud == 'timeout_hosted'
                  ? ['Muse Spark is taking longer than expected.', 'Please try again.']
              : cloud == 'key'
                  ? ['My thinking cloud did not accept that key.', 'A grown-up can check it in AI connections.']
                  : ['Tell me more.', 'Cloud AI is turned off in your privacy settings, so I use simple rules for now.'], ch: ['Read to me', 'Help me say something', 'Do steps']);
}
