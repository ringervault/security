import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ringer_vault/sync/one_at_a_time.dart';

void main() {
  test('a second job waits for the first, then runs', () async {
    final gate = OneAtATime();
    final order = <String>[];
    final release = Completer<void>();

    final first = gate.run(() async {
      order.add('first start');
      await release.future;
      order.add('first end');
    });
    final second = gate.run(() async => order.add('second'));

    await Future<void>.delayed(Duration.zero);
    expect(order, ['first start']);
    expect(gate.busy, isTrue);

    release.complete();
    await Future.wait([first, second]);
    expect(order, ['first start', 'first end', 'second']);
    expect(gate.busy, isFalse);
  });

  // The freeze: the first job's main work finished, then it waited on the
  // event queue (in the app, saving the time of the sync to secure storage)
  // while a second job was already waiting. The old wait looped on the
  // finished future in microtasks and never let that event through.
  test('a waiter does not starve the event queue the running job needs', () async {
    final gate = OneAtATime();
    final first = gate.run(() async {
      await Future<void>.value(); // the engine's run, already finished
      await Future<void>.delayed(const Duration(milliseconds: 5)); // a platform call
      return 'first';
    });
    final second = gate.run(() async => 'second');

    expect(
      await Future.wait([first, second]).timeout(const Duration(seconds: 2)),
      ['first', 'second'],
    );
  });

  test('a job that fails still lets the next one run', () async {
    final gate = OneAtATime();
    final failing = gate.run<void>(() async {
      await Future<void>.delayed(Duration.zero);
      throw StateError('no network');
    });
    final next = gate.run(() async => 'ran');

    await expectLater(failing, throwsStateError);
    expect(await next.timeout(const Duration(seconds: 2)), 'ran');
    expect(gate.busy, isFalse);
  });

  test('three waiting jobs all run, never two at once', () async {
    final gate = OneAtATime();
    var running = 0;
    var most = 0;
    Future<int> job(int n) => gate.run(() async {
          running++;
          most = most > running ? most : running;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          running--;
          return n;
        });

    final results = await Future.wait([job(1), job(2), job(3), job(4)])
        .timeout(const Duration(seconds: 2));
    expect(results.toSet(), {1, 2, 3, 4});
    expect(most, 1);
  });
}
