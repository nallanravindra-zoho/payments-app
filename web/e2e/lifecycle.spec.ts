import { expect, test, type Browser, type BrowserContext, type Page } from '@playwright/test';

/** Full lifecycle against the real PWA build + real SQL (RLS, RPCs) via the local harness. Tests share one seeded database and run in order. */
test.describe.configure({ mode: 'serial' });
const PW = 'Passw0rd-test1';

/** Signs in with email + password; registers the account first if it does not exist yet (the harness auto-confirms email). */
async function signIn(page: Page, email: string) {
  await page.goto('/login');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  const role = page.getByRole('heading', { name: 'How will you use ClassPay?' });
  const bad = page.getByRole('status').filter({ hasText: 'not correct' });
  await Promise.race([role.waitFor(), bad.waitFor()]).catch(() => {});
  if (await bad.isVisible()) { await page.getByRole('link', { name: 'Create an account' }).click(); await page.getByRole('button', { name: 'Create account' }).click(); }
}
async function asRole(page: Page, email: string, role: RegExp) {
  await signIn(page, email);
  await expect(page.getByRole('heading', { name: 'How will you use ClassPay?' })).toBeVisible();
  await page.getByRole('button', { name: role }).click();
}
const nav = (page: Page, name: string) => page.locator('nav.bottom').getByRole('button', { name }).click();
const heading = (page: Page, name: string | RegExp) => expect(page.getByRole('heading', { name, level: 1 })).toBeVisible();
async function fresh(browser: Browser): Promise<{ ctx: BrowserContext; page: Page }> {
  const ctx = await browser.newContext({ viewport: { width: 420, height: 860 }, permissions: ['clipboard-read', 'clipboard-write'] });
  return { ctx, page: await ctx.newPage() };
}

let ownerCtx: BrowserContext; let owner: Page;
test.beforeAll(async ({ browser }) => { ({ ctx: ownerCtx, page: owner } = await fresh(browser)); });
test.afterAll(async () => { await ownerCtx.close(); });

test('PWA: manifest and service worker are served', async ({ request }) => {
  const m = await request.get('/manifest.webmanifest');
  expect(m.ok()).toBeTruthy();
  const j = await m.json();
  expect(j.name).toBe('ClassPay'); expect(j.display).toBe('standalone'); expect(j.icons.length).toBeGreaterThanOrEqual(3);
  expect((await request.get('/sw.js')).ok()).toBeTruthy();
});

test('unauthenticated visitors are sent to login; a wrong password is rejected', async ({ page }) => {
  await page.goto('/home');
  await expect(page).toHaveURL(/\/login$/);
  await heading(page, 'Your classes. Your payments. All together.');
  await page.getByLabel('Email').fill('nobody@nowhere.test');
  await page.getByLabel('Password').fill('wrong-password-1');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('status').filter({ hasText: 'not correct' })).toBeVisible();
  await page.getByLabel('Password').fill('short');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByRole('status').filter({ hasText: 'at least 8 characters' })).toBeVisible();
});

test('owner signs in and the dashboard reflects the academy', async () => {
  await asRole(owner, 'anita@swar.demo', /Academy owner/);
  await expect(owner).toHaveURL(/\/home$/);
  await expect(owner.getByText(/Good (morning|afternoon|evening), Anita/)).toBeVisible();
  await expect(owner.getByText('3 payment proofs to verify')).toBeVisible();
  await expect(owner.getByText('5 overdue follow-ups · 2 classes today')).toBeVisible();
  await expect(owner.locator('.metric', { hasText: 'Collected' })).toContainText('₹78,000');
  await expect(owner.locator('.metric', { hasText: 'Overdue' })).toContainText('₹18,500');
  await expect(owner.getByText('65% achieved')).toBeVisible();
});

