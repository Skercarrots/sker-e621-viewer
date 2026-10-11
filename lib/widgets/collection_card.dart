import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../models/collection_model.dart';
import '../providers/follows_provider.dart';
import '../pages/collection_detail_page.dart';

class CollectionCard extends StatelessWidget {
  final E621Collection collection;
  final int newCount;
  final VoidCallback? onTap;

  const CollectionCard({
    super.key,
    required this.collection,
    this.newCount = 0,
    this.onTap,
  });

  Color _badgeColor() {
    if (!collection.isPool) return Colors.amberAccent;
    if (collection.category == 'series') return Colors.blueAccent;
    return Colors.purpleAccent;
  }

  String _badgeLabel() {
    if (!collection.isPool) return 'SET';
    if (collection.category == 'series') return 'SERIES';
    if (collection.category == 'collection') return 'COLLECTION';
    return 'POOL';
  }

  @override
  Widget build(BuildContext context) {
    final follows = Provider.of<FollowsProvider>(context);
    final isFollowed = follows.isFollowing(collection.type, collection.id);

    return GestureDetector(
      onTap: onTap ??
          () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => CollectionDetailPage(collection: collection),
              ),
            );
          },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey[800]!, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top: Cover Image
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (collection.coverUrl != null && collection.coverUrl!.isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: collection.coverUrl!,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(color: Colors.grey[800]),
                      errorWidget: (context, url, error) => Container(
                        color: Colors.grey[800],
                        child: const Icon(Icons.broken_image, color: Colors.grey),
                      ),
                    )
                  else
                    Container(
                      color: Colors.grey[800],
                      child: Center(
                        child: Icon(
                          collection.isPool ? Icons.collections_bookmark_outlined : Icons.folder_outlined,
                          size: 40,
                          color: Colors.grey[600],
                        ),
                      ),
                    ),

                  // Top gradient shadow for badge readability
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 48,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black54, Colors.transparent],
                        ),
                      ),
                    ),
                  ),

                  // Category Badge (Top-left)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: _badgeColor().withValues(alpha: 0.8),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        _badgeLabel(),
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                          color: _badgeColor(),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),

                  // Top-Right Badges: New posts indicator (+N) & Follow heart
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (newCount > 0) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '+$newCount',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () async {
                              final nowFollowed = await follows.toggleFollow(collection);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).clearSnackBars();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      nowFollowed
                                          ? 'Following "${collection.displayName}"'
                                          : 'Unfollowed "${collection.displayName}"',
                                    ),
                                    duration: const Duration(seconds: 1),
                                  ),
                                );
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                isFollowed ? Icons.favorite : Icons.favorite_border,
                                size: 18,
                                color: isFollowed ? Colors.redAccent : Colors.white70,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Bottom gradient overlay on cover for title readability
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: 28,
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Colors.black54, Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Bottom: Info (Title & Counts)
            Padding(
              padding: const EdgeInsets.all(10.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    collection.displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13.5,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        '${collection.postCount} ${collection.postCount == 1 ? "art" : "arts"}',
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (collection.creatorName != null &&
                          collection.creatorName!.isNotEmpty) ...[
                        Text(
                          ' • ',
                          style: TextStyle(color: Colors.grey[600], fontSize: 11),
                        ),
                        Expanded(
                          child: Text(
                            collection.creatorName!,
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

