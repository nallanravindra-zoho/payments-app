# ClassPay — clickable high-fidelity concept prototype

## Open

Open **index.html** in Chrome, Edge, Firefox or Safari. It is a standalone HTML file: no installation, accounts, internet connection, database, or build steps required. On a desktop, a screen navigator appears on the left, a mobile phone preview in the centre and scenario controls on the right. On a phone, the experience fills the viewport.

If your browser restricts local files, serve the folder with `python -m http.server 8000` and open `http://localhost:8000`.

## Suggested walkthrough

1. Start with **Login** → enter demo OTP `1234` → **Academy owner**.
2. Enter the academy profile → import/sample students → assign a student → fee plan → invoice preview → parent invite → owner home.
3. Navigate to **Money → Collections inbox → Verify payment**, and approve or reject a proof.
4. Use the **Parent** role switch → **Family fees → Pay now → UPI**. Select *Simulate successful payment* or *Simulate pending / failed*.
5. Try **Upload proof** and the **offline cash/bank payment** path.
6. Inspect **Reports & exports** for revenue, overdue aging, profitability, reconciliation, GST, and retention.
7. Switch to **Teacher** to mark attendance and issue make-up credits.

## Included

- 50 named screens mapped from the expanded 32-screen flows and the 18 earlier core screen concepts
- Owner, parent, teacher experiences
- Responsive design system (typography, cards, forms, navigation, actions, badges, charts)
- Simulated data and session-only local state, basic validation, navigation, sample CSV download
- Payment success/pending/rejected paths, receipt preview, reminder promise, partial allocation illustration
- Existing updated `REQUIREMENTS_AND_DESIGN.md` for reference

## Important boundaries

This is a **front-end interactive prototype**, not a production application. It does not contain live authentication, SMS, WhatsApp, gateway checkout, webhook verification, persistence, production invoicing, real GST calculations, audit logs or bank reconciliation. Payment status is simulated. It is not connected to real personal information or money.

Some advanced controls are concept demonstrations; e.g. the CSV upload selects a file but does not import records, reports use sample metrics, and calendar week/month modes are deferred. These are explicit prototype limitations, not completed application features.


## Student portal (v0.4)

Choose **Student** in the role switcher, or on the login role-choice screen. Start with **Student activation**, using demo invitation `CP-STU-102`. Choose **Under 18** or **18 or older**, activate, and test Home → Classes → Class details → Attendance → Profile. Under-18 accounts display guardian-managed billing; adult accounts can access **My fees → Payment methods**. The demo OTP is `1234`. All permissions are visual demo behavior only; real authorization requires Supabase Auth and RLS as specified in the Markdown.


## Calendar upgrade (v0.5)

All four roles now have Day/Week/Month schedules. Navigate using the mode tabs, previous/next controls and day selectors. Parent supports child filters; Owner supports batch filters. The schedules use fictional example sessions and do not yet sync to Supabase.
