/// Speech text normalisation (Phase 4B). Pure functions, fully unit-tested.
///
/// What it does: expands abbreviations, maps native digits to latin (TTS
/// engines vary; latin is the safe common path), verbalises small English
/// integers, strips emoji/symbols while keeping sentence punctuation, and
/// splits long text into speakable sentences with word offsets so read-aloud
/// highlighting keeps working.
///
/// What it does NOT do: invent pronunciations. The [lexicon] hook lets a
/// voice profile carry verified fixes (populated from bake-off listening,
/// never from guesses); the default map only holds unambiguous expansions.
const kSpeechLexicon = <String, String>{'OK': 'okay', 'ok': 'okay'};

const _abbr = <String, String>{
  'Dr.': 'Doctor', 'Mr.': 'Mister', 'Mrs.': 'Missus', 'Ms.': 'Miss',
  'St.': 'Saint', 'e.g.': 'for example', 'i.e.': 'that is',
  'etc.': 'and so on', 'vs.': 'versus',
};

// Devanagari U+0966..U+096F, Malayalam U+0D66..U+0D6F.
const _devDigits = '०१२३४५६७८९', _malDigits = '൦൧൨൩൪൫൬൭൮൯';

const _ones = ['zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten',
  'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen'];
const _tens = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];

String _smallNum(int n) => n < 20 ? _ones[n] : '${_tens[n ~/ 10]}${n % 10 == 0 ? '' : ' ${_ones[n % 10]}'}';

String normalizeForSpeech(String text, String lang, {Map<String, String> lexicon = kSpeechLexicon}) {
  var s = text;
  lexicon.forEach((k, v) => s = s.replaceAll(RegExp('\\b${RegExp.escape(k)}\\b'), v)); // whole words only: 'ok' must not rewrite 'okay'
  _abbr.forEach((k, v) => s = s.replaceAll(k, v));
  for (var i = 0; i < 10; i++) {
    s = s.replaceAll(_devDigits[i], '$i').replaceAll(_malDigits[i], '$i');
  }
  if (lang == 'en') {
    s = s.replaceAllMapped(RegExp(r'\b\d{1,2}\b'), (m) => _smallNum(int.parse(m.group(0)!)));
  }
  // Keep letters (all scripts), marks, numbers, whitespace and sentence
  // punctuation; drop emoji, bullets and decorative symbols.
  s = s.replaceAll(RegExp('[^\\p{L}\\p{M}\\p{N}\\s.,?!;:\'"()\\-…–/‘’]', unicode: true), ' ');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Splits [text] into speakable sentences of at most [maxWords] words each,
/// splitting first at sentence ends, then at commas/semicolons, then at
/// spaces. Each item carries its global word offset so read-aloud callbacks
/// (`onWord`) keep pointing at the right word.
List<({String text, int wordOffset})> splitSentences(String text, int maxWords) {
  final out = <({String text, int wordOffset})>[];
  var offset = 0;
  final words = RegExp(r'\S+').allMatches(text).map((m) => m.group(0)!).toList();
  if (words.isEmpty) return out;
  // Sentence boundaries: ends with . ? ! … (keep the mark on the sentence).
  final sents = <String>[];
  final buf = StringBuffer();
  for (final w in words) {
    if (buf.isNotEmpty) buf.write(' ');
    buf.write(w);
    if (RegExp(r"""[.?!…]+["' )]*$""").hasMatch(w)) {
      sents.add(buf.toString());
      buf.clear();
    }
  }
  if (buf.isNotEmpty) sents.add(buf.toString());
  for (final s in sents) {
    final ws = s.split(' ');
    if (ws.length <= maxWords) {
      out.add((text: s, wordOffset: offset));
      offset += ws.length;
      continue;
    }
    // Long sentence: chunk at commas/semicolons, then hard-cut at spaces.
    final chunks = <String>[];
    final cur = <String>[];
    for (final w in ws) {
      cur.add(w);
      if (cur.length >= maxWords || (RegExp(r'[,;:]$').hasMatch(w) && cur.length >= maxWords ~/ 2)) {
        chunks.add(cur.join(' '));
        cur.clear();
      }
    }
    if (cur.isNotEmpty) chunks.add(cur.join(' '));
    for (final c in chunks) {
      out.add((text: c, wordOffset: offset));
      offset += c.split(' ').length;
    }
  }
  return out;
}
