# HisaabKaro — Voice-First Business Assistant for Small Businesses in India

> *"WhatsApp jaisi simplicity, accountant jaisi accuracy"*

HisaabKaro is a Flutter mobile app designed for small Indian vendors — kirana stores, hardware shops, street vendors — who need simple tools to manage their daily business. No complex accounting software. No confusing screens. Just speak in Hindi and get things done.

---

## The Problem

**60M+ small businesses** in India still track credit (udhari) in paper notebooks. Existing apps like Tally, Khatabook, and Vyapar are either too complex or require too much typing. Most shopkeepers:

- Have low tech literacy
- Prefer Hindi / Hinglish over English
- Want to record transactions while attending to customers (hands busy)
- Need credit tracking more than anything else

## The Solution

A **voice-first** business assistant where a shopkeeper can say:

> *"Shah ke ₹200 aa gaye"*

...and the payment gets recorded automatically. No forms, no typing, no navigation.

---

## Features

### Built & Working

| Feature | Description |
|---------|-------------|
| **Voice Input** 🎤 | Speak in Hindi/Hinglish — text appears in chat, edit before sending |
| **Smart Chat** 💬 | Gemini 2.5 Flash AI — understands natural Hindi/Hinglish/English with live business context |
| **Voice Payments** 💰 | Say "Shah ke ₹500 aa gaye" → payment auto-recorded |
| **Credit Tracking** 📒 | Track udhari per customer with full transaction history |
| **Invoice Generation** 🧾 | Create PDF invoices with GST, units, decimal quantities |
| **Quick Cash Sale** ⚡ | Walk-in sales without customer — one tap from home screen |
| **Product Management** 📦 | Stock tracking, low-stock alerts, unit dropdown (kg, piece, dozen...) |
| **Customer Management** 👥 | Add, edit, search, sort by balance/name, filter pending only |
| **Payment Recording** 💳 | Date picker, payment mode (Cash/UPI/Bank/Cheque), notes |
| **Dashboard** 📊 | Live stats — total udhari, customer count, top debtors chart |
| **Invoice History** 📋 | View & reprint past invoices from dashboard |
| **Business Profile** 🏪 | Name, address, GSTIN on invoices |
| **GST Toggle** | Enable/disable GST per business, item-wise GST rates |

### Planned

| Feature | Status |
|---------|--------|
| **Android APK** | Ready for build |
| **WhatsApp Reminders** | Payment reminder via WhatsApp share |
| **Offline Mode** | SQLite cache for no-internet areas |
| **AI Business Insights** | Smart suggestions on dashboard ("Sharma ka payment 15 din se pending hai") |

---

## Screenshots

*Coming soon — app screenshots on mobile device*

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Frontend** | Flutter (Dart) — single `main.dart` file |
| **Backend** | Supabase (PostgreSQL + Auth + Realtime) |
| **PDF Generation** | `pdf` + `printing` Flutter packages |
| **Voice Input** | `speech_to_text` package (Web Speech API on Chrome, Google STT on Android) |
| **AI Chat** | Google Gemini 2.5 Flash API (live business context, Hinglish responses) |

## Database Schema

```
customers    → id, user_id, name, phone, balance, created_at
products     → id, user_id, name, price, stock, unit, low_stock_threshold, gst_rate, created_at
invoices     → id, user_id, customer_id, invoice_number, items (JSONB), subtotal, gst_amount, total, payment_type, created_at
transactions → id, user_id, customer_id, type (credit/debit/cash_sale), amount, items (JSONB), notes, created_at
```

---

## Getting Started

### Prerequisites

- Flutter SDK (3.x+)
- Chrome (for web development)
- A Supabase project (free tier works)

### Setup

```bash
# Clone the repo
git clone https://github.com/caaditijain0407-jpg/HisaabKaro.git
cd HisaabKaro

# Install dependencies
flutter pub get

# Add required packages (if not in pubspec.yaml)
flutter pub add supabase_flutter
flutter pub add pdf
flutter pub add printing
flutter pub add path_provider
flutter pub add speech_to_text

# Run on Chrome
flutter run -d chrome

# Build Android APK
flutter build apk --release
```

### Environment Setup

All secrets are passed via `--dart-define` (not hardcoded). Copy `.env.example` to `.env` and fill in your keys:

```bash
# Run locally with your keys
flutter run -d chrome \
  --dart-define=SUPABASE_URL=your_url \
  --dart-define=SUPABASE_ANON_KEY=your_key \
  --dart-define=GEMINI_API_KEY=your_gemini_key

# Build for web deployment
flutter build web --release \
  --dart-define=SUPABASE_URL=your_url \
  --dart-define=SUPABASE_ANON_KEY=your_key \
  --dart-define=GEMINI_API_KEY=your_gemini_key
```

