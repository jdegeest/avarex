import 'package:window_manager/window_manager.dart';

import '../constants.dart';
import '../storage.dart';

class FullScreen {
  static bool get supported => Constants.supportsWindowManagement;

  static Future<void> applySaved() async {
    if (!supported) {
      return;
    }
    try {
      await windowManager.ensureInitialized();
      await windowManager.setFullScreen(Storage().settings.getFullScreen());
    }
    catch (e) {
      Storage().setException("Full screen failed: $e");
    }
  }

  static Future<bool> set(bool on) async {
    if (!supported) {
      return false;
    }
    try {
      await windowManager.setFullScreen(on);
      Storage().settings.setFullScreen(on);
      return on;
    }
    catch (e) {
      Storage().setException("Full screen failed: $e");
      return Storage().settings.getFullScreen();
    }
  }
}
