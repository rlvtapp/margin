# Feedback and crash reports

Margin tracks nothing, so the Margin team only hears about a problem when someone says so. Both
ways of saying so are an ordinary message from the person's own mailbox, written in the normal
composer, to Margin's own inbox, `margin@mail.relevate.app`, where incoming mail is sorted into
feature requests and support.

## Send Feedback

- **Where:** Margin › Help › Send Feedback… (and Report a Problem…), the Help panel, Settings ›
  About (also on iPhone and iPad), and `/feedback` in Ask.
- **What it opens:** a new message to `margin@mail.relevate.app` with an empty subject for the
  person to write, and at the bottom, in plain sight and editable, which Margin version and build
  and which system it is (`MailModel.appDescription`). Nothing is attached and nothing goes out
  until they send it (`MailModel.startFeedback`).

## Crash reports (Mac)

iPhone and iPad do not scan for system crash reports; Send Feedback is available there.

When Margin quits unexpectedly, macOS writes a crash report to
`~/Library/Logs/DiagnosticReports`. At the next launch Margin looks there for reports of its own
written since it last looked (`MailModel.checkForCrash`; the time is kept in `crash.checkedAt`,
and the first launch only notes it, so older crashes aren't offered). A report counts as
Margin's when its first line names Margin's own bundle id, so the screenshot build and other apps
are left out.

If there is one, Margin asks **Margin quit unexpectedly**: **Send Report…** opens the same
composer to Margin's inbox with the report attached (the person can open it, or remove it, before
sending) and a line asking what they were doing; **Not Now** forgets it. Margin never sends a
report on its own.

Tests: `Tests/MailUITests/CrashReportTests.swift`.
