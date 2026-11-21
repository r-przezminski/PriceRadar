import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:priceradar/main.dart';
import 'package:priceradar/scraper_service.dart';
import 'package:priceradar/tracked_product.dart';

void main() {
  test('extractOnlyUrl extracts clean URL and strips surrounding text', () {
    expect(
      NativeBridge.extractOnlyUrl(
        'Sprawdź ten produkt: https://www.rossmann.pl/Produkt/Krem/123456 super!',
      ),
      'https://www.rossmann.pl/Produkt/Krem/123456',
    );

    expect(
      NativeBridge.extractOnlyUrl('https://hebe.pl/produkt/456.'),
      'https://hebe.pl/produkt/456',
    );

    expect(
      NativeBridge.extractOnlyUrl('Zobacz tutaj (https://notino.pl/produkt/789)!'),
      'https://notino.pl/produkt/789',
    );

    expect(
      NativeBridge.extractOnlyUrl('Brak adresu www tutaj'),
      isNull,
    );
  });

  test('isSameProduct accepts exact match and rejects different products of same brand', () {
    final base = ProductInfo(
      store: 'Rossmann',
      category: 'Drogeria',
      url: 'https://rossmann.pl/1',
      brand: 'Beauty of Joseon',
      title: 'Relief Sun Rice Probiotics SPF50+ 50ml',
      fullName: 'Beauty of Joseon Relief Sun Rice Probiotics SPF50+ 50ml',
      unit: '50ml',
      ean: '8809643070003',
      currentPrice: 59.99,
      regularPrice: 79.99,
      isPromo: true,
      availability: 'Dostępny',
      checkedAt: '',
    );

    final sameProductDifferentStore = ProductInfo(
      store: 'Hebe',
      category: 'Drogeria',
      url: 'https://hebe.pl/1',
      brand: 'Beauty of Joseon',
      title: 'Krem przeciwsłoneczny Relief Sun Rice Probiotics 50 ml',
      fullName: 'Beauty of Joseon Krem przeciwsłoneczny Relief Sun Rice Probiotics 50 ml',
      unit: '50ml',
      ean: '8809643070003',
      currentPrice: 49.99,
      regularPrice: 69.99,
      isPromo: true,
      availability: 'Dostępny',
      checkedAt: '',
    );

    final differentProductSameBrand = ProductInfo(
      store: 'Hebe',
      category: 'Drogeria',
      url: 'https://hebe.pl/2',
      brand: 'Beauty of Joseon',
      title: 'Ginseng Essence Water Tonik żeń-szeniowy 150ml',
      fullName: 'Beauty of Joseon Ginseng Essence Water Tonik żeń-szeniowy 150ml',
      unit: '150ml',
      ean: '8809643070010',
      currentPrice: 45.00,
      regularPrice: 45.00,
      isPromo: false,
      availability: 'Dostępny',
      checkedAt: '',
    );

    // Powinno dopasować ten sam produkt
    expect(
      ScraperService.isSameProduct(
        baseProduct: base,
        candidate: sameProductDifferentStore,
        searchedEan: '8809643070003',
      ),
      isTrue,
    );

    // Powinno bezwzględnie ODRZUCIĆ inny produkt tej samej marki (inny model / pojemność / EAN)
    expect(
      ScraperService.isSameProduct(
        baseProduct: base,
        candidate: differentProductSameBrand,
        searchedEan: '8809643070003',
      ),
      isFalse,
    );

    // Nawet przy wyszukiwaniu bez EAN (po samej nazwie):
    expect(
      ScraperService.isSameProduct(
        baseProduct: base,
        candidate: differentProductSameBrand,
      ),
      isFalse,
    );
  });

  test('TrackedItem tags: serialization, auto tags and stores', () {
    ProductInfo prod(String store) => ProductInfo(
          store: store,
          category: 'Drogeria',
          url: 'https://example.com/p',
          brand: 'Marka',
          title: 'Produkt',
          fullName: 'Marka Produkt',
          unit: '',
          currentPrice: 20,
          regularPrice: 30,
          isPromo: true,
          availability: 'Dostępny',
          checkedAt: '',
        );

    final item = TrackedItem(
      product: prod('Rossmann'),
      offers: [
        StoreOffer(
          store: 'Hebe',
          price: 15,
          regularPrice: 15,
          isPromo: false,
          url: 'https://hebe.pl/x',
          availability: 'Dostępny',
          isOrigin: false,
        ),
        StoreOffer(
          store: 'Rossmann',
          price: 20,
          regularPrice: 30,
          isPromo: true,
          url: 'https://rossmann.pl/x',
          availability: 'Dostępny',
          isOrigin: true,
        ),
      ],
      tags: ['Twarz', 'Prezent'],
    );

    expect(item.stores, {'Rossmann', 'Hebe'});
    expect(item.allTags, contains('Drogeria'));
    expect(item.allTags, contains(TrackedItem.tagPromo));
    expect(item.allTags, contains(TrackedItem.tagCheaperElsewhere));
    expect(item.allTags, containsAll(['Twarz', 'Prezent']));

    final restored = TrackedItem.fromJson(
      Map<String, dynamic>.from(jsonDecode(jsonEncode(item.toJson())) as Map),
    );
    expect(restored.tags, ['Twarz', 'Prezent']);

    // Stare zapisy bez pola "tags" muszą się wczytywać poprawnie.
    final legacy = item.toJson()..remove('tags');
    expect(TrackedItem.fromJson(legacy).tags, isEmpty);
  });

  test('isSameProduct: EAN odczytany ze złej strony nie może dopasować obcego produktu', () {
    ProductInfo mk({
      required String store,
      required String brand,
      required String fullName,
      String unit = '',
      String? ean,
    }) =>
        ProductInfo(
          store: store,
          category: 'Drogeria',
          url: 'https://example.com',
          brand: brand,
          title: fullName,
          fullName: fullName,
          unit: unit,
          ean: ean,
          currentPrice: 10,
          regularPrice: 10,
          isPromo: false,
          availability: 'Dostępny',
          checkedAt: '',
        );

    // Hebe: Mokosh, ale EAN odczytany omyłkowo z herbaty (np. karuzela "Polecane").
    final mokosh = mk(
      store: 'Hebe',
      brand: 'Mokosh',
      fullName: 'Mokosh Brązujący balsam do ciała i twarzy 180 ml',
      unit: '180 ml',
      ean: '4792331009147',
    );
    final tea = mk(
      store: 'Rossmann',
      brand: "Adalbert's Tea",
      fullName:
          "Adalbert's Tea herbata czarna cejlońska liściasta Śnieżna Pomarańcza z Cynamonem 80 g",
      ean: '4792331009147',
    );
    expect(
      ScraperService.isSameProduct(
        baseProduct: mokosh,
        candidate: tea,
        searchedEan: '4792331009147',
      ),
      isFalse,
    );

    // Gdy marki nie znamy (brand = nazwa sklepu), też odrzucamy po braku słów modelu.
    final mokoshNoBrand = mk(
      store: 'Hebe',
      brand: 'Hebe',
      fullName: 'Hebe Brązujący balsam do ciała i twarzy 180 ml',
      unit: '180 ml',
      ean: '4792331009147',
    );
    expect(
      ScraperService.isSameProduct(
        baseProduct: mokoshNoBrand,
        candidate: tea,
        searchedEan: '4792331009147',
      ),
      isFalse,
    );

    // Prawdziwy ten sam produkt z tym samym EAN i inną nazwą w innym sklepie - nadal OK.
    final sameInRossmann = mk(
      store: 'Rossmann',
      brand: 'Mokosh Cosmetics',
      fullName: 'Mokosh Cosmetics balsam do ciała i twarzy brązujący 180 ml',
      unit: '180 ml',
      ean: '4792331009147',
    );
    expect(
      ScraperService.isSameProduct(
        baseProduct: mokosh,
        candidate: sameInRossmann,
        searchedEan: '4792331009147',
      ),
      isTrue,
    );
  });

  test('normalizeTagInput cleans user input', () {
    expect(normalizeTagInput('  #  Twarz   i  szyja '), 'Twarz i szyja');
    expect(normalizeTagInput('   '), '');
    expect(normalizeTagInput('a' * 40).length, 24);
  });

  test('parseHtmlDocument: Hebe Mokosh JSON-LD (brand as List + disambiguatingDescription) i fallback bez ceny jednostkowej', () {
    const hebeJsonLd = '''
    {
      "@context": "https://schema.org",
      "@type": "Product",
      "name": "Mokosh Pomarańcza z cynamonem",
      "disambiguatingDescription": "brązujący balsam do ciała i twarzy, 180 ml",
      "brand": [{"@type": "Brand", "name": "Mokosh", "url": "/marki-mokosh/"}],
      "offers": {
        "@type": "AggregateOffer",
        "price": 88.99,
        "priceCurrency": "PLN",
        "lowPrice": 88.99,
        "highPrice": 88.99
      }
    }
    ''';

    final parsed = ScraperService.parseHtmlDocument(
      html: '',
      url: 'https://www.hebe.pl/mokosh-brazujacy-balsam-do-ciala-i-twarzy-180-ml-000000000000407303.html',
      storeInfo: {'name': 'Hebe', 'category': 'Drogeria'},
      extraJsonLd: [hebeJsonLd],
      extractionMethod: 'WebView',
    );

    expect(parsed, isNotNull);
    expect(parsed!.brand, 'Mokosh');
    expect(parsed.currentPrice, 88.99);
    expect(parsed.unit, '180ml');
    expect(parsed.fullName.toLowerCase(), contains('brązujący balsam'));

    final tea = ProductInfo(
      store: 'Rossmann',
      category: 'Drogeria',
      url: 'https://www.rossmann.pl/Produkt/Herbaty-czarne/Adalberts-Tea-herbata-czarna-cejlonska-lisciasta-Sniezna-Pomarancza-z-Cynamonem-80-g,2116629,14092',
      brand: "Adalbert's Tea",
      title: 'herbata czarna cejlońska liściasta Śnieżna Pomarańcza z Cynamonem 80 g',
      fullName: "Adalbert's Tea herbata czarna cejlońska liściasta Śnieżna Pomarańcza z Cynamonem 80 g",
      unit: '80g',
      ean: '4792331009147',
      currentPrice: 24.99,
      regularPrice: 24.99,
      isPromo: false,
      availability: 'Dostępny',
      checkedAt: '',
    );

    expect(ScraperService.isSameProduct(baseProduct: parsed, candidate: tea), isFalse);

    // Fallback tekstowy musi pominąć cenę jednostkową (49,44 zł /100ml), rekomendowaną (89,00 zł) i kupon (10,00 zł)
    final fromText = ScraperService.parseHtmlDocument(
      html: '',
      url: 'https://www.hebe.pl/test.html',
      storeInfo: {'name': 'Hebe', 'category': 'Drogeria'},
      fallbackTitle: 'Mokosh Pomarańcza z cynamonem',
      fallbackText:
          'Dołącz do my hebe i zyskaj kupon powitalny 10,00 zł\n'
          'Rekomendowana cena dostawcy: 89,00 zł\n'
          'Cena jednostkowa: 49,44 zł /100ml\n'
          '88,99 zł\nDodaj do koszyka',
      extractionMethod: 'WebView',
    );
    expect(fromText, isNotNull);
    expect(fromText!.currentPrice, 88.99);
  });

  test('detectSmartCategory classifies products accurately regardless of store', () {
    expect(
      ScraperService.detectSmartCategory(
        fullName: 'Lavazza Qualita Oro kawa ziarnista 1 kg',
        url: 'https://www.morele.net/kawa-lavazza-qualita-oro-1kg-12345/',
        storeFallbackCategory: 'Elektronika',
      ),
      'Kawa i herbata',
    );
    expect(
      ScraperService.detectSmartCategory(
        fullName: 'DeLonghi Magnifica S ekspres do kawy ciśnieniowy',
        url: 'https://www.morele.net/ekspres-delonghi-12345/',
        storeFallbackCategory: 'Elektronika',
      ),
      'Elektronika',
    );
    expect(
      ScraperService.detectSmartCategory(
        fullName: 'Mokosh Pomarańcza z cynamonem brązujący balsam do ciała i twarzy 180 ml',
        url: 'https://www.hebe.pl/mokosh-brazujacy-balsam-180-ml.html',
        storeFallbackCategory: 'Drogeria',
      ),
      'Kosmetyki',
    );
    expect(
      ScraperService.detectSmartCategory(
        fullName: 'Dior Sauvage woda perfumowana 100 ml',
        url: 'https://www.notino.pl/dior/sauvage-edp/',
        storeFallbackCategory: 'Drogeria',
      ),
      'Perfumy',
    );
  });

  test('parseHtmlDocument handles string prices in JSON-LD (e.g. Allegro) without type cast error', () {
    const allegroJsonLd = '''
    {
      "@context": "https://schema.org",
      "@type": "Product",
      "name": "Kawa ziarnista Lavazza Qualita Oro 1kg",
      "brand": {"@type": "Brand", "name": "Lavazza"},
      "offers": {
        "@type": "Offer",
        "price": "84.99",
        "priceCurrency": "PLN",
        "priceSpecification": [
          {"@type": "UnitPriceSpecification", "priceType": "https://schema.org/ListPrice", "price": "99,99"}
        ]
      }
    }
    ''';

    final parsed = ScraperService.parseHtmlDocument(
      html: '',
      url: 'https://allegro.pl/oferta/kawa-lavazza-12345',
      storeInfo: {'name': 'Allegro', 'category': 'Marketplace'},
      extraJsonLd: [allegroJsonLd],
      extractionMethod: 'WebView',
    );

    expect(parsed, isNotNull);
    expect(parsed!.currentPrice, 84.99);
    expect(parsed.regularPrice, 99.99);
    expect(parsed.category, 'Kawa i herbata');
  });

  testWidgets('PriceRadar smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const PriceRadarApp());
    expect(find.text('PriceRadar'), findsOneWidget);
  });
}
