# Google sign-in: verification checklist

Everything Google asks for before "Sign in with Google" works for more than 100 people. Until it's
approved, Gmail works with an app password (see the support page), and Google sign-in works only
for test users, who must sign in again every 7 days.

Margin asks for one restricted permission (full Gmail access, which IMAP and SMTP need) and some
sensitive ones. Restricted means the longest review: brand check, permission review, and possibly
a yearly security assessment.

## 1. Accounts and domain

- [ ] A Google Cloud project owned by the company's Google Workspace account, not a personal one.
- [ ] Two owners or editors on the project, so the review never stalls on one person.
- [ ] **relevate.app verified in Google Search Console** by one of the project owners. The
      homepage, privacy policy and terms must be on a verified domain.
- [ ] A support inbox someone reads (the site uses `hello@relevate.app`; make sure it exists).
      Google's reviewers write there and expect answers within days.
- [ ] A developer contact email for Google's notices.

## 2. Website (done in `site/`, needs publishing)

- [ ] Homepage live at **https://margin.relevate.app**: says what Margin is and what it does with
      Gmail, links to the privacy policy, needs no login.
- [ ] Privacy policy live at **/privacy**. It already has the required sentence about Google's
      Limited Use requirements, explains what each Google permission is used for, and says data
      stays on the device. Re-read it against the final app before submitting.
- [ ] Terms at **/terms**.
- [ ] The app's name is "Margin" everywhere: site, consent screen, App Store, video.

## 3. Consent screen (Google Auth Platform → Branding)

- [ ] App name: Margin.
- [ ] Logo: 120 × 120 px PNG, Margin's own icon (no Google marks).
- [ ] User support email.
- [ ] Home page: https://margin.relevate.app
- [ ] Privacy policy: https://margin.relevate.app/privacy
- [ ] Terms: https://margin.relevate.app/terms
- [ ] Authorized domain: relevate.app
- [ ] Audience: External. Publishing status: In production.
- [ ] Submit for **brand verification** first; it's quick (a few days) and the scope review
      follows it.

## 4. Sign-in clients (Google Auth Platform → Clients)

- [ ] One **iOS** client for the iPhone/iPad app, with the final bundle ID (now
      `app.relevate.margin`, in its own Google Cloud project for Margin).
- [ ] The Mac app uses the same kind of client; Google treats native Apple apps as "iOS" clients.
      Margin signs in with PKCE and the reversed client ID as the redirect
      (`com.googleusercontent.apps.<id>:/oauth2redirect`), so no client secret is needed.
- [ ] Put the client ID in the app's Info.plist as `MarginGoogleClientID`.

## 5. Permissions to list (Google Auth Platform → Data access)

Each needs a short written reason. Draft wording:

| Permission | Kind | What Margin does with it |
| --- | --- | --- |
| `https://mail.google.com/` | Restricted | Reads, sends, organises and deletes mail over IMAP and SMTP, which only accept this permission. Also used to start Gmail push notifications. Mail stays on the device. |
| `gmail.settings.basic` | Sensitive | Turns the out-of-office reply on or off and changes its message when the person asks. |
| `contacts.readonly` | Sensitive | Suggests addresses and shows names when writing a message. Kept on the device. |
| `contacts.other.readonly` | Sensitive | The same, for people the person has emailed but not saved as contacts. |
| `calendar.events` | Sensitive | Creates the event when the person sends a new meeting invitation from Margin. |
| `calendar.freebusy` | Sensitive | Shows when invited people and rooms are free while planning a meeting. |
| `admin.directory.resource.calendar.readonly` | Sensitive | Lists the company's meeting rooms so one can be booked. |
| `email` | Basic | Shows which Google account is signed in. |

- [ ] Check each one is still used before submitting; every unused permission slows the review.
      If rooms and meetings can wait, leaving out the calendar and directory permissions makes
      the first review simpler.

## 6. Demo video

- [ ] An unlisted YouTube video, a few minutes long, in English:
  1. Starting Google sign-in in Margin, with the browser's address bar showing the client ID.
  2. The consent screen showing "Margin" and every permission.
  3. Each permission in use: the inbox loading, sending a message, deleting one, turning the
     out-of-office on, a contact suggestion, creating a meeting with a room.
- [ ] Same app name and logo as on the consent screen.

## 7. Security assessment (CASA), if Google asks

Google's pages say the yearly assessment applies when Gmail data passes through a server, which
Margin's doesn't. In practice Google has asked desktop mail apps with no server for it anyway, so
plan for it.

- [ ] Ask in the review whether it applies, mentioning that mail never leaves the device and the
      push relay only receives Google's notice (address and a change number).
- [ ] If yes: a Tier 2 assessment through one of Google's approved labs. Expect roughly $540–$1,800
      a year with Google's partner discount, a self-assessment questionnaire, and a scan of the app.
      Renewed every 12 months.

## 8. Gmail push (iPhone and iPad notifications)

- [ ] A Pub/Sub topic in the same project, with `gmail-api-push@system.gserviceaccount.com`
      allowed to publish to it.
- [ ] A push subscription on that topic pointing at the relay's `/v1/hooks/gmail?token=…`.
- [ ] The relay hosted on a relevate.app address.

## 9. While waiting

- [ ] Add testers under Audience → Test users (up to 100 in total, ever).
- [ ] Gmail users sign in with an app password; the steps are on the support page.

## After approval

- Keep the privacy policy true: new Google permissions or a new server that sees Gmail data mean
  updating the policy and, usually, a new review.
- Watch the support inbox for the yearly re-verification notice.
