import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skerdev_e621/services/tag_autocomplete_service.dart';
import 'package:skerdev_e621/widgets/tag_search_bar.dart';

void main() {
  group('TagTokenContext Tests', () {
    test('extracts single partial tag at end of input', () {
      const text = 'drag';
      final ctx = TagTokenContext.extract(text, text.length);

      expect(ctx, isNotNull);
      expect(ctx!.query, 'drag');
      expect(ctx.prefixModifier, '');
      expect(ctx.tokenStart, 0);
      expect(ctx.tokenEnd, 4);

      final updated = ctx.applySuggestion('dragon');
      expect(updated.text, 'dragon ');
      expect(updated.selection.baseOffset, 'dragon '.length);
    });

    test('completes second tag while preserving previous tags', () {
      const text = 'rating:s drag';
      final ctx = TagTokenContext.extract(text, text.length);

      expect(ctx, isNotNull);
      expect(ctx!.query, 'drag');

      final updated = ctx.applySuggestion('dragon');
      expect(updated.text, 'rating:s dragon ');
      expect(updated.selection.baseOffset, 'rating:s dragon '.length);
    });

    test('completes middle tag when cursor is inside middle token', () {
      const text = 'solo drag order:score';
      // Cursor right after "drag" (index 9)
      final ctx = TagTokenContext.extract(text, 9);

      expect(ctx, isNotNull);
      expect(ctx!.query, 'drag');

      final updated = ctx.applySuggestion('dragon');
      expect(updated.text, 'solo dragon order:score');
      // Cursor placed after "dragon "
      expect(updated.selection.baseOffset, 'solo dragon '.length);
    });

    test('preserves negation (-) and OR (~) modifiers when completing tag', () {
      const negText = 'dragon -fer';
      final negCtx = TagTokenContext.extract(negText, negText.length);
      expect(negCtx, isNotNull);
      expect(negCtx!.prefixModifier, '-');
      expect(negCtx.query, 'fer');
      expect(negCtx.applySuggestion('feral').text, 'dragon -feral ');

      const orText = '~wolf ~fo';
      final orCtx = TagTokenContext.extract(orText, orText.length);
      expect(orCtx, isNotNull);
      expect(orCtx!.prefixModifier, '~');
      expect(orCtx.query, 'fo');
      expect(orCtx.applySuggestion('fox').text, '~wolf ~fox ');
    });

    test('returns null when cursor is after a trailing space or only modifier is typed', () {
      expect(TagTokenContext.extract('dragon ', 7), isNull);
      expect(TagTokenContext.extract('dragon -', 8), isNull);
      expect(TagTokenContext.extract('', 0), isNull);
    });
  });

  group('TagAutocompleteService Tests', () {
    test('uses /tags/autocomplete.json for 3+ char queries and prioritizes direct matches over aliases', () async {
      Uri? requestedUri;
      final mockClient = MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          jsonEncode([
            {
              'id': 75,
              'name': 'penis',
              'post_count': 2000000,
              'category': 0,
              'antecedent_name': 'dragon_penis',
            },
            {
              'id': 1,
              'name': 'dragon',
              'post_count': 473000,
              'category': 5,
              'antecedent_name': null,
            },
            {
              'id': 340535,
              'name': 'dragon_humanoid',
              'post_count': 9950,
              'category': 5,
              'antecedent_name': null,
            },
          ]),
          200,
        );
      });

      final service = TagAutocompleteService(client: mockClient);
      final results = await service.fetchSuggestions('drag');

      expect(requestedUri, isNotNull);
      expect(requestedUri!.path, '/tags/autocomplete.json');
      expect(requestedUri!.queryParameters['search[name_matches]'], 'drag');

      // Direct prefix matches ('dragon', 'dragon_humanoid') should be sorted before alias match ('penis')
      expect(results.length, 3);
      expect(results[0].name, 'dragon');
      expect(results[0].categoryLabel, 'Species');
      expect(results[0].formattedPostCount, '473k');
      expect(results[1].name, 'dragon_humanoid');
      expect(results[2].name, 'penis');
      expect(results[2].antecedentName, 'dragon_penis');
    });

    test('uses /tags.json fallback for 1-2 character queries', () async {
      Uri? requestedUri;
      final mockClient = MockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'name': 'dragon',
              'post_count': 473000,
              'category': 5,
            },
          ]),
          200,
        );
      });

      final service = TagAutocompleteService(client: mockClient);
      final results = await service.fetchSuggestions('dr');

      expect(requestedUri, isNotNull);
      expect(requestedUri!.path, '/tags.json');
      expect(requestedUri!.queryParameters['search[name_matches]'], 'dr*');
      expect(results.first.name, 'dragon');
    });

    test('returns built-in metatag suggestions for metatag prefixes like order:', () async {
      bool networkCalled = false;
      final mockClient = MockClient((request) async {
        networkCalled = true;
        return http.Response('[]', 200);
      });

      final service = TagAutocompleteService(client: mockClient);
      final results = await service.fetchSuggestions('order:');

      expect(networkCalled, isFalse);
      expect(results.map((r) => r.name), containsAll(['order:score', 'order:favcount']));
    });
  });

  group('TagSearchBar Widget Tests', () {
    testWidgets('shows suggestions as user types and completes tag on tap', (WidgetTester tester) async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode([
            {
              'id': 1,
              'name': 'dragon',
              'post_count': 473000,
              'category': 5,
              'antecedent_name': null,
            },
            {
              'id': 2,
              'name': 'dragon_ball',
              'post_count': 9100,
              'category': 3,
              'antecedent_name': null,
            },
          ]),
          200,
        );
      });

      final service = TagAutocompleteService(client: mockClient);
      final controller = TextEditingController();
      String? submittedQuery;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: TagSearchBar(
                controller: controller,
                autocompleteService: service,
                debounceDuration: Duration.zero,
                onSubmitted: (val) => submittedQuery = val,
              ),
            ),
          ),
        ),
      );

      // Focus and type "solo drag"
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'solo drag');
      await tester.pumpAndSettle();

      // Suggestions should appear in the overlay
      expect(find.text('Species'), findsOneWidget);
      expect(find.text('Copyright'), findsOneWidget);
      expect(find.text('473k'), findsOneWidget);

      // Tap the "Species" / "dragon" suggestion row
      await tester.tap(find.text('473k'));
      await tester.pumpAndSettle();

      // Controller text should have completed "drag" -> "dragon " while preserving "solo "
      expect(controller.text, 'solo dragon ');
      expect(submittedQuery, isNull);
    });
  });
}