### Deployment

**Live Demo:** Deploy to Netlify in 2 minutes — see [DEPLOY_NETLIFY.md](DEPLOY_NETLIFY.md)

### Supabase Configuration

1. Create the 4 tables (customers, products, invoices, transactions) — see schema above
2. Disable RLS on all tables (for MVP)
3. Turn OFF email confirmation in Auth settings
4. Run this SQL for decimal stock support:
```sql
ALTER TABLE products ALTER COLUMN stock TYPE NUMERIC;
ALTER TABLE products ADD COLUMN IF NOT EXISTS gst_rate NUMERIC DEFAULT 18;
```

---

## Voice Commands

The chatbot understands these commands in **Hindi, Hinglish, and English**:

| Command | Examples |
|---------|----------|
| **Record payment** | "Shah ke ₹200 aa gaye", "Sharma ne 500 diye" |
| **Check udhari** | "उधारी लिस्ट", "baaki dikhao", "pending list" |
| **Today's sales** | "आज की बिक्री", "aaj ka total", "today summary" |
| **Stock check** | "स्टॉक चेक", "maal kitna bacha" |
| **Make bill** | "बिल बनाना है", "invoice banana hai" |
| **Customer info** | Say any customer's name |
| **Help** | "help", "madad", "kya kar sakta hai" |

---

## AI Architecture

HisaabKaro uses a **dual-mode chat system** for maximum reliability:

**Mode 1: Gemini AI (Primary)** — When API key is configured
- Every message goes to Gemini 2.5 Flash with **live business context** (customer balances, product stock, today's sales)
- Gemini responds in natural Hinglish with ₹ symbols
- For payment commands, Gemini returns a hidden action tag (`##ACTION:PAYMENT|name|amount##`) that the app auto-executes
- System prompt is dynamically built with real-time Supabase data

**Mode 2: Keyword Matching (Fallback)** — When no API key or API is down
- Regex-based Hindi/Hinglish/English pattern matching
- Handles payments, udhari list, stock check, today's summary, bill creation
- Zero latency, works offline

This ensures the app **never breaks** — if AI is unavailable, keyword mode handles everything.

---

## Project Structure

```
lib/
  main.dart          # Complete app (single file for MVP)
android/
  app/src/main/
    AndroidManifest.xml   # Mic permission for voice
```

Currently everything is in a single `main.dart` file (~2000 lines) for rapid iteration. Will be split into proper architecture before Play Store release.

---

## Roadmap

### Phase 1: MVP ✅ (Current)
- [x] Phone number auth
- [x] Customer & Product CRUD
- [x] Invoice generation with PDF
- [x] Payment recording with date/mode/notes
- [x] Voice input (speech-to-text)
- [x] Hindi/Hinglish keyword chatbot
- [x] **Gemini 2.5 Flash AI integration** — natural language understanding
- [x] **AI-powered payment recording** — "Shah ke 200 aa gaye" auto-records
- [x] Quick Cash Sale
- [x] Search, sort, filter
- [x] Dashboard with invoice history
- [x] Netlify web deployment

### Phase 2: Enhancements (Next)
- [ ] AI-powered business insights on dashboard
- [ ] Smart suggestions ("Sharma ka payment 15 din se pending hai")
- [ ] Multi-turn conversation memory

### Phase 3: Play Store Release
- [ ] Split code into proper architecture
- [ ] Android APK build & testing
- [ ] Offline mode with SQLite
- [ ] WhatsApp payment reminders
- [ ] Play Store listing & ASO

### Phase 4: Growth
- [ ] Multi-language UI
- [ ] Barcode scanning for products
- [ ] Export reports (Excel/PDF)
- [ ] Multi-user support (staff accounts)

---

## Design Principles

1. **Simple over feature-rich** — shopkeepers don't want complexity
2. **Voice-first** — minimize typing, maximize speaking
3. **Hindi-first** — all responses in Hinglish (natural mix)
4. **Big tap targets** — fat fingers on small screens
5. **2-3 taps max** — everything should be achievable quickly
6. **Orange theme (#FF6B00)** — saffron for Indian market identity

---

## Target Users

- **Kirana store owners** in Tier 2/3 cities
- **Hardware shop** vendors
- **Street vendors** & small traders
- **Any MSME** in India's unorganized sector
- Low tech literacy, prefer Hindi
- Currently using paper notebooks or basic apps

---

## Contributing

This is currently a learning project but contributions are welcome! Please open an issue first to discuss what you'd like to change.

## License

MIT License — see [LICENSE](LICENSE) for details.

---

**Made with ❤️ for Indian small businesses**
