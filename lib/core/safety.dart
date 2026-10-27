import '../contracts/brain_contract.dart';

/// Local safety pre-filter: runs BEFORE any cloud call and needs no network (doc 6.5).
/// English + Hindi + Malayalam starter patterns. A fluent speaker must review them before real users (docs/LAUNCH_CHECKLIST.md).
class Safety {
  static final _crisis = RegExp(
      r"(hurt myself|kill myself|want to die|wanna die|end my life|suicid|self[- ]?harm|cut myself|hurting me|abus(e|ing) me|touch(es|ed|ing) me|(told|telling) me to keep (it|this|that) (a )?secret|hit(s|ting)? me|(don'?t|do not) want to be here|want to disappear|no reason to live|better off without me|nobody would miss me|wish i (was|were) dead)"
      r"|आत्महत्या|मरना चाहता|मरना चाहती|खुद को नुकसान|ആത്മഹത്യ|മരിക്കണം|മരിക്കാൻ",
      caseSensitive: false);
  static bool isCrisis(String t) => _crisis.hasMatch(t.replaceAll('’', "'"));

  /// Hand-written, never generated. Locale lines need native review.
  static BrainTurn supportTurn(String lang) {
    final say = switch (lang) {
      'hi' => ['मुझे खुशी है कि आपने मुझे बताया।', 'क्या आपके पास कोई बड़ा या भरोसेमंद व्यक्ति है?'],
      'ml' => ['ഇത് എന്നോട് പറഞ്ഞതിൽ സന്തോഷം.', 'നിങ്ങളുടെ അടുത്ത് വിശ്വസ്തനായ ഒരാൾ ഉണ്ടോ?'],
      _ => ['I’m really glad you told me.', 'Is a grown-up or someone you trust nearby?'],
    };
    return BrainTurn(risk: 'crisis', emotion: 'concerned', intensity: .5, say: say, followup: 'wait');
  }
}
