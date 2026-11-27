import AppKit

/// Pomocník – vysvetlenie všetkých funkcií aplikácie (menu Pomoc).
final class HelpWindowController: NSWindowController {
    private static let sections: [(String, String, [String])] = [
        ("Úvod", "info.circle", [
            "Vimeo Viewer je aplikácia na prezeranie, komentovanie a správu videí na Vimeu (tím NUNEZ NFE).",
            "Hore v lište prepínate režimy Knižnica (⌘1) a Video (⌘3). Ikona zemegule otvorí web vimeo.com, domček sa vráti na úvodnú obrazovku.",
            "Do adresného riadku môžete vložiť odkaz na Vimeo, číslo videa alebo hľadaný výraz.",
        ]),
        ("Prihlásenie", "person.crop.circle", [
            "Ikona osoby vpravo hore (⇧⌘L) otvorí prihlásenie. Prihlásite sa e-mailom a heslom.",
            "Ak máte účet cez Google/Apple alebo dvojfázové overenie, použite „Prihlásiť cez webovú stránku“.",
            "Prihlásenie je potrebné pre knižnicu, komentáre, nahrávanie a sťahovanie.",
        ]),
        ("Knižnica", "square.grid.2x2", [
            "Vľavo je strom priečinkov – šípkou rozbalíte podpriečinky, kliknutím priečinok otvoríte.",
            "Vpravo je mriežka: najprv priečinky, potom videá. Hore je cesta – kliknutím na jej časť sa vrátite vyššie. Šípka Späť ide o úroveň vyššie.",
            "Obľúbené: hviezdička pri ceste alebo pravý klik na priečinok → „Pridať medzi obľúbené“. Obľúbené sú navrchu bočného panela hneď po spustení.",
            "Vyhľadávanie hore vpravo hľadá videá v celej knižnici.",
            "Pravý klik na video: Otvoriť, Stiahnuť, Kopírovať odkaz.",
            "Aplikácia si pamätá posledný otvorený priečinok. Zobraziť → Nastaviť ako úvodnú obrazovku (⇧⌘D) určí, čo sa zobrazí po spustení.",
        ]),
        ("Video a ovládanie", "play.rectangle", [
            "Ovládanie je v lište pod videom: prehrať/pauza (⌘↩), −10 s / +10 s (⌥⌘← / ⌥⌘→), čas, časová os, hlasitosť, rýchlosť, titulky vo videu (CC), kvalita, obraz v obraze a celá obrazovka.",
            "Časová os: kliknutím pretočíte video. Bodky označujú komentáre – oranžové sú komentáre kolaborátorov, modré komentáre s časom. Prejdením myšou nad bodkou uvidíte text, kliknutím skočíte na čas komentára.",
            "Panely Prepis a Komentáre skryjete/zobrazíte v menu Zobraziť (⌥⌘1, ⌥⌘2), lištu zdieľania ⌥⌘3.",
        ]),
        ("Prepis", "text.alignleft", [
            "Prepis (titulky) sa načíta automaticky. Aktuálna veta sa zvýrazňuje, kliknutím na vetu alebo čas pretočíte video.",
            "„Jazyk“: originál alebo preklad do slovenčiny, češtiny, angličtiny a ďalších jazykov. Voľbu si aplikácia pamätá – cudzojazyčné videá sa automaticky preložia.",
            "Hľadanie v prepise: ⌘F. Menu ⋯: kopírovať prepis, uložiť ako .txt alebo .srt, nahrať vlastné titulky na Vimeo.",
            "Preklad robí Google Prekladač, alebo DeepL, ak zadáte kľúč v Nastaveniach (⌘,).",
        ]),
        ("Komentáre", "bubble.left.and.bubble.right", [
            "Panel Komentáre zobrazuje komentáre kolaborátorov (s časom a značkou ✓ vyriešené) a verejné komentáre.",
            "Nový komentár: kliknite do poľa „Kliknite sem…“ – video sa zastaví a zaznamená sa presný čas (vidno ho na štítku ⏱). Napíšte text a stlačte Pridať. Rovnako funguje ⌘K.",
            "Pod komentárom: Odpovedať, Upraviť, Zmazať (vlastné komentáre, alebo všetky, ak ste vlastník videa).",
            "Časy v texte komentára (napr. 12:34) sú klikateľné.",
        ]),
        ("Zdieľanie a Review link", "square.and.arrow.up", [
            "Review link: odkaz na video, cez ktorý môžu ostatní pozerať a komentovať. Môžete ho skopírovať, zdieľať, poslať e-mailom alebo otvoriť.",
            "Lišta zdieľania: odkaz (voliteľne od aktuálneho času), embed kód, Markdown, AirDrop/Správy/Mail, sociálne siete, QR kód, otvorenie v prehliadači.",
        ]),
        ("Menu Video – nahradenie, sťahovanie, titulky", "film", [
            "Nahradiť video novým súborom (Replace, ⇧⌘R): nahrá nový súbor ako novú verziu toho istého videa – odkaz, review link aj komentáre zostanú.",
            "Stiahnuť video (⌥⌘S): vyberiete kvalitu a miesto uloženia.",
            "Nahrať titulky (⇧⌘U): .srt, .vtt, .dfxp/.ttml, .scc, .sami – zvolíte jazyk, typ a názov.",
        ]),
        ("Nahrávanie videí", "arrow.up.circle", [
            "V Knižnici tlačidlo „Nahrať video…“ (⌘U) nahrá jedno alebo viac videí do práve otvoreného priečinka.",
            "Priebeh nahrávania a sťahovania je v okne Prenosy (⌥⌘T) – dá sa zrušiť alebo zobraziť súbor vo Finderi.",
        ]),
        ("Odkazy na Vimeo z iných aplikácií", "link", [
            "Aby sa odkazy na Vimeo z prezentácií, PDF či e-mailov otvárali tu, nastavte aplikáciu ako predvolený prehliadač (Nastavenia ⌘,). Ostatné odkazy sa okamžite pošlú do vášho bežného prehliadača.",
            "Odkaz zo schránky otvoríte cez ⇧⌘V.",
        ]),
        ("Aktualizácie a inštalácia", "arrow.triangle.2.circlepath", [
            "Vimeo Viewer → Skontrolovať aktualizácie… – aplikácia stiahne novú verziu, nahradí sa a znova spustí. Kontroluje to aj sama pri spustení.",
            "Ak macOS pri prvej inštalácii hlási „poškodenú“ aplikáciu, spustite v Termináli: xattr -cr \"/Applications/Vimeo Viewer.app\"",
        ]),
        ("Keď niečo nefunguje", "stethoscope", [
            "Pomoc → Diagnostika: zopakujte problém, kliknite „Kopírovať všetko“ a text pošlite. Heslá sa nezaznamenávajú.",
        ]),
    ]

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.title = "Návod – Vimeo Viewer"
        super.init(window: win)
        let (sv, tv) = UI.scrollingTextView()
        tv.textContainerInset = NSSize(width: 24, height: 20)
        tv.textStorage?.setAttributedString(HelpWindowController.content())
        win.contentView = sv
        win.center()
        win.setFrameAutosaveName("HelpWindow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static func content() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let title = NSMutableParagraphStyle()
        title.paragraphSpacing = 10
        out.append(NSAttributedString(string: "Vimeo Viewer – návod\n", attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.labelColor, .paragraphStyle: title]))
        let head = NSMutableParagraphStyle()
        head.paragraphSpacingBefore = 16
        head.paragraphSpacing = 6
        let bullet = NSMutableParagraphStyle()
        bullet.headIndent = 16
        bullet.firstLineHeadIndent = 0
        bullet.paragraphSpacing = 5
        bullet.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
        for (name, symbol, lines) in sections {
            let h = NSMutableAttributedString()
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let att = NSTextAttachment()
                att.image = img
                att.bounds = NSRect(x: 0, y: -3, width: 17, height: 16)
                h.append(NSAttributedString(attachment: att))
                h.append(NSAttributedString(string: "  "))
            }
            h.append(NSAttributedString(string: name + "\n"))
            h.addAttributes([.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor,
                             .paragraphStyle: head], range: NSRange(location: 0, length: h.length))
            out.append(h)
            for l in lines {
                out.append(NSAttributedString(string: "•\t" + l + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: bullet]))
            }
        }
        return out
    }
}
