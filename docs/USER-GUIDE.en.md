# CarroNote User Guide

> CarroNote, write safely on every page.

Welcome to CarroNote! This is a privacy-focused encrypted note-taking app. This guide will walk you through everything, from opening the app for the first time to mastering every feature. Don't worry — it's written in plain language, with no technical background needed.

---

## 1. Getting to Know CarroNote

Before we start, here's what makes CarroNote special:

**🔐 End-to-end encryption — only you can read your notes**

Every note is encrypted the moment you save it. Even if someone grabs your phone, or (if you enable sync) intercepts the data in transit, all they'd see is scrambled garbage. Not even we can read your notes.

**📱 Local-first — works without the internet**

Your notes are stored on your own device by default, and they're encrypted at rest. On a plane, in the subway, or anywhere with no signal — you can still take notes.

**☁️ Multi-device sync — never lose a note when you switch devices**

Want to sync notes between your computer and phone? You can. Your notes are encrypted before they leave your device, so any sync server only ever sees ciphertext.

**🎨 Colorful themes and colored notes — make it yours**

Switch between light and dark mode, pick from over a hundred theme colors and a dozen note palettes, and make note-taking a pleasure to look at.

**🔒 Layers of privacy protection**

Fingerprint / face unlock, screenshot protection, incognito keyboard, auto-lock, brute-force protection — every detail is designed to protect your privacy.

---

## 2. First Time: Set Your Passphrase

The first time you open CarroNote, you'll see a "Set Passphrase" screen. This is the foundation of your security, so please take it seriously.

1. Type the passphrase you want to use (at least 8 characters; overly weak passphrases will be rejected).
2. Type it again to confirm.
3. Tap "Confirm".

**⚠️ Very important: memorize this passphrase.**

It's the only key to all your notes, and it lives only in your head. If you forget it, nobody can recover it for you — including us. Without it, your notes can never be decrypted.

> Tip: a passphrase can be a sentence or a meaningful phrase — it's more secure and easier to remember than a bare number combination.

Once set up, you'll land on the home screen, ready to write your first note.

---

## 3. Logging In and Unlocking

Every time you open CarroNote, you'll need to unlock it. There are two ways:

**Option 1: Enter your passphrase**

Type your passphrase on the login screen and tap "Login".

**Option 2: Fingerprint / face unlock**

If you've enabled biometrics in Settings, the login screen will show a "Biometric" button — tap your fingerprint or glance at the screen to unlock, no typing needed.

> To help you remember your passphrase, CarroNote will occasionally ask you to log in with it after a number of biometric unlocks. This is normal — it's protecting you.

**Forgot your passphrase?**

Below the login form there's a "Can't decrypt without phrase" hint. If you truly forgot it:

1. Tap it to reveal the "Reset Local Data" option.
2. This is the last resort — it deletes all local data and lets you start over.
3. The good news: before resetting, CarroNote automatically saves an encrypted snapshot, so if you remember the passphrase later, you may be able to recover it manually.

> ⚠️ Resetting local data is irreversible. Think twice.

---

## 4. Writing Notes: Create, Edit, Save

**Create a note**

Tap the ➕ button in the bottom-right corner of the home screen.

**What a note looks like**

Each note has two parts:

- **Title**: the note's name, so you can tell at a glance what it's about.
- **Body**: the note's content — write whatever you like.

**Edit and preview**

When you open a note, you'll first see it in "preview" (the formatted view). Tap the pencil icon in the top-right to switch to "edit" mode and start writing; tap the eye icon to switch back to "preview".

**Save**

Tap the 💾 save icon in the top-right when you're done.

> If you try to leave without saving, CarroNote will ask: save, discard, or keep editing? No more losing work by accident.

**Delete a note**

Tap the 🗑️ trash icon in the editor's top-right. After confirming, the note moves to the trash (it doesn't disappear immediately — you can still change your mind).

---

## 5. Formatting Notes with Markdown

CarroNote supports Markdown, so you can write beautifully formatted notes using simple symbols.

**What is Markdown?**

Markdown is a way to format text using symbols. For example:

