import 'package:conduit/core/startup/omni_launch_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('release without a hold is a no-op and never throws', () {
    expect(OmniLaunchGate.isHeld, isFalse);
    OmniLaunchGate.release('nothing-held');
    OmniLaunchGate.release('again');
    expect(OmniLaunchGate.isHeld, isFalse);
  });

  test('without preferences the first frame is never held', () {
    OmniLaunchGate.holdIfOmni();
    expect(OmniLaunchGate.isHeld, isFalse);
  });
}
