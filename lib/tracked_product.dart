double? _safeDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().replaceAll(',', '.').trim());
}

class StoreOffer {
  final String store;
  double price;
  final double regularPrice;
  final bool isPromo;
  final String url;
  final String availability;
  final bool isOrigin;

  StoreOffer({
    required this.store,
    required this.price,
    required this.regularPrice,
    required this.isPromo,
    required this.url,
    required this.availability,
    required this.isOrigin,
  });

  factory StoreOffer.fromJson(Map<String, dynamic> json) {
    return StoreOffer(
      store: (json['store'] ?? 'Sklep').toString(),
      price: _safeDouble(json['price']) ?? 0.0,
      regularPrice: _safeDouble(json['regularPrice']) ?? 0.0,
      isPromo: json['isPromo'] == true,
      url: (json['url'] ?? '').toString(),
      availability: (json['availability'] ?? 'Dostępny').toString(),
      isOrigin: json['isOrigin'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'store': store,
        'price': price,
        'regularPrice': regularPrice,
        'isPromo': isPromo,
        'url': url,
        'availability': availability,
        'isOrigin': isOrigin,
      };
}

class ProductInfo {
  final String store;
  String category;
  final String url;
  final String brand;
  final String title;
  final String fullName;
  final String unit;
  final String? ean;
  double currentPrice;
  final double regularPrice;
  final double? lowestOmnibusPrice;
  final String? pricePerUnit;
  final bool isPromo;
  final String? promotionTo;
  final String? image;
  final String availability;
  String checkedAt;
  final String? extractionMethod;
  final String? screenshotBase64;

  ProductInfo({
    required this.store,
    required this.category,
    required this.url,
    required this.brand,
    required this.title,
    required this.fullName,
    required this.unit,
    this.ean,
    required this.currentPrice,
    required this.regularPrice,
    this.lowestOmnibusPrice,
    this.pricePerUnit,
    required this.isPromo,
    this.promotionTo,
    this.image,
    required this.availability,
    required this.checkedAt,
    this.extractionMethod,
    this.screenshotBase64,
  });

  factory ProductInfo.fromJson(Map<String, dynamic> json) {
    return ProductInfo(
      store: (json['store'] ?? 'Sklep').toString(),
      category: (json['category'] ?? 'Sklep').toString(),
      url: (json['url'] ?? '').toString(),
      brand: (json['brand'] ?? '').toString(),
      title: (json['title'] ?? 'Produkt').toString(),
      fullName: (json['fullName'] ?? 'Produkt').toString(),
      unit: (json['unit'] ?? '').toString(),
      ean: json['ean']?.toString(),
      currentPrice: _safeDouble(json['currentPrice']) ?? 0.0,
      regularPrice: _safeDouble(json['regularPrice']) ?? 0.0,
      lowestOmnibusPrice: _safeDouble(json['lowestOmnibusPrice']),
      pricePerUnit: json['pricePerUnit']?.toString(),
      isPromo: json['isPromo'] == true,
      promotionTo: json['promotionTo']?.toString(),
      image: json['image']?.toString(),
      availability: (json['availability'] ?? 'Dostępny').toString(),
      checkedAt: (json['checkedAt'] ?? DateTime.now().toIso8601String()).toString(),
      extractionMethod: json['extractionMethod']?.toString(),
      screenshotBase64: json['screenshotBase64']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'store': store,
        'category': category,
        'url': url,
        'brand': brand,
        'title': title,
        'fullName': fullName,
        'unit': unit,
        'ean': ean,
        'currentPrice': currentPrice,
        'regularPrice': regularPrice,
        'lowestOmnibusPrice': lowestOmnibusPrice,
        'pricePerUnit': pricePerUnit,
        'isPromo': isPromo,
        'promotionTo': promotionTo,
        'image': image,
        'availability': availability,
        'checkedAt': checkedAt,
        'extractionMethod': extractionMethod,
        'screenshotBase64': screenshotBase64,
      };
}

class TrackedItem {
  ProductInfo product;
  List<StoreOffer> offers;

  /// Własne tagi nadawane przez użytkownika (np. "Twarz", "Prezent").
  List<String> tags;

  TrackedItem({
    required this.product,
    required this.offers,
    List<String>? tags,
  }) : tags = tags ?? <String>[];

  static const String tagPromo = 'PROMOCJA';
  static const String tagCheaperElsewhere = 'Taniej w innym sklepie';

  /// Tagi automatyczne wyliczane z danych produktu.
  List<String> get autoTags => [
        if (product.category.trim().isNotEmpty) product.category.trim(),
        if (product.isPromo) tagPromo,
        if (cheaperInOtherStore) tagCheaperElsewhere,
      ];

  /// Wszystkie tagi (automatyczne + własne) bez duplikatów.
  List<String> get allTags {
    final seen = <String>{};
    final out = <String>[];
    for (final t in [...autoTags, ...tags]) {
      if (seen.add(t.toLowerCase())) out.add(t);
    }
    return out;
  }

  /// Sklepy, w których produkt ma ofertę (łącznie ze sklepem źródłowym).
  Set<String> get stores {
    final out = <String>{};
    if (product.store.trim().isNotEmpty) out.add(product.store.trim());
    for (final o in offers) {
      if (o.store.trim().isNotEmpty) out.add(o.store.trim());
    }
    return out;
  }

  StoreOffer get bestOffer => offers.isNotEmpty
      ? offers.first
      : StoreOffer(
          store: product.store,
          price: product.currentPrice,
          regularPrice: product.regularPrice,
          isPromo: product.isPromo,
          url: product.url,
          availability: product.availability,
          isOrigin: true,
        );

  bool get cheaperInOtherStore =>
      bestOffer.store != product.store && bestOffer.price < product.currentPrice;

  factory TrackedItem.fromJson(Map<String, dynamic> json) {
    final prod = ProductInfo.fromJson(
        Map<String, dynamic>.from(json['product'] as Map? ?? {}));
    final rawOffers = (json['offers'] as List?) ?? [];
    final parsedOffers = rawOffers
        .map((e) => StoreOffer.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    final rawTags = (json['tags'] as List?) ?? [];
    final parsedTags = rawTags
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return TrackedItem(product: prod, offers: parsedOffers, tags: parsedTags);
  }

  Map<String, dynamic> toJson() => {
        'product': product.toJson(),
        'offers': offers.map((o) => o.toJson()).toList(),
        'tags': tags,
      };
}
