// Integration events → island state. Port of the `handle…` methods in the Swift
// pollers: a genuinely new item flips the pill to finished/error, badges it when
// the pill isn't focused, plays a sound, and clears itself after 60 s.

import { onEvent, Bridge, type IntegrationUpdate } from "../core/bridge";
import { gitHubAlert, type GitHubEvent } from "../core/github";
import { availablePills } from "../core/pills";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import type { Island } from "./island";

const GITHUB = "integration_github";

const clearTimers = new Map<string, number>();

export function registerIntegrationHandlers(island: Island) {
  void onEvent<IntegrationUpdate>("integration", (update) => handle(island, update));
  void onEvent<GitHubEvent[]>("github-alerts", handleGitHubAlerts);
  void refreshConfigured();
  State.subscribe(refreshGitHubWhenShown);
}

/**
 * AppState.handleGitHubEvents: the loudest event sets the badge — only while the
 * GitHub pill isn't the one on screen — and plays its sound. Unlike the other
 * integrations it leaves Mochi's state alone and the badge stays until the pill
 * is focused, as on macOS.
 */
export function handleGitHubAlerts(events: GitHubEvent[]) {
  if (State.paused) return;
  const alert = gitHubAlert(events);
  if (!alert) return;
  const task = State.tasks.find((t) => t.id === GITHUB);
  if (!task) return;
  if (State.focusId !== GITHUB) task.pillBadge = alert.badge;
  Sound.play(alert.sound);
  State.notify();
}

let gitHubShown = false;

/** The GitHub card just came on screen (focused, island opened): refresh it if stale. */
function refreshGitHubWhenShown() {
  const shown = State.mode === "expanded" && State.focusTask?.id === GITHUB;
  if (shown && !gitHubShown) void Bridge.githubRefresh("pulse");
  gitHubShown = shown;
}

/**
 * Whether each pill is connected, so its idle card can say so: a key in the
 * credential store for a service or a chat provider, the hooks in place for a
 * pill fed by hook events (Mac #183), nothing at all for Claude Desktop.
 */
export async function refreshConfigured() {
  const hooks = (await Bridge.agentHooksStatus()) ?? null;
  for (const def of availablePills(State.os)) {
    let configured: boolean;
    switch (def.connect.kind) {
      case "key":
        configured = (await Bridge.secretPresent(def.connect.key)) ?? false;
        break;
      case "hooks":
        // Without an answer from Rust (a plain browser), the Claude Code pill
        // falls back to what the settings say about its hooks.
        configured = hooks?.[def.id] ??
          (def.id === "integration_claude" ? State.settings.hooksInstalled : false);
        break;
      case "server":
        // A local model server counts once the chat is connected to it.
        configured = State.settings[def.connect.field] !== "";
        break;
      case "none":
        configured = true;
        break;
    }
    const info = State.integrations[def.id] ?? { data: {}, error: null, loaded: false, configured: false };
    State.integrations[def.id] = { ...info, configured };
  }
  State.notify();
}

/** Only the hook-driven pills, for when the island opens: a few small file reads. */
export async function refreshHookPills() {
  const hooks = await Bridge.agentHooksStatus();
  if (!hooks) return;
  for (const [id, present] of Object.entries(hooks)) {
    const info = State.integrations[id] ?? { data: {}, error: null, loaded: false, configured: false };
    State.integrations[id] = { ...info, configured: present };
  }
  State.notify();
}

function handle(island: Island, update: IntegrationUpdate) {
  if (State.paused) return;

  const previous = State.integrations[update.id];
  State.integrations[update.id] = {
    data: update.error ? (previous?.data ?? {}) : update.data,
    error: update.error,
    loaded: update.error ? (previous?.loaded ?? false) : true,
    // Google is connected and disconnected from the settings window, which the
    // key check at boot doesn't see: the poller's own answer says which it is
    // (events, or an error such as an expired sign-in, versus the `{}` that
    // disconnecting sends).
    configured:
      update.id === "integration_gcal"
        ? update.error != null || Array.isArray(update.data.events)
        : (previous?.configured ?? true),
  };

  const event = update.event;
  if (event) {
    const task = State.tasks.find((t) => t.id === update.id);
    if (task) {
      // Something waiting on you (a review asked of you, a meeting about to
      // start) reads as a question with the amber badge, not as done or broken.
      const attention = event.attention === true;
      task.state = attention ? "question" : event.success ? "finished" : "error";
      task.steps = event.detail ? [event.label, event.detail] : [event.label];
      task.stepIndex = task.steps.length - 1;
      if (State.focusId !== update.id) {
        task.pillBadge = attention ? "approval" : event.success ? "finished" : "error";
      }

      if (event.item && update.id === "integration_gcal") {
        // A reminder is a message, not a badge: open a card that says what,
        // when and where, with Join / Open. Unless you are in the middle of
        // something — the chat, an approval, a file drop — then it waits as
        // the amber badge on the Calendar pill.
        Sound.play("approval");
        const busy: string[] = ["prompt", "approval", "question", "upload", "uploading", "choose", "mail"];
        if (State.mode === "expanded" && busy.includes(State.view)) {
          island.reveal();
        } else {
          State.reminder = event.item;
          State.setFocus(update.id);
          if (State.mode === "expanded") island.setView("reminder");
          else island.alert("reminder");
        }
      } else {
        Sound.play(attention ? "question" : event.success ? "finish" : "error");
        // Same as the Swift pollers: show the compact island so the badge is seen,
        // but never steal the screen for a successful deploy.
        island.reveal();
      }

      const existing = clearTimers.get(update.id);
      if (existing != null) window.clearTimeout(existing);
      clearTimers.set(
        update.id,
        window.setTimeout(() => {
          clearTimers.delete(update.id);
          const t = State.tasks.find((x) => x.id === update.id);
          if (!t || (t.state !== "finished" && t.state !== "error" && t.state !== "question")) return;
          t.state = "idle";
          t.steps = [];
          t.stepIndex = 0;
          t.pillBadge = null;
          State.notify();
        }, 60_000),
      );
    }
  }

  State.notify();
}
