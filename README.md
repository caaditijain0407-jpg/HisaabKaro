# HisaabKaro — Voice-First Business Assistant for Small Businesses in India

> *"WhatsApp jaisi simplicity, accountant jaisi accuracy"*

HisaabKaro is a Flutter web app designed for small Indian vendors — kirana stores, hardware shops, street vendors — who need simple tools to manage their daily business. No complex accounting software. No confusing screens. Just speak in Hindi and get things done.

🔗 **[Live Demo](https://caaditijain0407-jpg.github.io/HisaabKaro/)** — Try it instantly, no signup needed!

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
| **AI Chat** 🤖 | Groq Llama 3.3 70B — understands natural Hindi/Hinglish/English with live business context |
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
| **Demo Mode** ▶️ | One-tap demo login with sample data — no signup needed |

### Planned

| Feature | Status |
|---------|--------|
| **Android APK** | Ready for build |
| **WhatsApp Reminders** | Payment reminder via WhatsApp share |
| **Offline Mode** | SQLite cache for no-internet areas |
| **AI Business Insights** | Smart suggestions on dashboard ("Sharma ka payment 15 din se pending hai") |

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **Frontend** | Flutter (Dart) |
| **Backend** | Supabase (PostgreSQL + Auth + Row Level Security) |
| **AI Chat** | Groq API — Llama 3.3 70B Versatile (Hindi/Hinglish/English) |
| **PDF Generation** | `pdf` + `printing` Flutter packages |
| **Voice Input** | `speech_to_text` package (Web Speech API on Chrome, Google STT on Android) |
| **Hosting** | GitHub Pages |

---

## AI Architecture

HisaabKaro uses a **dual-mode chat system** for maximum reliability:

**Mode 1: Groq AI (Primary)** — When API key is configured
- Every message goes to Llama 3.3 70B via Groq with **live business context** (customer balances, product stock, today's sales)
- AI responds in natural Hinglish with ₹ symbols
- For payment commands, AI returns a hidden action tag (`##ACTION:PAYMENT|name|amount##`) that the app auto-executes
- System prompt is dynamically built with real-time Supabase data

**Mode 2: Keyword Matching (Fallback)** — When no API key or API is down
- Regex-based Hindi/Hinglish/English pattern matching
- Handles payments, udhari list, stock check, today's summary, bill creation
- Zero latency, works offline

This ensures the app **never breaks** — if AI is unavailable, keyword mode handles everything.

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

## Database Schema

```
customers    → id, user_id, name, phone, balance, created_at
products     → id, user_id, name, price, stock, unit, low_stock_threshold, gst_rate, created_at
invoices     → id, user_id, customer_id, invoice_number, items (JSONB), subtotal, gst_amount, total, payment_type, created_at
transactions → id, user_id, customer_id, type (credit/debit/cash_sale), amount, items (JSONB), notes, created_at
```

Row Level Security (RLS) is enabled — each user can only access their own data.

---

## Getting Started

### Prerequisites

- Flutter SDK (3.x+)
- Chrome (for web development)
- A Supabase project (free tier works)
- A Groq API key (free at https://console.groq.com)

### Setup

```bash
# Clone the repo
git clone https://github.com/caaditijain0407-jpg/HisaabKaro.git
cd HisaabKaro

# Install dependencies
flutter pub get

# Run on Chrome with your keys
flutter run -d chrome \
  --dart-define=SUPABASE_URL=your_supabase_url \
  --dart-define=SUPABASE_ANON_KEY=your_supabase_key \
  --dart-define=AI_API_KEY=your_groq_key

# Build for deployment
flutter build web --release \
  --dart-define=SUPABASE_URL=your_supabase_url \
  --dart-define=SUPABASE_ANON_KEY=your_supabase_key \
  --dart-define=AI_API_KEY=your_groq_key
```

### Supabase Configuration

1. Create the 4 tables (customers, products, invoices, transactions) — see schema above
2. Enable RLS on all tables with `auth.uid() = user_id` policies
3. Turn OFF email confirmation in Auth settings
4. Run this SQL for decimal stock support:
```sql
ALTER TABLE products ALTER COLUMN stock TYPE NUMERIC;
ALTER TABLE products ADD COLUMN IF NOT EXISTS gst_rate NUMERIC DEFAULT 18;
```

---

## Roadmap

### Phase 1: MVP ✅ (Current)
- [x] Phone number auth + Demo mode
- [x] Customer & Product CRUD
- [x] Invoice generation with PDF
- [x] Payment recording with date/mode/notes
- [x] Voice input (speech-to-text)
- [x] Hindi/Hinglish keyword chatbot
- [x] AI-powered chat (Groq Llama 3.3 70B)
- [x] AI-powered payment recording — "Shah ke 200 aa gaye" auto-records
- [x] Quick Cash Sale
- [x] Search, sort, filter
- [x] Dashboard with invoice history
- [x] Row Level Security (data isolation per user)
- [x] GitHub Pages deployment

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

Contributions are welcome! Please open an issue first to discuss what you'd like to change.

## License

MIT License — see [LICENSE](LICENSE) for details.

---

**Made with ❤️ for Indian small businesses**
