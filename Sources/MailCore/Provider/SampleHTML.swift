import Foundation

/// HTML versions of some sample mails, written the way real ones are: tables for layout,
/// inline styles, remote images and a tracking pixel. Every host uses the `.example` TLD.
enum SampleHTML {
    static func html(for subject: String) -> String? {
        switch subject {
        case "Issue 212: Quiet interfaces": newsletter
        case "Card payment of €42.10": receipt
        case "Your tickets for 14 May": tickets
        case "Five soups for cold evenings": recipes
        default: nil
        }
    }

    static let newsletter = """
    <!doctype html><html><head><meta charset="utf-8"><title>The Design Weekly</title>
    <style>
      .wrap { width: 100%; background: #f3f1ec; padding: 24px 0; }
      .sheet { max-width: 600px; margin: 0 auto; background: #ffffff; border-radius: 6px; }
      h1 { font-family: Georgia, serif; font-weight: normal; font-size: 30px; margin: 0; color: #1d1d1b; }
      h2 { font-family: Georgia, serif; font-weight: normal; font-size: 21px; margin: 0 0 6px; color: #1d1d1b; }
      p { font-family: Helvetica, Arial, sans-serif; font-size: 15px; line-height: 1.55; color: #3d3d3a; margin: 0 0 14px; }
      .kicker { text-transform: uppercase; letter-spacing: .08em; font-size: 11px; color: #9a8f7a; }
      a.more { color: #b5541c; text-decoration: none; font-weight: bold; }
    </style></head><body style="margin:0">
    <table class="wrap" role="presentation" cellpadding="0" cellspacing="0"><tr><td>
    <table class="sheet" role="presentation" cellpadding="0" cellspacing="0" align="center">
      <tr><td style="padding:28px 32px 8px"><p class="kicker">Issue 212 · Sunday edition</p><h1>The Design Weekly</h1></td></tr>
      <tr><td style="padding:12px 32px"><img src="https://images.weekly.example/212/hero.jpg" width="536" alt="A quiet desk by a window" style="display:block;width:100%;border-radius:4px"></td></tr>
      <tr><td style="padding:12px 32px">
        <h2>Why calm software wins</h2>
        <p>The tools people keep are the ones that stay out of the way. This week we look at three products that removed features and grew anyway.</p>
        <p><a class="more" href="https://weekly.example/212/calm">Read the essay →</a></p>
      </td></tr>
      <tr><td style="padding:4px 32px 12px"><hr style="border:0;border-top:1px solid #ece8df">
        <h2>A short history of the command palette</h2>
        <p>From text editors to mail clients: how one keyboard shortcut quietly replaced the menu bar for a generation of power users.</p>
        <p><a class="more" href="https://weekly.example/212/palette">Keep reading →</a></p>
      </td></tr>
      <tr><td style="padding:16px 32px 28px;background:#faf9f6;border-radius:0 0 6px 6px">
        <p style="font-size:12px;color:#9a948a;margin:0">You're getting this because you subscribed at weekly.example. <a href="https://weekly.example/leave" style="color:#9a948a">Unsubscribe</a></p>
      </td></tr>
    </table></td></tr></table>
    <img src="https://t.weekly.example/open/212.gif" width="1" height="1" alt="">
    </body></html>
    """

    static let receipt = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
    <style>
      body { font-family: -apple-system, Helvetica, sans-serif; color: #111; }
      .card { max-width: 440px; border: 1px solid #e3e3e3; border-radius: 12px; padding: 20px 22px; }
      .amount { font-size: 34px; font-weight: 600; letter-spacing: -0.02em; margin: 6px 0 2px; }
      .muted { color: #6b6b6b; font-size: 13px; }
      td { padding: 7px 0; font-size: 14px; border-top: 1px solid #efefef; }
      @media (prefers-color-scheme: dark) {
        body { color: #eee; } .card { border-color: #333; } td { border-color: #2a2a2a; } .muted { color: #999; }
      }
    </style></head><body>
    <div class="card">
      <div class="muted">Card payment</div>
      <div class="amount">€42.10</div>
      <div class="muted">Corner Bakery · Today at 09:54</div>
      <table style="width:100%;margin-top:14px;border-collapse:collapse">
        <tr><td>Card</td><td style="text-align:right">•••• 4410</td></tr>
        <tr><td>Category</td><td style="text-align:right">Food &amp; drink</td></tr>
        <tr><td>Status</td><td style="text-align:right;color:#1a7f4b">Completed</td></tr>
      </table>
    </div>
    <p class="muted" style="margin-top:16px">Didn't make this payment? Freeze your card in the app.</p>
    </body></html>
    """

    static let tickets = """
    <!doctype html><html><head><meta charset="utf-8"></head><body style="font-family:Helvetica,Arial,sans-serif;color:#1b2430">
    <table role="presentation" style="max-width:520px;width:100%;border-collapse:collapse">
      <tr><td style="background:#0f3d5e;color:#fff;padding:18px 22px;border-radius:10px 10px 0 0">
        <img src="https://static.coastline.example/logo-white.png" height="22" alt="Coastline Rail"><br>
        <span style="font-size:22px;font-weight:bold">Your tickets for 14 May</span>
      </td></tr>
      <tr><td style="border:1px solid #d7dee6;border-top:0;padding:18px 22px;border-radius:0 0 10px 10px">
        <table role="presentation" style="width:100%">
          <tr><td style="font-size:12px;color:#6a7787">FROM</td><td style="font-size:12px;color:#6a7787;text-align:right">TO</td></tr>
          <tr><td style="font-size:26px;font-weight:bold">Amsterdam</td><td style="font-size:26px;font-weight:bold;text-align:right">Brussels</td></tr>
          <tr><td style="color:#6a7787">Depart 08:17</td><td style="color:#6a7787;text-align:right">Arrive 10:09</td></tr>
        </table>
        <p style="margin:16px 0 0;font-size:14px">Coach 7 · Seats 41 and 42 · Show the attached PDF at the gate.</p>
      </td></tr>
    </table></body></html>
    """

    static let recipes = """
    <!doctype html><html><head><meta charset="utf-8"></head>
    <body style="margin:0;background:#fbf7f1;font-family:Georgia,serif;color:#2b2420">
    <div style="max-width:560px;margin:0 auto;padding:28px 24px">
      <p style="font-family:Helvetica,sans-serif;font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:#a0866a">The Slow Cook</p>
      <h1 style="font-weight:normal;font-size:28px;margin:4px 0 16px">Five soups for cold evenings</h1>
      <img src="https://img.slowcook.example/soups/lentil.jpg" width="512" alt="A bowl of red lentil soup" style="width:100%;border-radius:8px">
      <p style="font-size:16px;line-height:1.6">A lentil soup that takes ten minutes, and four that are worth the wait. Start with the lentils: onion, garlic, cumin, a tin of tomatoes, stock, and red lentils until they fall apart.</p>
      <p style="font-family:Helvetica,sans-serif;font-size:12px;color:#a0866a">Not hungry for these? <a href="https://slowcook.example/leave" style="color:#a0866a">Unsubscribe</a></p>
    </div>
    <img src="https://slowcook.example/o.gif?u=8812" width="1" height="1" style="display:block">
    </body></html>
    """
}
