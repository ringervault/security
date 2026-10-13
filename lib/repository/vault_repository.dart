import 'package:flutter/foundation.dart';
import 'package:ringer_vault/autofill/suggest.dart';
import 'package:ringer_vault/models/vault_entry.dart';
import 'package:ringer_vault/repository/decoy_seed.dart';
import 'package:ringer_vault/services/storage_service.dart';
import 'package:ringer_vault/services/activity_log_service.dart';
import 'package:ringer_vault/services/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:math';

class VaultRepository {
  final StorageService _storageService = StorageService();
  final ActivityLogService _activityLog = ActivityLogService(); // Add ActivityLogService

  /// Category lists are per vault, and kept inside it (StorageService's
  /// vault metadata): a category name ("Offshore", "Crypto") says something
  /// about what is in the vault, and a second list beside the first says
  /// there is a second vault. They used to be in the app's preferences, in
  /// the clear, under a name ending "_decoy" for the decoy's; [_stored]
  /// moves them in the first time each vault reads them.
  static const String _customCategoriesKey = 'custom_categories';
  static const String _dashboardCategoriesKey = 'dashboard_categories';

  Future<List<String>?> _stored(String key) async {
    final inVault = _storageService.metaStrings(key);
    if (inVault != null) return inVault;
    final prefs = await SharedPreferences.getInstance();
    final old = AuthService().isDecoyMode ? '${key}_decoy' : key;
    final moved = prefs.getStringList(old);
    if (moved == null || !_storageService.isReady) return moved;
    await _storageService.setMetaStrings(key, moved);
    await prefs.remove(old);
    return moved;
  }

  Future<void> _store(String key, List<String> value) =>
      _storageService.setMetaStrings(key, value);

  Future<List<String>> getDashboardCategories() async {
    final list = await _stored(_dashboardCategoriesKey);
    if (list != null && list.isNotEmpty) return list;
    return ['Banking', 'Social', 'Email']; // Defaults
  }

  Future<void> rotateDashboardCategory(String category) async {
    List<String> list = await _stored(_dashboardCategoriesKey) ?? ['Banking', 'Social', 'Email'];
    
    // If already exists, move to end? Or just ignore?
    // "1st one should disappear, 2nd move to 1st". FIFO.
    // Ensure we keep exactly 3.
    if (list.contains(category)) {
      list.remove(category);
      list.add(category); // Move to end
    } else {
      if (list.length >= 3) {
        list.removeAt(0); // Remove 1st
      }
      list.add(category); // Add to end (3rd place)
    }
    
    await _store(_dashboardCategoriesKey, list);
  }

  List<VaultEntry> getAllEntries() {
    return _storageService.getEntries();
  }

  List<VaultEntry> searchEntries(String query) {
    if (query.isEmpty) return getAllEntries();
    
    final lowerQuery = query.toLowerCase();
    return _storageService.getEntries().where((entry) {
      return entry.title.toLowerCase().contains(lowerQuery) ||
             entry.username.toLowerCase().contains(lowerQuery) ||
             entry.email.toLowerCase().contains(lowerQuery) ||
             entry.category.toLowerCase().contains(lowerQuery) ||
             // Names of the secrets, never their values: searching for "TPIN"
             // should find the card that has one, and no search must ever be
             // able to confirm a guess at a password.
             entry.searchableLabels.toLowerCase().contains(lowerQuery) ||
             (entry.notes?.toLowerCase().contains(lowerQuery) ?? false) ||
             // The websites and apps it is linked to: "amazon.in", or a
             // whole address pasted from the browser.
             linkedPlaces(entry).any((p) => p.toLowerCase().contains(lowerQuery)) ||
             sameSiteAs(entry, query);
    }).toList();
  }

  // Adding, editing and deleting work the same in the decoy as in the real
  // vault, and save into the decoy's own slot. The decoy used to refuse every
  // edit with an error the real vault never shows, which told whoever was
  // looking that the vault was not the real one. Nothing written here leaves
  // the decoy: sync refuses to run in it (SyncService.unavailableReason), and
  // its deletions are not kept as tombstones (StorageService.deleteEntry).

  Future<void> addEntry(VaultEntry entry) async {
    await _storageService.addEntry(entry);
    await _activityLog.logActivity(
      action: 'Entry Added',
      details: '${entry.category}: ${entry.title}',
    );
  }

  Future<void> updateEntry(VaultEntry entry) async {
    await _storageService.updateEntry(entry);
    await _activityLog.logActivity(
      action: 'Entry Updated',
      details: '${entry.category}: ${entry.title}',
    );
  }

  Future<void> deleteEntry(String id) async {
    // We need to fetch the entry first to log its details before deleting?
    // StorageService.deleteEntry just takes ID.
    // Let's try to find it first.
    final entries = _storageService.getEntries();
    final entry = entries.firstWhere((e) => e.id == id, orElse: () => VaultEntry(id: '?', title: 'Unknown', username: '', password: '', category: '', createdAt: DateTime.now(), updatedAt: DateTime.now()));
    
    await _storageService.deleteEntry(id);
    await _activityLog.logActivity(
      action: 'Entry Deleted',
      details: '${entry.category}: ${entry.title}',
    );
  }
  
