/// Persistence contracts and implementations for saved bank cards.
library;

import 'dart:convert';

import 'bank_card.dart';
import 'platform_stores.dart';

/// Persistence interface for saved payment cards.
abstract class BankCardStore {
  /// Loads all saved bank cards, newest first.
  Future<List<SavedBankCard>> loadCards();

  /// Saves or updates a bank card (deduplicated by PAN).
  Future<void> saveCard(SavedBankCard card);

  /// Removes a card by [id].
  Future<void> deleteCard(String id);
}

/// [BankCardStore] backed by a persistent [PlainStore].
class PlatformBankCardStore implements BankCardStore {
  PlatformBankCardStore({required this.plainStore});

  final PlainStore plainStore;
  static const String storageKey = 'saved_bank_cards';

  @override
  Future<List<SavedBankCard>> loadCards() async {
    final raw = await plainStore.readString(storageKey);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((item) => SavedBankCard.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> saveCard(SavedBankCard card) async {
    final cleanPan = card.cleanPan;
    final current = (await loadCards())
        .where((c) => c.cleanPan != cleanPan && c.id != card.id)
        .toList();
    current.insert(0, card);
    await plainStore.writeString(
      storageKey,
      jsonEncode(current.map((c) => c.toJson()).toList()),
    );
  }

  @override
  Future<void> deleteCard(String id) async {
    final current = (await loadCards()).where((c) => c.id != id).toList();
    await plainStore.writeString(
      storageKey,
      jsonEncode(current.map((c) => c.toJson()).toList()),
    );
  }
}

/// In-memory implementation for tests.
class MemoryBankCardStore implements BankCardStore {
  MemoryBankCardStore([List<SavedBankCard>? initial])
      : _cards = initial != null ? List.of(initial) : [];

  final List<SavedBankCard> _cards;

  @override
  Future<List<SavedBankCard>> loadCards() async => List.unmodifiable(_cards);

  @override
  Future<void> saveCard(SavedBankCard card) async {
    _cards.removeWhere((c) => c.cleanPan == card.cleanPan || c.id == card.id);
    _cards.insert(0, card);
  }

  @override
  Future<void> deleteCard(String id) async {
    _cards.removeWhere((c) => c.id == id);
  }
}
