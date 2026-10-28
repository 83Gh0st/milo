import '../director.dart';

/// Deterministic local greeting pools (spec 2D): 8 lines per profile per
/// language (en, hi, ml), chosen by time of day, date and days together.
/// Replaces the single fixed line per profile. No streak or guilt language.
const _pools = <Profile, Map<String, List<String>>>{
  Profile.playful: {
    'en': [
      'Hi! I’m Milo, your AI friend. Ready to play with words?',
      'Hey hey! It’s a brand-new day to explore together!',
      'Hiya! I saved all my wiggles for you today!',
      'Hello, sunshine! What shall we discover first?',
      'Hey! I was just thinking about you. Let’s play!',
      'Hi hi! My sprout is extra bouncy today. What’s up?',
      'Hey there, friend! I missed our chats. What’s new?',
      'Hello! I dreamed of stories. Want to hear one?',
    ],
    'hi': [
      'नमस्ते! मैं मीलो हूँ। चलो, शब्दों से खेलें?',
      'हे! आज कुछ नया सीखते हैं!',
      'हैलो! मैं तुम्हारा इंतज़ार कर रहा था!',
      'नमस्ते दोस्त! आज क्या खोजें?',
      'हे! मैं तुमसे मिलकर बहुत खुश हूँ!',
      'हाय! चलो आज खूब मज़े करते हैं!',
      'नमस्ते! मेरी पत्ती आज बहुत हिल रही है!',
      'हैलो! कहानी सुनोगे?',
    ],
    'ml': [
      'ഹലോ! ഞാൻ മിലോ ആണ്. വാക്കുകളുമായി കളിക്കാം?',
      'ഹേ! ഇന്ന് പുതിയ എന്തെങ്കിലും പഠിക്കാം!',
      'ഹലോ! ഞാൻ നിനക്കായി കാത്തിരിക്കുകയായിരുന്നു!',
      'ഹായ് കൂട്ടുകാരാ! ഇന്ന് എന്ത് കണ്ടെത്തും?',
      'ഹേ! നിന്നെ കണ്ടതിൽ എനിക്ക് ഒരുപാട് സന്തോഷം!',
      'ഹായ്! ഇന്ന് നമുക്ക് ഒരുപാട് രസിക്കാം!',
      'ഹലോ! എന്റെ ഇല ഇന്ന് നന്നായി ആടുന്നുണ്ട്!',
      'ഹായ്! കഥ കേൾക്കുന്നോ?',
    ],
  },
  Profile.friendly: {
    'en': [
      'Hi, I’m Milo, an AI companion. What shall we do?',
      'Good to see you! What’s on your mind today?',
      'Hello! I’m glad you’re here. How are you feeling?',
      'Hi there! Ready when you are — no rush at all.',
      'Welcome back! I kept everything just as you left it.',
      'Hello, friend. Shall we learn something small today?',
      'Hi! It’s nice to spend time with you again.',
      'Hey! Whatever today brings, we’ll handle it together.',
    ],
    'hi': [
      'नमस्ते, मैं मीलो हूँ। आज क्या करें?',
      'आपसे मिलकर अच्छा लगा! आज क्या मन है?',
      'नमस्ते! आप यहाँ हैं, मुझे खुशी है।',
      'हैलो! जब आप तैयार हों, तब शुरू करते हैं।',
      'वापसी पर स्वागत है! सब कुछ वैसा ही है।',
      'नमस्ते दोस्त। आज कुछ छोटा सीखें?',
      'हाय! आपसे फिर मिलकर अच्छा लगा।',
      'हे! आज जो भी हो, हम साथ संभालेंगे।',
    ],
    'ml': [
      'ഹലോ, ഞാൻ മിലോ ആണ്. ഇന്ന് എന്ത് ചെയ്യും?',
      'നിന്നെ കണ്ടതിൽ സന്തോഷം! ഇന്ന് എന്താണ് മനസ്സിൽ?',
      'ഹലോ! നീ ഇവിടെയുള്ളതിൽ എനിക്ക് സന്തോഷമുണ്ട്.',
      'ഹായ്! നീ തയ്യാറാകുമ്പോൾ തുടങ്ങാം — ധൃതിയില്ല.',
      'തിരിച്ചുവരവിന് സ്വാഗതം! എല്ലാം അതേപടി ഉണ്ട്.',
      'ഹലോ കൂട്ടുകാരാ. ഇന്ന് ചെറിയ എന്തെങ്കിലും പഠിക്കാം?',
      'ഹായ്! നിന്നോടൊത്ത് വീണ്ടും സമയം ചെലവഴിക്കുന്നത് നല്ലതാണ്.',
      'ഹേ! ഇന്ന് എന്തുവന്നാലും നമ്മൾ ഒരുമിച്ച് നോക്കാം.',
    ],
  },
  Profile.discreet: {
    'en': [
      'Hello. I’m Milo, an AI companion.',
      'Hello. I’m here when you need me.',
      'Hi. Take your time — I’ll wait.',
      'Hello. What would you like to do?',
      'Hi. I’m listening whenever you’re ready.',
      'Hello. Shall we begin quietly?',
      'Hi. No rush. I’m right here.',
      'Hello. It’s good to see you.',
    ],
    'hi': [
      'नमस्ते। मैं मीलो हूँ।',
      'नमस्ते। जब ज़रूरत हो, मैं यहीं हूँ।',
      'हाय। आराम से — मैं इंतज़ार करूँगा।',
      'नमस्ते। आप क्या करना चाहेंगे?',
      'हाय। जब आप तैयार हों, मैं सुन रहा हूँ।',
      'नमस्ते। क्या हम धीरे से शुरू करें?',
      'हाय। कोई जल्दी नहीं। मैं यहीं हूँ।',
      'नमस्ते। आपसे मिलकर अच्छा लगा।',
    ],
    'ml': [
      'ഹലോ. ഞാൻ മിലോ ആണ്.',
      'ഹലോ. ആവശ്യമുള്ളപ്പോൾ ഞാൻ ഇവിടെയുണ്ട്.',
      'ഹായ്. സമയമെടുക്കൂ — ഞാൻ കാത്തിരിക്കാം.',
      'ഹലോ. എന്ത് ചെയ്യാനാണ് ആഗ്രഹം?',
      'ഹായ്. നീ തയ്യാറാകുമ്പോൾ ഞാൻ കേൾക്കുന്നുണ്ട്.',
      'ഹലോ. നമുക്ക് മെല്ലെ തുടങ്ങിയാലോ?',
      'ഹായ്. ധൃതിയില്ല. ഞാൻ ഇവിടെയുണ്ട്.',
      'ഹലോ. നിന്നെ കണ്ടതിൽ സന്തോഷം.',
    ],
  },
};