  /// Where older versions kept the name and email a new decoy's filler
  /// should carry, until the decoy was first opened. A decoy is now filled
  /// the moment it is created (AuthService.fillNewDecoy), so these are only
  /// read once, for a decoy made before that, and then removed: their being
  /// there at all said a decoy existed.
  static const String _oldDecoyNameKey = 'profile_display_name';
  static const String _oldDecoyEmailKey = 'profile_display_email';

  Future<DecoyIdentity> _takeOldDecoyIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    final identity = DecoyIdentity(
      name: prefs.getString(_oldDecoyNameKey) ?? '',
      email: prefs.getString(_oldDecoyEmailKey) ?? '',
    );
    await prefs.remove(_oldDecoyNameKey);
    await prefs.remove(_oldDecoyEmailKey);
    return identity;
  }

  /// Fills an empty decoy vault the first time it is opened: one made before
  /// decoys were filled at creation.
  ///
  /// The filler used to read "Social Account 1 / user584 / password2890",
  /// which announces itself as generated the moment anyone looks. A decoy
  /// that is not believed is worse than no decoy: it tells the person holding
  /// the phone that there is a real vault to keep asking for.
  Future<void> checkAndPopulateDecoy() async {
    if (!AuthService().isDecoyMode) return;
    final identity = await _takeOldDecoyIdentity();
    if (_storageService.getEntries().isNotEmpty) return;

    for (final entry in buildDecoyEntries(identity, Random.secure())) {
      await _storageService.addEntry(entry);
    }
  }

  // Standard Categories for consistency
  static const List<Map<String, dynamic>> defaultCategories = [
    {'name': 'Social', 'icon': 0xe491}, // Icons.people_outline code point? No, better to store string or handle icons in UI mapping.
    // Simplifying: Store simplified map and use UI helper for Icons.
  ];
  
  // Actually, icons are UI concern. Current implementation in CategoryListScreen uses Icons.people_outline.
  // Best to just list names here and map in UI.
  static const List<String> defaultCategoryNames = ['Social', 'Banking', 'Work', 'Entertainment', 'Email', 'Utility'];

  /// Changes whenever the open vault does.
  ValueListenable<int> listenable() => _storageService.listenable();

  List<VaultEntry> getEntriesByCategory(String category) {
    return _storageService.getEntries().where((entry) => entry.category == category).toList();
  }

  List<VaultEntry> getRecentEntries(int limit) {
    final entries = _storageService.getEntries();
    // Sort by Last Updated (Modified/Opened logic if opened updates updatedAt)
    // Assuming updatedAt represents modification.
    entries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return entries.take(limit).toList();
  }

  // Custom Categories
  Future<List<String>> getCustomCategories() async {
    return await _stored(_customCategoriesKey) ?? [];
  }

  Future<bool> addCustomCategory(String category) async {
    final categories = [...?await _stored(_customCategoriesKey)];
    
    // Case-insensitive duplicate check
    if (defaultCategoryNames.map((e) => e.toLowerCase()).contains(category.toLowerCase()) || 
        categories.map((e) => e.toLowerCase()).contains(category.toLowerCase())) {
      return false; // Already exists
    }

    categories.add(category);
    await _store(_customCategoriesKey, categories);
    await _activityLog.logActivity(
      action: 'Category Created',
      details: category,
    );
    return true;
  }

  Future<bool> renameCustomCategory(String oldName, String newName) async {
    final categories = [...?await _stored(_customCategoriesKey)];

    if (!categories.contains(oldName)) return false; // Old category not found

    // Check if new name exists
    if (defaultCategoryNames.map((e) => e.toLowerCase()).contains(newName.toLowerCase()) || 
        categories.map((e) => e.toLowerCase()).contains(newName.toLowerCase())) {
      return false; // New name already taken
    }

    // 1. Update List
    final index = categories.indexOf(oldName);
    categories[index] = newName;
    await _store(_customCategoriesKey, categories);

    // 2. Update Entries
    final entries = _storageService.getEntries().where((e) => e.category == oldName).toList();
    for (var entry in entries) {
      // Use copyWith to create updated entry
      final updatedEntry = entry.copyWith(category: newName);
      // We must preserve other fields exactly. copyWith handles ID preservation if implemented correctly.
      // Checking copyWith implementation in VaultEntry...
      // It sets updatedAt to Now. That's probably fine/desired for a rename.
      await _storageService.updateEntry(updatedEntry);
    }
    
    await _activityLog.logActivity(
      action: 'Category Renamed',
      details: '$oldName -> $newName',
    );
    
    return true;
  }

  Map<String, int> getCategoryCounts() {
    final entries = _storageService.getEntries();
    final Map<String, int> counts = {};
    
    // Initialize defaults
    for (var cat in defaultCategoryNames) {
      counts[cat] = 0;
    }

    // Counts from entries
    for (var entry in entries) {
      counts[entry.category] = (counts[entry.category] ?? 0) + 1;
    }
    return counts;
  }
}
