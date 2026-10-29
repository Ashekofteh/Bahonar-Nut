<div align="center">

<img src="assets/images/app_logo.png" alt="Selfiyar Logo" width="130" height="130" style="border-radius: 24px; box-shadow: 0 8px 24px rgba(0,0,0,0.15);" />

# سِلفیار — Selfiyar
### دستیار و سامانه هوشمند اتوماسیون تغذیه دانشگاه شهید باهنر کرمان
**Next-Generation Cross-Platform Smart Dining Assistant for Shahid Bahonar University of Kerman (SBUK)**

[![GitHub Release](https://img.shields.io/github/v/release/Ashekofteh/Bahonar-Nut?include_prereleases&style=for-the-badge&color=2563eb&logo=github)](https://github.com/Ashekofteh/Bahonar-Nut/releases/latest)
[![Platform Support](https://img.shields.io/badge/Platform-Android%20%7C%20Windows%20%7C%20macOS-3b82f6?style=for-the-badge&logo=android&logoColor=white)](https://github.com/Ashekofteh/Bahonar-Nut/releases)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?style=for-the-badge&logo=dart&logoColor=white)](https://dart.dev)
[![Tests Passing](https://img.shields.io/badge/Tests-1016%2F1016%20Passed-10b981?style=for-the-badge&logo=checkmarx&logoColor=white)](https://github.com/Ashekofteh/Bahonar-Nut/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-f59e0b?style=for-the-badge)](LICENSE)

<br/>

[📱 دانلود نسخه اندروید](https://github.com/Ashekofteh/Bahonar-Nut/releases/latest/download/selfiyar-beta.apk) &bull;
[🪟 دانلود نسخه ویندوز](https://github.com/Ashekofteh/Bahonar-Nut/releases/latest/download/selfiyar-windows-x64.zip) &bull;
[🍎 دانلود نسخه مک‌اواس](https://github.com/Ashekofteh/Bahonar-Nut/releases/latest/download/selfiyar-macos.zip) &bull;
[✨ قابلیت‌های کلیدی](#-قابلیتهای-برجسته-و-کلیدی) &bull;
[🏗️ معماری نرم‌افزار](#-معماری-نرم‌افزار-و-اصول-فنی) &bull;
[🛠️ راهنمای توسعه](#-راهنمای-توسعه-و-کامپایل)

</div>

---

## 📖 درباره پروژه (About the Project)

**سِلفیار (Selfiyar)** یک کلاینت مدرن، آفلاین‌محور و بومی (Native) با رابط کاربری اختصاصی راست‌به‌چپ (RTL) و طراحی متریال ۳ است که تجربه تعامل دانشجویان دانشگاه شهید باهنر کرمان با سامانه اتوماسیون تغذیه (Cullinan) را متحول می‌سازد. 

این پروژه با عبور از محدودیت‌ها و کندی‌های نسخه وب، امکاناتی فراتر از یک سامانه رزرو معمولی شامل: **شکار خودکار غذاهای پرطرفدار**، **رزرو دسته‌جمعی با تفکیک سلف و غذا**، **حل محلی و بلادرنگ کپچا بدون اینترنت**، **مدیریت چند حسابه**، **کیف پول کارت‌های شتاب و شارژ هوشمند**، **ثبت و دریافت فیش فراموشی فوری** و **عرضه غذا در سبد مازاد** را فراهم می‌کند.

---

## 🚀 دانلود آخرین نسخه (Download Latest Releases)

| پلتفرم | فایل دانلودی | توضیحات و پیش‌نیاز | وضعیت |
| :--- | :--- | :--- | :---: |
| 📱 **اندروید (Android)** | [**`selfiyar-beta.apk`**](https://github.com/Ashekofteh/Bahonar-Nut/releases/latest/download/selfiyar-beta.apk) | اندروید ۸.۰ به بالا (امضای رسمی با کلید دائمی) | [![Release](https://img.shields.io/badge/APK-Ready-success?style=flat-square)](#) |
| 🪟 **ویندوز (Windows x64)** | [**`selfiyar-windows-x64.zip`**](https://github.com/Ashekofteh/Bahonar-Nut/releases/latest/download/selfiyar-windows-x64.zip) | ویندوز ۱۰ و ۱۱ نسخه ۶۴ بیتی (Portable) | [![Release](https://img.shields.io/badge/ZIP-Ready-blue?style=flat-square)](#) |
| 🍎 **مک‌اواس (macOS)** | [**`selfiyar-macos.zip`**](https://github.com/Ashekofteh/Bahonar-Nut/releases/latest/download/selfiyar-macos.zip) | مک‌اواس ۱۲+ (Apple Silicon و Intel) | [![Release](https://img.shields.io/badge/ZIP-Ready-purple?style=flat-square)](#) |

> [!TIP]
> برای مشاهده تاریخچه نسخه‌ها و تغییرات هر نسخه، به صفحه [**GitHub Releases**](https://github.com/Ashekofteh/Bahonar-Nut/releases) مراجعه کنید.

---

## 🌟 قابلیت‌های برجسته و کلیدی (Key Features)

### 👥 ۱. مدیریت چند حساب کاربری با شناسایی خودکار هویت
- امکان ذخیره و جابه‌جایی سریع میان حساب‌های کاربری متعدد (مناسب برای دوستان، برادران و خواهران) با ذخیره‌ساز کوکی مجزا.
- **استخراج خودکار نام دانشجو:** در صورتی که کاربر نام حساب را دستی وارد نکند، برنامه نام و نام خانوادگی واقعی دانشجو را در اولین همگام‌سازی از پورتال استخراج کرده و به صورت دائمی ثبت می‌کند.

### 🍽️ ۲. رزرو دسته‌جمعی غذاها با انتخاب دقیق سلف و نوع غذا
- رزرو سریع چندین وعده به طور همزمان با یک ضربه.
- برگه اختصاصی تنظیمات رزرو گروهی جهت تعیین سلف (مرکزی، فنی و مهندسی) و انتخاب از میان غذاهای چندگزینه‌ای به ازای هر روز یا به صورت سراسری.
- ناوبری هوشمند دو هفته‌ای (هفته جاری و هفته آینده) با قابلیت فوکوس خودکار روی هفته‌های دارای غذای باز.

### 🎯 ۳. موتور خودکار شکار وعده (Food Hunt Engine)
- مانیتورینگ خودکار ظرفیت‌های آزاد شده در پورتال بر اساس ترجیحات و اولویت‌های تعیین‌شده دانشجو (غذاها و سلف‌های هدف).
- نرخ پولینگ بهینه و هوشمند بر مبنای ساعات اوج و غیراوج به منظور جلوگیری از فشار به سرور دانشگاه یا مسدودی آی‌پی.
- اجرای مستقل به عنوان فورگراند سرویس با معافیت بهینه‌سازی باتری در اندروید (`BatteryExemption`) و توقف فوری پردازش به محض شکار موفق.

### ⚡ ۴. حل‌کننده درون‌دستگاهی کپچا (On-Device CAPTCHA Solver)
- الگوریتم اختصاصی بینایی ماشین مبتنی بر تحلیل تفاضل شدت روشنایی و تطبیق الگو (Nearest-Template Matching).
- **دقت ۱۰۰٪ با زمان اجرای زیر ۱ میلی‌ثانیه**، بدون نیاز به ارسال تصویر به سرورهای خارجی، بدون مصرف ترافیک اینترنت و بدون وابستگی به فیلترشکن.

### 💳 ۵. صندوق کارت‌های شتاب و شارژ هوشمند کسری موجودی
- تشخیص خودکار مبلغ کسری موجودی هنگام رزرو تکی یا چندگانه و پیش‌فرض قرار دادن مبلغ به تومان در برگه افزایش اعتبار.
- ذخیره‌سازی محلی و امن اطلاعات کارت‌های بانکی دانشجو با امکان تکمیل خودکار فرم درگاه پرداخت (شماره کارت، تاریخ انقضا و CVV2).
- سازوکار خودکار «استعلام و بازگشت» جهت ثبت قطعی افزایش اعتبار در سامانه کالینان پس از پرداخت، حتی در صورت قطعی اینترنت در صفحه بانک.
- **رزرو خودکار پس از شارژ:** رزرو خودکار وعده‌های معلق بلافاصله پس از تکمیل افزایش موجودی.

### 🧾 ۶. فیش فراموشی فوری کارت تغذیه (Instant Forgot Voucher)
- دریافت بلادرنگ بارکد و کد شناسه فیش فراموشی موقت جهت تحویل غذا از سلف بدون نیاز به کارت فیزیکی همراه با قابلیت کپی سریع.

### 🍱 ۷. سبد غذایی ثانویه (خرید و فروش مازاد)
- سازگاری کامل با بخش `FoodBasketBuy` و `FoodBasketSale` جهت خرید غذاهای حراجی یا ثبت و عرضه وعده‌های رزروشده جهت جلوگیری از هدررفت ژتون.

### 📊 ۸. داشبورد مالی و یادآورهای بدون مصرف باتری
- نمایش نمودار هزینه‌کرد و تراکنش‌ها به تفکیک وعده‌های صبحانه، ناهار و شام.
- یادآورهای اعلام وعده و تلنگر رزرو هفته آینده با بهره‌گیری از `AlarmManager` سخت‌افزاری اندروید با **مصرف باتری صفر در حالت استندبای**.

---

## 📸 گالری تصاویر برنامه (Screenshots)

<div align="center">

| مدیریت حساب‌ها | جدول رزرو هفتگی | جزئیات رزرو دسته‌جمعی |
| :---: | :---: | :---: |
| <img src="screenshots/01_accounts_screen.png" width="240" /> | <img src="screenshots/02_reservations_table.png" width="240" /> | <img src="screenshots/06_multi_select_deficit.png" width="240" /> |

| شارژ هوشمند و کارت‌ها | موتور شکار غذا (Hunt) | یادآورها و اعلان‌ها |
| :---: | :---: | :---: |
| <img src="screenshots/08_top_up_sheet_prefilled.png" width="240" /> | <img src="screenshots/11_hunt_screen.png" width="240" /> | <img src="screenshots/10_reminders_screen.png" width="240" /> |

| داشبورد آمار و هزینه‌ها | فیش فراموشی کارت | ثبت غذا برای فروش |
| :---: | :---: | :---: |
| <img src="screenshots/09_dashboard_screen.png" width="240" /> | <img src="screenshots/03_forgot_receipt_dialog.png" width="240" /> | <img src="screenshots/04_food_basket_sale_dialog.png" width="240" /> |

</div>

---

## 🏗️ معماری نرم‌افزار و اصول فنی (Architecture)

سِلفیار بر اساس معماری چندلایه پاک (Clean Layered Architecture) پیاده‌سازی شده و از وابستگی‌های غیرضروری کاملاً پیراسته است:

```mermaid
flowchart TD
    subgraph UI ["لایه ارائه (UI Layer - Material 3 RTL)"]
        Screens["Screens & Sheets\n(Accounts, Reservations, Hunt, TopUp, Dashboard)"]
        State["AppState (ChangeNotifier)\nShared reactive state management"]
    end

    subgraph Core ["لایه دامنه و بیزنس (Core Domain - Pure Dart)"]
        Models["Domain Models & Invariants\n(MealRef, Balance, StoredMeal, BankCard)"]
        Engines["Engines & Schedulers\n(SnipeEngine, SessionManager, ServerClock)"]
        LocalStores["Local Stores\n(LocalMealStore, RequestLedger)"]
    end

    subgraph Adapter ["لایه انطباق سامانه (Adapter & Parsing)"]
        CullinanClient["CullinanPortalClient\nASP.NET WebForms Flow Engine"]
        CullinanParser["CullinanParser & HTML Tools\nOptimized Compiled Regex Parsers"]
        CaptchaSolver["CaptchaSolver\nOn-device 100% Image Recognition"]
    end

    subgraph Platform ["لایه پلتفرم و زیرساخت (Platform & Hardware)"]
        Transport["PortalTransport & CookieJarStore\nConnection Pooling & Rate Budget"]
        Security["SecureStore & AES-256-GCM\nAndroid Keystore / EncryptedPrefs"]
        NativeService["Android Native Layer\n(AlarmScheduler, HuntService, BootReceiver)"]
    end

    Screens --> State
    State --> Core
    Core --> Adapter
    Adapter --> Platform
```

### 🔒 امنیت و حریم خصوصی (Privacy & Security First)
- **رمزنگاری سخت‌افزاری:** کلیه گذرواژه‌ها و شماره کارت‌ها با استفاده از الگوریتم **AES-256-GCM** و کلید اختصاصی `Android Keystore` ذخیره شده و هرگز در فایل‌های متنی ساده قرار نمی‌گیرند.
- **ارتباط ایزوله کوکی‌ها:** هر حساب کاربری در کانتینر کوکی مستقل (`CookieJarStore`) نگهداری می‌شود و هیچ تداخل یا نشت نشستی میان حساب‌ها وجود ندارد.
- **ترافیک مستقیم دانشگاه:** کلیه درخواست‌ها مستقیماً و منحصراً میان دستگاه دانشجو و سرورهای رسمی دانشگاه (`nut.uk.ac.ir`) رد و بدل می‌شوند؛ هیچ سرور واسط یا سرور پروکسی وجود ندارد.

---

## 🛠️ راهنمای توسعه و کامپایل (Development & Build)

### پیش‌نیازها
- **Flutter SDK:** نسخه `^3.13.5` یا جدیدترین نسخه Stable
- **Android SDK:** حداقل API 24 (اندروید ۷+) و Target API 36
- **ابزارهای دسکتاپ:** Visual Studio C++ (برای بیلد ویندوز) یا Xcode (برای بیلد مک‌اواس)

### راه‌اندازی و اجرای سورس

1. **کلون مخزن:**
   ```bash
   git clone https://github.com/Ashekofteh/Bahonar-Nut.git
   cd Bahonar-Nut
   ```

2. **دریافت پکیج‌ها:**
   ```bash
   flutter pub get
   ```

3. **بررسی صحت کد و تحلیل ایستا:**
   ```bash
   dart analyze lib/
   ```

4. **اجرای آزمون‌های خودکار:**
   ```bash
   flutter test
   ```

5. **کامپایل خروجی رسمی:**
   ```bash
   # کامپایل نسخه اندروید
   flutter build apk --release

   # کامپایل نسخه ویندوز
   flutter build windows --release

   # کامپایل نسخه مک‌اواس
   flutter build macos --release
   ```

---

## 🤝 مشارکت و توسعه (Contributing)

مشارکت‌ها، پیشنهادات و گزارش اشکالات به گرمی استقبال می‌شوند! لطفاً پیش از ارسال Pull Request، فایل [**CONTRIBUTING.md**](CONTRIBUTING.md) را مطالعه کرده و اطمینان حاصل کنید که کلیه تست‌های پروژه با موفقیت پاس می‌شوند.

---

## 📜 مجوز (License)

این پروژه تحت مجوز متن‌باز [**MIT License**](LICENSE) منتشر شده است و استفاده، شخصی‌سازی و بازنشر آن با رعایت شرایط این مجوز کاملاً آزاد است.

---

<div align="center">
  <sub>طراحی و توسعه‌یافته با ❤️ برای دانشجویان و جامعه دانشگاهی دانشگاه شهید باهنر کرمان</sub>
</div>
