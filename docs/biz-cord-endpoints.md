# biz-cord.com endpoints used by BoostBar

BoostBar calls two fixed addresses on biz-cord.com. Because the app only knows these URLs,
you can change the Stripe product, price, or storage on the site without shipping a new app.

---

## 1. Card payments: `GET /boostbar/donate`

The **Card $4.95** button in BoostBar's About window opens:

```
https://biz-cord.com/boostbar/donate?amount=4.95&app=BoostBar&version=1.3.4
```

**Simplest setup (no code): redirect to a Stripe Payment Link**

1. In the Stripe Dashboard, go to **Payment Links ▸ + New**.
2. Product: **"BoostBar energy drink"**, price **$4.95** (or choose *Customers choose what to pay* with $4.95 suggested).
3. Under *After payment*, show a confirmation page or redirect to `https://biz-cord.com/boostbar/thanks`.
4. Copy the link (`https://buy.stripe.com/...`).
5. On biz-cord.com, make `/boostbar/donate` return a **302 redirect** to that link.

Example (Express / Node):
```js
app.get('/boostbar/donate', (req, res) => {
  res.redirect(302, process.env.BOOSTBAR_STRIPE_LINK); // https://buy.stripe.com/xxxx
});
```

Example (Next.js App Router: `app/boostbar/donate/route.ts`):
```ts
import { redirect } from 'next/navigation';
export function GET() { redirect(process.env.BOOSTBAR_STRIPE_LINK!); }
```

**Alternative: Stripe Checkout Session (if you want the amount from the query string)**
```js
import Stripe from 'stripe';
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

app.get('/boostbar/donate', async (req, res) => {
  const cents = Math.round(Math.min(Math.max(parseFloat(req.query.amount) || 4.95, 1), 500) * 100);
  const session = await stripe.checkout.sessions.create({
    mode: 'payment',
    line_items: [{ quantity: 1, price_data: {
      currency: 'usd', unit_amount: cents,
      product_data: { name: 'BoostBar energy drink ⚡' } } }],
    success_url: 'https://biz-cord.com/boostbar/thanks',
    cancel_url: 'https://biz-cord.com/',
    metadata: { app: 'BoostBar', version: String(req.query.version || '') },
  });
  res.redirect(303, session.url);
});
```

---

## 2. Install counter: `POST /api/public/boostbar/install`

BoostBar sends this **once per version per Mac**. It retries on later launches until it gets a
2xx, so installs that happen before this endpoint exists are still counted once it's live.

Request body (JSON):
```json
{
  "app": "BoostBar",
  "event": "install",          // "install" = first run on this Mac, "update" = new version
  "install_id": "6F1C…-UUID",  // random, generated on the Mac; not tied to the user
  "version": "1.3.4",
  "previous_version": null,    // or e.g. "1.3.3" for updates
  "macos": "15.1.0",
  "arch": "arm64"              // or "x86_64"
}
```
Reply **204 No Content** (any 2xx works).

The Windows version sends the same request with `"platform": "windows"`, `"channel": "windows"`, `"macos": null` and
`"windows": "10.0.22631"` (major.minor.build); `arch` is `x86_64`, `arm64` or `x86`. Mac builds send `"channel": "direct"` or `"appstore"`.

Storage (Postgres example):
```sql
create table boostbar_installs (
  id               bigserial primary key,
  install_id       uuid not null,
  event            text not null check (event in ('install','update')),
  version          text not null,
  previous_version text,
  macos            text,
  arch             text,
  created_at       timestamptz not null default now()
);
create index on boostbar_installs (install_id);
```

Handler (Express):
```js
app.post('/api/public/boostbar/install', express.json({ limit: '2kb' }), async (req, res) => {
  const b = req.body || {};
  const uuid = /^[0-9A-F-]{36}$/i;
  if (b.app !== 'BoostBar' || !uuid.test(b.install_id || '') || !['install','update'].includes(b.event)) {
    return res.sendStatus(400);
  }
  await db.query(
    `insert into boostbar_installs (install_id, event, version, previous_version, macos, arch)
     values ($1,$2,$3,$4,$5,$6)`,
    [b.install_id, b.event, String(b.version).slice(0, 20), b.previous_version ? String(b.previous_version).slice(0, 20) : null,
     String(b.macos || '').slice(0, 20), String(b.arch || '').slice(0, 10)]);
  res.sendStatus(204);
});
```

Useful counts:
```sql
-- unique Macs that installed BoostBar
select count(distinct install_id) from boostbar_installs;
-- installs per day
select date(created_at), count(*) from boostbar_installs where event='install' group by 1 order by 1;
-- how many Macs are on each version
select version, count(distinct install_id) from boostbar_installs group by 1 order by 1 desc;
```

Privacy: the app sends no name, email, serial number or hardware ID, only a random ID.
The About window says so, and users can turn it off with **Share Anonymous Install Count** in the menu.
