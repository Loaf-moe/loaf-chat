import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/models.dart';

Member _member(String name) => Member('@x:loaf.test', name, Colors.blue);
Space _space(String name) => Space(id: '!x', name: name, color: Colors.blue);

void main() {
  // Names come from the server now, and anyone can set theirs to a space.
  group('a name with nothing in it still has initials', () {
    for (final name in ['', '   ']) {
      test('a member named "$name"', () {
        expect(_member(name).initials, '?');
      });
      test('a space named "$name"', () {
        expect(_space(name).initials, '?');
      });
    }
  });

  test('initials are unchanged for real names', () {
    expect(_member('ada lovelace').initials, 'AL');
    expect(_member(' sam ').initials, 'S');
    expect(_space('loaf bakery club').initials, 'LB');
    expect(_space('annex').initials, 'A');
  });
}
