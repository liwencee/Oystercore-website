# OysterCore Group platform: design

**Date:** 23 November 2026 (revision 3: no monthly cost to the client; review answers Q1 to Q3 added)
**Client:** OysterCore Group (Package Three, Ecosystem)
**Built by:** Slatech Solution Limited
**Status:** approved by Slatech on 23 November 2026. The client has signed the PRD (told by Slatech on 23 November), so the PRD is now the baseline and wording changes go through PRD §16.

Requirement IDs (CMS-01, PRC-05, and so on) refer to the client PRD, `OYSTERCORE_PRD.pdf`, reference OCG/WEB/2026-021-PRD v1.0, 9 November 2026. Copies are in `Desktop\Claude\` and `Documents\Oystercore\`. The PRD is the scope. This document says how that scope gets built. Where the two disagree, the PRD wins, unless this document says it is changing the PRD and why.

How decisions are marked here:

- **Decided by Slatech:** settled in conversation. Do not reopen it.
- **Claude's call:** proposed with a reason. The builder may change it, but only for an equally good reason.
- **Open:** waiting on OysterCore or Slatech. Build so that either answer fits.

---

## 1. Intent

OysterCore Group is a holding company with ten subsidiaries, and it needs one credible front door. Ministries, development agencies, multinationals and institutional investors will judge the group by this site. Over the coming years the site will also take in the group's tenders, vendor registrations, investor enquiries and job applications (PRD §2).

That makes it three things at once:

1. **A premium corporate site.** It presents the group and its ten companies, each company in its own colour.
2. **An editing system.** OysterCore's staff run it themselves, without a developer (CMS-01 to CMS-06).
3. **Three portals: procurement, careers and investors.** Each takes in confidential documents from the public.

The prototype gives the look. Everything in it is placeholder: copy is in [brackets], and the companies are "Company 01" to "Company 10" with sample colours. **So nothing on the site may be hard-coded (HOM-02).** Every name, colour, headline, figure, photo and link comes from the editing system.

## 2. Goals, non-goals, anti-goals

**Goals**
- Every requirement in PRD §7 and §8 is met and shown working against its acceptance criterion. The launch checklist is PRD §14. Where this design can't meet a PRD sentence at zero running cost, it says so and proposes new wording (§14, O1 and O8).
- The site matches the approved prototype: layout, palette, type, components and interactions.
- Editors manage all content through the editing system, using the roles in PRD §3.2. A company editor can reach only their own company.
- Confidential uploads (tender bids, vendor documents, CVs, investor-only files) are encrypted at rest. They are never reachable without authorisation, and they are checked and made safe before anyone can open them (§10.4).
- The site is fast on mobile against the Core Web Vitals targets in PRD §8. It must stay fast even though managed hosting stops apps that sit idle.
- **No monthly cost to OysterCore (decided by Slatech).** Everything runs on the Hostinger plan included in the package, on free tiers of outside services, or on subscriptions OysterCore already holds (§6).

**Non-goals** (from PRD §4.2, plus a few this design adds)
- Evaluating or scoring bids online. The portal receives bids; OysterCore evaluates them offline.
- ERP, HR, applicant-tracking or e-procurement integrations.
- Content in languages other than English at launch. The framework is ready for more (LNG-01, D1).
- Online payments, a mobile app, and running our own real-time chat server.
- Any paid service or paid edition: Strapi Growth or Enterprise, cloud storage, a paid malware scanner, a paid CDN or WAF plan.

**Anti-goals.** Any one of these makes the build a failure, even if every page works:
- A public or guessable URL that opens a bid, CV, vendor document or investor-only file.
- A sealed bid that can be opened before its tender closes, if D4 chooses sealed bids.
- A bid, CV or vendor document sent out as an email attachment, or pushed into Zoho, where this design can no longer control who opens it or when.
- A company editor able to change another company's content.
- Editors needing a developer for routine updates: news, tenders, vacancies, projects, documents or page text.
- The first visitor after a quiet spell waiting several seconds for a cold app.
- Copy, colours or company data written into templates instead of coming from the editing system.
- A monthly bill for OysterCore that nobody agreed to.

## 3. Constraints

- **Code (decided by Slatech):** Node.js and TypeScript throughout, on Node 22 LTS. Both Hostinger and Strapi 5 support it.
- **Hosting (decided by Slatech):** Hostinger managed Node.js web-app hosting on a Business or Cloud plan, not a VPS. Hostinger's limits page sets these rules:
  - No always-running background workers. Apps run on demand and stop when idle, and scheduled work runs from hPanel cron.
  - No inbound WebSockets, no Redis, no Docker, no custom ports, and no root access.
  - **Every request is cut off after 120 seconds.**
  - Every deploy overwrites `public_html` and `hbuilds/`, so files the app writes there do not survive a deploy.
  - A shared process limit (NPROC) covers every app on the plan: 120 on Business, 200 on Cloud Startup, 400 on Cloud Professional. Hostinger says one Next.js app uses about 10–11 threads.
  - Deploys come from GitHub, with auto-deploy on push. One GitHub account can be linked per plan. Node 18, 20, 22 and 24 are available.
- **Database:** the MySQL/MariaDB included with the plan. Strapi 5 needs MySQL 8.0+ or MariaDB 10.3+, through the `mysql2` driver.
- **Cost (decided by Slatech):** no monthly cost to the client. Outside services are used only on free tiers. Free tiers have limits, and §6 lists what happens if a limit is reached.
- **The "dedicated server" promise.** The PRD (§4.1, §8 Availability, §10) promises one, and managed hosting isn't one. See O1.
- **Timeline:** go-live is 8 weeks after the deposit *and complete content*, followed by 5 months of care (PRD §11). The deposit was received by 9 November 2026.
- **Compliance:**
  - WCAG 2.2 AA.
  - The Nigeria Data Protection Act 2023: data minimisation, consent records, retention and cross-border transfer.
  - Cookie consent before any non-essential script (CMP-01).
- **Content:** OysterCore supplies its copy and photos on the dates set in the Information Request (`OYSTERCORE_Information_Request.pdf`). Until then, build and test with clearly marked placeholders.

## 4. Approaches considered

| | Approach | What it buys | What it costs |
|---|---|---|---|
| A | **Payload CMS and Next.js in one app** | One TypeScript app, so one deploy and few threads. Drafts, versions, preview and field-level access control are built in. | No official MySQL support, so it needs an outside Postgres database with its own monthly bill. Admin two-step login needs a plugin. The build is heavy. |
| **B** | **Strapi 5 plus a separate front end (chosen)** | Uses the MySQL included with the hosting plan, so there's no outside database and the data stays on the plan. Mature editor interface. Custom admin roles are free in the Community edition. | Two apps, or four once staging is counted. Scheduled publishing (Releases) is in Strapi's paid plan. Admin two-step login isn't built in. Strapi isn't one of Hostinger's auto-detected frameworks, so it deploys as "Other". |
| C | **Our own Express or Fastify app on MySQL** | Full control and the smallest third-party footprint. | We'd build the admin, roles, drafts, scheduling and media library ourselves. That's weeks the schedule doesn't have, and more code to security-review. |

Two other options were ruled out. Directus charges a licence fee above US$5M annual revenue. WordPress isn't Node or TypeScript.

**Slatech picked B.** Claude had recommended A. A's outside database would also have broken the no-monthly-cost rule that came later, so B is the better fit now. B's costs are handled like this:

- **Scheduled publishing:** our own `publishAt` / `unpublishAt` fields and a cron job (§9).
- **Two-step login:** Cloudflare Access in front of the admin, plus a free TOTP plugin (§10.2).
- **Deploying as "Other":** a go/no-go deployment test before anything else (§13, Phase 0).

### Front end: Astro (Claude's call)

The front end is **Astro**, rendered on the server through its Node adapter:

- It ships plain HTML and adds JavaScript only where a page needs it: the hero slider, mega-menu, tabs, filters and booking calendar. That suits the mobile Core Web Vitals targets.
- It runs as one light Node process, which matters when four apps share one thread limit.
- Hostinger lists it as a supported framework.
- Its server routes handle forms and portal sessions.

Next.js would also work. It was set aside because it uses more threads and puts React on every page.

## 5. System overview

```
             Browser
                │  HTTPS
         ┌──────▼───────────────────────────────────────────┐
         │ Cloudflare Free: DNS, CDN cache, free managed WAF│
         │ rules, Turnstile, Access (admin, staging)        │
         └──────┬───────────────────────────┬───────────────┘
                │                           │
   www.<domain> │                           │ cms.<domain>
   ┌────────────▼──────────┐   server-to-   ┌▼────────────────────────────┐
   │ Astro (SSR, Node)     │───server only─►│ Strapi 5 (admin + API)      │
   │ pages, forms, portal  │  API token +   │ content, portal users,      │
   │ sessions, /media      │  shared secret │ submissions, file checks,   │
   └──────────┬────────────┘                │ encryption, jobs, audit     │
              │ browser ⇄ /transfer/*       └──┬───────────────┬──────────┘
              │ (signed, short-lived tokens)   │               │
              └───────────────────────────────►│               │
   ┌───────────────────────────────────────────▼──┐   ┌────────▼────────┐
   │ Hostinger disk, outside deploy folders:      │   │ Hostinger MySQL │
   │ ~/oc-data/media     (public images, docs)    │   └─────────────────┘
   │ ~/oc-data/private   (encrypted uploads)      │
   │ ~/oc-data/tmp       (chunked uploads)        │
   └──────────────────────────────────────────────┘
   Free or existing outside services: Zoho CRM (existing), Zoho SalesIQ (free),
   newsletter (free plan, D7), calendar (existing Google/Microsoft, D9),
   Google Maps Embed, GA4, Clarity, Sentry (free), UptimeRobot (free),
   Cloudflare R2 (free tier, encrypted off-site backups), Hostinger SMTP (email)
   hPanel cron ──► POST cms.<domain>/internal/jobs/tick  (every minute)
```

**Hostinger sites.** There are four. Each is its own Hostinger "website" with its own Node app, database and data folder.

| Site | App | Git branch | Database | Data folder |
|---|---|---|---|---|
| `www.<domain>` | Astro | `main` | none (reads through Strapi) | reads `~/oc-data/media` |
| `cms.<domain>` | Strapi | `main` | `oc_prod` | `~/oc-data/` |
| `staging.<domain>` | Astro | `staging` | none | reads `~/oc-data-staging/media` |
| `cms-staging.<domain>` | Strapi | `staging` | `oc_staging` | `~/oc-data-staging/` |

`~` is the hosting account's home directory. It sits outside `public_html` and `hbuilds/`, so the web server never serves it and deploys never touch it. Phase 0 proves both points.

**What staging is for (decided by Slatech, 23 November).** Staging tests *code, design and new templates* before they reach the live site. It does not move content.
- **Content is checked as a draft on the live site.** An editor saves a draft, opens the preview button in the admin, and then publishes or schedules it. The preview shows the draft on `www.<domain>` (§12).
- **That includes new companies and pages in the care period** (PRD §11.1). A new company is a draft entry on the live site, previewed and then published. Only work that needs new code, such as a new kind of page, is built on staging first.
- **Staging's database** is filled from production with personal data scrubbed, so tests run against realistic content. Nothing travels the other way. Strapi's transfer command replaces a whole database, so it is never pointed at production.
- **The PRD wording for CMS-06 and §11.1 changes** (O9).

**Repository.** One monorepo holds:
- `apps/web`: the Astro front end.
- `apps/cms`: Strapi.
- `packages/shared`: zod schemas for every form, design tokens, generated Strapi types, the time and status rules in §8, and the file-check rules in §10.4.

Each Hostinger site points at its own root directory in the repo. Phase 0 confirms that Hostinger handles a pnpm monorepo. If it doesn't, use two repositories.

**Who can call Strapi.**
- Strapi's public content API is switched off for the public role. Astro reads content with a read-only API token plus a shared-secret header, and Strapi refuses API calls that lack both.
- Editors reach `cms.<domain>/admin` only through Cloudflare Access.
- A few paths are open on the internet, each with its own check:
  - `/internal/*`, used by cron and webhooks, requires a bearer secret.
  - `/transfer/*`, used by browsers to upload and download files, requires a signed token that expires within minutes.
  - `/_health`.

**Hostinger plan (open item O2).** The four Node apps share one process limit. Cloud Startup or above (NPROC 200) gives headroom. Business (NPROC 120) may be enough, but Phase 0 must measure real thread use for Strapi and Astro under load before committing. The plan must fit the hosting line already in the quote.

## 6. Outside services: free tiers or existing subscriptions only (Claude's call)

| Service | Used for | Cost to OysterCore | If the free limit is reached |
|---|---|---|---|
| Cloudflare Free | DNS, CDN, SSL, the free managed WAF rules, DDoS protection, one rate-limiting rule, Turnstile, Access (free for up to 50 users) | $0 | Access is capped at 50 named users. At about 20–30 staff, that's enough headroom. |
| Zoho CRM | Every form (LEAD-01) | Existing subscription (PRD §4.3) | — |
| Zoho SalesIQ, free plan | Live chat (CHT-01) | $0 | Outside chat hours, or when the plan's limit is reached, the widget is replaced by a "Leave a message" button that opens our own enquiry form. That form goes to the CRM, so CHT-01 holds at $0 regardless. |
| Newsletter platform's free plan (D7; Zoho Campaigns suggested) | LEAD-06 | $0 | Growing past the free contact limit is a later choice for OysterCore. |
| OysterCore's existing Google Workspace or Microsoft 365 (D9) | Calendar for bookings (LEAD-05) | Existing subscription | — |
| Google Maps Embed API | Office locator (CON-02) | No usage charge | The builder confirms how the key is set up. Directions links need no key. |
| GA4, Search Console, Microsoft Clarity | Analytics (PRD §8) | $0 | — |
| Sentry, free plan | Error tracking | $0 | Errors beyond the monthly quota are dropped. Logs on Hostinger remain. |
| UptimeRobot, free plan | 24/7 uptime monitoring, alerts by email and app (PRD §8) | $0 | Checks every 5 minutes. |
| Cloudflare R2, free tier | Encrypted off-site backups (§11) | $0 while storage stays under 10 GB | The retention rule keeps it under, with an alert at 8 GB. Cloudflare needs a payment method on file to switch on R2. If OysterCore won't add one, backups go to their existing Google Workspace or Microsoft 365 storage instead. |
| Hostinger email (SMTP) | Notifications and confirmations | Included in the package's mailboxes | Phase 0 records the mailbox's daily sending limit. Form volume is far below it. |

All accounts are opened in OysterCore's name, or in a form that can be transferred at handover (PRD §10 Handover, §13). See O3.

**What zero cost gives up, compared with the first revision of this design:**
- **Real antivirus scanning of uploads.** It's replaced by checks that strip active content (§10.4, O8).
- **Cloudflare Pro's fuller WAF and rate limiting.** Rate limiting moves into the app (§10.5).
- **Cloud object storage.** Files live on the Hostinger disk, encrypted (§10.4).

## 7. Content model (Strapi)

Draft-and-publish is switched on for every content type the public sees. The i18n plugin is on, with English as the only locale (LNG-01). Every public type carries a shared **SEO component**: title, description, Open Graph image, canonical, noindex, and schema type.

### Collection types

**Company** (GRP-02, GRP-04)
- **Fields:**
  - Identity: name, slug, legal name, RC number, founded, head office, contact email and phone.
  - Brand: **brand colour**, logo, tagline.
  - Page content: overview (rich text), facts, leaders (a component with name, title, bio and portrait), figures (a component with value and label).
  - Home slider: hero headline, hero sub-text, hero image.
  - Display: sort order, active flag.
- **Colours (Claude's call): the brand colour is never refused.** Readable colours are derived from it. On save, a lifecycle hook stores two values:
  - **`onAccent`:** the first of white, deep navy and pure black (`#000000`) that gives at least 4.5:1 contrast on the brand colour. Black is the last resort, because some mid-tone colours (for example `#808080`) reach 4.5:1 with neither white nor navy. It's used for text on colour fields: the hero, buttons and chips. (Black added while planning, 23 November.)
  - **`accentOnWhite`:** the brand colour, darkened until it gives 4.5:1 on white. It's used for coloured text and links on white.

  So yellows, oranges and light greens still work, and the editor never sees an error. The theme CSS uses only the derived values for text.
- **Adding a company:** an eleventh company is just a new entry. GRP-04 is tested by adding one.

**Service and Industry** (16 of each; SVC-01, SVC-02)
- **Service:** name, slug, summary, body, capabilities, delivering companies (a relation), images, FAQs (a component), and quote fields (see LEAD-04 below).
- **Industry:** name, slug, summary, body, related services, and an example project.

**Project** (PRJ-01 to PRJ-04)
- **Fields:**
  - Links: company, services, industries.
  - Facts: location, year, client name, client logo, a **confidential** flag.
  - Story: challenge, approach, outcome, gallery images, videos, testimonial.
- **The confidential flag is enforced inside Strapi, not the front end.** When it's set, Strapi's response sanitiser removes the client name and logo, so they never leave Strapi (PRJ-04).
- **Related projects** come from the shared service, industry and company tags (SVC-03).

**News item** (NEW-01, NEW-02)
- Fields: category (news, press release, CSR, event or award), company (optional), featured flag, date, body, image.

**Document** (Download Centre; DLC-01 to DLC-03)
- Fields: title, description, category, year, file, access (`public` or `investor`), plus format and size, which are filled in from the file automatically.
- **Public files** are kept in the media store.
- **Investor files** are kept in the encrypted private store.
- **The public API returns details only, never a file URL.** Downloads go through §10.4.

**Office** (CON-02)
- Fields: name, address, phone, email, hours, latitude/longitude, sort order.

**Vacancy** (CAR-01)
- Fields: title, company, location, type, closing date and time, description, requirements.

**Tender** (PRC-04)
- Fields: reference, title, scope, eligibility, category, company (optional), public documents, amendments (a component with date and note).
- `closesAt` is stored as a moment in time and displayed in Africa/Lagos time.

**Vendor registration** (PRC-01, PRC-02)
- Fields: portal user, company details (the fields in prototype board 05), categories, documents, company (optional), reviewer notes.
- Status: `received`, `under_review`, `approved` or `rejected`.

**Tender submission** (PRC-05 to PRC-07)
- Fields: tender, vendor, files (with the SHA-256 of each), submitted-at (server time), receipt number.

**Application** (CAR-02, CAR-03, CAR-05)
- Fields: what it's for (a vacancy, a programme, or "general CV"), company (empty for a general CV), personal fields, CV file, and the version of the consent text the applicant saw.

**Investor access request** (INV-03)
- Fields: requester details, reason, status, decided by, decided at.

**Form submission**
- One table covers enquiry, quote, booking, investor enquiry and newsletter forms.
- Fields: form type, payload (JSON, validated), source page, company, service, consent text version and timestamp, a hash of the IP address, CRM sync status.

**Landing page**
- Covers the 13 marketing pages, plus About, Governance, HSE, Quality, ESG, Why OysterCore, Capabilities, Our Process and the legal pages (GRP-03, SVC-04).
- Built from a dynamic zone of section components: hero, rich text, cards, figures, FAQ, testimonial, call to action, and gallery.

**FAQ**
- Fields: question, answer, topic.

**Routing rule** (LEAD-02, D8)
- Fields: form type, company, service, region, owner email, Zoho owner ID, priority.
- A fallback rule is required.

### Single types

- **Site settings:** emergency line, WhatsApp number(s) (D6), social links, footer text, company number, chat hours.
- **Home:** group slide (headline, sub-text, video, poster), headline figures, featured items, trust badges.
- **Procurement page, Careers page, Investor page:** the static copy, policies (PRC-08), disclaimers (INV-04), and the graduate and internship pages (CAR-04).

### Internal types

These are not editable in the admin.

- **Audit event:** who, what, when, which record, before and after. Append-only.
- **Stored file:** owner record, original name, detected type, size, SHA-256, the encrypted data key, and status.
- **Job lease.**
- **Outbox message.**
- **Search entry.**
- **Rate-limit counter.**

### Quote fields per service (LEAD-04)

Each Service holds a repeatable "quote field" component with: label, type (text, number, select, date or file), options, and required. The quote form shows these fields once a service is picked. The Astro server builds a zod schema from the same definition, so validation always matches the form.

## 8. Rules that depend on time

All of these live in `packages/shared` and are covered by unit tests. They use one function for the server clock. Times are stored in UTC and shown in Africa/Lagos time (WAT, UTC+1, no daylight saving).

**Tender status (PRC-04, PRC-05)**
- A tender is `open` while now < `closesAt`, and `closed` otherwise. **This is worked out on every read and never stored**, so it can't drift and needs no job.
- A submission is accepted only if the server's time when the vendor **presses Submit** is before `closesAt`. Every one of its files must already have finished uploading and passed the checks in §10.4. Because those checks run as each file finishes uploading, the vendor knows of any rejected file before pressing Submit, with time to replace it.
- The receipt records the moment of acceptance and each file's SHA-256.
- Upload tokens are issued only before `closesAt`. They expire at `closesAt`, or after 15 minutes if that comes first.
- A bid half-done at the deadline is refused, and the vendor is told why. D4 may change this rule; procurement confirms it in week 4.

**Changing a tender's closing time**
- `closesAt` can be moved later while the tender is open, **never after it has closed**.
- Every change is written to the audit log and shown on the notice as an amendment.

**Vacancies (CAR-01).** A vacancy is listed only while now < its closing time.

**Scheduled publishing (CMS-03)**
- An entry with a future `publishAt` stays a draft until the cron tick publishes it. `unpublishAt` does the reverse.
- The public site shows the change within about a minute (NEW-02): one minute of cron, plus up to 60 seconds of edge caching.

## 9. Work done without background processes

hPanel cron calls `POST https://cms.<domain>/internal/jobs/tick` **every minute**, with a bearer secret. Phase 0 confirms that Hostinger allows one-minute cron.

**How a tick runs**
1. It takes a lease row in MySQL, so ticks that overlap skip instead of running twice.
2. It runs whatever jobs are due, within a 60-second budget.
3. It returns. Anything unfinished carries over to the next tick.

**Jobs**
- **Scheduled publish and unpublish.**
- **Outbox:** emails and Zoho CRM pushes, retried with exponential backoff. After 10 failures a message is dead-lettered and an alert goes out.
- **Temp cleanup:** deletes unfinished chunked uploads older than 24 hours.
- **Retention:** runs daily and deletes personal data and files past their retention period (O5).
- **Search index catch-up:** a safety net. The index is normally updated by lifecycle hooks.
- **Nightly backup** (§11). It runs in steps across several ticks, to stay inside the 120-second limit.

**Sending straight away.** Emails and CRM pushes are tried first inside the request itself, with a 5-second timeout. They fall back to the outbox only if that fails. That is what meets "both emails arrive within a minute" (LEAD-03).

**Keeping the apps warm.** A second cron calls `https://www.<domain>/healthz` every 5 minutes, so the front end is never cold when a visitor arrives. The one-minute tick already keeps Strapi awake.

## 10. Security design

The bar is OWASP ASVS 4.0 level 2 for everything that handles personal data or bids. Before launch, the builder works through the ASVS L2 checklist and PRD §14 item 7, and records the result.

### 10.1 Threats this design guards against

- **Competitors reading bids:** before or after closing, by guessing URLs, abusing a vendor account, or getting at the hosting account's files.
- **Credential stuffing and account enumeration** on vendor and investor sign-in.
- **Malicious uploads:** disguised file types, documents with macros or scripts, embedded files, decompression bombs, oversized files.
- **Form spam and bots** (LEAD-07).
- **Insiders overreaching:** a company editor touching another company, or anyone reading CVs or bids outside their role.
- **A compromised editor, admin or hosting account.**
- **Leaked secrets and vulnerable dependencies.**
- **Third-party scripts** on public pages.

### 10.2 Admin access (CMS-02, CMS-01)

**Two layers in front of the admin**
- **Cloudflare Access** (free for up to 50 users) protects `cms.<domain>/admin` and every staging host. Editors sign in with OysterCore's Google or Microsoft identity, or with Cloudflare's emailed one-time code. **This is the required second factor, and it doesn't depend on a Strapi plugin.**
- **Strapi's own login** sits behind it. Passwords are at least 12 characters. Lockout and rate limits are on.

**TOTP plugin.** `strapi-identity` (MIT licence, supports Strapi 5) is evaluated in Phase 0 as a further layer. It's added only if it passes code review and is actively maintained. Either way, Cloudflare Access alone meets CMS-02.

**The hosting account itself.** Anyone who can sign in to hPanel can reach the database, the files and the environment variables. So:
- Two-step login is mandatory on the Hostinger account.
- There are two named owners, one at Slatech and one at OysterCore after handover.
- Access is never shared as a single password.

**Admin roles** (Strapi's custom roles, which are free):
- Super Admin: Slatech only, for emergencies, two named accounts.
- Group Administrator.
- Communications.
- Company Editor.
- Procurement Officer.
- Group HR.
- Company HR.
- Investor Relations Officer.

**Which roles cover the whole group, and which cover one company (Claude's call; PRD §3.2 confirms in discovery)**
- **Group-wide by default:** Procurement Officer, Group HR, Investor Relations Officer.
- **Own company only:** Company Editor and Company HR. A custom RBAC condition, "the entry's company is one of the user's companies", applies on every type that has a company field. Phase 0 proves custom conditions work in the Community edition. If they don't, the fallback is one role per company with the condition built in.
- **Optional company field** on Tender, Vendor registration, Vacancy and Application. If OysterCore turns out to run procurement per company, a "Company procurement" role uses that field with the same condition. That's a new role, not a schema change.

**Audit log.** Strapi's audit log is an Enterprise feature, so we keep our own **Audit event** table, written from lifecycle hooks and middleware. It records:
- admin logins and failed logins;
- role changes;
- status changes on vendor registrations and investor requests;
- every download of a bid, CV, vendor document or investor document;
- every change to a tender's closing time;
- publishes.

It's append-only at the API level and goes into the nightly backup.

### 10.3 Portal accounts (vendors, investors)

**Accounts and sessions**
- Vendors and investors are Strapi `users-permissions` users, with the roles `vendor` and `investor`. They are completely separate from admin users.
- Only the Astro server calls Strapi's sign-in endpoints, never the browser. Astro keeps the Strapi JWT inside a sealed (AES-GCM) cookie: httpOnly, Secure, SameSite=Lax.
- Sessions end after 30 minutes idle, and after 8 hours regardless.
- **Ending sessions.** Each user has a `sessionVersion` field, checked on every request. Signing out, changing the password, or an admin action bumps it, which ends all of that user's sessions.

**Sign-up and sign-in**
- The email address is verified before anything else.
- Passwords must be at least 12 characters. They're checked against known breaches through the HIBP k-anonymity range API, which sends only a 5-character hash prefix (free).
- Wording never reveals whether an account exists.
- Sign-in is rate-limited per IP and per account (§10.5).

**Investor access (INV-02, D3)**
- Gated content needs an approved investor account.
- Under either D3 model, a request creates an **Investor access request**. The Investor Relations Officer approves or declines it in the admin, the requester is emailed, and the decision is audited.
- If D3 chooses invitation only, open sign-up is switched off and the officer sends invite links instead.

**Vendor accounts.** A vendor can sign in once their email is verified, and work on their registration. They can submit tenders only once the registration is `approved` (PRC-03, PRC-05).

### 10.4 Files and uploads (PRC-06, PRC-07, CAR-02, DLC-03)

**Where files live**
- **Public media:** `~/oc-data/media/`.
  - Strapi's media library writes here through a small custom upload provider.
  - Strapi creates the responsive image sizes with sharp.
  - File names are content-hashed. Astro serves them at `www.<domain>/media/*` with `Cache-Control: public, max-age=31536000, immutable`, so Cloudflare caches them and the app is rarely hit.
  - If Phase 0 finds the Astro site can't read this folder, Strapi serves it at `cms.<domain>/media/*` instead.
- **Private uploads:** `~/oc-data/private/`. This holds bids, vendor documents, CVs, quote attachments and investor-only documents.
  - **Every file is encrypted at rest** with AES-256-GCM, in chunks.
  - Each file gets its own random data key. That key is wrapped by a master key held only in an environment variable.
  - So a file copied through FTP or the File Manager, or taken from a backup, is unreadable on its own. Someone with full hPanel access could still read the environment variable, which is why two-step login on hPanel is mandatory (§10.2).
  - Only Strapi decrypts files.

**How an upload works.** Files are uploaded in chunks, because of the 120-second limit.
1. The signed-in user picks a file. Astro asks Strapi for an upload slot.
2. Strapi checks the declared type against that form's allow-list, the declared size against its limit, and the number of files. It then returns a signed upload token for `cms.<domain>/transfer/upload/:token`, valid for 15 minutes and tied to the user, form, size and type. CORS allows only `www.<domain>`.
3. The browser sends the file in **5 MB chunks**, each as its own request. That's about 40 seconds per chunk even at 1 Mbps, well under the 120-second limit. An interrupted upload resumes from the last chunk received. Chunks collect in `~/oc-data/tmp/`.
4. Once the last chunk arrives, Strapi checks that the SHA-256 the browser sent matches the assembled file. It then runs **the file checks** below, encrypts the file into the private store, deletes the temporary copy, and tells the browser whether the file was accepted or rejected, and why.

**Size limits.** Each file is limited to 25 MB by default, and D4 may set it lower. A submission can carry up to 10 files, so a large proposal can be split.

**The file checks.** These run inside Strapi in Node, at no cost. They are content disarm, not antivirus.
- **Real type.**
  - The file's magic bytes must match an allowed type for that form. The extension and the browser's claim are ignored.
  - Allowed by default: PDF, JPG and PNG for vendor documents, bids and quote attachments; PDF and DOCX for CVs.
  - XLSX is allowed for bids only if D4 needs it, and then gets the same checks as DOCX.
  - Never allowed: archives (ZIP, RAR), legacy Office files (.doc, .xls), macro-enabled files (.docm, .xlsm), and executables or scripts.
- **Images** are decoded and re-encoded with sharp. That strips metadata and anything appended to the file. Only the re-encoded copy is kept.
- **PDFs** are parsed. A PDF is rejected if it:
  - is encrypted or can't be parsed;
  - contains JavaScript (`/JS`, `/JavaScript`);
  - contains automatic actions (`/OpenAction` or `/AA` that run scripts or launch anything, or `/Launch`);
  - contains embedded files (`/EmbeddedFile`, `/FileAttachment`);
  - contains `/RichMedia` or `/XFA`.
- **DOCX and XLSX** are opened as zip packages. A file is rejected if it contains:
  - a VBA project (`vbaProject.bin`);
  - ActiveX controls;
  - embedded OLE objects;
  - external relationships (`TargetMode="External"`, which is how remote-template attacks work);
  - more than 50 MB uncompressed, more than 1,000 entries, or a compression ratio above 100:1 (decompression bombs).
- **Optional known-malware hash check (Claude's call, Phase 0 to evaluate).** The file's SHA-256 is looked up on abuse.ch MalwareBazaar's free API. Only the hash leaves the server, never the file. It's added only if the terms allow commercial use.
- **How files are served.** Files always download as attachments, with `Content-Disposition: attachment`, `X-Content-Type-Options: nosniff` and a generic content type for anything that isn't an image. They are never displayed inside our pages.
- **Staff computers.** As a compensating control, OysterCore IT confirms that staff computers run endpoint antivirus, so a file is also scanned when it's opened.

**What this does and doesn't cover.**
- **It covers** the ways documents usually carry malware: macros, PDF scripts and launch actions, embedded files, disguised types, and decompression bombs.
- **It doesn't cover** a file that exploits a bug, not yet publicly known, in a PDF reader or in Word. That file could still pass the checks.
- **The PRD needs rewording.** PRC-07's acceptance test ("a disallowed or infected file is rejected") and PRD §8's "malware scanning" overstate what this does. See O8 for the proposed wording.

**How a download works.** There are two routes, one for each kind of account. Both use one checking service inside Strapi, so the rules can't drift apart.
- **Portal users** (vendors opening their own documents, approved investors): `GET https://www.<domain>/files/:id`.
  1. Astro checks the portal session and asks Strapi.
  2. Strapi checks the role and the rules below, writes an audit event, and returns a **single-use download token valid for 60 seconds**.
  3. Astro redirects to `cms.<domain>/transfer/download/:token`.
  4. Strapi decrypts and streams the file, with HTTP Range support.
- **Staff** (Strapi admin users): from inside the admin. A button on the record calls `cms.<domain>/admin-files/:id`, which sits behind Cloudflare Access and needs the Strapi admin session. It runs the same check and audit, and returns the same kind of token.
  - For files over about 25 MB, the button downloads in Range pieces and joins them in the browser, so each request stays under the 120-second limit.

**Who may download what**
- **Bids:** Procurement Officers only. If D4 chooses sealed bids, **only after `closesAt`**. Strapi refuses to issue a token before then. Only Strapi can decrypt, so this is enforced in one place.
- **Vendor documents:** Procurement Officers, and the vendor who uploaded them.
- **CVs:** Company HR for the applicant's company, plus Group HR. General CVs have no company and go to Group HR only.
- **Quote attachments:** the owner set by the routing rule, plus the Group Administrator.
- **Investor documents:** approved investors, and the Investor Relations Officer.

**Files never travel by email or into Zoho (decided by Slatech, 23 November).** A copy that leaves the encrypted store can't be sealed until closing, audited, or deleted on schedule.
- **Emails name the record and carry a link, never the file.** For example: "New application for Company 03: open it in the admin." The link opens the record in `cms.<domain>/admin`, behind Cloudflare Access and the Strapi login. The role-based mailbox the PRD mentions (CAR-03, Information Request §11) still receives these notifications.
- **Zoho gets the form fields and the same link,** never the file. A CRM user without an admin account sees the fields but can't open the file.
- **Quote attachments (LEAD-04) follow the same rule.**
- **Applicants and vendors get no copy of their upload by email.** Their confirmation lists the file names. A tender submission also gets its receipt.
- **So everyone who needs to open a file needs a named admin account** and a seat in Cloudflare Access: HR for each company, Group HR, procurement, the investor relations officer, and whoever owns each quote route. That's an estimated 20 to 30 people against a free limit of 50 (O10).

**File names.** The name the user uploaded is kept as metadata only. It's never used to store the file, and it's cleaned before it goes into the `Content-Disposition` header.

### 10.5 Forms and rate limits (LEAD-01 to LEAD-07)

Every form posts to an Astro server route. That route:
1. Checks that `Origin` is our domain.
2. Checks the SameSite cookie and a per-form CSRF token (for signed-in portal forms).
3. Verifies the **Cloudflare Turnstile** token (LEAD-07). Turnstile shows no puzzle, which suits WCAG 2.2's rule on accessible sign-in.
4. Validates the input with the shared zod schema.
5. Applies the **app rate limits**.

**Rate limits.** Cloudflare Free allows only one edge rate-limiting rule, and we spend it on the sign-in, sign-up and password-reset paths together. Everything else is limited in the app, using counters in MySQL kept per IP hash and per email over sliding windows. Expired counters are cleaned by the retention job.

The route then saves the submission to Strapi, together with the version of the consent text the visitor saw. Consent text is versioned in the editing system (CMP-02). Finally it pushes the submission to Zoho CRM and sends both emails (§9).

### 10.6 Browser hardening

- **Content Security Policy:**
  - nonce- or hash-based scripts;
  - `default-src 'self'`;
  - an explicit list of allowed hosts for Maps, GA4, Clarity, SalesIQ and Turnstile;
  - `frame-ancestors 'none'`, `base-uri 'none'`, `form-action 'self'`.

  It ships in report-only mode on staging first, then is enforced.
- **Other headers:**
  - HSTS, with `preload` added only once the domain is final;
  - `X-Content-Type-Options: nosniff`;
  - `Referrer-Policy: strict-origin-when-cross-origin`;
  - a `Permissions-Policy` that blocks camera, microphone and geolocation.
- **Rich text** from Strapi blocks is rendered through a structured renderer. **Raw HTML from editors is never rendered.**
- **Fonts and scripts are self-hosted.** No Google Fonts calls; the prototype currently loads them from Google. Third-party scripts load only after consent.
- **Caching.** Portal pages, form pages and anything personalised send `Cache-Control: private, no-store`. Cloudflare cache rules bypass the cache whenever a session cookie is present.

### 10.7 Supply chain and secrets

**Secrets**
- Secrets are kept only in Hostinger environment variables and the CI secret store, with a separate set for each environment.
- The file master key and the backup public key are generated at setup.
- The backup *private* key is never stored on the server. It's kept offline by two named people, one at Slatech and one at OysterCore.
- A rotation runbook goes into the handbook. Rotating the file master key re-wraps the data keys; files aren't re-encrypted.

**Dependencies**
- `pnpm` with a lockfile.
- Renovate for updates: weekly batches, with security updates immediately.
- `pnpm audit`, OSV-Scanner and gitleaks run in CI on GitHub Actions' free minutes.

**Branch protection.** Hostinger deploys on every push, so `main` and `staging` are protected branches. A merge needs CI passing and one review.

### 10.8 Data protection (NDPA 2023)

- **Minimal forms.** Forms collect only the fields shown in the prototype boards.
- **Consent.** Consent is recorded together with the version of the text that was shown.
- **Retention.** The retention schedule (O5) is enforced by the daily job.
- **Data-subject requests.** A runbook covers exporting and deleting a person's data.
- **Staging data.** Staging is filled from production only after personal data is scrubbed.
- **Where the data goes:**
  - It lives in the Hostinger data centre chosen at setup.
  - It passes through Cloudflare.
  - CRM data goes to Zoho.
  - Encrypted backups go to Cloudflare R2.

  The DPO signs off these transfers (O4).

## 11. Reliability, backups, monitoring

**Backups**
- **First layer:** Hostinger's own daily backups, included in the plan. They cover the databases and the home directory, including `~/oc-data`.
- **Off-site copy** (PRD §8): the nightly backup job.
  1. It dumps each production database.
  2. It packs that dump with a list of what changed in `~/oc-data` since the previous run.
  3. It encrypts everything with the **backup public key**, so the server can make backups but can't read old ones.
  4. It uploads the result to **Cloudflare R2's free tier**. Private files are already encrypted, so they're copied as they are.
- **Retention:** 14 daily and 8 weekly backups. An alert fires when storage reaches 8 GB of the 10 GB free limit.
- **Restore tests:** one into staging before go-live (PRD §14 item 7), then monthly during the care period.

**Monitoring**
- UptimeRobot (free) checks `www`, `cms/_health`, and the time of the last cron tick.
- Sentry (free) watches both apps.
- The tick reports how long the outbox queue is, and alerts if it grows.
- Disk use under `~/oc-data` is reported weekly against the plan's storage limit.

## 12. Front end

**Design system** (from prototype board 00):
- **Colours**

  | Name | Hex |
  |---|---|
  | Deep navy | `#0B1F3A` |
  | Group navy | `#14305C` |
  | Gold | `#C9A24B` |
  | Dark gold (gold text on white) | `#8A6A1C` |
  | Light grey | `#F2F4F8` |
  | Slate | `#4B5668` |

- **Type:** headings in Manrope 800; body in Inter 400 at 17px on desktop.
- **Controls:** form fields are 48px tall. Buttons come in primary, dark, outline and text-link styles, plus chips and status pills.
- **Implementation:** all of these become CSS custom properties. On each company's pages, `--company-accent` is set from that company's derived colours.

**Pages and templates** follow PRD §6. The final list is fixed when the sitemap is signed off (D10).

**Home hero** (HOM-01). This comes from prototype board 01, plus the client's note of 9 November.
- **Slides.** There are 11: the group slide, then one per active company, in their sort order.
- **Controls.** The slider advances every 6 seconds and has pause and play, previous and next, and company chips. If the visitor's device asks for reduced motion, it starts paused.
- **The company cards.** On desktop, the stack of company cards on the right **links to each company's page.** In the prototype these cards only switched slides; the client's annotated screenshot of 9 November asks for links. The chips, the arrows and auto-advance still change slides.
- **The group slide** plays a muted video with a poster image.
  - The poster is the page's largest visible element, the one the LCP target measures. The video loads after first render.
  - If reduced motion or Save-Data is on, only the poster shows.

**Interactive pieces.** These are small islands, written in vanilla TypeScript, or Preact where one needs it:
- the hero slider;
- the mega-menu;
- the portal tabs;
- the filters (projects, careers, downloads);
- the booking calendar;
- the multi-step vendor registration;
- the chunked uploader.

Every one must work by keyboard and with a screen reader. The prototype's focus styles, reduced-motion handling and ARIA labels are the starting point.

**Search** (SRC-01)
- A MySQL FULLTEXT index on the **Search entry** table, kept current by lifecycle hooks.
- **Only published, public items are indexed**, so gated content can't show up in results.

**WhatsApp** (CON-01). A `wa.me` link on every page, using the number or numbers from D6.

**Maps** (CON-02). A Google Maps Embed iframe that switches to the office the visitor picks. Until consent is given, a static placeholder with a "Load map" button shows instead. Directions links work without consent.

**Draft preview.** The preview button in Strapi opens `www.<domain>/preview?token=…`.
- The token is signed by Strapi, tied to one entry, and expires after 10 minutes.
- The page renders the draft with `noindex`, `Cache-Control: private, no-store`, and a visible "Draft preview" banner.
- Cloudflare Access also protects the `/preview` path, so only signed-in staff reach it. Phase 0 confirms Access can protect a path on the public host. If it can't, the signed token is the only control.

**SEO** (PRD §9)
- `sitemap.xml` and `robots.txt` are generated from Strapi.
- Staging is `noindex` and sits behind Access.
- Structured data:
  - Organization;
  - LocalBusiness for each office;
  - BreadcrumbList;
  - Article for news;
  - **JobPosting for vacancies** (Google for Jobs);
  - FAQPage.

**Performance budgets.** Lighthouse CI fails the build if the home page, or the company, service, project or news template, goes over any of:
- 2.5 seconds mobile LCP;
- 0.1 CLS;
- 70 KB of compressed JavaScript.

Public HTML is cached at Cloudflare for 60 seconds, with stale-while-revalidate.

## 13. Delivery phases

**Phase 0: deployment test (2–3 days, go/no-go).** On the real Hostinger plan, prove each of these:
1. Strapi (deployed as "Other") and Astro build and run from the monorepo.
2. Strapi connects to Hostinger's MySQL or MariaDB. Record the version.
3. The Strapi admin builds within Hostinger's build limits.
4. **The app can write to `~/oc-data` and the files survive a redeploy.** The Astro site can read `~/oc-data/media` (same account user). The folder isn't web-served.
5. A chunked upload of a 25 MB file works over a throttled connection, through the checks, encryption and a Range download.
6. One-minute cron reaches `/internal/jobs/tick`.
7. Cloudflare Free sits in front of all four hosts, with Access on admin and staging.
8. Email sends through Hostinger SMTP. Record the daily limit.
9. An encrypted backup reaches R2 and is restored into staging.
10. Thread use under a 50-user load test stays inside the plan's process limit.
11. Custom RBAC conditions work in Strapi Community.

**If items 1–4 fail, stop and take it to Slatech.** Moving Strapi to a VPS or switching to approach A each carry a monthly cost, so this is Slatech's decision, not one to work around quietly.

**Phase 1: foundation.** The content model, roles and conditions, the audit log, the design system, the header and footer, the home page, Our Group, the company template, CI, and staging live. The **project case study and portfolio prototype board** is designed in the first week, so the sponsor can approve it before Phase 2 builds projects.

**Phase 2: content sections.**
- About and its subpages.
- Services and industries.
- Projects.
- News.
- The Download Centre.
- FAQ.
- Contact: enquiry, quote, and booking through the D9 adapter.
- Zoho CRM and routing.
- Search.
- Consent and analytics.

**Phase 3: portals.**
- Procurement: registration, review, the supplier area, tenders and submission.
- Careers.
- Investors.
- The file pipeline (§10.4) is built at the start of this phase.

**Phase 4.** The 13 marketing pages, live chat, the newsletter, and the hardening pass.

**Phase 5: launch readiness.** Content loading, the accessibility audit, the Core Web Vitals report, the ASVS checklist, the restore test, training and the handbook, then go-live against PRD §14.

**Design approval (decided by Slatech, 23 November)**
- **Approved as prototype boards**, which is the PRD's design gate (DR-04): the eleven existing boards, plus one new board for the project case study and portfolio.
- **Every other template** is built straight from the design system. The sponsor reviews each on staging as its phase finishes. The PRD's three revision rounds still apply.
- **The sponsor signs off the boards in writing.** That sign-off is the design approval gate in DR-04.

**Testing**
- **Unit tests (vitest):** the time and status rules, routing, schema building, the file checks and encryption. File checks get a fixture set: a PDF with JavaScript, a PDF with an embedded file, an encrypted PDF, a DOCX with a macro, a DOCX with an external template, a decompression bomb, a renamed EXE, and clean files. Tender closing gets tests one second either side of `closesAt`.
- **Integration tests:** Strapi against MySQL or MariaDB, at the version Phase 0 recorded, in GitHub Actions.
- **End-to-end tests (Playwright, on staging):** every PRD acceptance criterion a browser can show. That includes one test per form, each portal from start to finish, a signed-out request for an investor file being refused, and a confidential project hiding its client.
- **Accessibility:** axe on every template.
- **Performance:** Lighthouse CI for the budgets in §12.

## 14. Open items

**Client decisions from PRD §17.** Each is taken as a setting or an adapter, so no answer forces rework:
- D1: languages.
- D2: hero video source.
- D3: investor access model.
- D4: tender rules, including accepted file types and the size limit.
- D5: vendor workflow.
- D6: WhatsApp numbers.
- D7: newsletter platform, on its free plan.
- D8: lead routing.
- D9: calendar platform.
- D10: sitemap.

**Items this design adds**

| # | Item | Owner | Why it matters |
|---|---|---|---|
| O1 | The PRD (§4.1, §8, §10) and the quote promise a "dedicated server". The site will run on managed shared hosting. | Slatech, with OysterCore, as a written change request under PRD §16 (the PRD is signed) | It's a contract statement that won't be true. |
| O2 | Which Hostinger plan: Business, or Cloud Startup and above. | Slatech | Four Node apps share one process limit. Phase 0 measures it. The plan must fit the hosting line in the quote. |
| O3 | Who owns the Cloudflare, GitHub, Sentry and UptimeRobot accounts, and how they're handed over. | Slatech and OysterCore | PRD §10 and §13 promise to hand over credentials. Accounts opened under Slatech will have to move. |
| O4 | DPO sign-off on where the data goes: the Hostinger data-centre location, Zoho, Cloudflare, and encrypted R2 backups. | OysterCore's DPO | Required by NDPA 2023. Pick the data-centre location when the plan is set up. |
| O5 | How long to keep CVs, vendor documents, bids, form submissions and audit logs. | OysterCore legal and HR | Drives the deletion job. The careers form already has a placeholder for this. |
| O6 | Does OysterCore have a website live today? If so, its URLs need a 301 redirect map. | OysterCore | Avoids losing search rankings and existing links at launch. |
| O7 | The final domain (`.com` or `.com.ng`) and where email is hosted. | OysterCore | Affects DNS, Cloudflare, email deliverability (SPF, DKIM, DMARC), and the cutover described in PRD §15. |
| O8 | **The malware-scanning wording.** PRC-07, PRD §8 Security and §14 item 7 all promise "malware scanning". Zero cost rules out a real scanner. Proposed wording: "Uploads are limited by type and size, and checked and disarmed: macros, scripts, embedded files and disguised file types are rejected." Acceptance: "A disallowed or unsafe file is rejected." | Slatech, with OysterCore, as a written change request under PRD §16 (the PRD is signed) | Same as O1: the PRD must not promise what won't be delivered. If OysterCore later wants true scanning, it's a paid add-on that plugs in at step 4 of the upload flow. |
| O9 | **PRD wording that the answers to Q1 and Q2 change.** CMS-06 and PRD §11.1 say changes are "checked on staging" and new pages are "built on the staging environment first". Proposed wording: code, design and new templates are tested on staging, and content is checked as a draft preview before it's published. CAR-02 and CAR-03 say an application is "received with its CV attached" and "sent to the HR inbox". Proposed wording: HR is notified and opens the CV from the record. The quotation's staging line needs the same fix. | Slatech, with OysterCore, as a written change request under PRD §16 (the PRD is signed) | The acceptance tests as written would fail, even though the platform works as designed. |
| O10 | **Who needs an admin account.** A list of everyone who has to open files or edit content: HR for each company, Group HR, procurement, the investor relations officer, communications, company editors, and anyone who owns a quote route. | OysterCore | Cloudflare Access is free for up to 50 users, and the design estimates 20 to 30. The four training sessions (PRD §13) must also cover opening files, not only editing content. |

**Raised by the design review on 23 November**

Answered by Slatech on 23 November, by accepting Claude's picks:
- **Q1. File delivery.** Files are never emailed or pushed into Zoho. Emails and CRM records carry a link to the admin record (§10.4).
- **Q2. Staging.** Staging is for code, design and new templates. Content is checked as a draft preview on the live site (§5, §12).
- **Q3. Templates without a prototype board.** They are built from the design system and reviewed on staging. The project case study gets a prototype board first (§13).

Still open:
- **Q4. Schedule.** The PRD is signed (Slatech, 23 November). Still unknown: is the sitemap (D10) signed, how many developers are building this, and is launch fixed at about 4 January 2027, or does it move with content, as PRD §11 allows? The answers decide whether the build plan runs as one sequence or as parallel tracks with cut lines. They don't change this design.

## 15. Left to the builder

These are the builder's calls:
- Folder layout inside each app.
- Component library and naming.
- Test structure.
- The exact Cloudflare rules.
- The CSP host list.
- Where Turnstile sits on each form.
- Email templates.
- The Zoho field mapping.
- Image breakpoints.
- How each island is built.
- Which PDF and zip parsing libraries to use.
- The chunk-encryption format (for example, STREAM-style chunked AES-GCM with the chunk index in the associated data).
- Whether Astro sessions use a sealed cookie, or Astro's session API with a database driver, as long as the rules in §10.3 hold.

## 16. Reference material

- **Prototype boards:** markup for each board is in `design/prototype/`, next to this document. Each board's `<script type="text/x-dc">` block holds its interaction logic and sample data.
  - The full bundle is `Downloads\OysterCore Website Design Prototype.html`.
  - The design-canvas artifact is at https://claude.ai/artifact/S3LHD9b49YJz2ZPoZPSQCw
- **Screenshots** in `Documents\Oystercore\`:
  - `Design foundations@2x.png`
  - `Home (desktop)@2x.png`
  - `Home (mobile)@2x.png`
  - `WhatsApp Image 2026-11-09 at 8.17.06 PM.jpeg`, the client's annotated hero screenshot.
- **What OysterCore has to supply:** `OYSTERCORE_Information_Request.pdf`.
- **Hostinger limits:** https://www.hostinger.com/support/hostinger-node-js-limits-for-web-and-cloud-plans/
- **Strapi supported databases:** https://docs.strapi.io/snippets/supported-databases
