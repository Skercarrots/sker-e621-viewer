import '../models/board_model.dart';
import '../models/collection_model.dart';
import '../models/favorite_tags_model.dart';
import '../models/post_model.dart';
import '../models/ref_board_model.dart';

enum BackupImportMode { merge, replace }

enum BackupFormatErrorType {
  invalidFormat,
  unsupportedVersion,
  passwordRequired,
  passwordRequiredForCredentials,
  wrongPasswordOrCorrupted,
  checksumMismatch,
  payloadTooLarge,
}

class BackupFormatException implements Exception {
  final BackupFormatErrorType type;
  final String message;

  const BackupFormatException(this.type, this.message);

  @override
  String toString() => 'BackupFormatException($type): $message';
}

/// Category toggles used by both Export and Import flows.
class BackupCategorySelection {
  final bool boards;
  final bool refBoards;
  final bool favoriteTags;
  final bool follows;
  final bool guestFavorites;
  final bool blacklist;
  final bool preferences;
  final bool credentials;

  const BackupCategorySelection({
    this.boards = true,
    this.refBoards = true,
    this.favoriteTags = true,
    this.follows = true,
    this.guestFavorites = true,
    this.blacklist = true,
    this.preferences = true,
    this.credentials = false,
  });

  bool get hasAnySelected =>
      boards ||
      refBoards ||
      favoriteTags ||
      follows ||
      guestFavorites ||
      blacklist ||
      preferences ||
      credentials;

  BackupCategorySelection copyWith({
    bool? boards,
    bool? refBoards,
    bool? favoriteTags,
    bool? follows,
    bool? guestFavorites,
    bool? blacklist,
    bool? preferences,
    bool? credentials,
  }) {
    return BackupCategorySelection(
      boards: boards ?? this.boards,
      refBoards: refBoards ?? this.refBoards,
      favoriteTags: favoriteTags ?? this.favoriteTags,
      follows: follows ?? this.follows,
      guestFavorites: guestFavorites ?? this.guestFavorites,
      blacklist: blacklist ?? this.blacklist,
      preferences: preferences ?? this.preferences,
      credentials: credentials ?? this.credentials,
    );
  }
}

/// Unencrypted header of a `.skerbackup` envelope.
class BackupEnvelopeHeader {
  final String magic;
  final int formatVersion;
  final int schemaVersion;
  final String appVersion;
  final DateTime exportedAt;
  final bool encrypted;
  final String? kdfAlgorithm;
  final int? kdfIterations;
  final String? kdfSaltBase64;
  final String? cipherAlgorithm;
  final String? cipherNonceBase64;
  final String? cipherMacBase64;
  final String checksumSha256;
  final String payloadBase64;

  const BackupEnvelopeHeader({
    required this.magic,
    required this.formatVersion,
    required this.schemaVersion,
    required this.appVersion,
    required this.exportedAt,
    required this.encrypted,
    this.kdfAlgorithm,
    this.kdfIterations,
    this.kdfSaltBase64,
    this.cipherAlgorithm,
    this.cipherNonceBase64,
    this.cipherMacBase64,
    required this.checksumSha256,
    required this.payloadBase64,
  });
}

class BlacklistBackupData {
  final String rawTags;
  final bool isEnabled;
  final bool blacklistPoolPosts;
  final bool hideBlacklistedPools;
  final bool hideEmptyCollections;

  const BlacklistBackupData({
    required this.rawTags,
    required this.isEnabled,
    required this.blacklistPoolPosts,
    required this.hideBlacklistedPools,
    required this.hideEmptyCollections,
  });

  int get ruleCount => rawTags
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .length;

  Map<String, dynamic> toJson() => {
        'rawTags': rawTags,
        'isEnabled': isEnabled,
        'blacklistPoolPosts': blacklistPoolPosts,
        'hideBlacklistedPools': hideBlacklistedPools,
        'hideEmptyCollections': hideEmptyCollections,
      };

  factory BlacklistBackupData.fromJson(Map<String, dynamic> json) {
    return BlacklistBackupData(
      rawTags: json['rawTags']?.toString() ?? '',
      isEnabled: json['isEnabled'] != false,
      blacklistPoolPosts: json['blacklistPoolPosts'] == true,
      hideBlacklistedPools: json['hideBlacklistedPools'] == true,
      hideEmptyCollections: json['hideEmptyCollections'] != false,
    );
  }
}

class PreferencesBackupData {
  final String siteHost;
  final bool isOver18Verified;
  final bool isGuestMode;
  final bool? artistModeEnabled;

