# ClassPay (working name) — Requirements, Market Research & Design

Status: **DRAFT v0.5 — 58-screen prototype with student portal, expanded workflows, and low-cost serverless design**. Sections 1–19 retain the product requirements and historical proposals; sections 20–25 are the current implementation recommendation. A clickable front-end demo exists with four role views (owner, parent, teacher, student), but production services are not yet connected.

---

## 1. Vision

One app (Android + iOS) that runs the full lifecycle of a small teaching business (music class, tuition, dance, sports coaching):

**Create batch → enroll students → schedule classes → set fees → remind → collect (UPI/card/cash) → receipt → track revenue & GST.**

Primary goal: **everyone pays by the due date**, with minimal manual chasing by the admin.

### Users and roles

| Role | Who | Can do |
|---|---|---|
| **Admin / Owner** | You | Everything: users, batches, fees, payments, reports, GST, settings |
| **Teacher** | Instructors | See own batches/schedule, mark attendance, (optional) see roster only; no financial data by default |
| **Parent / Guardian** | Pays for 1+ children | See children, schedules, dues, pay, upload proof, download receipts |
| **Student** (adult or teen) | Learner | See own schedule, attendance, (optional) pay own fees |

Admin creates all accounts (requirement 6). One parent login can be linked to several students (siblings).

---

## 2. Market research (what exists today)

Quick scan of fee/class-management tools used by Indian tutors and academies. Findings come mostly from vendor pages, so treat claims as unverified marketing.

