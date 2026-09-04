// Portability guard: web is a target, so `lib/` never imports `dart:ui` or `dart:html`, and
// `dart:io` appears only in the VM platform file behind the conditional import in
// `api_client.dart`.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib stays portable: dart:io only in the platform layer, never dart:ui or dart:html', () {
    // Never allowed anywhere in lib.
    final bannedEverywhere = RegExp(r'''import\s+['"]dart:(ui|html)['"]''');
    // Allowed only in the VM platform file.
    final bannedIo = RegExp(r'''import\s+['"]dart:io['"]''');
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Separators normalized so the allowance holds on Windows too.
      final isPlatformLayer = entity.path.replaceAll(r'\', '/').contains('/src/platform/');
      for (final (index, line) in entity.readAsLinesSync().indexed) {
        if (bannedEverywhere.hasMatch(line)) {
          offenders.add('${entity.path}:${index + 1}  ${line.trim()}');
        } else if (!isPlatformLayer && bannedIo.hasMatch(line)) {
          offenders.add('${entity.path}:${index + 1}  ${line.trim()}  (dart:io allowed only in src/platform/)');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'lib must stay portable (web target, no Flutter engine in the core). '
          'Offending imports:\n${offenders.join('\n')}',
    );
  });
}