  const PreferencesBackupData({
    required this.siteHost,
    required this.isOver18Verified,
    required this.isGuestMode,
    this.artistModeEnabled,
  });

  Map<String, dynamic> toJson() => {
        'siteHost': siteHost,
        'isOver18Verified': isOver18Verified,
        'isGuestMode': isGuestMode,
        if (artistModeEnabled != null) 'artistModeEnabled': artistModeEnabled,
      };

  factory PreferencesBackupData.fromJson(Map<String, dynamic> json) {
    return PreferencesBackupData(
      siteHost: json['siteHost']?.toString() ?? 'e926.net',
      isOver18Verified: json['isOver18Verified'] == true,
      isGuestMode: json['isGuestMode'] == true,
      artistModeEnabled: json['artistModeEnabled'] is bool
          ? json['artistModeEnabled'] as bool
          : null,
    );
  }
}

class CredentialsBackupData {
  final String username;
  final String apiKey;
  final String? userProfileJson;

  const CredentialsBackupData({
    required this.username,
    required this.apiKey,
    this.userProfileJson,
  });

  Map<String, dynamic> toJson() => {
        'username': username,
        'apiKey': apiKey,
        if (userProfileJson != null) 'userProfileJson': userProfileJson,
      };

  factory CredentialsBackupData.fromJson(Map<String, dynamic> json) {
    return CredentialsBackupData(
      username: json['username']?.toString() ?? '',
      apiKey: json['apiKey']?.toString() ?? '',
      userProfileJson: json['userProfileJson']?.toString(),
    );
  }
}

/// Complete decoded backup payload ready for preview or import.
class AppBackupPayload {
  final int schemaVersion;
  final String appVersion;
  final DateTime exportedAt;
  final List<Board>? boards;
  final List<RefBoard>? refBoards;
  final List<FavoriteTag>? favoriteTags;
  final List<FavoriteTagSet>? favoriteTagSets;
  final Map<String, List<FollowedCollection>>? followsByNamespace;
  final List<E621Post>? guestFavorites;
  final BlacklistBackupData? blacklist;
  final PreferencesBackupData? preferences;
  final CredentialsBackupData? credentials;

  const AppBackupPayload({
    required this.schemaVersion,
    required this.appVersion,
    required this.exportedAt,
    this.boards,
    this.refBoards,
    this.favoriteTags,
    this.favoriteTagSets,
    this.followsByNamespace,
    this.guestFavorites,
    this.blacklist,
    this.preferences,
    this.credentials,
  });

  int get boardCount => boards?.length ?? 0;
  int get refBoardCount => refBoards?.length ?? 0;
  int get favoriteTagCount => favoriteTags?.length ?? 0;
  int get favoriteTagSetCount => favoriteTagSets?.length ?? 0;
  int get followCount =>
      followsByNamespace?.values.fold<int>(0, (s, list) => s + list.length) ?? 0;
  int get guestFavoriteCount => guestFavorites?.length ?? 0;
  int get blacklistRuleCount => blacklist?.ruleCount ?? 0;
  bool get hasBlacklist => blacklist != null;
  bool get hasPreferences => preferences != null;
  bool get hasCredentials =>
      credentials != null &&
      credentials!.username.isNotEmpty &&
      credentials!.apiKey.isNotEmpty;

