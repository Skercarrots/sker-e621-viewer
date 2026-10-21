import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/post_model.dart';

class DownloadResult {
  final bool isSuccess;
  final String? filePath;
  final String? errorMessage;

  const DownloadResult({
    required this.isSuccess,
    this.filePath,
    this.errorMessage,
  });
}

class DownloadService {
  /// Resolves the best directory to store user-visible downloaded files on the current platform
  static Future<Directory> getDestinationDirectory() async {
    if (Platform.isAndroid) {
      // Primary Android user-visible Download folder
      final androidDownload = Directory('/storage/emulated/0/Download');
      if (await androidDownload.exists()) {
        return androidDownload;
      }
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) return extDir;
      } catch (_) {}
    }

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null && await downloadsDir.exists()) {
          return downloadsDir;
        }
      } catch (_) {}

      if (Platform.isWindows) {
        final userProfile = Platform.environment['USERPROFILE'];
        if (userProfile != null) {
          final winDownloads = Directory('$userProfile\\Downloads');
          if (await winDownloads.exists()) return winDownloads;
        }
      }
    }

    // Default cross-platform fallback
    return await getApplicationDocumentsDirectory();
  }

  /// Downloads an art file and saves it locally
  static Future<DownloadResult> downloadPost(
    E621Post post, {
    Map<String, String>? authHeaders,
    http.Client? client,
  }) async {
    final downloadUrl = post.fileUrl ?? post.previewUrl;
    if (downloadUrl == null || downloadUrl.isEmpty) {
      return const DownloadResult(
        isSuccess: false,
        errorMessage: 'No downloadable file URL available for this post.',
      );
    }

    final ext = post.extension.isNotEmpty ? post.extension : 'jpg';
    final fileName = 'e621_${post.id}.$ext';

    final httpClient = client ?? http.Client();
    try {
      final uri = Uri.parse(downloadUrl);
      final response = await httpClient.get(uri, headers: authHeaders);

      if (response.statusCode != 200) {
        return DownloadResult(
          isSuccess: false,
          errorMessage: 'Server returned HTTP ${response.statusCode}',
        );
      }

      final dir = await getDestinationDirectory();
      final filePath = '${dir.path}${Platform.pathSeparator}$fileName';
      final file = File(filePath);

      await file.writeAsBytes(response.bodyBytes);

      return DownloadResult(
        isSuccess: true,
        filePath: filePath,
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
    final ext = post.extension.isNotEmpty ? post.extension : 'jpg';
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
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: Colors.green[800],
          content: Row(
            children: [
              const Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Saved $fileName to Downloads!'),
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

