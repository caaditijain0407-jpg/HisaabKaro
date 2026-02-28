# Deploying HisaabKaro on Netlify

## Option A: Drag & Drop (Easiest — 2 minutes)

### Step 1: Build locally
```bash
cd ~/Desktop/HisaabKaro/03_App_Code/hisaab_karo

flutter build web --release \
  --dart-define=SUPABASE_URL=https://txqlreeelhyqpkvlsitj.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InR4cWxyZWVlbGh5cXBrdmxzaXRqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0OTM2NzMsImV4cCI6MjA4NzA2OTY3M30.Tw-YA-jafRku7OsOHaMUTsLbltvkBdJMSbJXY3TsJQk \
  --dart-define=GEMINI_API_KEY=AIzaSyBAHgZc0brSh2oSO6ii4xyJiyjKcMJr-IM
```

### Step 2: Deploy to Netlify
1. Go to https://app.netlify.com
2. Login (free account)
3. Click **"Add new site"** → **"Deploy manually"**
4. Drag & drop the `build/web` folder
5. Done! Your site is live at `https://random-name.netlify.app`

### Step 3: Custom domain (optional)
1. Site settings → Domain management → Add custom domain
2. Or just rename: `https://hisaabkaro.netlify.app`

---

## Option B: GitHub Auto-Deploy (For ongoing updates)

### Step 1: Push code to GitHub
```bash
cd ~/Desktop/HisaabKaro/03_App_Code/hisaab_karo
git init
git add .
git commit -m "HisaabKaro MVP — Voice-first MSME assistant"
git remote add origin https://github.com/YOUR_USERNAME/HisaabKaro.git
git push -u origin main
```

### Step 2: Connect Netlify to GitHub
1. Go to https://app.netlify.com
2. **"Add new site"** → **"Import from Git"** → Select your repo
3. Build settings:
   - **Build command:** `flutter build web --release --dart-define=SUPABASE_URL=$SUPABASE_URL --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY --dart-define=GEMINI_API_KEY=$GEMINI_API_KEY`
   - **Publish directory:** `build/web`
4. Add environment variables in Netlify dashboard:
   - `SUPABASE_URL` = your Supabase URL
   - `SUPABASE_ANON_KEY` = your Supabase anon key
   - `GEMINI_API_KEY` = your Gemini API key

> ⚠️ **Note:** Netlify needs Flutter SDK. You may need to use the Netlify Flutter build plugin or build locally.

---

## Recommended: Option A first, then move to Option B

Option A gets you live in 2 minutes. Option B is for when you want auto-deploy on every git push.

---

## After Deployment

- Share the Netlify URL with test users
- Test on mobile Chrome (add to home screen for app-like experience)
- Keys are safe in env vars, NOT in your GitHub code
