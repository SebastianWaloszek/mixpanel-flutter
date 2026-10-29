import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/masking/mask_detector.dart';
import 'package:mixpanel_flutter_session_replay/src/models/configuration.dart';
import 'package:mixpanel_flutter_session_replay/src/models/masking_directive.dart';
import 'package:mixpanel_flutter_session_replay/src/widgets/widgets.dart';

void main() {
  testWidgets('should skip capture when a route transition is in progress', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('First route')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundaryElement = boundaryKey.currentContext! as Element;
    final boundary = boundaryElement.renderObject! as RenderRepaintBoundary;
    final detector = MaskDetector(
      directive: MaskingDirective(autoMaskTypes: const {}),
    );

    expect(
      detector
          .detectMaskRegions(boundary, boundaryElement: boundaryElement)
          .shouldSkipCapture,
      isFalse,
    );

    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Second route')),
        ),
      ),
    );
    await tester.pump();

    expect(
      detector
          .detectMaskRegions(boundary, boundaryElement: boundaryElement)
          .shouldSkipCapture,
      isTrue,
    );

    await tester.pumpAndSettle();
    expect(
      detector
          .detectMaskRegions(boundary, boundaryElement: boundaryElement)
          .shouldSkipCapture,
      isFalse,
    );
  });

  testWidgets(
    'should preserve name matching when a custom render type is used',
    (tester) async {
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: const _CompatibilityTextRenderObjectWidget(),
        ),
      );

      final boundaryElement = boundaryKey.currentContext! as Element;
      final boundary = boundaryElement.renderObject! as RenderRepaintBoundary;
      final directive = MaskingDirective(
        autoMaskTypes: const {AutoMaskedView.text},
      );
      final result = MaskDetector(
        directive: directive,
      ).detectMaskRegions(boundary, boundaryElement: boundaryElement);

      expect(result.maskRegions, hasLength(1));
      expect(result.maskRegions.single.source, MaskSource.auto);
    },
  );

  group('inside a RotatedBox', () {
    for (final quarterTurns in [1, 3]) {
      testWidgets(
        'should mask text in a scroll view rotated $quarterTurns quarter turns',
        (tester) async {
          final boundaryKey = GlobalKey();
          final textKey = GlobalKey();
          await _pumpPhone(
            tester,
            RepaintBoundary(
              key: boundaryKey,
              child: RotatedBox(
                quarterTurns: quarterTurns,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: 120),
                      Text('Guest name', key: textKey),
                    ],
                  ),
                ),
              ),
            ),
          );

          final result = _detect(boundaryKey, const {AutoMaskedView.text});

          final textBounds = _boundsInBoundary(textKey, boundaryKey);
          expect(result.maskRegions, isNotEmpty);
          for (final region in result.maskRegions) {
            expect(region.source, MaskSource.auto);
            expect(region.bounds, _rectCloseTo(textBounds));
          }
        },
      );

      testWidgets(
        'should place a MixpanelMask rotated $quarterTurns quarter turns '
        'over its rendered position',
        (tester) async {
          final boundaryKey = GlobalKey();
          final maskedKey = GlobalKey();
          await _pumpPhone(
            tester,
            RepaintBoundary(
              key: boundaryKey,
              child: RotatedBox(
                quarterTurns: quarterTurns,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 40, top: 10),
                    child: MixpanelMask(
                      child: SizedBox(key: maskedKey, width: 200, height: 30),
                    ),
                  ),
                ),
              ),
            ),
          );

          final result = _detect(boundaryKey, const {});

          final maskedBounds = _boundsInBoundary(maskedKey, boundaryKey);
          final manual = result.maskRegions
              .where((region) => region.source == MaskSource.manual)
              .toList();
          expect(manual, isNotEmpty);
          for (final region in manual) {
            expect(_covers(maskedBounds, region.bounds), isTrue);
          }
          expect(_covers(manual.first.bounds, maskedBounds), isTrue);
        },
      );
    }

    testWidgets('should drop text scrolled out of a rotated scroll view', (
      tester,
    ) async {
      final boundaryKey = GlobalKey();
      await _pumpPhone(
        tester,
        RepaintBoundary(
          key: boundaryKey,
          child: RotatedBox(
            quarterTurns: 1,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: const [
                  SizedBox(width: 2000),
                  Text('Off screen guest'),
                ],
              ),
            ),
          ),
        ),
      );

      final result = _detect(boundaryKey, const {AutoMaskedView.text});

      expect(result.maskRegions, isEmpty);
    });
  });
}

const _phoneSize = Size(400, 800);

Future<void> _pumpPhone(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = _phoneSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    Directionality(textDirection: TextDirection.ltr, child: child),
  );
}

MaskDetectionResult _detect(
  GlobalKey boundaryKey,
  Set<AutoMaskedView> autoMaskTypes,
) {
  final boundaryElement = boundaryKey.currentContext! as Element;
  final boundary = boundaryElement.renderObject! as RenderRepaintBoundary;
  return MaskDetector(
    directive: MaskingDirective(autoMaskTypes: autoMaskTypes),
  ).detectMaskRegions(boundary, boundaryElement: boundaryElement);
}

Rect _boundsInBoundary(GlobalKey key, GlobalKey boundaryKey) {
  final box = key.currentContext!.findRenderObject()! as RenderBox;
  final boundary = boundaryKey.currentContext!.findRenderObject()!;
  return MatrixUtils.transformRect(
    box.getTransformTo(boundary),
    Offset.zero & box.size,
  );
}

Matcher _rectCloseTo(Rect expected) => predicate<Rect>(
  (actual) =>
      (actual.left - expected.left).abs() < 0.01 &&
      (actual.top - expected.top).abs() < 0.01 &&
      (actual.right - expected.right).abs() < 0.01 &&
      (actual.bottom - expected.bottom).abs() < 0.01,
  'a rect close to $expected',
);

bool _covers(Rect outer, Rect inner) =>
    outer.inflate(0.01).contains(inner.topLeft) &&
    outer.inflate(0.01).contains(inner.bottomRight);

class _CompatibilityTextRenderObjectWidget extends LeafRenderObjectWidget {
  const _CompatibilityTextRenderObjectWidget();

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderParagraphCompatibilityProxy();
  }
}

class _RenderParagraphCompatibilityProxy extends RenderBox {
  @override
  void performLayout() {
    size = constraints.constrain(const Size(100, 40));
  }
}
