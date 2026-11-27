import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// MARK: - Menu

func key(_ scalar: Int) -> String {
    return String(Character(UnicodeScalar(UInt32(scalar))!))
}

func item(_ title: String, _ action: Selector?, _ keyEq: String = "", _ mods: NSEvent.ModifierFlags = [.command],
          target: AnyObject? = AppDelegate.shared, tag: Int = 0) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: keyEq)
    i.keyEquivalentModifierMask = mods
    i.target = target
    i.tag = tag
    return i
}

func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let m = NSMenu(title: title)
    for i in items { m.addItem(i) }
    top.submenu = m
    return top
}

let appName = "Vimeo Viewer"
let mainMenu = NSMenu()

mainMenu.addItem(submenu(appName, [
    item("O aplikácii \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: nil),
    .separator(),
    item("Nastavenia…", #selector(AppDelegate.showPreferences(_:)), ","),
    item("Skontrolovať aktualizácie…", #selector(Updater.checkNow(_:)), target: Updater.shared),
    item("Nastaviť ako predvolený prehliadač", #selector(AppDelegate.makeDefaultBrowser(_:))),
    .separator(),
    item("Skryť \(appName)", #selector(NSApplication.hide(_:)), "h", target: nil),
    item("Skryť ostatné", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: nil),
    item("Zobraziť všetko", #selector(NSApplication.unhideAllApplications(_:)), target: nil),
    .separator(),
    item("Ukončiť \(appName)", #selector(NSApplication.terminate(_:)), "q", target: nil),
]))

mainMenu.addItem(submenu("Súbor", [
    item("Hlavné okno", #selector(AppDelegate.showMainWindow(_:)), "n"),
    item("Otvoriť odkaz…", #selector(AppDelegate.openLocation(_:)), "l"),
    item("Nahrať video…", #selector(AppDelegate.uploadVideo(_:)), "u"),
    item("Stiahnuť video…", #selector(AppDelegate.downloadVideo(_:)), "s", [.command, .option]),
    .separator(),
    item("Prihlásiť sa do Vimea…", #selector(AppDelegate.login(_:)), "l", [.command, .shift]),
    item("Otvoriť odkaz zo schránky", #selector(AppDelegate.openPasteboardLink(_:)), "v", [.command, .shift]),
    .separator(),
    item("Otvoriť vo webovom prehliadači", #selector(AppDelegate.openInBrowser(_:)), "o", [.command, .shift]),
    item("Kopírovať odkaz s aktuálnym časom", #selector(AppDelegate.copyLinkAtTime(_:)), "c", [.command, .shift]),
    .separator(),
    item("Zavrieť okno", #selector(NSWindow.performClose(_:)), "w", target: nil),
]))

mainMenu.addItem(submenu("Upraviť", [
    item("Späť", Selector(("undo:")), "z", target: nil),
    item("Znova", Selector(("redo:")), "z", [.command, .shift], target: nil),
    .separator(),
    item("Vystrihnúť", #selector(NSText.cut(_:)), "x", target: nil),
    item("Kopírovať", #selector(NSText.copy(_:)), "c", target: nil),
    item("Vložiť", #selector(NSText.paste(_:)), "v", target: nil),
    item("Vybrať všetko", #selector(NSText.selectAll(_:)), "a", target: nil),
    .separator(),
    item("Hľadať v prepise", #selector(AppDelegate.findInTranscript(_:)), "f"),
]))

mainMenu.addItem(submenu("Zobraziť", [
    item("Knižnica", #selector(AppDelegate.showLibraryMode(_:)), "1"),
    item("Prehliadať Vimeo", #selector(AppDelegate.showBrowseMode(_:)), "2"),
    item("Video", #selector(AppDelegate.showVideoMode(_:)), "3"),
    .separator(),
    item("Panel Prepis", #selector(AppDelegate.toggleTranscript(_:)), "1", [.command, .option]),
    item("Panel Komentáre", #selector(AppDelegate.toggleComments(_:)), "2", [.command, .option]),
    item("Panel Zdieľanie", #selector(AppDelegate.toggleShare(_:)), "3", [.command, .option]),
    .separator(),
    item("Späť", #selector(AppDelegate.navBack(_:)), "["),
    item("Dopredu", #selector(AppDelegate.navForward(_:)), "]"),
    item("Domov", #selector(AppDelegate.navHome(_:)), "h", [.command, .shift]),
    item("Nastaviť ako úvodnú obrazovku", #selector(AppDelegate.setHomePage(_:)), "d", [.command, .shift]),
    item("Obnoviť pôvodnú úvodnú stránku", #selector(AppDelegate.resetHomePage(_:))),
    item("Obnoviť", #selector(AppDelegate.navReload(_:)), "r"),
    .separator(),
    item("Celá obrazovka", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: nil),
]))

let rates: [(String, Int)] = [("0,75×", 75), ("1×", 100), ("1,25×", 125), ("1,5×", 150), ("2×", 200)]
mainMenu.addItem(submenu("Prehrávanie", [
    item("Prehrať / Pozastaviť", #selector(AppDelegate.playPause(_:)), "\r"),
    item("Pridať komentár k aktuálnemu času", #selector(AppDelegate.addTimedComment(_:)), "k"),
    item("Dozadu o 10 s", #selector(AppDelegate.skipBack(_:)), key(NSLeftArrowFunctionKey), [.command, .option]),
    item("Dopredu o 10 s", #selector(AppDelegate.skipForward(_:)), key(NSRightArrowFunctionKey), [.command, .option]),
    .separator(),
    submenu("Rýchlosť", rates.map { item($0.0, #selector(AppDelegate.setRate(_:)), tag: $0.1) }),
]))

let windowMenuItem = submenu("Okno", [
    item("Minimalizovať", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
    item("Zväčšiť", #selector(NSWindow.performZoom(_:)), target: nil),
    .separator(),
    item("Prenosy (nahrávanie a sťahovanie)", #selector(AppDelegate.showTransfers(_:)), "t", [.command, .option]),
    .separator(),
    item("Preniesť všetko dopredu", #selector(NSApplication.arrangeInFront(_:)), target: nil),
])
mainMenu.addItem(windowMenuItem)

mainMenu.addItem(submenu("Pomoc", [
    item("Diagnostika…", #selector(AppDelegate.showDiagnostics(_:))),
]))

app.mainMenu = mainMenu
app.windowsMenu = windowMenuItem.submenu

app.run()
