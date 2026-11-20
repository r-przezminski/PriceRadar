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
      price: (json['price'] as num?)?.toDouble() ?? 0.0,
      regularPrice: (json['regularPrice'] as num?)?.toDouble() ?? 0.0,
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
  final String category;
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
      currentPrice: (json['currentPrice'] as num?)?.toDouble() ?? 0.0,
      regularPrice: (json['regularPrice'] as num?)?.toDouble() ?? 0.0,
      lowestOmnibusPrice: (json['lowestOmnibusPrice'] as num?)?.toDouble(),
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

  TrackedItem({
    required this.product,
    required this.offers,
  });

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
    return TrackedItem(product: prod, offers: parsedOffers);
  }

  Map<String, dynamic> toJson() => {
        'product': product.toJson(),
        'offers': offers.map((o) => o.toJson()).toList(),
      };
}
