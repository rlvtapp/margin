import Foundation

/// What an email's own words say about whether it wants something from you, read on the
/// device: a reminder, confirmation or receipt expects no answer, and a bill paid
/// automatically needs no action. Used by Home's "reply owed" and "bill" notes.
public enum MailNotice {
    /// Reminders, confirmations, receipts and messages sent by a system: nobody waits for an
    /// answer to these, even from a sender you know (your dentist's appointment reminder).
    public static func expectsNoReply(subject: String, text: String) -> Bool {
        // Words a friend might also write ("sending the confirmation") count in the subject
        // only; in the text, only the phrasing companies and systems use.
        let title = normalized(subject)
        if subjectWords.contains(where: { title.contains($0) }) { return true }
        let words = normalized(subject + "\n" + text.prefix(1_500))
        return noReplyPhrases.contains { words.contains($0) }
    }

    /// Whether a bill asks you to pay: a pay link or "pay now", bank transfer details, a payment
    /// reminder, overdue, or a charge that failed. An invoice that only says it's there (the
    /// amount, a due date, a PDF) is taken automatically as a rule, and a receipt is paid
    /// already: neither needs you.
    public static func asksForPayment(subject: String, text: String) -> Bool {
        let words = normalized(subject + "\n" + text.prefix(4_000))
        return payPhrases.contains { words.contains($0) }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    /// In a subject: a reminder, confirmation, receipt or order.
    static let subjectWords = [
        "reminder", "herinnering", "erinnerung", "rappel", "recordatorio", "promemoria",
        "confirmation", "confirmed", "bevestiging", "bevestigd", "bestätigung", "bestätigt", "confirmación", "conferma",
        "receipt", "ontvangstbewijs", "betalingsbewijs", "kwitantie", "quittung", "reçu", "recibo",
        "your order", "je bestelling", "uw bestelling", "ihre bestellung", "votre commande", "tu pedido",
    ]

    /// In the text: how companies remind, confirm and take payment, and how systems say they're one.
    static let noReplyPhrases = [
        "this is a reminder", "a friendly reminder", "would like to remind you", "we'd like to remind you",
        "herinneren wij u", "wij herinneren u", "willen wij u herinneren", "herinneren we je", "erinnern wir sie",
        "nous vous rappelons", "le recordamos", "le ricordiamo",
        "has been confirmed", "is now confirmed", "is bevestigd", "wurde bestätigt",
        "authorized with", "authorised with", "you sent a payment", "you've sent a payment", "payment received",
        "order number", "bestelnummer", "bestellnummer", "numéro de commande",
        "do not reply", "don't reply", "please do not respond", "no-reply", "noreply", "automated message",
        "automatically generated", "this is an automated", "this email was sent automatically", "niet beantwoorden",
        "niet op deze e-mail reageren", "niet reageren op deze", "automatisch verzonden", "automatisch gegenereerd",
        "nicht auf diese", "nicht antworten", "automatisch erstellt", "ne pas répondre", "no responda",
    ]

    /// Asking for money, in the languages Margin speaks.
    static let payPhrases = [
        "pay now", "pay invoice", "pay your invoice", "pay this invoice", "pay the invoice", "pay online", "please pay",
        "make a payment", "make payment", "payment link", "pay by bank", "bank transfer", "transfer the amount", "iban",
        "payment due", "payment is due", "is overdue", "past due", "payment failed", "payment was declined",
        "card was declined", "couldn't charge", "could not charge", "unable to charge", "update your payment",
        "nu betalen", "betaal nu", "betaal de factuur", "betalen via", "betaallink", "overmaken", "over te maken",
        "maak het bedrag", "graag betalen", "te betalen voor", "openstaand bedrag", "achterstallig", "aanmaning",
        "betalingsherinnering", "betaling mislukt", "jetzt bezahlen", "überweisen", "zahlbar bis", "überfällig",
        "zahlung fehlgeschlagen", "mahnung", "zahlungserinnerung", "payer maintenant", "à payer avant", "virement",
        "en retard de paiement", "paiement refusé", "pagar ahora", "transferencia", "pago fallido",
    ]
}
