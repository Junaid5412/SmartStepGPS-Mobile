# 📱 Smart Step GPS — Flutter Mobile Application

Cross-platform mobile application for **Parents** and **School Bus Attendants (Monitors / Drivers)**.

---

## 1. Features

* **Parent Portal**:
  * Real-time live bus tracking using `flutter_map` (OpenStreetMap).
  * Road-wise polyline routing and turn-by-turn distance/ETA.
  * Shift-aware tracking (Active transit hours only).
  * Boarding and drop-off attendance records.
  * Absence leave application submission.
  * School circulars and announcements.
  * Family contact profile management.
* **Monitor / Driver Portal**:
  * Complete student passenger roster assigned to the bus.
  * Grouped by family / pickup stop with direct call actions.
  * 1-tap progressive attendance check-in (Pickup &rarr; Drop-off &rarr; Absent &rarr; Leave).
  * Shift locking to prevent duplicate or conflicting check-ins.

---

## 2. Quick Setup & Run

### 2.1 Set API Target
Open `lib/services/api_service.dart` and configure your API URL:
```dart
static const String baseUrl = 'https://gps.yourdomain.com/api/mobile';
```

### 2.2 Install Dependencies
```bash
flutter pub get
```

### 2.3 Run in Debug Mode
```bash
flutter run
```

### 2.4 Compile Release APK
```bash
flutter build apk --release
```
The compiled APK will be output at:
`build/app/outputs/flutter-apk/app-release.apk`

---

## 3. Comprehensive Documentation

For complete architectural details, screen workflows, OSRM routing, and permissions, refer to:
👉 [**docs/MOBILE_APP_GUIDE.md**](file:///f:/xampp/htdocs/GPS/docs/MOBILE_APP_GUIDE.md)
