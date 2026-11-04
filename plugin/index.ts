/*
 * DMRelay — personal userplugin, not part of upstream Vencord.
 * Forwards DM and group-DM messages on this account to a local HTTP
 * receiver (127.0.0.1 only) so they can be read later, e.g. while away
 * from the keyboard. Never touches guild/server messages on purpose.
 *
 * SET YOUR OWN secret below (plugin settings, not this file) before use —
 * do not reuse the example value. See the main README for setup.
 */

import { definePluginSettings } from "@api/Settings";
import { sendMessage } from "@utils/discord";
import { OptionType } from "@utils/types";
import definePlugin from "@utils/types";
import { findLazy } from "@webpack";
import { ChannelStore, UserStore } from "@webpack/common";

const ChannelTypes = findLazy(m => m.DM === 1 && m.GROUP_DM === 3);

const settings = definePluginSettings({
    port: {
        type: OptionType.NUMBER,
        description: "Port of the local receiver",
        default: 17493,
        min: 1,
        max: 65535
    },
    sharedSecret: {
        type: OptionType.STRING,
        description: "Shared secret sent as X-DMRelay-Secret — set your own, matching your receiver's config. Do not leave the example value.",
        default: "CHANGE_ME_generate_your_own_secret"
    }
});

interface RelayMessage {
    message_id: string;
    channel_id: string;
    channel_type: number;
    channel_name: string | null;
    author_id: string;
    author_username: string;
    author_display_name: string;
    content: string;
    attachments: string[];
    timestamp: string;
}

function send(payload: RelayMessage) {
    const port = settings.store.port || 17493;
    fetch(`http://127.0.0.1:${port}/dm`, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            "X-DMRelay-Secret": settings.store.sharedSecret || ""
        },
        body: JSON.stringify(payload)
    }).catch(() => {
        // the local receiver isn't running — drop silently, never break Discord over this
    });
}

let pollTimer: ReturnType<typeof setInterval> | undefined;

async function pollForOutgoing() {
    const port = settings.store.port || 17493;
    try {
        const res = await fetch(`http://127.0.0.1:${port}/pending-send`, {
            headers: { "X-DMRelay-Secret": settings.store.sharedSecret || "" }
        });
        if (!res.ok) return;
        const item = await res.json();
        if (item?.channel_id && item?.content) {
            // A flat, fixed pause — NOT derived from message length or
            // tuned to a words-per-minute rate. The point is only to avoid
            // a multi-line reply appearing in literally zero seconds,
            // which looks odd to whoever's reading it; it is deliberately
            // NOT a human-typing-speed simulator (that would be timing
            // evasion of Discord's own automation detection, which this
            // plugin does not do).
            await new Promise(r => setTimeout(r, 2000));
            // The dictated words only — never AI-composed. Sent exactly
            // as queued, no paraphrasing, no extra text.
            sendMessage(item.channel_id, { content: item.content });
        }
    } catch {
        // receiver isn't running — try again on the next tick
    }
}

export default definePlugin({
    name: "DMRelay",
    description: "Forwards this account's DMs to a local receiver for later reading",
    authors: [{ name: "Jyxen", id: 0n }],

    settings,

    start() {
        pollTimer = setInterval(pollForOutgoing, 2000);
    },

    stop() {
        if (pollTimer) clearInterval(pollTimer);
    },

    flux: {
        MESSAGE_CREATE({ message, optimistic }: { message: any; optimistic: boolean; }) {
            if (optimistic) return;

            const me = UserStore.getCurrentUser();
            if (!me || message.author?.id === me.id) return;

            const channel = ChannelStore.getChannel(message.channel_id);
            if (!channel) return;
            if (channel.type !== ChannelTypes.DM && channel.type !== ChannelTypes.GROUP_DM) return;

            const attachments: string[] = Array.isArray(message.attachments)
                ? message.attachments.map((a: any) => a?.url).filter(Boolean)
                : [];

            // Discord's display name (globalName), not the @username handle.
            const authorUser = UserStore.getUser(message.author?.id);
            const displayName = authorUser?.globalName
                || message.author?.global_name
                || message.author?.username
                || "";

            send({
                message_id: message.id,
                channel_id: message.channel_id,
                channel_type: channel.type,
                channel_name: channel.name || null,
                author_id: message.author?.id ?? "",
                author_username: message.author?.username ?? "",
                author_display_name: displayName,
                content: message.content ?? "",
                attachments,
                timestamp: message.timestamp ?? new Date().toISOString()
            });
        }
    }
});