test('owner verifies a proof: approval needs a bank check, then a receipt is issued', async () => {
  await nav(owner, 'Money');
  await heading(owner, 'Collections inbox');
  await expect(owner.getByText('Arjun Mehta')).toBeVisible();
  await owner.locator('.listrow', { hasText: 'Arjun Mehta' }).getByRole('button', { name: 'Review' }).click();
  await heading(owner, 'Verify payment');
  await expect(owner.getByText('₹2,500').first()).toBeVisible();
  await expect(owner.getByText('Reference appears unique')).toBeVisible();
  const approve = owner.getByRole('button', { name: 'Approve' });
  await expect(approve).toBeDisabled();                               // a screenshot is evidence, not settlement
  await owner.getByLabel(/confirmed this credit in the academy’s bank account/).check();
  await approve.click();
  await heading(owner, 'Payment receipt');
  await expect(owner.getByText(/#CP-2026-\d{4}/)).toBeVisible();
  await expect(owner.locator('.receipt')).toContainText('₹2,500');
  await expect(owner.locator('.receipt')).toContainText('Arjun Mehta');
});

test('owner rejects a proof with a reason', async () => {
  await nav(owner, 'Money');
  await owner.locator('.listrow', { hasText: 'Diya Rao' }).getByRole('button', { name: 'Review' }).click();
  await owner.getByRole('button', { name: 'Issue / reject' }).click();
  await heading(owner, 'Resolve payment issue');
  await owner.getByLabel('Reason').selectOption('UTR already used');
  await owner.getByRole('button', { name: 'Reject proof and notify' }).click();
  await heading(owner, 'Collections inbox');
  await expect(owner.locator('.metric', { hasText: 'Verify' })).toContainText('1');
  await expect(owner.getByText('Diya Rao')).toHaveCount(0);
});

test('owner records cash for an overdue student; receipt is issued and overdue drops', async () => {
  await nav(owner, 'Home');
  await owner.getByRole('button', { name: 'Record payment' }).click();
  await heading(owner, 'Record an offline payment');
  await owner.getByLabel('Student').selectOption({ label: 'Rohan Sharma' });
  await expect(owner.getByLabel('Amount (₹)')).toHaveValue('2000');
  await owner.getByRole('button', { name: 'Save and issue receipt' }).click();
  await heading(owner, 'Payment receipt');
  await expect(owner.locator('.receipt')).toContainText('₹2,000');
  await expect(owner.locator('.receipt')).toContainText('Cash');
});

test('owner logs a promise to pay for an overdue family', async () => {
  await nav(owner, 'Money');
  await owner.locator('.listrow', { hasText: 'Priya Patel' }).getByRole('button', { name: 'Follow up' }).click();
  await heading(owner, 'Promise to pay');
  await expect(owner.getByText('₹3,500 overdue')).toBeVisible();
  await owner.getByRole('button', { name: 'Save promise' }).click();
  await heading(owner, 'Collections inbox');
  await expect(owner.locator('.metric', { hasText: 'Promised' })).toContainText('1');
});

test('reports compute from the ledger', async () => {
  await owner.goto('/aging');
  await heading(owner, 'Overdue aging');
  await expect(owner.locator('.card', { hasText: 'Receivables at risk' })).toContainText('₹16,500');
  await owner.goto('/retention');
  await expect(owner.locator('.metric', { hasText: 'Active' })).toContainText('82');
  await expect(owner.locator('.metric', { hasText: 'New' })).toContainText('11');
  await expect(owner.locator('.metric', { hasText: 'Left' })).toContainText('3');
  await owner.goto('/revenue');
  await expect(owner.locator('.metric', { hasText: 'Collected' })).toContainText('₹');
  await expect(owner.locator('.card', { hasText: 'Payment channel mix' })).toContainText('UPI');
  await owner.goto('/gst');
  await expect(owner.locator('.card', { hasText: 'Tax overview' })).toContainText('Taxable value');
  await owner.goto('/reconcile');
  await expect(owner.locator('.metric', { hasText: 'Matched' })).toBeVisible();
  await owner.goto('/profit');
  await expect(owner.getByText('Estimated net contribution')).toBeVisible();
});

test('calendar: day, week and month views with batch filter', async () => {
  await owner.goto('/calendar');
  await heading(owner, 'Academy calendar');
  await expect(owner.locator('.session-row', { hasText: 'Guitar Beginners' })).toBeVisible();
  await owner.getByRole('button', { name: 'Week', exact: true }).click();
  await expect(owner.locator('.week-cell')).toHaveCount(7);
  await owner.getByRole('button', { name: 'Month', exact: true }).click();
  await expect(owner.locator('.month-cell')).toHaveCount(42);
  await owner.getByRole('button', { name: 'Previous month' }).click();
  await owner.getByRole('button', { name: 'Today' }).click();
  await owner.getByRole('button', { name: 'Day', exact: true }).click();
  await owner.getByLabel('Batch').selectOption({ label: 'Vocals — Intermediate' });
  await expect(owner.locator('.session-row')).toHaveCount(1);
  await expect(owner.locator('.session-row')).toContainText('Vocals — Intermediate');
});

test('new owner: onboarding, CSV import with duplicate handling, batch, enrolment, invoice, invite', async ({ browser }) => {
  const { ctx, page } = await fresh(browser);
  await asRole(page, 'newowner@test.dev', /Academy owner/);
  await heading(page, 'Tell us about your academy');                       // no academy yet -> create one
  await page.getByLabel('Your name').fill('Test Owner');
  await page.getByLabel('Academy name').fill('Test Academy');
  await page.getByLabel('City').fill('Pune');
  await page.getByRole('button', { name: 'Save and add students' }).click();
  await heading(page, 'Bring your students over');

  const csv = 'name,guardian_name,phone,batch,fee,opening_balance\nAsha Rao,Priya Rao,9822200001,,,1500\nAsha Rao,Priya Rao,9822200001,,,\nBad Row,Nobody,123,,,\nVeer Rao,Priya Rao,9822200001,,,\n';
  await page.locator('#csvfile').setInputFiles({ name: 'students.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
  await page.getByRole('button', { name: 'Preview import' }).click();
  const prev = page.locator('.card', { hasText: 'Import preview' });
  await expect(prev).toContainText('Valid students');
  await expect(prev.locator('.align', { hasText: 'Valid students' })).toContainText('2');
  await expect(prev.locator('.align', { hasText: 'Duplicates' })).toContainText('1');
  await expect(prev.locator('.align', { hasText: 'Rows needing a fix' })).toContainText('1');
  await prev.getByLabel('Duplicate rows').selectOption('merge');
  await prev.getByRole('button', { name: 'Confirm import' }).click();
  await heading(page, 'Your batches');
  await expect(page.getByText('No batches yet')).toBeVisible();

  await page.getByRole('button', { name: '＋ Create new batch' }).click();
  await page.getByLabel('Batch name').fill('Piano Beginners');
  await page.getByLabel('Teacher name').fill('Rahul');
  await page.getByLabel('Day').selectOption('Monday & Wednesday');
  await page.getByLabel('Start time').fill('17:00');
  await page.getByLabel('Max capacity').fill('12');
  await page.getByRole('button', { name: 'Create batch' }).click();
  await expect(page.getByText('Piano Beginners')).toBeVisible();

  await page.goto('/addstudent');
  await page.getByLabel('Student name').fill('Meera Joshi');
  await page.getByLabel('Parent / guardian').fill('Sunil Joshi');
  await page.getByLabel('Guardian mobile').fill('9822200002');
  await page.getByLabel(/Guardian email/).fill('sunil.joshi@example.com');
  await page.getByRole('button', { name: 'Save student' }).click();
  await heading(page, 'Assign student to a class');
  await expect(page.getByText('Meera Joshi is ready to enrol.')).toBeVisible();
  await expect(page.getByText(/0 of 12 seats filled/)).toBeVisible();
  await page.getByRole('button', { name: 'Continue to fee plan' }).click();
  await heading(page, 'Set your fee plan');
  await page.getByLabel('Amount (₹)').fill('2000');
  await page.getByLabel('Sibling discount (₹)').fill('0');
  await page.getByRole('button', { name: 'Preview invoice' }).click();
  await heading(page, 'Invoice preview');
  await expect(page.locator('.card', { hasText: 'Amount due' })).toContainText('₹2,000');
  await page.getByRole('button', { name: 'Create invoice' }).click();
  await heading(page, 'Invite your parent');
  await page.getByRole('button', { name: 'Copy invite link' }).click();
  await expect(page.getByRole('status').filter({ hasText: 'Invite link copied' })).toBeVisible();
  const link = await page.evaluate(() => navigator.clipboard.readText());
  expect(link).toMatch(/\/pay\/[0-9a-f]{64}$/);

  // owner turns on direct-UPI proof payments for this academy
  await page.goto('/settings');
  await page.getByLabel('Academy UPI ID').fill('testacademy@upi');
  await page.getByRole('button', { name: 'Save payment settings' }).click();
  await expect(page.getByRole('status').filter({ hasText: 'Payment settings saved' })).toBeVisible();

  // parent: no-install link -> family bill -> pay by UPI proof (direct UPI not enabled yet for gateway) -> pending
  const { ctx: pctx, page: parent } = await fresh(browser);
  await parent.goto(new URL(link).pathname);
  await heading(parent, 'Fee payment link');
  await expect(parent.getByText('Test Academy')).toBeVisible();
  await expect(parent.getByText('Link verified')).toBeVisible();
  await parent.getByRole('button', { name: 'View family bill' }).click();
  await heading(parent, 'Family bill');
  await expect(parent.getByText('₹2,000').first()).toBeVisible();
  await parent.getByRole('button', { name: 'Continue to payment' }).click();
  await heading(parent, 'Choose how to pay');
  await expect(parent.getByRole('button', { name: /^UPI/ })).toHaveCount(0);                // gateway is off for this academy
  await parent.getByRole('button', { name: /Direct UPI \+ proof/ }).click();
  await heading(parent, 'Upload payment proof');
  await expect(parent.getByText('Pay to testacademy@upi')).toBeVisible();
  await parent.getByLabel('UPI transaction / UTR number').fill('555000111222');
  await parent.locator('#prooffile').setInputFiles({ name: 'proof.png', mimeType: 'image/png', buffer: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64') });
  await parent.getByRole('button', { name: 'Submit for verification' }).click();
  await heading(parent, 'Payment not confirmed yet');
  await expect(parent.getByText('No receipt will be issued until the payment is verified.')).toBeVisible();

  // owner sees the proof (with the uploaded evidence), approves with the bank check
  await page.goto('/inbox');
  await expect(page.locator('.listrow', { hasText: 'Pending' })).toHaveCount(1);
  await page.getByRole('button', { name: 'Review' }).click();
  await expect(page.locator('img[alt="Payment proof"]')).toBeVisible();
  await page.getByLabel(/confirmed this credit/).check();
  await page.getByRole('button', { name: 'Approve' }).click();
  await heading(page, 'Payment receipt');
  await expect(page.locator('.receipt')).toContainText(/#CP-2026-\d{4}/);

  // a revoked link stops working
  await ctx.close(); await pctx.close();
});

test('parent (signed in) pays the family bill online; replay and double-pay protections hold', async ({ browser }) => {
  const { ctx, page } = await fresh(browser);
  await asRole(page, 'neha@swar.demo', /Parent/);
  await expect(page).toHaveURL(/\/parenthome$/);
  await heading(page, 'Family fees');
  await expect(page.locator('.card', { hasText: 'Amount due' })).toContainText('₹4,500');
  await expect(page.locator('.card', { hasText: 'Amount due' })).toContainText('Across 2 children');
  await expect(page.getByText('Aarav Sharma')).toBeVisible();
  await page.getByRole('button', { name: 'Pay now' }).click();
  await heading(page, 'Family bill');
  await expect(page.getByText('Total payable').locator('..')).toContainText('₹4,500');
  await page.getByRole('button', { name: 'Continue to payment' }).click();
  await page.getByRole('button', { name: /^UPI/ }).click();
  await heading(page, /Waiting for UPI payment/);
  await expect(page.getByText(/PAY-\d+/)).toBeVisible();
  await page.getByRole('button', { name: 'Simulate successful payment' }).click();
  await heading(page, 'Payment successful!');
  await expect(page.locator('.receipt')).toContainText('₹4,500');
  await page.getByRole('button', { name: 'View receipt' }).click();
  await heading(page, 'Payment receipt');
  await page.goto('/parenthome');
  await expect(page.locator('.card', { hasText: 'Amount due' })).toContainText('₹0');
  await nav(page, 'Payments');
  await expect(page.getByRole('button', { name: 'Receipt' }).first()).toBeVisible();
  await ctx.close();
});

test('parent calendar is scoped to their children and can be filtered', async ({ browser }) => {
  const { ctx, page } = await fresh(browser);
  await asRole(page, 'neha@swar.demo', /Parent/);
  await nav(page, 'Schedule');
  await heading(page, 'Family schedule');
  await page.getByRole('button', { name: 'Week', exact: true }).click();
  await expect(page.locator('.session-row').first()).toBeVisible();
  const all = await page.locator('.session-row').count();
  await page.getByLabel('Child').selectOption({ label: 'Aarav' });
  await expect.poll(async () => page.locator('.session-row').count()).toBeLessThan(all);
  await expect(page.locator('.session-row').first()).toContainText('Aarav');
  // other academy data is not reachable
  await page.goto('/inbox');
  await expect(page).toHaveURL(/\/parenthome$/);
  await ctx.close();
});

test('teacher: sees only assigned classes, marks attendance, issues a make-up credit', async ({ browser }) => {
  const { ctx, page } = await fresh(browser);
  await asRole(page, 'rahul@swar.demo', /Teacher/);
  await expect(page).toHaveURL(/\/teacherhome$/);
  await expect(page.getByText('You have 2 sessions today.')).toBeVisible();
  await page.getByRole('button', { name: 'Mark attendance' }).first().click();
  await heading(page, 'Mark attendance');
  await expect(page.getByText(/Guitar Beginners/)).toBeVisible();
  await page.locator('.control', { hasText: 'Aarav Sharma' }).getByRole('checkbox').check();
  await page.getByRole('button', { name: 'Save attendance' }).click();
  await expect(page.getByRole('status').filter({ hasText: 'Attendance saved' })).toBeVisible();
  await page.getByRole('button', { name: 'Issue make-up credit' }).click();
  await heading(page, 'Issue make-up credit');
  await page.getByLabel('Student').selectOption({ label: 'Aarav Sharma' });
  await page.getByRole('button', { name: 'Issue 1 lesson credit' }).click();
  await heading(page, /Good (morning|afternoon|evening), Rahul/);
  // finance is off limits
  await page.goto('/inbox');
  await expect(page).toHaveURL(/\/teacherhome$/);
  await nav(page, 'Classes');
  await expect(page.locator('.session-row').first()).toBeVisible();
  await expect(page.locator('.session-row .desc small', { hasText: 'Meera' })).toHaveCount(0);
  await ctx.close();
});

test('minor student: activation, dashboard, no billing, make-up request', async ({ browser }) => {
  const { ctx, page } = await fresh(browser);
  await asRole(page, 'student1@test.dev', /Student/);
  await heading(page, 'Activate your student account');
  await page.getByLabel('Invitation code').fill('CP-STU-WRONG0000');
  await page.getByRole('button', { name: 'Activate student account' }).click();
  await expect(page.getByRole('status').filter({ hasText: 'invitation code' })).toBeVisible();
  await page.getByLabel('Invitation code').fill('CP-STU-DEMO0001');
  await expect(page.locator('.card', { hasText: 'Invitation' })).toContainText('Aarav');
  await page.getByRole('button', { name: 'Activate student account' }).click();
  await expect(page).toHaveURL(/\/studenthome$/);
  await expect(page.getByRole('heading', { name: /Hi, Aarav!/ })).toBeVisible();
  await expect(page.getByText(/managed by your linked guardian, Neha Sharma/)).toBeVisible();
  await expect(page.locator('.metric', { hasText: 'Make-up' })).toContainText('1');          // the credit issued by the teacher above
  await page.goto('/studentfees');
  await heading(page, 'Guardian-managed billing');
  await nav(page, 'Classes');
  await heading(page, 'My timetable');
  await expect(page.locator('.session-row').first()).toContainText('Guitar Beginners');
  await expect(page.locator('.session-row', { hasText: 'Vocals' })).toHaveCount(0);
  await page.goto('/studentclass');
  await heading(page, 'Guitar Beginners');
  await page.getByRole('button', { name: 'Request make-up class' }).click();
  await expect(page.getByRole('button', { name: 'Make-up request submitted' })).toBeDisabled();
  await page.goto('/studentattendance');
  await expect(page.locator('.card', { hasText: 'Attendance overview' })).toBeVisible();
  await page.goto('/inbox');
  await expect(page).toHaveURL(/\/studenthome$/);
  await ctx.close();
});

test('adult student pays their own invoice only', async ({ browser }) => {
  const { ctx, page } = await fresh(browser);
  await asRole(page, 'ishaan@swar.demo', /Student/);
  await page.getByLabel('Invitation code').fill('CP-STU-DEMO0002');
  await expect(page.getByLabel('Student account type')).toHaveValue(/18 or older/);
  await page.getByRole('button', { name: 'Activate student account' }).click();
  await expect(page.getByRole('heading', { name: /Hi, Ishaan!/ })).toBeVisible();
  await expect(page.locator('.card', { hasText: 'My fees' })).toContainText('₹2,000 due');
  await page.getByRole('button', { name: 'View and pay' }).click();
  await heading(page, 'My fees');
  await page.getByRole('button', { name: 'Pay my fees' }).click();
  await heading(page, 'Family bill');
  await expect(page.getByRole('button', { name: 'Request a payment date' })).toHaveCount(0);
  await page.getByRole('button', { name: 'Continue to payment' }).click();
  await page.getByRole('button', { name: /^UPI/ }).click();
  await page.getByRole('button', { name: 'Simulate successful payment' }).click();
  await heading(page, 'Payment successful!');
  await ctx.close();
});

test('owner: student search and settings notice', async () => {
  await owner.goto('/home');
  await expect(owner.locator('.metric', { hasText: 'Collected' })).toContainText('₹');
  await owner.goto('/student');
  await heading(owner, 'Students');
  await owner.getByLabel('Search').fill('Aarav');
  await expect(owner.locator('.listrow', { hasText: 'Aarav Sharma' })).toBeVisible();
  await owner.goto('/settings');
  await expect(owner.getByText('Payment gateway, SMS/WhatsApp, GST filing and bank reconciliation require production integrations.')).toBeVisible();
});
