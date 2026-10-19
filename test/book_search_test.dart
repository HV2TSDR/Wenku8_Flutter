import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenku8_flutter/book_search.dart';
import 'package:wenku8_flutter/catalog.dart';
import 'package:wenku8_flutter/library_search_repository.dart';
import 'package:wenku8_flutter/library_state.dart';
import 'package:wenku8_flutter/local_books.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  bool matches(String query) => BookSearch(query).matches(
    title: 'Sword Art Online 刀剑・神域 ２',
    author: '川原 砾',
    tags: '校园 冒险 科幻',
    id: '123',
  );
  test(
    'metadata partial matching handles author, tags, width, punctuation and multiple words',
    () {
      for (final query in [
        '川原',
        '校园',
        'ｓｗｏｒｄ',
        'ＳＡＯ',
        '刀剑神域',
        '神域2',
        '川原 冒险',
        '#校园 川原',
        '１２３',
        '',
      ]) {
        expect(matches(query), query != 'ＳＡＯ', reason: query);
      }
      expect(matches('#刀剑'), false);
      expect(matches('川原 魔法'), false);
      expect(matches('#'), false);
    },
  );
  test(
    'scoped shelf search includes known metadata tags without searching outside the shelf',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      const book = Novel(
        id: 71,
        title: '刀剑・神域',
        author: '川原砾',
        genre: '校园 冒险',
        summary: '',
        colors: [Colors.grey, Colors.black],
      );
      await state.setShelfMembership(book.id, true, novel: book);
      final repository = LibrarySearchRepository(
        source: const DemoNovelRepository(),
        state: state,
      );
      expect((await repository.search('川原 #校园')).single.id, 71);
      expect((await repository.search('刀剑神域')).single.id, 71);
      expect(await repository.search('不存在的标签'), isEmpty);
    },
  );
  test(
    'local search and classified lists share category and multi-keyword matching',
    () async {
      SharedPreferences.setMockInitialValues({});
      final state = await LibraryState.load();
      addTearDown(state.dispose);
      final directory = await Directory.systemTemp.createTemp('wenku-search-');
      addTearDown(() => directory.delete(recursive: true));
      final store = LocalBookStore(directory);
      addTearDown(store.dispose);
      final bytes = utf8.encode('第一章\n风掠过书页。');
      final book = await store.import(LocalBookInput('银河档案.txt', bytes));
      final organization = state.organization;
      final category = await organization.addGroup('星际科幻');
      await organization.assign(book.id, category);
      final repository = LibrarySearchRepository(
        source: const DemoNovelRepository(),
        state: state,
        local: store,
        localOnly: true,
      );
      expect((await repository.search('银河 #科幻')).single.id, book.id);
      expect(
        organization.filter(store.books, query: '银河 #科幻').single.id,
        book.id,
      );
      expect(await repository.search('#校园'), isEmpty);
      await organization.renameGroup(category, '太空旅行');
      expect(await repository.search('#科幻'), isEmpty);
      expect((await repository.search('#旅行')).single.id, book.id);
    },
  );
}
