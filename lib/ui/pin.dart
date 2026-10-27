import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import '../data/secure_store.dart';
import 'theme.dart';

/// Trusted-adult PIN: salted + iterated hash in Keychain/Keystore; five wrong tries trigger a delay.
class Pin {
  static int _wrong = 0;
  static DateTime _until = DateTime(2000);
  static String _h(String salt, String pin) { var d = utf8.encode('$salt:$pin'); for (var i = 0; i < 20000; i++) { d = sha256.convert(d).bytes; } return base64Encode(d); }
  static Future<bool> isSet(SecureStore s) async => await s.read('pin.hash') != null;
  static Future<void> set(SecureStore s, String pin) async { final salt = DateTime.now().microsecondsSinceEpoch.toRadixString(36); await s.write('pin.salt', salt); await s.write('pin.hash', _h(salt, pin)); }
  static Future<bool> check(SecureStore s, String pin) async {
    if (DateTime.now().isBefore(_until)) return false;
    final ok = _h((await s.read('pin.salt')) ?? '', pin) == await s.read('pin.hash');
    if (ok) { _wrong = 0; return true; }
    if (++_wrong >= 5) { _until = DateTime.now().add(const Duration(seconds: 60)); _wrong = 0; }
    return false;
  }
  static Future<String?> ask(BuildContext c, String title) => Navigator.push<String>(c, MaterialPageRoute(builder: (_) => PinPad(title: title)));
  /// Returns true when the adult is allowed in (creating a PIN the first time).
  static Future<bool> gate(BuildContext c, SecureStore s) async {
    if (!await isSet(s)) { final p = await ask(c, 'Create a 4-digit PIN'); if (p == null || p.length != 4) return false; await set(s, p); return true; }
    final p = await ask(c, 'Enter your PIN');
    return p != null && await check(s, p);
  }
}

/// Wireframe 10.1: round keypad, four dots, "five wrong tries add a delay".
class PinPad extends StatefulWidget { const PinPad({super.key, required this.title}); final String title; @override State<PinPad> createState() => _PinPadState(); }
class _PinPadState extends State<PinPad> {
  String v = '';
  void _k(String k) { setState(() { if (k == '<') { if (v.isNotEmpty) v = v.substring(0, v.length - 1); } else if (v.length < 4) { v += k; } }); if (v.length == 4) Future.delayed(const Duration(milliseconds: 150), () { if (mounted) Navigator.pop(context, v); }); }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0), body: SafeArea(child: Column(children: [
    const Icon(Icons.lock, size: 40, color: T.pri), const SizedBox(height: 10), Text(widget.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)), const SizedBox(height: 18),
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (var i = 0; i < 4; i++) Container(margin: const EdgeInsets.all(8), width: 16, height: 16, decoration: BoxDecoration(shape: BoxShape.circle, color: i < v.length ? T.pri : T.line))]),
    const SizedBox(height: 24),
    for (final row in [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9'], ['', '0', '<']]) Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final k in row) Padding(padding: const EdgeInsets.all(8), child: k.isEmpty ? const SizedBox(width: 76, height: 76) : Material(color: Colors.white, shape: const CircleBorder(side: BorderSide(color: T.line)), child: InkWell(customBorder: const CircleBorder(), onTap: () => _k(k), child: SizedBox(width: 76, height: 76, child: Center(child: k == '<' ? const Icon(Icons.backspace_outlined) : Text(k, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)))))))]),
    const Spacer(), const Padding(padding: EdgeInsets.all(16), child: Text('Five wrong tries add a delay.', style: TextStyle(fontSize: 12, color: T.mute))),
  ])));
}
