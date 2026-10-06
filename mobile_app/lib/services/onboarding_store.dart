import 'package:shared_preferences/shared_preferences.dart';

/// 新用户引导是否看过的标记，存在本机偏好里（不进数据库）。
class OnboardingStore {
  OnboardingStore._();

  /// 键名带版本后缀：以后引导内容大改时可以再展示一次。
  static const String _seenKey = 'onboarding_seen_v1';

  static Future<bool> hasSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_seenKey) ?? false;
    } catch (_) {
      // 偏好读不到时不要把人卡在引导页，直接进首页。
      return true;
    }
  }

  static Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_seenKey, true);
    } catch (_) {
      // 写失败只是下次再看一遍引导，不值得打断任何流程。
    }
  }
}
