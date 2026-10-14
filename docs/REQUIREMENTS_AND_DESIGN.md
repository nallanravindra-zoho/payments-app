# ClassPay (working name) — Requirements, Market Research & Design

Status: **DRAFT v0.1 for review** — no code yet. Refine this, then implement.

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

## 7. Suggested tech stack (proposal — open to change)
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
