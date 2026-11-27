# Vimeo Viewer pre macOS (Big Sur 11 a novší)

Samostatná aplikácia na prezeranie Vimeo videí. Odkazy na Vimeo z prezentácií (Keynote, PowerPoint),
PDF (Náhľad, Acrobat), Mailu, Wordu atď. sa otvoria **priamo v nej** a ostatné odkazy prepošle do vášho
bežného prehliadača.

## Rozloženie okna (režim „Video“)

```
┌──────────────┬────────────────────────────┬──────────────────┐
│ 1. PREPIS    │ 2. VIDEO                   │ 3. KOMENTÁRE     │
│ • klik na    │ oficiálny Vimeo prehrávač  │ • čítanie        │
│   riadok =   │ (celá obrazovka, PiP,      │ • odpovede       │
│   skok v     │ titulky, kvalita…)         │ • pridanie       │
│   videu      │                            ├──────────────────┤
│ • hľadanie   │                            │ 4. ZDIEĽANIE     │
│ • export     │                            │ odkaz (aj s ča-  │
│              │                            │ som), embed, QR, │
│              │                            │ Mail, Správy, …  │
└──────────────┴────────────────────────────┴──────────────────┘
```

* **Prepis** – titulky / automatický prepis videa, aktuálna veta sa zvýrazňuje a posúva počas
  prehrávania. Klik na čas alebo text pretočí video na to miesto. Hľadanie (⌘F), výber jazyka,
  kopírovanie a uloženie do .txt.
* **Video** – oficiálny Vimeo prehrávač vrátane nezverejnených videí (odkazy typu `vimeo.com/123/abcdef`)
  a odkazov s časom (`#t=1m30s`).
* **Komentáre** – načítanie, stránkovanie, odpovede, pridanie komentára; časy typu `12:34`
  v komentároch sú klikateľné.
* **Zdieľanie** – kopírovať odkaz (voliteľne od aktuálneho času), embed kód, Markdown, systémové
  zdieľanie (AirDrop, Poznámky…), E-mail, Správy, X, Facebook, LinkedIn, otvoriť v prehliadači, QR kód.

Panely sa dajú skryť/zobraziť cez menu **Zobraziť** (⌥⌘1 / ⌥⌘2 / ⌥⌘3) a zmeniť ich šírku ťahaním.
Režim **Prehliadať** (⌘1) zobrazí celý vimeo.com (prihlásenie, vaše videá, vyhľadávanie). Klik na
akékoľvek video vás prepne do režimu **Video** (⌘2).

## Inštalácia (raz, cca 2 minúty)

1. Skopírujte priečinok `VimeoViewer` na Mac.
2. Ak nemáte Xcode, nainštalujte nástroje vývojára (stačí raz):
   ```bash
   xcode-select --install
   ```
3. V Termináli prejdite do priečinka a spustite:
   ```bash
   cd ~/Downloads/VimeoViewer
   ```
   ```bash
   ./build.sh install
   ```
   Aplikácia sa zostaví (univerzálne pre Intel aj Apple Silicon), nainštaluje do `/Applications`
   a spustí.

## Aby sa VŠETKY Vimeo odkazy otvárali v aplikácii

macOS posiela odkazy z iných aplikácií vždy do *predvoleného webového prehliadača*. Preto sa
Vimeo Viewer nastaví ako predvolený prehliadač a funguje ako inteligentný „rozdeľovač“:

* odkaz na **vimeo.com / player.vimeo.com** → otvorí sa v aplikácii,
* **akýkoľvek iný odkaz** → okamžite sa prepošle do Safari / Chrome / Firefoxu (podľa výberu).

Pri prvom spustení sa aplikácia opýta; neskôr cez **Vimeo Viewer → Nastavenia… (⌘,)** →
„Nastaviť ako predvolený prehliadač“ (macOS zobrazí potvrdzovací dialóg – zvoľte *Použiť „Vimeo Viewer“*).
V nastaveniach vyberiete aj prehliadač pre ostatné odkazy a kedykoľvek ho viete vrátiť späť tlačidlom
„Vrátiť …“.

Rozpoznávajú sa aj odkazy zabalené cez Outlook Safe Links, Google a Facebook presmerovania, ako aj
vlastná schéma `vimeoviewer://vimeo.com/123456` a súbory `.webloc`.

Po zavretí okna aplikácia ostáva bežať (aby mohla ďalej preposielať odkazy); okno znova otvoríte
kliknutím na ikonu v Docku alebo ⌘N. Úplne ju ukončíte cez ⌘Q.

## Komentáre – Vimeo API token (voliteľné, zadarmo)

Prepis aj video fungujú bez akéhokoľvek nastavenia. Komentáre poskytuje Vimeo len cez svoje API:

1. Na <https://developer.vimeo.com/apps> sa prihláste a kliknite **Create an app** (názov ľubovoľný).
2. V aplikácii → **Generate an access token** → **Authenticated (you)** → oprávnenia
   **Public, Private, Interact** → Generate.
3. Token vložte v aplikácii do **Nastavenia → Vimeo API token → Uložiť** (uloží sa do Kľúčenky).

Bez tokenu má panel Komentáre tlačidlo „Zobraziť na vimeo.com“.

## Klávesové skratky

| Skratka | Akcia |
|---|---|
| ⌘L | Otvoriť odkaz / hľadať |
| ⇧⌘V | Otvoriť Vimeo odkaz zo schránky |
| ⌘1 / ⌘2 | Prehliadať / Video |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Panel Prepis / Komentáre / Zdieľanie |
| ⌘↩ | Prehrať / Pozastaviť |
| ⌥⌘← / ⌥⌘→ | −10 s / +10 s |
| ⇧⌘C | Kopírovať odkaz s aktuálnym časom |
| ⇧⌘O | Otvoriť vo webovom prehliadači |
| ⌘F | Hľadať v prepise |
| ⌃⌘F | Celá obrazovka |

## Poznámky

* Prepis je k dispozícii len pre videá, ktoré majú titulky alebo automatický prepis od Vimea.
* Niektorí autori zakazujú vkladanie videa mimo vimeo.com – vtedy ho otvorte v režime Prehliadať.
* Po každom novom zostavení sa macOS môže raz opýtať na prístup ku Kľúčenke (token) – zvoľte „Vždy povoliť“.
* Zdrojový kód: `Sources/` (Swift, AppKit + WebKit, bez externých závislostí).

## Vytvorenie DMG

```bash
./make_dmg.sh
```
Vznikne `build/Vimeo Viewer 1.0.dmg` – po otvorení stačí aplikáciu pretiahnuť do priečinka Aplikácie.
Ak DMG pošlete na iný Mac, pri prvom spustení na ňom kliknite na aplikáciu pravým tlačidlom → **Otvoriť**
(aplikácia nie je podpísaná certifikátom Apple Developer).

## Hotové DMG z GitHubu (bez Xcode)

Každý push do vetvy `main` spustí na GitHube zostavenie na Mac serveri (záložka **Actions** →
posledný beh → **Artifacts** → `Vimeo-Viewer-dmg`). Pri vytvorení tagu `v1.0` sa DMG zverejní
aj v sekcii **Releases**.
