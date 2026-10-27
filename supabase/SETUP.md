# Setting up sync

Montra syncs through your own free Supabase project. Your data is encrypted on your device
before it is uploaded, so the database only holds unreadable data.

## 1. Create the project
1. Go to https://supabase.com and sign up (free).
2. Click **New project**. Pick any name (for example `montra`), set a database password
   (save it somewhere; Montra doesn't need it), choose the region closest to you and create it.

## 2. Add the sync functions
1. In your project, open **SQL Editor** → **New query**.
2. Paste everything from [`montra-sync.sql`](montra-sync.sql) and click **Run**.
   It should say "Success". Running it again later is safe.

## 3. Copy two values
Open **Project Settings** → **API Keys** (or **Data API**) and copy:
- **Project URL**, like `https://abcdefgh.supabase.co`
- **Publishable key** (`sb_publishable_…`) or the legacy **anon public** key

Both are meant to be public. Never use the **secret** / **service_role** key.

## 4. Put them in the app
In `index.html`, find this line and fill in your two values:

```js
var SB_URL='',SB_KEY='';
```

## Using it
- On the device that has your data: **Home → Sync devices → Link a new device**. A 6-digit code appears.
- On the other device: **Home → Sync devices → I have a code**, then type the code.

Each code works once and expires after 10 minutes. After 10 wrong codes from one network,
guessing is blocked for 15 minutes.

Free Supabase projects pause after a week with no use. Supabase emails you, and you can
restore the project from the dashboard; your data is kept.
