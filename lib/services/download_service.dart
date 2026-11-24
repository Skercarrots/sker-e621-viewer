import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/post_model.dart';

class DownloadResult {
  final bool isSuccess;
  final String? filePath;
  final String? locationLabel;
  final String? errorMessage;

  const DownloadResult({
    required this.isSuccess,
    this.filePath,
    this.locationLabel,
    this.errorMessage,
  });
}

class DownloadService {
  static const String _defaultUserAgent = 'SkerE621/1.0 (by anonymous on e621)';

  static Map<String, String> _safeMediaHeaders(Map<String, String>? authHeaders) {
    final ua = authHeaders?['User-Agent']?.trim();
    return {
      'User-Agent': (ua != null && ua.isNotEmpty) ? ua : _defaultUserAgent,
    };
  }

  static String _resolveExtension(E621Post post, String downloadUrl) {
    String rawExt = '';
    final usingFallbackPreview = post.fileUrl == null || post.fileUrl!.isEmpty;
    if (usingFallbackPreview) {
      final uri = Uri.tryParse(downloadUrl);
      if (uri != null && uri.pathSegments.isNotEmpty) {
        final last = uri.pathSegments.last;
        final dot = last.lastIndexOf('.');
        if (dot != -1 && dot < last.length - 1) {
          rawExt = last.substring(dot + 1);
        }
      }
    } else {
      rawExt = post.extension;
    }
    final sanitized = rawExt.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return sanitized.isNotEmpty ? sanitized : 'jpg';
  }

  /// Resolves candidate directories to store downloaded files on the current platform.
  static Future<List<(Directory dir, String label)>> _candidateDirectories() async {
    final candidates = <(Directory, String)>[];

    if (Platform.isAndroid) {
      final androidDownload = Directory('/storage/emulated/0/Download');
      if (await androidDownload.exists()) {
        candidates.add((androidDownload, 'Downloads'));
      }
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          candidates.add((extDir, 'app external storage'));
        }
      } catch (_) {}
    }

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null && await downloadsDir.exists()) {
          candidates.add((downloadsDir, 'Downloads'));
        }
      } catch (_) {}

      if (Platform.isWindows) {
        final userProfile = Platform.environment['USERPROFILE'];
        if (userProfile != null) {
          final winDownloads = Directory('$userProfile\\Downloads');
          if (await winDownloads.exists()) {
            candidates.add((winDownloads, 'Downloads'));
          }
        }
      }
    }

    final docsDir = await getApplicationDocumentsDirectory();
    candidates.add((docsDir, 'Documents'));
    return candidates;
  }

  /// Resolves the best directory to store user-visible downloaded files on the current platform
  static Future<Directory> getDestinationDirectory() async {
    final candidates = await _candidateDirectories();
    return candidates.first.$1;
  }

  /// Downloads an art file and saves it locally by streaming directly to disk.
  static Future<DownloadResult> downloadPost(
    E621Post post, {
    Map<String, String>? authHeaders,
    http.Client? client,
  }) async {
    final downloadUrl = (post.fileUrl != null && post.fileUrl!.isNotEmpty)
        ? post.fileUrl
        : post.previewUrl;
    if (downloadUrl == null || downloadUrl.isEmpty) {
      return const DownloadResult(
        isSuccess: false,
        errorMessage: 'No downloadable file URL available for this post.',
      );
    }

    final ext = _resolveExtension(post, downloadUrl);
    final fileName = 'e621_${post.id}.$ext';
    final safeHeaders = _safeMediaHeaders(authHeaders);

    final httpClient = client ?? http.Client();
    try {
      final uri = Uri.parse(downloadUrl);
      final request = http.Request('GET', uri)..headers.addAll(safeHeaders);
      final streamedResponse = await httpClient.send(request);

      if (streamedResponse.statusCode != 200) {
        await streamedResponse.stream.drain<void>();
        return DownloadResult(
          isSuccess: false,
          errorMessage: 'Server returned HTTP ${streamedResponse.statusCode}',
        );
      }

      final candidates = await _candidateDirectories();
      File? writableFile;
      String? locationLabel;
      IOSink? sink;
      Object? lastFsError;

      for (final (dir, label) in candidates) {
        final filePath = '${dir.path}${Platform.pathSeparator}$fileName';
        final candidateFile = File(filePath);
        try {
          sink = candidateFile.openWrite();
          writableFile = candidateFile;
          locationLabel = label;
          break;
        } on FileSystemException catch (e) {
          lastFsError = e;
        }
      }

      if (sink == null || writableFile == null) {
        await streamedResponse.stream.drain<void>();
        return DownloadResult(
          isSuccess: false,
          errorMessage: lastFsError?.toString() ?? 'Could not open destination file.',
        );
      }

      try {
        await streamedResponse.stream.pipe(sink);
      } on FileSystemException catch (e) {
        try {
          await sink.close();
        } catch (_) {}
        return DownloadResult(
          isSuccess: false,
          errorMessage: e.toString(),
        );
      }

      return DownloadResult(
        isSuccess: true,
        filePath: writableFile.path,
        locationLabel: locationLabel ?? 'Downloads',
      );
    } catch (e) {
      return DownloadResult(
        isSuccess: false,
        errorMessage: e.toString(),
      );
    } finally {
      if (client == null) {
        httpClient.close();
      }
    }
  }

  /// High-level download trigger with UI notifications and error handling
  static Future<void> downloadWithFeedback(
    BuildContext context,
    E621Post post, {
    Map<String, String>? authHeaders,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final downloadUrl = (post.fileUrl != null && post.fileUrl!.isNotEmpty)
        ? post.fileUrl!
        : (post.previewUrl ?? '');
    final ext = _resolveExtension(post, downloadUrl);
    final fileName = 'e621_${post.id}.$ext';

    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text('Downloading $fileName...')),
          ],
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    final result = await downloadPost(post, authHeaders: authHeaders);

    if (!context.mounted) return;

    messenger.hideCurrentSnackBar();

    if (result.isSuccess) {
      final location = result.locationLabel ?? 'Downloads';
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: Colors.green[800],
          content: Row(
            children: [
              const Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Saved $fileName to $location!'),
              ),
            ],
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: Colors.red[800],
          content: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Download failed: ${result.errorMessage ?? "Unknown error"}'),
              ),
            ],
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }
}

