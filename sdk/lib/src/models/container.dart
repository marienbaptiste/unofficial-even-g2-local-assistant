/// Container models for the EvenHub display system.
///
/// EvenHub allows creating custom page layouts with text, image, and list
/// containers on the G2 glasses display.
///
/// Display resolution: 288x144 pixels.

/// A text container for displaying text content on the glasses.
class TextContainer {
  /// Unique container ID (0-11).
  final int id;

  /// Optional name for event identification.
  final String? name;

  /// X position in pixels.
  final int x;

  /// Y position in pixels.
  final int y;

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Border width in pixels.
  final int borderWidth;

  /// Border color (0 = white, 1 = black).
  final int borderColor;

  /// Border corner radius in pixels.
  final int borderRadius;

  /// Inner padding in pixels.
  final int paddingLength;

  /// Text content to display.
  final String? content;

  /// Whether this container generates touch events.
  final bool captureEvents;

  TextContainer({
    required this.id,
    this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.borderWidth = 0,
    this.borderColor = 0,
    this.borderRadius = 0,
    this.paddingLength = 0,
    this.content,
    this.captureEvents = false,
  });

  @override
  String toString() => 'TextContainer(id=$id, ${name ?? ""} ${x}x$y ${width}x$height)';
}

/// An image container for displaying bitmap data on the glasses.
class ImageContainer {
  /// Unique container ID (0-11).
  final int id;

  /// Optional name for event identification.
  final String? name;

  /// X position in pixels.
  final int x;

  /// Y position in pixels.
  final int y;

  /// Width in pixels (20-288).
  final int width;

  /// Height in pixels (20-144).
  final int height;

  ImageContainer({
    required this.id,
    this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  })  : assert(width >= 20 && width <= 288, 'Image width must be 20-288, got $width'),
        assert(height >= 20 && height <= 144, 'Image height must be 20-144, got $height');

  @override
  String toString() => 'ImageContainer(id=$id, ${name ?? ""} ${x}x$y ${width}x$height)';
}

/// A scrollable list container for displaying selectable items.
class ListContainer {
  /// Unique container ID (0-11).
  final int id;

  /// Optional name for event identification.
  final String? name;

  /// X position in pixels.
  final int x;

  /// Y position in pixels.
  final int y;

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Border width in pixels.
  final int borderWidth;

  /// Border color (0 = white, 1 = black).
  final int borderColor;

  /// Border corner radius in pixels.
  final int borderRadius;

  /// Inner padding in pixels.
  final int paddingLength;

  /// List of item display names.
  final List<String> itemNames;

  /// Width of each item (null = auto).
  final int? itemWidth;

  /// Whether to show a border around the selected item.
  final bool showSelectionBorder;

  /// Whether this container generates touch events.
  final bool captureEvents;

  ListContainer({
    required this.id,
    this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.borderWidth = 0,
    this.borderColor = 0,
    this.borderRadius = 0,
    this.paddingLength = 0,
    required this.itemNames,
    this.itemWidth,
    this.showSelectionBorder = true,
    this.captureEvents = false,
  });

  @override
  String toString() => 'ListContainer(id=$id, ${name ?? ""} ${itemNames.length} items)';
}

/// A complete page layout for the EvenHub display.
///
/// A page can hold up to 12 containers total, with a maximum of
/// 8 text containers and 4 image containers.
class PageLayout {
  /// Text containers (max 8).
  final List<TextContainer> textContainers;

  /// Image containers (max 4).
  final List<ImageContainer> imageContainers;

  /// List containers.
  final List<ListContainer> listContainers;

  PageLayout({
    this.textContainers = const [],
    this.imageContainers = const [],
    this.listContainers = const [],
  })  : assert(textContainers.length <= 8,
            'Maximum 8 text containers, got ${textContainers.length}'),
        assert(imageContainers.length <= 4,
            'Maximum 4 image containers, got ${imageContainers.length}'),
        assert(
            textContainers.length + imageContainers.length + listContainers.length <= 12,
            'Maximum 12 total containers, got ${textContainers.length + imageContainers.length + listContainers.length}');

  /// Total number of containers in this layout.
  int get containerCount =>
      textContainers.length + imageContainers.length + listContainers.length;

  @override
  String toString() =>
      'PageLayout(${textContainers.length} text, ${imageContainers.length} image, ${listContainers.length} list)';
}