| Tool | What it advertises | Takeaway for us |
|---|---|---|
| [TutorOne](https://www.goodfirms.co/software/tutorone) | UPI collection via Razorpay, auto reminders, GST invoicing, parent portal without app install, no commission | Parent web-link (no install) is valuable |
| [CoFee](https://cofee.life/blog/introducing-cofee-the-ultimate-fee-collection-app) | Due reminders by SMS/WhatsApp/push, digital receipts, UPI/cards/net banking | Multi-channel reminders are table stakes |
| [Tufee](https://apps.apple.com/us/app/-/id6740474461) | Fee tracking, SMS reminders, receipts, offline-first | Offline/simple tracking matters for cash-heavy classes |
| [FeeAlert](https://www.softwaresuggest.com/feealert) | WhatsApp reminders + UPI payment links for coaching centres | WhatsApp + payment link is the dominant pattern |
| Teachmint, Classplus, Fedena, MyClassBoard | Not verified in this research (search did not return them) | Larger school/ed-tech suites; likely heavier than a solo teacher needs. **TODO: review hands-on before final scope** |

**Gaps we can exploit**
1. Most tools are fee trackers *or* schedulers; few combine **scheduling + attendance + fees + GST** in one simple flow.
2. Per-student vs per-batch fee models, sibling discounts, and pro-rated joining mid-month are often clumsy.
3. Cash + screenshot-proof reconciliation (the real-world way small classes get paid) is usually an afterthought.
4. Revenue **target tracking** and GST period summaries are rarely built in for solo operators.

### Payment gateway notes (verify before committing)
- UPI MDR is 0% for merchants; gateways still charge a platform fee. [Razorpay](https://razorpay.com/blog/razorpay-payment-gateway-pricing-explained/) publishes ~2% + 18% GST on that fee (UPI listed within it); Cashfree is reported around 1.75–1.95% by [third-party comparisons](https://www.paritydeals.com/blog/best-payment-gateways-india-2026/). Pricing must be confirmed directly.
- Recurring options: UPI AutoPay mandates / subscriptions (extra ~1% reported, per-mandate limits apply — unverified) and Payment Links.
- **Cost-saving design choice:** offer a **zero-fee path** (show your UPI QR / VPA, parent pays in any UPI app, uploads screenshot, admin confirms) *and* an **in-app gateway path** (auto-reconciled, with fees). Admin picks per their preference; gateway fee can be absorbed or passed on as a convenience fee (check RBI/gateway rules).

### GST notes (verify with a CA)
- Per [published guides](https://www.incorpx.io/blog/gst-on-education-coaching-services-india-2026), coaching/hobby/music classes by non-recognised institutions are generally **taxable at 18% (SAC 9992)**; recognised educational institutions are exempt. Search results did not confirm the 2026 registration threshold or QRMP rules.
- From general knowledge (**to be verified**): service-provider registration threshold is ₹20 lakh turnover (₹10 lakh in special-category states); small taxpayers may opt for quarterly filing (QRMP, up to ₹5 crore) with monthly tax payment; GSTR-1 / GSTR-3B are the main returns.
- The app will be a **calculation and export aid, not a filing tool or tax advice**. GST rate, thresholds, and filing frequency are **admin-configurable** so law changes don't need an app update.

---

## 3. Functional requirements

Legend: **MVP** = first release · **V2** = next · **V3** = later/optional.

### 3.1 Accounts & roles (Req 6)
- **MVP** Admin creates Teacher / Student / Parent accounts (name, phone, email); invite by SMS/WhatsApp link.
- **MVP** Login via **phone number + OTP** (no password to forget; parents/kids friendly). Optional PIN/biometric unlock.
- **MVP** Role-based access (table in §1). Parent ↔ multiple students link.
- **MVP** Deactivate/archive users without losing payment history.
- V2 Multiple admins / staff accountant role (limited to payments).
- V3 Multiple branches/institutes (multi-tenant).

### 3.2 Batches (classrooms) & scheduling (Req 0, 1, 7)
- **MVP** Create batch: name, subject/instrument, teacher, room/online link, capacity, start/end date, level.
- **MVP** Weekly recurring schedule (e.g. Mon/Wed 5–6 pm) + one-off sessions.
- **MVP** Add/remove students per batch; a student may be in several batches; student-specific time slot if different.
- **MVP** Reschedule / cancel a single session with auto-notify; mark holidays.
- **MVP** Calendar views: day / week / list for admin, teacher, parent.
- **MVP** Teacher/room clash detection.
- V2 Attendance marking by teacher (present/absent/late), attendance report; absent → optional make-up class.
- V2 Trial class / waitlist for full batches.
- V3 Teacher payroll (per-class or monthly pay).

### 3.3 Fees (Req 0)
- **MVP** Fee plans: **per student** or **per batch** (batch fee applies to each enrolled student, or split — configurable); frequency monthly / quarterly / term / one-time.
- **MVP** Admission fee, material/exam fee as extra line items.
- **MVP** Due date rule (e.g. 5th of every month) + grace days + optional late fee.
- **MVP** Auto-generate **invoices/fee dues** each cycle per student.
- **MVP** Discounts: sibling, scholarship, custom amount per student.
- V2 Pro-rata fee for mid-cycle joining; pause/leave of absence; refunds and credit notes.
- V2 Advance payment/wallet credit carried forward.

### 3.4 Payments (Req 1, 2, 0)
- **MVP** Pay in app: **UPI** (intent to GPay/PhonePe/Paytm etc.), **card**, **net banking** via gateway (e.g. Razorpay/Cashfree). Auto-marks fee as paid on webhook.
- **MVP** Pay outside the app via admin's UPI QR/VPA → parent **uploads screenshot** + UTR/reference → status **"Pending verification"** → admin approves/rejects.
- **MVP** **Cash / cheque / bank transfer**: admin records "Paid by cash", date, amount, note → receipt auto-issued.
- **MVP** Partial payments and part-settled dues; payment history per student.
- **MVP** Duplicate protection (same UTR twice flagged).
- V2 Payment link (shareable via WhatsApp) that works without app install.
- V2 UPI AutoPay / recurring mandate for monthly fees.
- V2 Bank-statement/CSV import for bulk reconciliation.
- V3 Gateway-fee pass-through toggle; payouts report.

### 3.5 Reminders & notifications (Req 3)
- **MVP** Class reminders to students/parents (e.g. 1 day + 1 hour before), push notification; SMS/WhatsApp as fallback.
- **MVP** Fee reminders to parents/guardians: before due (3 days), on due date, overdue (+1, +7, +14 days) — templates and cadence editable.
- **MVP** One-tap "Remind all unpaid" and "Remind this parent".
- **MVP** Schedule-change/cancellation alerts.
- V2 WhatsApp Business API integration (needs template approval & cost per message — see §8).
- V2 Quiet hours; per-parent language (English/Hindi/regional).
- V2 Escalation: after N days overdue, flag for admin follow-up/call.

### 3.6 Receipts & invoices (Req 5)
- **MVP** Auto-generated PDF receipt on every confirmed payment (sequential receipt no., date, student, batch, period, mode, amount, GST breakup).
- **MVP** Send via WhatsApp/SMS link/email/push; downloadable from the parent's app.
- **MVP** Custom business header (name, logo, address, GSTIN).
- V2 GST tax invoice format when GST-registered; credit notes.

### 3.7 Revenue, targets & reports (Req 2, 7, 0)
- **MVP** Admin dashboard: collected this month, outstanding, overdue count, collection rate %.
- **MVP** **Targets**: set monthly/quarterly/yearly revenue target → progress bar and "on track / behind" indicator.
- **MVP** "Who hasn't paid" list sorted by days overdue, with one-tap reminder / call / mark cash.
- **MVP** Reports: revenue by batch, by month, by payment mode; export CSV/PDF.
- V2 Forecast of expected vs actual; aging buckets (0–7, 8–30, 30+); teacher/batch profitability; student retention/churn.

### 3.8 GST (Req 4)
- **MVP** Settings: GST registered? GSTIN, rate (default 18%), prices **inclusive or exclusive** of GST, filing frequency **monthly / quarterly / yearly**.
- **MVP** GST summary report for any period: taxable value, GST collected, (CGST/SGST vs IGST split by state), payments excluded/exempt.
- **MVP** Turnover tracker with alert as annual turnover nears the registration threshold (configurable).
- V2 Export in GSTR-1/3B-friendly CSV for the accountant; input-tax-credit (expenses) tracking.
- Disclaimer in-app: reports are assistive, confirm with a CA.

### 3.9 Parent / student experience
- **MVP** Home: next class, pending dues, pay button, recent receipts.
- **MVP** Child switcher for multi-child parents.
- V2 Progress notes / teacher remarks, homework/resources, announcements.

---

## 4. Non-functional requirements
- **Security & privacy:** OTP login, TLS, encrypted data at rest, role-based access, audit log of payment edits. Children's data → collect minimum PII; follow India's DPDP Act (parental consent for minors, data export/delete on request).
- **Payments compliance:** never store card data (gateway hosted/tokenised, PCI handled by gateway); webhook signature verification.
- **Reliability:** payment status must be idempotent; screenshots stored securely with size limits.
- **Performance/offline:** schedule and dues viewable offline; sync when online.
- **Accessibility/UX:** large tap targets, English + Hindi (more later), light/dark.
- **Scale:** designed for ~1–5 admins, ≤ ~2,000 students initially.

---

## 5. Key flows

### 5.1 Fee lifecycle
```
Fee plan set ─► Cycle starts ─► Due created ─► Reminder (D-3)
     ─► Parent pays ──┬─ in-app UPI/card ─► webhook ─► PAID ─► receipt
                      ├─ outside UPI + screenshot ─► PENDING ─► admin approves ─► PAID ─► receipt
                      └─ cash ─► admin marks PAID ─► receipt
     ─► Not paid by due date ─► OVERDUE ─► reminders D+1/D+7/D+14 ─► admin follow-up
```

### 5.2 Payment status machine
`DUE → (PENDING_VERIFICATION) → PAID` · `DUE → PARTIAL → PAID` · `DUE → OVERDUE → PAID` · `PAID → REFUNDED (V2)`

---

## 6. Data model (high level)

```
User(id, role, name, phone, email, status)
ParentStudentLink(parent_id, student_id)
Batch(id, name, subject, teacher_id, capacity, start, end, fee_plan_id)
Enrollment(id, student_id, batch_id, slot_override, join_date, status)
Session(id, batch_id, start_ts, end_ts, status[scheduled|cancelled|done], room)
Attendance(session_id, student_id, status)             -- V2
FeePlan(id, scope[student|batch], amount, frequency, due_day, grace_days, late_fee, gst_mode)
FeeDue(id, student_id, enrollment_id, period, amount, discount, gst_amount, due_date, status)
Payment(id, fee_due_id, amount, mode[upi|card|netbanking|cash|bank], ref/UTR,
        proof_url, status[pending|verified|rejected], recorded_by, paid_at)
Receipt(id, payment_id, number, pdf_url, sent_via, sent_at)
Reminder(id, type[class|fee], target_user, channel, scheduled_at, status)
Target(id, period, amount)
BusinessSettings(name, logo, gstin, gst_rate, filing_freq, inclusive, upi_vpa, gateway_keys)
AuditLog(id, actor, action, entity, before, after, ts)
```

---

## 7. Original tech stack proposal (historical; superseded by §20)
- **App:** Flutter *or* React Native — one codebase for Android + iOS. Recommendation: **Flutter** (consistent UI, good offline support).
- **Backend:** Node.js (NestJS) or Python (FastAPI) + **PostgreSQL**; scheduled jobs for fee generation and reminders.
- **Auth:** Firebase Auth phone OTP (or MSG91).
- **Payments:** Razorpay or Cashfree (decide after comparing fees/UPI AutoPay support).
- **Messaging:** FCM push; SMS (MSG91/Twilio); WhatsApp Business API (V2).
- **Storage:** S3-compatible for screenshots & receipt PDFs.
- **Hosting:** managed cloud (AWS/GCP) in an India region.

---

## 8. Risks & open decisions
1. **WhatsApp reminders** cost per message and need template approval; push + SMS first, WhatsApp in V2.
2. **Gateway fees** (~2% on UPI per published pricing) may annoy; hence the zero-fee screenshot path.
3. **GST rules** vary by entity type/state and change; configurable + CA review.
4. **App-store policy:** fees for real-world services (classes) are allowed outside in-app purchase, but confirm with Apple review guidelines.
5. **Minors' data** (DPDP consent).
6. Unverified competitor claims → hands-on trial of 2–3 tools before finalising scope.

### Questions for you
- Q1 Solo operator or multiple branches/admins? Approximate number of students/batches?
- Q2 Are you GST-registered today? Expected annual turnover?
- Q3 Should the batch fee be **per student in batch** or a **fixed total split across students**?
- Q4 Which gateway do you already have (Razorpay/Cashfree/none)? Do you want the zero-fee screenshot flow as default?
- Q5 Reminder channel priority: push, SMS, WhatsApp?
- Q6 Languages required?
- Q7 Do teachers need to see fee status of students?
- Q8 Late fees and refunds policy?

---

## 9. Release plan
| Phase | Scope |
|---|---|
| **MVP (≈8–10 wks)** | Roles/login, batches & schedule, fee plans & dues, cash/screenshot/in-app payments, reminders (push+SMS), receipts, admin dashboard, targets, basic GST report |
| **V2** | Attendance, WhatsApp, payment links, AutoPay, pro-rata/refunds, GSTR exports, languages |
| **V3** | Multi-branch, payroll, parent engagement features, analytics |

---

## 10. UX principles
- Admin's home answers 3 questions in 5 seconds: *How much collected? Who's overdue? What's today's schedule?*
- Max 2 taps for the common tasks: mark cash paid, send reminder, approve screenshot.
- Parents see one primary button: **Pay now**.
- Status colors + text labels (not color alone): Paid (green), Pending (amber), Overdue (red).
- Bottom navigation, role-specific.

---

## 11. Wireframes (low-fidelity, for refinement)

### 11.1 Login (OTP)
```
┌──────────────────────────┐
│        ♪ ClassPay        │
│                          │
│  Welcome back            │
│  ┌────────────────────┐  │
│  │ +91  98xxxxxx10    │  │
│  └────────────────────┘  │
│  [     Send OTP       ]  │
│                          │
│  Accounts are created    │
│  by your institute admin │
└──────────────────────────┘
```

### 11.2 Admin — Dashboard
```
┌──────────────────────────────┐
│ Hi Ravi ▾ Sharma Music Class │ 🔔
├──────────────────────────────┤
│ October target     ₹1,20,000 │
│ ████████████░░░░░  ₹78,000   │
│ 65%  • Behind pace (−₹12k)   │
├──────────────┬───────────────┤
│ Collected    │ Outstanding   │
│ ₹78,000      │ ₹42,000       │
├──────────────┼───────────────┤
│ Overdue: 9   │ Pending ✓: 3  │
│ [Remind all] │ [Review]      │
├──────────────────────────────┤
│ Today's classes               │
│ 5:00pm Guitar-B1  (12)  Anil │
│ 6:00pm Keyboard-A2 (8)   Mia │
├──────────────────────────────┤
│ Overdue fees                  │
│ Aarav K.  ₹2,000  6d  [📞][⏰]│
│ Diya M.   ₹2,000  3d  [Cash]  │
├──────────────────────────────┤
│ Home Batches Payments Reports│
└──────────────────────────────┘
```

### 11.3 Batches list & create batch
```
┌──────────────────────────────┐        ┌───────────────────────────┐
│ Batches              [+ New] │        │ New batch              ✕  │
│ 🔍 search                    │        │ Name   [Guitar Beginners] │
│ ┌──────────────────────────┐ │        │ Teacher [Anil ▾]          │
│ │ Guitar Beginners  12/15  │ │        │ Days  [M][T][W][T][F][S][S]│
│ │ Mon Wed 5–6pm • ₹2,000/mo│ │        │ Time  [5:00pm]–[6:00pm]   │
│ │ ● 2 overdue              │ │        │ Capacity [15]             │
│ └──────────────────────────┘ │        │ Fee   (•) Per student     │
│ ┌──────────────────────────┐ │        │       ( ) Per batch       │
│ │ Keyboard A2        8/10  │ │        │ Amount [₹2,000] [Monthly▾]│
│ │ Tue Thu 6–7pm • ₹2,500/mo│ │        │ Due day [5th] Grace [3d]  │
│ └──────────────────────────┘ │        │ Starts [01 Nov 2026]      │
│ Home Batches Payments Reports│        │ [      Create batch     ] │
└──────────────────────────────┘        └───────────────────────────┘
```

### 11.4 Batch detail (roster)
```
┌──────────────────────────────┐
│ ← Guitar Beginners        ⋮  │
│ Mon Wed 5–6pm • Anil • Rm 2  │
│ [Schedule] [Students] [Fees] │
├──────────────────────────────┤
│ Students (12)    [+ Add]     │
│ Aarav K.   ● Paid            │
│ Diya M.    ● Overdue 3d      │
│ Rohan S.   ● Pending verify  │
│ Sana P.    ● Due in 2d       │
│  └ custom slot: Fri 4pm      │
├──────────────────────────────┤
│ Next: Mon 20 Oct  [Cancel][↻]│
└──────────────────────────────┘
```

### 11.5 Student / fee record (admin)
```
┌──────────────────────────────┐
│ ← Aarav K.                   │
│ Parent: Mr. Kumar 98xxxxxx10 │
│ Batches: Guitar Beginners    │
├──────────────────────────────┤
│ Oct 2026   ₹2,000   OVERDUE  │
│ [Mark paid (cash)] [Remind]  │
│ [Add discount]               │
├──────────────────────────────┤
│ Sep 2026   ₹2,000   PAID UPI │
│ Receipt #R-0143   [View][⇪]  │
│ Aug 2026   ₹2,000   PAID Cash│
│ Receipt #R-0098   [View][⇪]  │
└──────────────────────────────┘
```

### 11.6 Record cash payment (bottom sheet)
```
┌──────────────────────────────┐
│ Record payment – Aarav K.    │
│ Amount   [₹2,000]            │
│ Mode     (•)Cash ( )Cheque   │
│          ( )Bank  ( )UPI     │
│ Date     [14 Oct 2026]       │
│ Note     [Paid to Anil]      │
│ [✓ Send receipt to parent]   │
│ [      Save & issue       ]  │
└──────────────────────────────┘
```

### 11.7 Verify uploaded screenshots (admin)
```
┌──────────────────────────────┐
│ Pending verification (3)     │
│ ┌──────────────────────────┐ │
│ │ Rohan S. ₹2,500  14 Oct  │ │
│ │ UTR 4021xxxx88  [🖼 proof]│ │
│ │ [Reject]     [Approve ✓] │ │
│ └──────────────────────────┘ │
└──────────────────────────────┘
```

### 11.8 Reports & GST
```
┌──────────────────────────────┐        ┌───────────────────────────┐
│ Reports                      │        │ GST summary               │
│ Period [Oct 2026 ▾]          │        │ Period [Q2 Jul–Sep ▾]     │
│ Revenue by batch   ▇▇▇▇ ▇▇   │        │ Taxable value  ₹3,05,085  │
│ By mode  UPI 60% Cash 30%    │        │ GST @18%         ₹54,915  │
│ Aging  0-7 ▇▇  8-30 ▇  30+ ▏ │        │ Total collected ₹3,60,000 │
│ [Targets] [GST] [Export CSV] │        │ Turnover YTD  ₹6.1L / 20L │
└──────────────────────────────┘        │ [Export CSV] [PDF]        │
                                        │ ⓘ Confirm with your CA    │
                                        └───────────────────────────┘
```

### 11.9 Parent — Home
```
┌──────────────────────────────┐
│ Aarav ▾ (switch child)       │
├──────────────────────────────┤
│ Fee due  ₹2,000  by 5 Oct    │
│ ⚠ Overdue 6 days             │
│ [        PAY NOW         ]   │
│ or pay by UPI & upload proof │
├──────────────────────────────┤
│ Next class                   │
│ Mon 20 Oct 5:00pm Guitar     │
├──────────────────────────────┤
│ Receipts                     │
│ #R-0143 Sep ₹2,000  [⬇]      │
├──────────────────────────────┤
│ Home Schedule Payments Me    │
└──────────────────────────────┘
```

### 11.10 Parent — Pay
```
┌──────────────────────────────┐
│ ← Pay ₹2,000                 │
│ ( ) UPI apps (GPay, PhonePe) │
│ ( ) Card / Net banking       │
│ ( ) I paid already → upload  │
│        ┌─────────┐           │
│        │ 📷 Add  │ UTR [____]│
│        └─────────┘           │
│ [         Continue        ]  │
└──────────────────────────────┘
```

### 11.11 Teacher — Today
```
┌──────────────────────────────┐
│ Today – Mon 20 Oct           │
│ 5:00pm Guitar Beginners      │
│  Aarav ☐  Diya ☐  Rohan ☐ …  │
│  [Mark attendance]  (V2)     │
│ 6:00pm Guitar Level 2        │
└──────────────────────────────┘
```

### 11.12 Settings (admin)
```
Business profile • Users & roles • Fee defaults & late fee
Reminder templates & cadence • Payment methods (UPI QR / gateway)
GST settings (GSTIN, rate, inclusive/exclusive, filing freq)
Targets • Receipt template • Data export
```

---

## 12. Next steps
1. You review/answer the questions in §8 and mark changes on features/wireframes.
2. We lock MVP scope and pick stack/gateway.
3. Build clickable prototype (optional), then implement in sprints: (1) auth & users, (2) batches & schedule, (3) fees & payments, (4) reminders & receipts, (5) dashboard, targets & GST.

*Sources: [TutorOne](https://www.goodfirms.co/software/tutorone), [CoFee](https://cofee.life/blog/introducing-cofee-the-ultimate-fee-collection-app), [Tufee](https://apps.apple.com/us/app/-/id6740474461), [FeeAlert](https://www.softwaresuggest.com/feealert), [GST guide](https://www.incorpx.io/blog/gst-on-education-coaching-services-india-2026), [Razorpay pricing](https://razorpay.com/blog/razorpay-payment-gateway-pricing-explained/), [gateway comparison](https://www.paritydeals.com/blog/best-payment-gateways-india-2026/).*


---

## 13. October 2026 competitor review and updated positioning (NEW — v0.2)

**Research boundary:** the original section 2 reflects the initial draft. The following supplements it with publicly advertised features as checked in October 2026. Vendor claims are **not independent product testing**, and availability/prices require trials. In particular, do **not** market standard reminders, payment links, simple attendance, GST reports or fee tracking as unique.

| Product | Verified publicly advertised capabilities | Product strategy implication |
|---|---|---|
| [FeeAlert](https://www.feealert.in/) | WhatsApp-based payment reminders and commands, parent payment links without app install, receipts, UPI, fee ledger, bulk import, expenses and daily briefing | WhatsApp and no-install payment are competitive baseline; win on reliable ledger, reconciliations and exception handling rather than basic automation alone. |
| [MyClassAdmin](https://www.myclassadmin.com/homepage/) | Fee structures, instalments, discounts, GST and tax reports, online payment, receipts, attendance and parent portal | End-to-end features already exist; differentiate on simplicity and independent teacher workflows. |
| [Tufee](https://apps.apple.com/in/app/tufee/id6740474461) | The App Store describes a broad institute-management app including fees, attendance, staffing and schedule enhancements | Avoid unfocused ERP expansion; keep a 2-tap collection UX. |

**Refined differentiation hypothesis (requires customer validation):** *The collections-first operating system for independent teachers and skill academies, with predictable billing and human-friendly exception handling.* Four candidate wedges: (1) family-wide balances and single-checkout allocation; (2) proof-to-bank reconciliation with explicit confidence and audit trail; (3) pause, promise, make-up and lesson-credit rules for variable schedules; (4) actionable cash-flow and collection health, not only invoices issued.

**Discovery plan:** interview at least 5 solo tutors, 5 small academies (10–100 pupils) and 3 multi-teacher schools; observe an actual billing month; trial competitors directly; measure time to first payment, collection effort and disputed proof rate. Any “unique” differentiation claim must pass this test before launch.

## 14. Proposed new requirements and priority changes (NEW — v0.2)

P0 = required for trustworthy MVP, P1 = target release after MVP, P2 = later. These recommendations supersede conflicting v0.1 V2 labels **only after product sign-off**.

| ID | Capability | Phase | Detailed acceptance criteria / rationale |
|---|---|---|---|
| CP-01 | Excel/CSV import + reversible preview | P0 | Map parent, student, batch, due and opening balance; detect duplicates by phone + name; allow correcting rows; never silently merge unrelated family accounts. |
| CP-02 | No-install secure parent pay/receipt page | P0 | Time-limited, non-guessable link; show only authorized invoices; browser and low-bandwidth friendly; no parent app mandatory. |
| CP-03 | Family billing and multi-child dashboard | P0 | Guardian sees charges by child and consolidated due; choose invoice lines and pay once; configurable guardian financial responsibility. |
| CP-04 | Payment allocation ledger | P0 | Allocate one payment across multiple invoices and one invoice across multiple payments; leftover becomes unapplied credit; never allow allocation above verified available amount. |
| CP-05 | Payment proof verification + bank confirmation | P0 | Captured UTR, amount, payer, proof, reviewed_by, review_reason; flag duplicates; screenshot **is not evidence of bank settlement**; manual confirmation requires positive bank check. |
| CP-06 | Payment lifecycle including uncertain status | P0 | States include initiated, pending_provider, paid, failed, expired, pending_manual_review, verified, rejected, partially_allocated, refunded and reversed as distinct payment/invoice concepts. An unknown callback does not imply failure or success. |
| CP-07 | Promise-to-pay follow-up | P0 | Guardian agrees a future date, reason and optional amount; automated reminders can pause until deadline; missed promise re-enters collections queue; all transitions audited. |
| CP-08 | Dispute, waiver and notification hold | P0 | Owner marks a disputed balance or valid exception, creates case with reason; suppresses aggressive dunning but preserves principal; resolution logged and communicated. |
| CP-09 | Immutable financial snapshots and corrections | P0 | Invoice amount, tax basis, discounts and issued receipt never rewritten; amendments use void/credit-note/reversal and a linked audit event; role approvals for sensitive edits. |
| CP-10 | Configurable payment policy | P0 | Decide whether school accepts cash, direct UPI, gateway; disclose gateway fees before pay; configurable part-payment and family allocation ordering; comply with provider rules. |
| CP-11 | Import of outstanding balances | P0 | Migrate historic receivables without inventing paid receipts; opening balance marked sourced/imported and distinguishable from freshly issued invoices. |
| CP-12 | Delivery tracking and quiet hours | P1 | Record reminder channel, accepted/sent/delivered/failed status (where provider exposes); quiet hours, language, frequency cap, opt-outs as legally required. |
| CP-13 | Class packs, lesson credits and make-up bookings | P1 | Model e.g. 8 lessons valid for 10 weeks; attendance consumes credits only under policy; canceled class generates make-up eligibility without duplicate credits. |
| CP-14 | Pause/freezes, prorations, renewals | P1 | Effective dated suspension, billing effects, refund and credit policy, restart date and notification history; never silently alter previously issued invoice. |
| CP-15 | Expense capture, cost allocation, batch profitability | P1 | Costs per teacher/class/venue plus allocation for shared expenses; disclose profitability method; show gross vs net collection. |
| CP-16 | Bank CSV import and reconciliation rules | P1 | Match UTR, amount, date, payee and gateway payout; unmatched, one-to-many, duplicates and false matches enter queue with audit trail. |
| CP-17 | Trial, waitlist, enrolment conversion | P1 | Track lead -> trial -> confirmed enrolment; block over-capacity enrolment, support refundable deposits and follow-up tasks. |
| CP-18 | Student attendance / retention cohorts | P1 | Track active, paused, dropped, renewals by batch and reason; avoid labeling legitimate pauses as churn. |
| CP-19 | Multilingual parent and accessible mobile view | P1 | Start English + Hindi; test Telugu/Tamil regional support; proper currency formatting, screen-reader labels, large tap targets and status text. |
| CP-20 | AutoPay with mandates, cancellations and grace handling | P2 | Explicit opt-in and revoke journey; mandate failures generate non-duplicating retries and visible status. Validate provider/bank constraints. |
| CP-21 | Accountant role, cost centers and multi-branch | P2 | Enforce branch-scoped permission and cross-branch consolidated reporting; audit all finance access. |
| CP-22 | Predictive collection priority (rules first, AI later) | P2 | Priority suggested by days late, amount, previous promise, failed contact; prohibit opaque automatic sanctions or misleading “likelihood to pay” labels. |

### Scope guardrails

- **P0 does not mean build everything at once.** A release candidate must reliably complete *owner onboarding -> invoice -> parent payment -> confirmed settlement -> correct receipt*, including exceptions and security tests. Split into thin vertical slices.
- Keep homework, exams, content hosting, chat, video streaming and school ERP procurement out of the initial positioning.
- WhatsApp templates, messaging costs, bank reconciliation limitations, payment provider terms, child consent and GST/tax treatment must be independently verified before launch.

## 15. Detailed end-to-end journeys and state rules (NEW — v0.2)

### 15.1 Owner first launch
`Create owner account -> verify OTP -> choose/create institute -> business profile -> choose tax configuration -> import CSV or add family -> create teacher/batch -> configure schedule and fee -> preview invoice -> connect UPI/gateway -> invite guardian -> first paid invoice`.

Required error paths: OTP expiry and rate limit; import malformed/duplicate; teacher conflict; guardian with more than one child; GST not registered; payment provider not connected; failed invite link.

### 15.2 Enrolment and billing
`Add guardian -> add child -> assign batch -> dates/custom slot -> apply fee plan/discount -> preview tax and proration -> issue invoice -> deliver to responsible payer`.

Fee-generation jobs must be idempotent per invoice period and enrolment; effective-date fee changes must only affect relevant future charges. The draft's original “per batch fixed total split” choice must specify whether member changes automatically recalculate future charges.

### 15.3 Parent gateway payment
`Secure pay link or parent login -> select child(ren) and invoices -> review amount/fees -> select UPI/card/netbanking -> payment attempt created -> provider redirect -> provider confirmation/webhook validated -> allocate amount -> receipt -> notify parent`.

Do not mark *paid* merely because a browser redirected to success. Verify provider event signature and state; use idempotency keys. If payment remains uncertain, show *Processing — please avoid paying twice* and retry status checks safely.

### 15.4 Direct UPI screenshot payment
`Parent opens direct UPI -> pays externally -> inputs UTR and proof -> PENDING_MANUAL_REVIEW -> duplicate/amount checks -> admin matches actual bank credit -> approve or reject with reason -> verified payment allocated -> receipt/notification`.

Make it clear in UI that screenshot upload does **not** equal bank confirmation; admin must not approve by screenshot alone. If amounts mismatch, hold and contact payer, retaining all history.

### 15.5 Manual cash/bank payment
`Owner opens family/invoice -> records amount, method, collector, date -> selects allocation -> confirms -> immutable payment record -> receipt`. Refund or correction must create compensating entries, never erase paid records.

### 15.6 Collections follow-up
`Invoice due -> reminder eligibility check -> due notification -> overdue queue -> parent promise / dispute / partial payment -> hold or adjusted reminder -> resolve -> paid, write-off or approved correction`. Suppress reminders when a payment is processing or manual proof is pending within a configured period.

### 15.7 Teacher make-up journey (P1)
`Session canceled -> affected enrolments -> replacement slot / make-up credit -> parent notified -> student books -> attendance marks redemption -> original credit closed`. Define no-show rules, expiry policy and max simultaneous make-ups.

## 16. Data architecture changes for reliable money records (NEW — v0.2)

The original `Payment(fee_due_id)` is insufficient for consolidated family checkout or partially allocated money. Proposed relational additions:

```text
Institute(id, name, settings_version, timezone, currency)
Family(id, institute_id, label, billing_contact_user_id)
FamilyMember(family_id, student_id, relationship, active_from, active_to)
PayerAuthorization(id, guardian_id, student_id, can_view, can_pay)
Enrollment(id, student_id, batch_id, start_at, end_at, billing_policy_id)
Invoice(id, institute_id, student_id, family_id, invoice_number, issued_at,
        due_at, currency, tax_snapshot, subtotal, discount, tax_total,
        grand_total, state, source)
InvoiceLine(id, invoice_id, fee_plan_snapshot, description, service_period,
            quantity, unit_amount, discount, tax_rate, taxable_amount, total)
PaymentAttempt(id, payer_id, provider, provider_order_id, idempotency_key,
               intended_amount, state, initiated_at, last_checked_at)
Payment(id, institute_id, payer_id, channel, received_amount, verified_amount,
        currency, reference, bank_match_status, state, received_at)
PaymentAllocation(id, payment_id, invoice_id, amount, applied_at)
PaymentProof(id, payment_id, file_url, submitted_by, submitted_at, review_state,
             reviewed_by, reviewed_at, reviewer_note)
CreditBalance(id, family_id, currency, available_balance)
CreditEntry(id, family_id, invoice_id, payment_id, direction, amount, reason)
InvoiceAdjustment(id, invoice_id, type[credit_note|debit_note|writeoff],
                  amount, authorized_by, reason, effective_at)
CollectionCase(id, family_id, invoice_id, type[promise|dispute|hold], state,
               promise_date, promised_amount, owner_id, reason)
NotificationDelivery(id, template, invoice_id, channel, status, sent_at)
BankEntry(id, import_batch_id, date, amount, reference, counterparty, state)
BankMatch(id, bank_entry_id, payment_id, matched_by, confidence, review_state)
SessionCredit(id, enrollment_id, origin_session_id, expires_at, state)
SessionCreditRedemption(id, credit_id, replacement_session_id, redeemed_at)
Expense(id, institute_id, incurred_at, category, amount, cost_center_id)
AuditEvent(id, institute_id, actor, entity, entity_id, event_type,
           before_hash, after_hash, timestamp, request_id)
```

**Invariants:** (1) `sum(PaymentAllocation.amount)` cannot exceed confirmed available money; (2) no negative or duplicate allocation on replays; (3) invoice historical tax data must not change after issuance; (4) every correction is traceable; (5) guardian cannot access an unrelated child's finances; (6) provider callbacks can arrive more than once or out of order; (7) money rounding uses fixed-precision decimal/paise, never binary floating point.

## 17. Reporting requirements and definitions (NEW — v0.2)

| Report | Priority | Measures / filters | Drill-down, export, caveat |
|---|---|---|---|
| Owner revenue cockpit | P0 | Billed, collected, unpaid, overdue, monthly target, previous-month comparison; period, batch, teacher | Split actual receipts from invoice creation; export PDF/CSV |
| Aging + collections queue | P0 | 1–7 / 8–30 / 31+ day overdue, amount and family, promise/dispute/pending proof tags | Household-level deduplication; contact action; export collector worksheet |
| Payment and channel reconciliation | P0 basic / P1 bank CSV | Gateway confirmed, direct UPI verified, cash, pending proof, failed/refunded, unmatched | List transaction IDs and bank matches; refund impacts shown separately |
| Student/family ledger | P0 | Opening balance, invoices, allocated payments, credit notes, remaining balance | Download detailed statement and receipts; child and family views |
| GST/tax summary | P0 assistive | Taxable amount, configured tax, exemption, CGST/SGST vs IGST breakdown as applicable | Tax jurisdiction/policy needs CA confirmation; don't claim return filed |
| Collections by batch/teacher | P0 | Amount billed, confirmed collected, overdue, collection ratio | Teachers cannot view unless authorized; compare trends |
| Cash flow / gateway settlement | P1 | Received, settled into bank, unsettled, refund/chargebacks, provider fees | Provider settlement time distinct from parent successful payment |
| Batch profit and unit economics | P1 | Gross collections, teacher/room expense, refunds, contribution margin | State if expenses allocated or actual; cash vs accrual basis |
| Retention and capacity | P1 | Trial conversion, new/active/paused/dropout, renewals, average seats filled | Separate intentional pauses from losses |
| Reminder effectiveness | P1 | Sent, delivered where available, opted out, paid-after-notice, promise kept | Correlation ≠ causation; prevent harassment through rate caps |
| Tax/accountant export | P1 | Invoice-level transaction listing and tax categories | Configurable CSV mapping, no filing claims |

### Formula glossary
- **Billed** = invoices issued in report period (clearly state whether credit-note adjustments are subtracted).
- **Collected** = verified payment amounts received in report period; report unallocated money separately, and state whether refunds are netted.
- **Outstanding** = issued invoice total minus applied allocations and approved adjustments as at report cutoff.
- **Overdue** = outstanding portion of invoices with due date before report cutoff, excluding canceled/voided invoices; display held/disputed amount separately, not erased.
- **Collection rate** = verified allocations toward selected cohort's billed amount / net billed amount; avoid mixing current month receipts on older invoices unless separately disclosed.
- **Target progress** = selected-period actual collections / admin-entered target; pace indicators must disclose expected elapsed-day method.

## 18. Expanded image wireframes and screen inventory (NEW — v0.2)

**All wireframes use sample data, not live customer or payment data.** Original 18 mobile PNGs are preserved; **32 new screen PNGs** extend the flows. Assets delivered separately as `ClassPay_Expanded_Flow_Screens.zip` and four `flow_board_*.png` overview boards.

| Screen IDs | Actor | Screens and transitions |
|---|---|---|
| 01–05 | Owner | Create account -> verify OTP -> role selection -> business profile -> CSV import |
| 06–10 | Owner | Create student -> assign batch -> fee plan -> invoice preview -> parent invite |
| 11–17 | Owner | Collections inbox -> verify direct UPI -> handle mismatch -> allocate family payment -> record cash -> promise to pay -> receipt |
| 18–24 | Parent | Open link -> family bill -> choose method -> UPI processing -> upload proof -> success -> pending-verification state |
| 25–30 | Admin | Revenue -> overdue aging -> profitability -> reconciliation -> GST -> retention reports |
| 31–32 | Teacher/Owner | Attendance -> make-up class credit |

**Navigation recommendations:** owner: Home, Calendar, Students, Money, More. Teacher: Today, Classes, Students, More. Guardian: Home, Classes, Payments, Profile. Payment URL supports streamlined browser checkout separately from full application login.

**Design states still requiring production designs:** empty/new user, loading, network offline, failed OTP, session expired, denied permission, payment canceled, duplicate UTR, provider timed out, reversal, pending refund, wrong child selected, tax exception, accessibility at 200% text size. Do not treat storyboard pictures as production-ready field-by-field screen specs.

## 19. Release slicing, acceptance tests and decisions (NEW — v0.2)

**Slice A — activate owner:** OTP, institute and tax settings, import, batch, enrolment, invoice preview. KPI: time to first valid invoice; CSV import errors resolved.

**Slice B — collect money:** single and family payments, gateway status, direct UPI proof, manual cash, allocation, verified receipt. KPI: reconciliation accuracy, duplicate payment prevention, successful payment rate.

**Slice C — reduce chasing:** aging, promises, disputes, reminder suppression, follow-up tasks, ledger exports. KPI: administrative minutes per 100 invoices, paid-on-time rate and support escalations.

**Slice D — run classes and report:** calendar, timetable conflict checks, GST aids, revenue/aging/reconciliation reports, teacher attendance where activated. KPI: report accuracy against bookkeeper sample and schedule conflicts prevented.

**Release-blocking tests:** duplicate/out-of-order webhook; browser redirect without payment; double-submit on poor connectivity; 2 siblings/3 invoices/1 partial payment; duplicate UTR; refund after allocation; manual bank mismatch; tax edit after invoice issue; guardian invited into wrong institute; restricted teacher attempting finance API; revoked payment link; mixed timezone/date cutoff; offline retry.

**Decisions required before MVP lock:** whether family payments default to oldest-due-first, selected invoices or proportional allocation; whether screenshots require confirmed bank deposit; whether cash can be recorded by teachers; policy for holds/late fees; customer GST registration and invoice form; gateway pricing and fee disclosures; primary WhatsApp/SMS costs and consent; how to handle wallet/advance credits legally and operationally.

### Added sources (checked October 2026)
- FeeAlert: https://www.feealert.in/ (advertised features; vendor claims not independently tested)
- MyClassAdmin: https://www.myclassadmin.com/homepage/ and https://www.myclassadmin.com/signin/productFeeManagement
- Tufee App Store listing: https://apps.apple.com/in/app/tufee/id6740474461


---

## 20. Architecture decision: serverless, lowest practical cost (NEW — v0.3)

**Decision:** No permanently running Python/FastAPI or Node/NestJS application server is required for the initial release. Use **Supabase (managed PostgreSQL + Auth + Storage + Row Level Security)** as the backend, **Supabase Edge Functions** for privileged operations/integrations, and **scheduled PostgreSQL jobs / cron** for recurring billing and reminders. Retain the existing HTML clickable prototype as a UX reference, not a production backend.

**Delivery choice:** Build a **responsive Progressive Web App (PWA)** first to minimize cost and enable no-install parent payment links. Prefer **TypeScript + React (or another simple PWA framework)** for a maintainable production frontend. Flutter + Supabase is an alternative **only if native Android/iOS distribution and native mobile capabilities are required at launch**. Do not maintain both PWA and Flutter clients initially. The backend API, relational model and security rules should be client-agnostic so Flutter can be added later without a rewrite.

```text
Owner / Parent / Teacher
        |
        v
Mobile-first PWA (HTTPS; installable where supported)
        |       \-- Optional future Flutter clients
        v
Supabase Auth + PostgreSQL (RLS) + private Storage
        |                   |
        |                   +-- SQL views / RPC / atomic ledger transactions
        v
Edge Functions (secrets kept on server side)
        |          \-- Payment provider checkout creation, webhooks, receipt actions
        |          \-- Notifications and secure exports
        v
External providers when enabled: Razorpay/Cashfree, FCM, SMS/WhatsApp/email

Supabase Cron / scheduled jobs -> Invoice generation -> Aging/reminder queue
                                   -> Edge Function -> delivery provider
```

**Why PostgreSQL over Firestore for ClassPay:** parents have multiple students, students have multiple enrollments, a payment can settle multiple invoices, and invoices can receive multiple partial payments. Relational constraints, transactional allocations and SQL reports make PostgreSQL the simpler authoritative financial store. Firebase remains viable, particularly if native offline sync is paramount, but is not the initial recommendation.

### 20.1 Responsibilities by layer

| Layer | Responsibility | Do not do here |
|---|---|---|
| PWA / future Flutter client | Login UI, forms, parent bill display, schedule, proof upload via controlled permissions, report rendering, initiate checkout | Decide payment success, store provider secrets, calculate final ledger balance authoritatively |
| Supabase Auth | Identity sessions; owner/parent/teacher login with invites | Grant institute roles merely from an untrusted client field |
| PostgreSQL + RLS | Tenant-scoped records, relational constraints, accounting ledger, immutable issued invoice snapshots, views/RPC | Expose unrestricted finance tables to teachers or other tenants |
| Edge Functions | Signed gateway requests, verified webhooks, admin-authorized payment actions, notification provider calls, secure PDF issuance where required | Trust client-reported paid status |
| Cron / scheduled jobs | Generate dues once per cycle, check overdue statuses, queue notifications, retry eligible jobs | Depend on a user's phone/app being active |
| Private Storage | Payment proofs and receipt PDFs with short-lived authorized access | Public unrestricted proof images or ID documents |

### 20.2 Essential business and security invariants

1. Every tenant-facing table has a verifiable institute/tenant identifier, enforced through **RLS policies** and server-side role checks. Design and test access for admin, teacher, parent and student separately.
2. Client applications use only publishable/anon credentials with RLS. **Never embed Supabase service-role keys or payment gateway secrets in frontend code.**
3. The gateway webhook endpoint verifies provider signatures and uses event IDs/idempotency keys; only trusted gateway events or authorized back-office verification can confirm funds.
4. The **Payment**, **PaymentAllocation**, **Invoice** and **LedgerEntry** updates must be atomic with database transactions and unique constraints. Preserve reversed/refunded states and audit logs; never silently overwrite issued documents.
5. RLS alone is insufficient for all money mutations: expose carefully scoped server RPC/Edge Functions for approval, payment allocation, reversal and receipt issuance.
6. Store payment proofs privately; restrict access to authorized owners and the submitting family; use signed URLs and retention policies. Minimize data for minors, with guardian consent and deletion/export procedures as applicable.
7. Test out-of-order webhook delivery, retries, partial family allocations, duplicate UTR, a paid browser-return with no verified webhook, revoked links and mid-cycle fee changes.
8. Enable database backup/restore procedures, monitoring, rate limits, secret rotation and production incident handling before charging customers.

## 21. Authentication, payments and messaging: cost-aware choices (NEW — v0.3)

**Authentication:** For development, use email/password or approved email magic links with test accounts. For commercial onboarding, preserve admin-created invitations and guardian/student links. OTP through an SMS provider is optional at launch because messages are billable; if introduced, comply with applicable Indian messaging and consent rules. A device PIN/biometric can be a convenience unlock but is not a replacement for backend authentication. Harden invite tokens, expiry, one-time redemption, throttling, device/session revocation, and email deliverability.

**Payments — two supported paths:**
- **Direct academy UPI QR/VPA:** Parent leaves ClassPay to pay the owner and submits UTR/reference + proof. State becomes `PENDING_VERIFICATION` until the admin verifies it against real collection evidence; a screenshot alone is not proof of settlement. Cash/bank entries also require authorized approval/audit where applicable. This avoids platform gateway integration fees, **not** all underlying banking or merchant charges.
- **Gateway-managed UPI/cards/net banking:** Create payment orders/links via Edge Function; accept provider callbacks; verify signatures, idempotently record a successful transaction and allocate to invoice(s) before issuing a confirmed receipt. Browser redirect or client callback by itself must not mark paid. Include `PENDING`, `FAILED`, `CANCELLED`, `PARTIALLY_PAID`, `REFUNDED` / `REVERSED` states as appropriate and preserve recheck/retry UX.

**Messaging:** Start with in-app notices, push where feasible and user-initiated share-to-WhatsApp links; add automated SMS/WhatsApp after validation of consent, template approval, delivery fees and local regulations. **No-install parents cannot reliably receive push**; email, direct share and optional paid channels are needed. PWA push behavior varies by browser/OS, especially on iOS, so it is not a sole overdue-notification guarantee.

**Documents:** Invoices should freeze business identity, amounts, fees, discounts and tax settings at issuance; issue PDF receipts only for properly confirmed/recorded payments and support refunds/credit notes with explicit historical links. GST reports are aids for an accountant, not automatic tax filings.

## 22. Free-tier feasibility and cost model (NEW — v0.3)

All figures in this section are **planning assumptions** to be rechecked against current provider pricing and limits before launch. Free tiers and fees can change; no-cost infrastructure does not mean no-cost production operations.

| Service/cost item | Development / pilot plan | Production note |
|---|---|---|
| PWA frontend | Free framework; static hosting free tier where available | Custom domain, hosting limits and uptime needs may add costs |
| Supabase | Start on free tier (historically ~500 MB DB, ~1 GB file storage, ~500k function invocations/month) | Free-tier inactivity pausing, quotas and backup limitations; paid tier likely as usage grows |
| Database and business logic | PostgreSQL SQL/RPC + Edge Functions, no dedicated server | Monitor query costs, scheduled-job quotas and compute |
| Auth | Test email/password or magic links | SMS OTP, transactional email volumes or advanced provider features may cost |
| Push notifications | FCM standard messaging can be no-cost | PWA platform limitations, opt-in/permission and delivery guarantees apply |
| Direct UPI | No integrated gateway per-transaction fee from ClassPay | Human verification effort and any bank/merchant fees remain |
| Payment gateway | Sandbox testing generally available | Actual transaction rates, GST on service fees, settlements and disputes are provider-specific |
| Automated WhatsApp / SMS | Defer or limit pilot usage | Variable per-message/template/provider charges |
| File storage | Keep proofs compressed with lifecycle cleanup | Photos/PDF bandwidth and retention can outgrow free quotas |
| App stores | No store fee for PWA-only launch | Native stores require developer accounts and review |

**Rough budget targets (not quotes):** development with mocked checkout and test users can be ₹0/month in platform charges; a small pilot can potentially remain around ₹0–₹500/month **excluding** messaging, transaction fees, domain and developer labor; a more reliable commercial deployment may need **₹2,000–₹5,000+/month**, dependent on usage and chosen paid services. Avoid treating these as promised costs. Set hard budgets and usage alerts before connecting paid providers.

**Caution:** Do not use free hosting without backups/recovery and availability planning for a meaningful financial production workload. Review Supabase project pausing, storage, email/OTP and backup restrictions at go-live.

## 23. Deployment, operations and future portability (NEW — v0.3)

### 23.1 Environments

- **Local:** frontend on developer machine, Supabase local CLI or isolated development project, mocked payments and seeded test data.
- **Staging:** separate Supabase project, sandbox gateway, signed test webhooks, full user-role tests, seeded family invoices and mocked notifications.
- **Production:** separate project, HTTPS custom domain, production provider keys stored in function secrets, locked-down CORS, RLS tests, audit logs, health monitoring and supported backup recovery.

### 23.2 Technical choices

- **Frontend:** mobile-first TypeScript PWA, web app manifest, responsive layouts; cache only suitable non-sensitive static assets and clearly label offline/stale data. Do not queue irreversible payment approvals offline without safeguards.
- **DB:** managed Supabase PostgreSQL with versioned SQL migrations, constraints and indices; create separate tenant-scoped views for analytics.
- **APIs:** use Supabase client SDK for strictly RLS-protected read and routine writes; use Edge Functions/RPC for privileged financial workflows.
- **Jobs:** Supabase cron for invoice issue and aging with idempotent `institute + student/enrollment + billing period` keys; an outbox table for retryable notification delivery.
- **Storage:** private proof/receipt buckets, content-size/type constraints and expiration, no public listing.
- **Observability:** error capture, payment-event processing log, dead-letter/manual retry queue for failed notifications/webhooks, automated backups and restoration drills.
- **Exit plan:** Keep the core schema in standard PostgreSQL/SQL migrations; document Edge Function contracts so hosting or mobile clients can change without changing accounting semantics.

### 23.3 When would a dedicated Python backend make sense?

Only add FastAPI/Python (or another dedicated service) if actual needs justify it: CPU-intensive document/OCR processing, sophisticated ML forecasting, highly customized integrations, long-running asynchronous tasks beyond serverless limits or compliance/operations needs. Even then, use an on-demand container/job service before committing to a 24×7 VM. This is **not needed for the initial ClassPay feature scope**.

## 24. Updated build sequence, dependencies and release gates (NEW — v0.3)

| Stage | Deliverable | Must demonstrate |
|---|---|---|
| 0. Confirm delivery channel | PWA-first (default) or Flutter-first; freeze role model and payment policies | All essential flows feasible on chosen client, parent no-install link works |
| 1. Foundations | Supabase Auth, institute membership, RLS, schema migrations, owner onboarding, parent invites | No cross-tenant data visibility; revoked invite cannot be reused |
| 2. Teaching setup | CSV import, students/families, batches, enrollment, schedule/attendance where selected | Import validation, conflict detection, capacity rules |
| 3. Billing engine | Fee plans, frozen invoices, sibling combined bills, partial allocations, tax configuration | Multi-invoice atomic allocation, no duplicate billing cycle |
| 4. Manual collection | QR/VPA, private proofs, UTR checks, verification, cash/bank ledger, receipts | Pending ≠ Paid; audit trail and finance reports agree |
| 5. Automated collection | Payment gateway sandbox/live, verified webhook, retries, reconciliation | Duplicate/out-of-order events cannot double-credit; no false successes |
| 6. Reminders and reports | Cron due generation, aging, user-initiated sharing then paid channels, collections/reconciliation/GST reports | Accurate reminders and suppression; totals reconcile to underlying ledger |
| 7. Production hardening | Backups/restore, privacy, threat model, monitoring, user acceptance tests, pricing | Launch checklist approved and production provider policies verified |

**Design-to-code handoff:** Map the 50-screen prototype inventory (§18) to named routes, role permissions, backend reads/writes, validation states, loading/empty/error states and acceptance tests. Keep the existing clickable HTML demo for usability validation; it is not wired to Supabase yet.

## 25. Explicit decisions to confirm (NEW — v0.3)

1. **PWA-first (recommended for lowest cost)** or **Flutter-first** if downloadable native apps are mandatory at launch?
2. Default login: email/password or email magic link for pilot? If phone OTP is essential, which SMS provider and budget?
3. Launch collections: direct UPI with owner verification only, or enable a gateway immediately?
4. Are WhatsApp/SMS reminders necessary at launch or can the pilot use push + user-initiated share + email?
5. Pilot size (institutes, students, monthly transactions and screenshots), allowing estimation of storage, delivery and database quotas?
6. Required recovery targets, backup policy and regulatory/legal review for real payments and minors' data?

**Pricing/provider references to verify at implementation:** https://supabase.com/pricing · https://supabase.com/docs/guides/functions · https://supabase.com/docs/guides/cron · https://firebase.google.com/docs/cloud-messaging · https://razorpay.com/pricing/ · https://www.cashfree.com/payment-gateway-charges/ . These are links for later checking, not a claim that current terms were independently revalidated in this revision.


---

## 26. Student Portal & Authentication (v0.4 — NEW)

### 26.1 Product decision

The student is a **first-class, fourth application role**, alongside Owner/Admin, Parent/Guardian and Teacher. The student portal is for their personal learning experience, not academy financial administration. Reuse **the same authentication system, database, and PWA**; no separate Python server or student app is needed.

**MVP:** invitation/activation, role-specific home, next class, class timetable/detail, own attendance, notices, class reminders, limited profile, and guardian-linked permission model. **MVP adult-only option:** personal dues, self-payment and receipts reusing checkout. **V2:** lesson resources/homework, teacher feedback, self-service reschedule/make-up approvals, richer progress metrics.

### 26.2 Invite, sign-in and account linking

1. An authorized academy admin creates a student record and enrollment, then associates one or more authorized guardians if the learner is a minor.
2. Admin issues a **single-use, expiring** invitation to an approved contact channel. An academy-provisioned student account must be linked to the correct student and institute membership server-side.
3. Student activates using the invitation and a supported authentication method (initial cost-first plan: email magic link / email-password when available; SMS OTP only when the cost is justified). The demonstration uses sample code `CP-STU-102` and demo OTP `1234` **only in the mock prototype**, never in production.
4. Authentication establishes a Supabase user session, then the app reads the **authorized institute memberships and role(s)** from database records and routes to the appropriate dashboard. Role selection alone must not grant access.
5. One authenticated user can have several memberships or roles across academies; role/institute switching must be explicit. Never assume a globally unique role.
6. Minor access requires age-appropriate consent and guardian controls according to applicable privacy law. Do not require every child to own a phone or email. If a student cannot independently activate, the guardian can continue to view that learner's schedule from the guardian portal.
7. Reissue and revoke invites, deactivate/recover access, and maintain an audit trail. Invitations must not grant visibility into other students' records.

### 26.3 Permission matrix

| Capability | Minor student | Adult student | Guardian |
|---|---|---|---|
| Own timetable and class details | Yes | Yes | Linked children's timetables |
| Own attendance | Yes | Yes | Linked children's attendance (academy policy) |
| Announcements and class reminders | Yes (consent/policy) | Yes | Yes |
| Make-up class request | Request only | Request only | Request on child's behalf |
| Edit contact preferences | Limited | Yes | Own preferences |
| Edit legal identity, age, enrollment, guardian links | No | Admin-assisted | Admin-assisted |
| View billing, balances, receipts | No by default | Own only | Linked family accounts |
| Pay outstanding fees | No by default | Own only | Linked family accounts |
| View classmate contact/financial information | Never | Never | Never |
| Manage attendance or academy reports | Never | Never | Never |

**Policy:** A minor must not inherit a guardian's billing permissions. If a future academy setting enables teen fee visibility, it must be intentionally scoped and legally/privacy reviewed; never default to enabled.

### 26.4 Seven added clickable screens (51–57)

| ID | Screen | Primary action / behavior |
|---|---|---|
| 51 `studentactivate` | Student invitation and activation | Validate a demo invite, choose age group and display name, activate portal |
| 52 `studenthome` | Student home dashboard | Next class, attendance, announcements, make-up credits; adult billing shortcut only |
| 53 `studentschedule` | My timetable | Upcoming classes and schedule changes, open class details |
| 54 `studentclass` | Class detail | Studio, teacher, session, progress, submit demo make-up request |
| 55 `studentattendance` | My attendance | Percent, attended/total, session history |
| 56 `studentprofile` | My profile and permissions | Guardian link for minor; adult billing; notification preference |
| 57 `studentfees` | Adult student billing | Own fee, status and reusable payment checkout; minor access blocked |

These seven screens extend the **50 existing screens to 57 total**. The prototype navigation exposes **Owner / Parent / Teacher / Student** and supports scenario switching. All demo names, records, confirmations and payment actions remain simulated.

### 26.5 Student-specific data model additions

Proposed entities/columns for implementation (migration design, not yet deployed):

```sql
-- Existing User, Student and Enrollment entities remain authoritative.
AcademyMembership(id, academy_id, auth_user_id, role, status, created_at)
StudentAccountLink(id, academy_id, student_id, auth_user_id, activated_at, revoked_at)
GuardianStudentPermission(id, academy_id, guardian_user_id, student_id,
                          can_view_attendance, can_manage_billing, consent_record_id)
StudentInvite(id, academy_id, student_id, invited_contact_hash, token_hash,
              expires_at, used_at, revoked_at, issued_by)
StudentPreferences(id, academy_id, student_id, class_reminders, language)
MakeupRequest(id, academy_id, student_id, enrollment_id, session_id,
              reason, status, requested_at, reviewed_by, reviewed_at)
Announcement(id, academy_id, batch_id, visibility, content, published_at)
```

Use actual PostgreSQL DDL, constraints, tenancy keys and indexes during development. Student age/birth date should only be collected when needed, stored minimally and protected.

### 26.6 Security and serverless implementation rules

- Configure Supabase Auth for approved channels; all student identifiers must be resolved from authenticated, authorized membership, not trusted client IDs or a local role flag.
- Enable PostgreSQL RLS on all per-academy and per-student data. Students read only their own linked student record, enrollments, sessions, attendance and approved announcements.
- Prevent student reads of `Payment`, `Invoice`, `Receipt`, `PaymentAllocation` unless the identity is an **adult student with explicitly scoped self-billing permission**. Guardian access uses its own link-specific policy.
- Student make-up requests should use a server-validated RPC or Edge Function and a review status; submitting a request does not automatically change attendance or create monetary credit.
- Sign invitation tokens, hash stored tokens, expire them and verify them server-side. Demo activation codes must not be shipped as real credentials.
- Ensure guardian consent/minor notifications respect applicable DPDP requirements and future implementing rules, validated with local counsel.
- The `studentfees` prototype reuses the payment method screen but **production checkout** must obtain its invoice IDs, amounts and payee from server-authorized records only.

### 26.7 Acceptance tests before production

1. Minor account activation routes to student dashboard; direct navigation to fees yields an access-denied/guardian-managed response.
2. Adult student can view and pay **only their own** invoices, including after changing browsers/devices.
3. A student cannot read another student's timetable, attendance, guardian data, UTR, or receipts by modifying network requests or URLs.
4. Revoked student invitation cannot activate; a used token cannot be replayed; guardian unlink immediately removes guardian-specific permissions.
5. Multiple-academy users see only the selected authorized academy records; account deactivation blocks access without deleting historic invoices.
6. Student attendance comes from teacher-confirmed server records, not editable client-only counts.
7. Reschedule notices respect notification preferences; make-up requests require staff review; minor privacy/consent scenario is tested.

### 26.8 Scope and cost impact

The PWA + Supabase recommendation in sections 20–25 **does not change**. The student portal adds frontend routes, RLS policies and a few relational tables, not another always-on service. More authenticated users and notifications can increase platform and messaging usage; measure limits before production. The clickable prototype is for UX validation and **does not provide secure real authentication, data persistence or real payments**.


---

## 27. Shared Calendar: Day / Week / Month for All Roles (v0.5 — IMPLEMENTED IN PROTOTYPE)

### 27.1 Universal requirement

Every ClassPay schedule is available in **Day**, **Week**, and **Month** views for **Owner/Admin**, **Teacher**, **Parent/Guardian**, and **Student**. The selected view and date should persist while navigating within the session; a production client may store them as user preferences. The display defaults to the user's current local date in production (the browser demo uses 14 October 2026 as a fixed demonstration reference).

- **Day:** Chronological agenda with time, end time, session/batch, venue or meeting link, teacher, and status. Empty days show a clear empty state.
- **Week:** Monday-to-Sunday calendar/week strip, session counts per day, and a chronological agenda grouped by day. Selecting a day focuses it without losing the selected week.
- **Month:** Monday-first calendar grid with event indicators and an agenda of sessions for the selected date. Days outside the month remain navigable.
- All three modes support **previous**, **next**, and **today** navigation; tapping a session opens an authorized detail/action screen.
- Explicit **Scheduled**, **Cancelled**, and **Rescheduled** badges appear with accessible text, not color alone. The final session timestamp and notification history must survive edits.

### 27.2 Role-specific visibility

| Role | Calendar scope | Useful controls | Session actions |
|---|---|---|---|
| Owner/Admin | All institute sessions | Filter by batch, teacher, room, location, and status | Create/reschedule/cancel, detect overlaps, open batch, notify affected users |
| Teacher | Assigned teaching sessions only | Day/week/month, assigned batch, location | View roster, mark attendance, request reschedule (policy dependent) |
| Parent/Guardian | Sessions for linked children only | Child switcher (one or all), day/week/month | View class details and announcements, request make-up if policy allows |
| Student | Sessions belonging to current active enrollments only | Day/week/month, enrolled class | View session details, attendance, and eligible make-up requests |

A linked **minor** student can see session information but not another student's identity or private financial details. Parent linkage and teacher assignment are enforced by PostgreSQL Row Level Security (RLS), **not** by hiding calendar UI elements. Where a user belongs to multiple academies, academy context must be selected and checked server-side.

### 27.3 Session data and backend implementation

The existing `Session` model must include or reference: `academy_id`, `batch_id`, `teacher_id`, `starts_at`, `ends_at` (timezone-aware), `timezone`, `room_id`/online link, `status`, `original_session_id` or reschedule history, and `updated_at`. Enrollment effective dates and cancellation rules govern visibility. Store instants consistently (e.g., UTC) while displaying the academy-local timezone; handle daylight-saving differences where applicable.

- Generate recurring sessions from schedules with an explicit recurrence rule and date range. Support exceptions for holidays, cancellations, replacements, teacher changes, and one-off sessions.
- For large calendars, query a bounded date range based on the selected view instead of loading every session. Paginate or use an interval query for busy academies.
- Detect teacher and room collisions, including single occurrences of recurring classes.
- A reschedule updates affected viewers and queues notifications, while retaining original time and audit history.
- Preserve user-permitted offline cached views; label stale data and refresh after reconnection.
- All calendar links and API queries must enforce role-scoped reads (including teacher/student/guardian cross-academy isolation).

### 27.4 Prototype implementation and navigation

The clickable HTML prototype now has **four usable three-mode calendars**: Owner (`Calendar`), Teacher (`Teacher schedule`), Parent (`Family schedule`), and Student (`My timetable`). The parent calendar is a newly added screen, bringing the inventory to **58 named screens**. Owner has a batch filter, and Parent can select all linked children or a single child. Each calendar supports next/previous navigation, selecting dates, status labels, and role-relevant session actions. Sample sessions in the demo are fictional and held entirely in the browser; the Supabase read/write layer is still a production implementation task.

### 27.5 Acceptance tests

1. Every role can switch Day → Week → Month → Day without errors or losing date context.
2. Each view shows only sessions allowed by the signed-in user's academy, assignment, guardian links, or enrollment.
3. Parent switcher correctly combines or separates linked children's schedules.
4. Weekly and monthly grids navigate across months and years; empty periods have an empty state.
5. Changes to session times or cancellations display consistently across affected roles and send notifications according to settings.
6. The calendar remains usable with screen readers, larger font settings, and keyboard navigation.
7. RLS tests deny access to sessions outside the user's permitted academy and roster.
