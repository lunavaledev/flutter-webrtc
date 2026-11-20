import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter_test/flutter_test.dart';

void ensureTestBinding() {
  isWindowingEnabled = false;
  TestWidgetsFlutterBinding.ensureInitialized();
}