| What you want | How to write it |
|---|---|
| Heading 1 | `# Heading` |
| Heading 2 | `## Heading` |
| **Bold** | `**bold**` |
| Quote | `> quoted text` |
| Inline code | `` `code` `` |
| Code block | wrap it in ` ``` ` |
| Link | `[text](url)` |

Switch to "preview" to see the formatted result.

**Turn Markdown on / off**

Go to Settings → Appearance → Markdown to toggle it anytime. When off, note bodies are shown as plain text.

> 🔒 Privacy note: for safety, CarroNote won't auto-load images in your notes or make any network requests on its own. Links only open in your system browser when you tap them yourself.

---

## 6. Searching and Organizing Notes

**Search**

Use the search box at the top of the home screen. It matches both titles and bodies, so you can find any note quickly.

**List / grid view**

Toggle between "list" and "grid" layouts from the top-right — whichever you prefer.

**Sorting**

The arrow button in the top-right switches between "newest first" and "oldest first". Finer sorting (by modified date / by created date) is available in Settings.

---

## 7. Trash (Recently Deleted)

Deleted notes go to "Recently Deleted" (the trash), which you can find in the main menu.

- **Restore**: tap the "⋯" menu on a note and choose "Restore" to bring it back.
- **Permanently delete**: choose "Permanently Delete" to erase it for good — no going back.
- **Clear all**: tap the trash icon in the top-right to empty the whole trash at once.

> ⚠️ Permanent deletion and clearing are irreversible. Confirm before you proceed.

---

## 8. Sync: Keeping Notes Flowing Across Devices

Sync lets you share the same set of notes across your phone, tablet, and computer. Because everything is end-to-end encrypted, only ciphertext ever travels.

**Turn on sync**

Go to Settings → Data → Sync Settings and turn on "Enable Sync".

**Choose how to sync**

Tap "Sync Configuration". You have several options:

- **Local Folder**: sync encrypted data to a folder on this device (good for testing or single-device backup).
- **WebDAV**: for services like Nutstore, NextCloud, or self-hosted servers. You'll need the server address, username, and password (cloud drives usually require an "app password", not your login password).
- **SafeServer**: if you run the companion sync service yourself, enter the address and token.
- **No Sync**: turn sync off and keep data local only.

After filling in the details, tap "Test Connection", then tap "Save" once it passes.

**Auto sync / manual sync**

- Turn on "Auto sync after note changes" to sync automatically every time you edit a note.
- Or return to Sync Settings anytime and tap "Sync Now" to sync manually.

**Reading the sync icon**

The cloud icon in the top-right of the home screen shows sync status: spinning = syncing, checkmark = success, red broken cloud = failed.

---

## 9. Backup and Migration

**Auto backup**

Go to Settings → Data → Backup and turn on "Auto Backup". CarroNote will periodically back up your encrypted data to a location you choose.

**Back up now**

Tap "Backup Now" in the backup screen to create a backup file immediately.

**Export / import backup**

- **Export Backup**: package your notes into a file — choose encrypted (set an export password) or plain.
- **Import Backup**: import a previously exported backup on a new device for a seamless move.

> Backup files are encrypted by default, so nobody else can read them.

---

## 10. Themes and Appearance (Make It Pretty)

Go to Settings → Appearance to customize the whole look.

**Dark mode**

Tap "Dark Mode" to turn it on or off manually, or choose "Use device settings" so CarroNote follows your system's light/dark mode.

**Theme color**

Tap "Theme Color" to open the color picker. Colors are grouped into families (Default, Pastel, Vibrant, Earthy, Gemstone) — over a hundred colors to choose from.

- Tapping a color only "previews" it; the preview bar shows the effect.
- Once you're happy, tap "Apply theme" at the bottom and the whole app changes instantly.

**Notes color**

Tap "Notes Color" to color your note cards:

- Turn on "Colorful Notes" and cards automatically rotate through a palette by position.
- Pick from a dozen palette themes (Nord Arctic, Harmony, Blossom, and more) below.
- Or turn color off for a single, elegant neutral look across all notes.

**Other appearance options**

- **Compact Notes**: make note cards more compact so you can see more at once.
- **Markdown**: covered above — controls whether note bodies are rendered as Markdown.
- **Relative Time**: when on, timestamps show as "5 minutes ago"; when off, they show absolute dates.
- **Sort by Modified Date**: controls whether notes are sorted by last-modified or by created time.

---

## 11. Security and Privacy Settings

Go to Settings → Security for all the privacy switches.

**Biometric**

Turn on to unlock CarroNote with your fingerprint or face (it verifies your biometric once before enabling).

**Logout on inactivity**

When on, CarroNote auto-locks after a period of no activity, from 30 seconds up to 15 minutes.

**Secure display (anti-screenshot)**

When on, the system treats CarroNote's screen as "secure", blocking background snapshots and screenshots.

**Incognito keyboard**

When on, your keyboard won't learn or record what you type in CarroNote, reducing the risk of sensitive info leaking to the keyboard.

**Change passphrase**

Change your master passphrase here (you'll need your current one first).

---

## 12. Language and More

**Switch language**

Settings → General → Language. CarroNote supports Simplified Chinese, English, and more.

**About**

Settings → General → About — version info, open-source license, feedback, and more.

---

## 13. FAQ

**1. I forgot my passphrase. What now?**

It can't be recovered. The only option is "Reset Local Data" on the login screen (an encrypted snapshot is saved automatically before reset, so if you remember the passphrase later you may be able to recover it manually).

**2. Is sync safe? Can anyone see my notes?**

Yes, it's safe. Notes are encrypted before they leave your device; any sync server only ever sees ciphertext, never plaintext.

**3. I got a new phone. How do I move my notes over?**

Use "Export Backup" to save your notes to a file, then "Import Backup" on the new phone — or simply configure the same sync backend and let it pull automatically.

**4. Why don't images in my Markdown notes show up?**

For privacy reasons, CarroNote doesn't auto-load images (to avoid leaking your network location and other info). This is intentional by design.

**5. Can I get back a note I deleted?**

Regular deletion goes to the trash and can be restored. Only "Permanently Delete" or "Clear All" truly removes a note for good.

---

*CarroNote · your words kept safe*