const _firstDay = <Profile, Map<String, String>>{
  Profile.playful: {
    'en': 'Hi! I’m Milo, your new AI friend! I’m so excited to meet you!',
    'hi': 'नमस्ते! मैं मीलो हूँ, तुम्हारा नया दोस्त! तुमसे मिलकर बहुत खुशी हुई!',
    'ml': 'ഹലോ! ഞാൻ മിലോ ആണ്, നിന്റെ പുതിയ കൂട്ടുകാരൻ! നിന്നെ കണ്ടതിൽ ഒരുപാട് സന്തോഷം!',
  },
  Profile.friendly: {
    'en': 'Hi, I’m Milo, an AI companion. I’m really glad to meet you.',
    'hi': 'नमस्ते, मैं मीलो हूँ। आपसे मिलकर मुझे बहुत खुशी है।',
    'ml': 'ഹലോ, ഞാൻ മിലോ ആണ്. നിന്നെ കണ്ടതിൽ എനിക്ക് ശരിക്കും സന്തോഷമുണ്ട്.',
  },
  Profile.discreet: {
    'en': 'Hello. I’m Milo. Pleased to meet you.',
    'hi': 'नमस्ते। मैं मीलो हूँ। आपसे मिलकर खुशी हुई।',
    'ml': 'ഹലോ. ഞാൻ മിലോ ആണ്. കണ്ടതിൽ സന്തോഷം.',
  },
};

/// One pool for tests and the Lab (8 lines; falls back to English).
List<String> greetingPool(Profile p, String lang) => _pools[p]![_pools[p]!.containsKey(lang) ? lang : 'en']!;

/// Deterministic greeting: same day + profile + language + days-together
/// always yields the same line (testable, no randomness in the product).
String greetingFor(Profile p, String lang, DateTime now, int daysTogether, String lastScreen) {
  final l = _pools[p]!.containsKey(lang) ? lang : 'en';
  if (daysTogether <= 0) return _firstDay[p]![l]!;
  final bucket = now.hour < 5 ? 0 : now.hour < 12 ? 1 : now.hour < 18 ? 2 : 3;
  final day = now.difference(DateTime(now.year, 1, 1)).inDays;
  final pool = _pools[p]![l]!;
  return pool[(bucket + day * 3 + daysTogether * 5 + lastScreen.length) % pool.length];
}
