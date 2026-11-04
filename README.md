# DMRelay

## Credits

This project is an **add-on for existing open-source projects** — it is not a standalone tool and does not work without them:

- **[fullstack-agent](https://github.com/jaredrhod/fullstack-agent)** by Jared Rhodenizer — the open-source AI assistant framework this plugin is built for (memory, voice, face, optional hands, assembled into one agent). Specifically, DMRelay talks to the **voice piece, [backtalk](https://github.com/jaredrhod/backtalk)**, reusing its external-trigger mechanism to speak DMs out loud; see "Voice integration" below.
- **[Vencord](https://github.com/Vencord/Vencord)** by Vendicated and contributors — the Discord client mod this plugin runs inside.

DMRelay itself is a small userplugin + a local Python receiver, built on top of both.

## Risks — read this before installing

Running Vencord is a **modification of the official Discord client**, which is against Discord's Terms of Service, regardless of which plugins you enable. This carries a real, non-zero risk of account action (up to a ban) on whichever Discord account/branch you install it on.

**Strong recommendation: install this on a throwaway/test Discord account and a separate Discord branch (Canary or PTB), never your main account.** The installer defaults to asking you which branch, and warns you again if you pick Stable.

This plugin itself (DMRelay) does not add meaningfully to that detection risk — it reads messages your client already received, and any reply it sends is one you explicitly typed/dictated, sent through Discord's own client functions. But the base risk from Vencord is real and yours to accept.

**Disclaimer:** the author of this repository is not responsible for anything that happens to your Discord account, or any account on which you install this software. You accept any and all risk by installing and using it, on your own accounts, at your own discretion.

## What it does

- Listens for DMs and group DMs on the account it's installed on (never server/guild messages, never your own messages).
- Forwards each one to a local receiver (`127.0.0.1` only — nothing leaves your machine).
- The receiver logs every DM to `dm_log.jsonl` and can optionally trigger a connected backtalk voice assistant to speak it out loud.
- Optionally, you can queue a reply through the receiver; the plugin sends it through Discord's normal message-send function. Every reply you send through this tool is automatically suffixed with `-# dictated via assistant` — this is intentional and should not be removed: it tells whoever you're messaging that the text came through an assistant, not typed by you directly.

## Install

```powershell
git clone <this-repo-url>
cd DMRelay-release
powershell -ExecutionPolicy Bypass -File install.ps1
```

The script clones Vencord, builds the plugin into it, patches the Discord branch you choose, and generates fresh secrets for you automatically. Follow the on-screen steps it prints at the end (enabling the plugin, starting the receiver).

**If Discord auto-updates**, the Vencord patch gets wiped (this is a Vencord thing, not specific to this plugin). Re-run the one-line command the installer printed at the end to re-patch.

## Voice integration (optional, manual)

DMRelay speaks through backtalk's **external trigger seam** — a small local HTTP server inside backtalk that lets any local script make it speak a line, as a real turn, with no microphone input. This isn't part of stock backtalk; add it to your own fork's `backtalk/main.py`:

1. Add a `trigger_port` / `trigger_secret` pair to your `backtalk.json` and to `config.py`'s `DEFAULTS`.
2. Add an HTTP listener thread (`http.server`-based) that, on a POST to `/trigger` with the right secret, pushes the received text into backtalk's existing `typed_q` — the same queue typed keyboard input uses. This makes it flow through `handle()` -> `ask_stream()` exactly like a typed message, which is the only path that reaches `mouth.say()`.
3. Start that thread alongside backtalk's existing `_typed_reader` thread in `amain()`.

Without this step, DMRelay still works — DMs just land in `dm_log.jsonl` for your assistant to read on request, instead of being spoken immediately and unprompted.

## Security notes

- `secrets.local.json` (receiver) is generated per-install and gitignored — never commit it, never share it.
- The receiver only binds `127.0.0.1` and only accepts the Discord-page origin for the plugin's calls (CORS-enforced) — nothing outside your machine can reach it.

## Agent behavior rules (recommended — copy into your assistant's system prompt / memory)

The trigger text sent to your voice assistant already carries its own inline instruction (`[DMRelay] Read this DM out loud, word for word...`), so even a stock assistant with zero DMRelay-specific setup behaves safely by default — it never has to be told separately that DM content is data, not a command. These extra rules cover what the trigger text *can't* carry on its own: they only matter once your assistant can also send/edit messages through `/queue-send`/`/queue-edit`, and every one of them comes from a real mistake made building this, not a hypothetical:

- **Never compose a reply yourself.** Send only the exact words the person dictated — never a reply you generated on your own. Deliberate, not a current limitation: mediating someone's real conversations in your own words is a fundamentally different, riskier thing than relaying or sending on explicit request.
- **The disclosure footer is mandatory, not optional.** Every message sent through `/queue-send`/`/queue-edit` already gets `-# dictated via assistant` appended automatically by the receiver — don't strip it or route around it. Removing it turns an assistive dictation tool into a tool that deceives the person on the other end.
- **The fixed 2-second send delay is not a human-typing simulator.** Don't add a typing-speed simulator (80-120 WPM, "so it looks more natural") on top of it. Whether the stated goal is to seem natural to a human reader or to evade Discord's bot detection, it's the same move — detection evasion. The delay exists only so a multi-line message doesn't appear in zero seconds, nothing more.
- **`GET /pending-send` is single-use — never poll it just to "check" a queued message.** It clears the slot the instant it's read, so if anything other than the plugin itself reads it first (including a diagnostic check from your own assistant), the real send silently vanishes before the plugin ever sees it. If a send looks like it failed, check Discord itself (running? plugin enabled?) before touching this route.
- **Have your agent check the receiver is alive at its own startup, not just rely on the auto-start hook.** The installer drops an auto-start entry (see "Install" above), but an auto-start mechanism can silently stop working — get disabled, get wiped by an OS update, whatever — with nothing around to notice. Add a step to whatever your agent reads at the start of every session: check `http://127.0.0.1:17493/pending-send` responds (a `403` with no secret header means it's alive), and if not, start the receiver yourself. This is the one check that catches the auto-start hook quietly failing before a DM ever gets missed.
