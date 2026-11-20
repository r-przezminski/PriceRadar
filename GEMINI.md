# Kontekst Projektu PriceRadar (Kontynuacja Konwersacji)

Ten plik zawiera pełny kontekst naszej dotychczasowej konwersacji i architektury aplikacji **PriceRadar**, aby agent Antigravity na nowym urządzeniu (np. Linux) od razu wiedział, na jakim etapie jesteśmy.

## 1. Cel Aplikacji
Mobilna aplikacja na Androida (**Flutter / Dart + Kotlin Native**) do śledzenia cen produktów (drogerie: Rossmann, Hebe, Natura, eZebra, Cocolita, Pachnij, Super-Pharm, Notino; a docelowo także elektronika i inne sklepy):
- Użytkownik wkleja link do produktu z dowolnego sklepu i klika ikonę lupki.
- Aplikacja wyciąga dane produktu (marka, nazwa, pojemność, aktualna cena, cena regularna, najniższa cena z 30 dni wg dyrektywy Omnibus, data końca promocji, zdjęcie oraz **13-cyfrowy kod EAN/GTIN**).
- Na podstawie kodu EAN (oraz zweryfikowanej nazwy/marki/pojemności) aplikacja automatycznie przeszukuje inne sklepy równolegle (`Future.wait`) i listuje oferty od najtańszej.
- Dane są przechowywane **w 100% lokalnie na telefonie** (`SharedPreferences` pod kluczem `tracked_json` w `priceradar_prefs`) – aplikacja nie wymaga żadnego zewnętrznego serwera backendowego.

## 2. Zrealizowana Architektura i Funkcje
1. **UI (2 ekrany w `lib/main.dart`):**
   - **Ekran 1 (`WatchListScreen`):** Pole wklejania linku z przyciskiem lupki (`Icons.search`), lista obserwowanych produktów z miniaturką, tagami (`Drogeria`/`Elektronika`, `PROMOCJA`, `Taniej w <Sklep>!`) i najniższą znalezioną ceną. Obsługuje *Pull-to-Refresh* oraz przycisk `Sprawdź ceny`.
   - **Ekran 2 (`ProductDetailScreen`):** Otwierany po kliknięciu w produkt. Wyświetla zdjęcie, pełną nazwę, klikalną plakietkę `EAN/GTIN` (kopiuje kod EAN do schowka telefonu), tabelę porównania cen ze sklepów posortowaną od najtańszej oferty (`🏆`), kafelki Omnibus/jednostka/koniec promocji, przycisk wymuszenia odczytu przez Agenta (`🤖 Zrób zrzut ekranu i odczytaj przez Agenta`), podgląd zrobionego screena oraz przycisk usuwania z obserwowanych.
2. **Hybrydowy Scraper + Agent AI (`lib/scraper_service.dart` + `MainActivity.kt`):**
   - **Warstwa 1 (Szybki HTTP):** Parsuje `JSON-LD` (`schema.org/Product`), `__NEXT_DATA__` (Rossmann), `OpenGraph` i `Microdata`.
   - **Warstwa 2 (Offscreen `WebView` + Screenshot w `MainActivity.kt`):** Obiekt `OffscreenWebViewCapturer` otwiera stronę w natywnym silniku Chromium (`WebView`), automatycznie klika/zamyka banery Cookies/RODO, rozwija zakładki *„Specyfikacja / Szczegóły produktu"*, robi zrzut ekranu (`Bitmap` -> Base64 JPEG) i wyciąga wyrenderowany DOM. Działa również w pamięci RAM (`enableSlowWholeDocumentDraw()`) bez aktywnego okna `Activity`!
   - **Warstwa 3 (Multimodalny Agent Gemini 2.5 Flash):** Po wpisaniu darmowego klucza Gemini API (ikonka `🤖` w górnym pasku), aplikacja wysyła zrzut ekranu + wyrenderowany tekst strony do `gemini-2.5-flash` oraz wykorzystuje **Google Search Grounding** (`tools: [{"google_search": {}}]`) do znajdowania cen w sklepach chronionych przez Cloudflare.
3. **Weryfikacja Kodów EAN-13 i Dopasowania Produktów (`isSameProduct`):**
   - Walidator cyfry kontrolnej GS1 modulo-10 (`isValidEan13`) odrzuca fałszywe 13-cyfrowe numery ID i timestampy.
   - Funkcja `extractVerifiedEanFromContent` czyści tagi HTML (np. `<div class="col-12">`) przed szukaniem `Kod EAN: ...` i skanuje obiekty `dataLayer`.
   - Funkcja `isSameProduct` rygorystycznie weryfikuje oferty z innych sklepów po kodzie EAN, marce, słowach kluczowych (>= 50% pokrycia) oraz pojemności (`ml`/`g`), odrzucając przypadkowe boksy „Bestsellery / Promocja dnia" (np. *Plusssz Magnez* zamiast *Beauty of Joseon*).
4. **Sprawdzanie Cen w Tle co 2 Godziny (`PriceCheckWorker` w `MainActivity.kt`):**
   - Natywny Android `WorkManager` (`PeriodicWorkRequest` co 2 godziny) sprawdza ceny wszystkich obserwowanych produktów nawet przy całkowicie zamkniętej aplikacji i uśpionym telefonie (obsługuje zarówno szybki HTTP, jak i `OffscreenWebViewCapturer` + Gemini API w tle) i wysyła natywne powiadomienia systemowe Androida (`NotificationManager`), gdy cena spadnie.
   - W `android/app/build.gradle.kts` minifikacja R8 jest wyłączona (`isMinifyEnabled = false`), aby R8 nie zaciemniał klasy `androidx.work.impl.WorkDatabase_Impl`.

## 3. Automatyczny Upload `.apk` na Google Drive
- Po każdym zbudowaniu paczki (`flutter build apk --release`), wygenerowany plik `build/app/outputs/flutter-apk/app-release.apk` aktualizujemy na Dysku Google użytkownika (`r.przezminski@gmail.com`) za pomocą wtyczki `gdrive`:
  ```bash
  gdrive mutate update 1uzcxjFy8XasjAimZ_sDoNZ4GGTrwRbls build/app/outputs/flutter-apk/app-release.apk --mime-type "application/vnd.android.package-archive"
  ```
  Link do pliku na Google Drive: `https://drive.google.com/file/d/1uzcxjFy8XasjAimZ_sDoNZ4GGTrwRbls/view?usp=drivesdk`
