// Brain-to-body contract (doc section 5.6). The model proposes; this validates.
const kEmotions = ['calm','happy','excited','curious','thinking','listening','encouraging','proud','concerned','sleepy','playful','surprised'];
const kGestures = ['wave','nod','shrug','point','lean_in','think','celebrate','giggle'];
const kTabs = ['home','understand','express','do'];
const kScreens = [...kTabs, 'break'];
const kRisks = ['none','check_in','crisis'];

class BrainTurn {
  final String risk, emotion, followup;
  final double intensity;
  final String? gesture, openScreen;
  final List<String> say, choices;
  const BrainTurn({this.risk='none', this.emotion='calm', this.intensity=.5, this.gesture, this.say=const [], this.choices=const [], this.openScreen, this.followup='none'});
}

final _unsafe = RegExp(r'(https?://\S+|www\.\S+|\+?\d[\d\s\-]{6,}\d)');

/// Unknown values are dropped, intensity clamped, <=4 sentences, <=3 choices,
/// no URLs or phone numbers. Nothing here can touch files, storage or the OS.
BrainTurn validateTurn(Map<String, dynamic> j) {
  String pick(dynamic v, List<String> ok, String d) => ok.contains(v) ? v as String : d;
  final em = j['emotion'];
  final name = em is Map ? em['name'] : em;
  final inten = em is Map && em['intensity'] is num ? (em['intensity'] as num).toDouble() : .6;
  final say = (j['say'] is List ? j['say'] as List : <dynamic>[])
      .whereType<String>().map((s) => s.replaceAll(_unsafe, '').trim()).where((s) => s.isNotEmpty).take(4).toList();
  var choices = <String>[];
  String? open;
  for (final u in (j['ui'] is List ? j['ui'] as List : <dynamic>[])) {
    if (u is! Map) continue;
    if (u['action'] == 'offer_choices' && u['choices'] is List) choices = (u['choices'] as List).whereType<String>().take(3).toList();
    if (u['action'] == 'open_screen' && kScreens.contains(u['screen'])) open = u['screen'] as String;
  }
  final g = j['gesture'];
  return BrainTurn(
    risk: pick(j['risk'], kRisks, 'none'), emotion: pick(name, kEmotions, 'calm'),
    intensity: inten.clamp(0.0, 1.0).toDouble(), gesture: kGestures.contains(g) ? g as String : null,
    say: say, choices: choices, openScreen: open, followup: pick(j['followup'], ['wait','ask','none'], 'none'));
}

/// Memory keys each activity may send to the cloud (whitelist, mirrors contracts/brain_contract.json).
const kMemKeys = {
  'understand': ['explanation_style', 'reading_speed', 'language'],
  'express': ['voice', 'vocabulary_topic'],
  'do': ['step_style', 'pace'],
  'chat': ['explanation_style', 'language', 'call_name'],
};

/// Pictures Milo may generate on demand (concept allow-list; mirrors the gateway).
const kVisualConcepts = {'tree', 'flower', 'sun', 'moon', 'star', 'cloud', 'rain', 'mountain', 'river', 'ocean', 'fish', 'whale', 'dog', 'cat', 'bird', 'horse', 'cow', 'butterfly', 'bee', 'apple', 'banana', 'bread', 'water', 'milk', 'house', 'car', 'bus', 'bicycle', 'book', 'pencil', 'backpack', 'shoes', 'shirt', 'toothbrush', 'clock', 'door', 'chair', 'bed', 'ball', 'kite'};
