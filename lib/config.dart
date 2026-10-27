/// Build-time configuration:  flutter run --dart-define=API_BASE=https://api.yourdomain.com --dart-define=HELPLINE=14416
class Env {
  static const apiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:8000'); // Android emulator -> host machine
  static const helpline = String.fromEnvironment('HELPLINE', defaultValue: ''); // VERIFY the number for each country before shipping
  static const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'dev');
  static String get wsBase => apiBase.replaceFirst(RegExp('^http'), 'ws');
}