  bool get hasBoardsSection => boards != null;
  bool get hasRefBoardsSection => refBoards != null;
  bool get hasFavoriteTagsSection =>
      favoriteTags != null || favoriteTagSets != null;
  bool get hasFollowsSection => followsByNamespace != null;
  bool get hasGuestFavoritesSection => guestFavorites != null;

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'appVersion': appVersion,
      'exportedAt': exportedAt.toIso8601String(),
      if (boards != null)
        'boards': boards!.map((b) => b.toJson()).toList(),
      if (refBoards != null)
        'refBoards': refBoards!.map((b) => b.toJson()).toList(),
      if (favoriteTags != null)
        'favoriteTags': favoriteTags!.map((t) => t.toJson()).toList(),
      if (favoriteTagSets != null)
        'favoriteTagSets': favoriteTagSets!.map((s) => s.toJson()).toList(),
      if (followsByNamespace != null)
        'followsByNamespace': {
          for (final entry in followsByNamespace!.entries)
            entry.key: entry.value.map((f) => f.toJson()).toList(),
        },
      if (guestFavorites != null)
        'guestFavorites': guestFavorites!.map((p) => p.toJson()).toList(),
      if (blacklist != null) 'blacklist': blacklist!.toJson(),
      if (preferences != null) 'preferences': preferences!.toJson(),
      if (credentials != null) 'credentials': credentials!.toJson(),
    };
  }

  factory AppBackupPayload.fromJson(Map<String, dynamic> json) {
    List<Board>? parsedBoards;
    if (json['boards'] is List) {
      parsedBoards = (json['boards'] as List)
          .whereType<Map<String, dynamic>>()
          .map((e) => Board.fromJson(e))
          .toList();
    }

    List<RefBoard>? parsedRefBoards;
    if (json['refBoards'] is List) {
      parsedRefBoards = (json['refBoards'] as List)
          .whereType<Map<String, dynamic>>()
          .map((e) => RefBoard.fromJson(e))
          .toList();
    }

    List<FavoriteTag>? parsedFavTags;
    if (json['favoriteTags'] is List) {
      parsedFavTags = (json['favoriteTags'] as List)
          .whereType<Map<String, dynamic>>()
          .map((e) => FavoriteTag.fromJson(e))
          .where((t) => t.name.isNotEmpty)
          .toList();
    }

    List<FavoriteTagSet>? parsedFavSets;
    if (json['favoriteTagSets'] is List) {
      parsedFavSets = (json['favoriteTagSets'] as List)
          .whereType<Map<String, dynamic>>()
          .map((e) => FavoriteTagSet.fromJson(e))
          .where((s) => s.id.isNotEmpty && s.name.isNotEmpty)
          .toList();
    }

    Map<String, List<FollowedCollection>>? parsedFollows;
    if (json['followsByNamespace'] is Map) {
      parsedFollows = {};
      for (final entry in (json['followsByNamespace'] as Map).entries) {
        final key = entry.key.toString();
        if (entry.value is List) {
          parsedFollows[key] = (entry.value as List)
              .whereType<Map<String, dynamic>>()
              .map((e) => FollowedCollection.fromJson(e))
              .toList();
        }
      }
    }

    List<E621Post>? parsedGuestFavs;
    if (json['guestFavorites'] is List) {
      parsedGuestFavs = (json['guestFavorites'] as List)
          .whereType<Map<String, dynamic>>()
          .map((e) => E621Post.fromLocalJson(e))
          .toList();
    }

    BlacklistBackupData? parsedBlacklist;
    if (json['blacklist'] is Map<String, dynamic>) {
      parsedBlacklist = BlacklistBackupData.fromJson(
        json['blacklist'] as Map<String, dynamic>,
      );
    }

    PreferencesBackupData? parsedPrefs;
    if (json['preferences'] is Map<String, dynamic>) {
      parsedPrefs = PreferencesBackupData.fromJson(
        json['preferences'] as Map<String, dynamic>,
      );
    }

    CredentialsBackupData? parsedCreds;
    if (json['credentials'] is Map<String, dynamic>) {
      parsedCreds = CredentialsBackupData.fromJson(
        json['credentials'] as Map<String, dynamic>,
      );
    }

    return AppBackupPayload(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 1,
      appVersion: json['appVersion']?.toString() ?? '1.0.0+1',
      exportedAt: DateTime.tryParse(json['exportedAt']?.toString() ?? '') ??
          DateTime.now(),
      boards: parsedBoards,
      refBoards: parsedRefBoards,
      favoriteTags: parsedFavTags,
      favoriteTagSets: parsedFavSets,
      followsByNamespace: parsedFollows,
      guestFavorites: parsedGuestFavs,
      blacklist: parsedBlacklist,
      preferences: parsedPrefs,
      credentials: parsedCreds,
    );
  }
}

class BackupImportSummary {
  final BackupImportMode mode;
  final int boardsCount;
  final int refBoardsCount;
  final int favoriteTagsCount;
  final int favoriteTagSetsCount;
  final int followsCount;
  final int guestFavoritesCount;
  final int blacklistRulesAddedOrApplied;
  final bool preferencesApplied;
  final bool credentialsImported;
  final String? preImportSnapshotId;

  const BackupImportSummary({
    required this.mode,
    this.boardsCount = 0,
    this.refBoardsCount = 0,
    this.favoriteTagsCount = 0,
    this.favoriteTagSetsCount = 0,
    this.followsCount = 0,
    this.guestFavoritesCount = 0,
    this.blacklistRulesAddedOrApplied = 0,
    this.preferencesApplied = false,
    this.credentialsImported = false,
    this.preImportSnapshotId,
  });
}
