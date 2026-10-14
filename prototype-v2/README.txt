ClassPay - full lifecycle clickable prototype
=============================================
Open index.html in any modern browser (works offline, nothing to install).
On a phone/narrow window use the "Demo" button (top right) for the control panel.

Two ways in
  1. "Start guided lifecycle"  -> OTP 274918 -> role -> business -> import -> enrol -> invoice -> invite parent
  2. "Skip to populated demo"  -> institute with imported students, 2 payment proofs, overdue fees

Control panel (left on desktop)
  - Lifecycle journey: 13 steps, ticks as you complete them, click any to jump there
  - Switch role (Owner / Parent / Teacher) - all roles share the same live data
  - +1 day / +7 days / jump to 1 Nov: runs the daily jobs (reminders, promises, billing cycle)
  - Offline toggle, and a jump list for all 32 designed screens (S01-S32)

Suggested walk-through (10 minutes)
  1. Guided lifecycle through S01-S10, "Open as parent"
  2. Parent: Pay now -> UPI app -> on S21 try "Browser redirect" (ignored), "Signed webhook: success" (paid + receipt),
     "Replay same webhook" (ignored, no double credit)
  3. Owner > Money: open Shah family proof, tick bank check, change bank amount to 2000 -> mismatch -> "Handle payment issue"
     Open Thomas family proof -> approve -> allocate part of it -> remainder becomes family credit
  4. Remind / Promise to pay / Cash-bank; open a receipt and "Reverse payment" (creates a linked correction)
  5. More > Billing & reminders: jump to 1 Nov -> invoices generated once (re-run = nothing duplicated)
  6. Teacher: attendance; Owner > Calendar: cancel class -> make-up credits -> Parent > Classes: book make-up
  7. Money > Reports: revenue, aging, profitability, reconciliation, GST, retention (CSV exports work)

All data is dummy and lives in memory (refresh = reset). No server, no real payments.
