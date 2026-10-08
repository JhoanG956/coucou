// Dev harness: the overview with fake GitHub and Google Calendar data, so the
// cards can be checked (and screenshotted) without tokens or a live session.
// Not part of the app bundle.

import "../src/style.css";
import { State } from "../src/core/state";
import { h } from "../src/views/dom";
import { buildViews, type ViewActions } from "../src/views/views";
import { tickMiniBots } from "../src/mochi/minibots";

const noop = () => {};
const actions: ViewActions = {
  setView: noop, cancelDrop: noop, collapse: noop, foldApproval: noop, setFocus: (id) => State.setFocus(id),
  openTerminal: noop, openTarget: noop, openUrl: noop, decide: noop, answer: noop, answerInTerminal: noop,
  toggleSound: noop, setVolume: noop, setAutoClose: noop, openSettingsWindow: noop, blip: noop,
  chooseOutfit: noop, previewOutfit: noop,
};

State.settings.activeIntegrations = ["integration_github", "integration_gcal", "integration_vercel"];
State.loadIntegrationTasks();

const views = buildViews(actions, noop);
const overview = views.get("overview")!;
const reminderView = views.get("reminder")!;
overview.el.classList.add("on");
const viewsEl = h("div", { id: "views" }, overview.el, reminderView.el);
document.getElementById("stage")!.append(viewsEl);

/** Which of the two views the stage shows. */
function show(which: "overview" | "reminder") {
  overview.el.classList.toggle("on", which === "overview");
  reminderView.el.classList.toggle("on", which === "reminder");
}

const min = 60_000;
const now = Date.now();
const at = (offsetMin: number, lengthMin = 30) => ({
  startMs: now + offsetMin * min,
  endMs: now + (offsetMin + lengthMin) * min,
  start: new Date(now + offsetMin * min).toISOString(),
});

const loaded = (data: Record<string, unknown>, error: string | null = null) => ({
  data, error, loaded: true, configured: true,
});

const pr = (repo: string, number: number, title: string, ci: string, review = "unknown", isDraft = false) => ({
  id: `${repo}#${number}`, title, url: `https://github.com/${repo}/pull/${number}`, repo, number,
  isDraft, ci, review, headSha: null, headRef: null,
});
const main = (repo: string, ci: string) => ({
  repo, url: `https://github.com/${repo}`, branch: "main", ci, headSha: null,
});
const branch = (name: string, ci: string, failing: string[] = [], pushed = true) => ({
  repo: "Louis-CFM/coucou", branch: name, pushed, oid: "abc", ci, failing, url: "", prId: null,
});
const github = (pulse: Record<string, unknown>) => ({
  totalRepos: 14, totalStars: 37,
  pulse: {
    login: "jhoan", fetchedAt: Date.now(),
    myPRs: [pr("Louis-CFM/coucou", 8, "Windows: GitHub CI and Calendar", "failure")],
    toReview: [pr("Louis-CFM/coucou", 9, "Mac: approval view polish", "unknown", "pending")],
    mainCI: [main("Louis-CFM/coucou", "success"), main("jhoan/dotfiles", "success")],
    ...pulse,
  },
});

const scenarios: Record<string, () => void> = {
  "GitHub · CI failing": () => {
    State.integrations.integration_github = loaded(github({ branch: branch("feat/windows-github-ci-calendar", "failure", ["build-windows"]) }));
    State.setFocus("integration_github");
  },
  "GitHub · running": () => {
    State.integrations.integration_github = loaded(github({ branch: branch("fix/windows-wake-strip", "pending") }));
    State.setFocus("integration_github");
  },
  "GitHub · not pushed": () => {
    State.integrations.integration_github = loaded(github({ branch: branch("feat/new-thing", "unknown", [], false) }));
    State.setFocus("integration_github");
  },
  "GitHub · no session": () => {
    State.integrations.integration_github = loaded(github({ branch: null }));
    State.setFocus("integration_github");
  },
  "Calendar · meeting in 4 min": () => {
    State.integrations.integration_gcal = loaded({
      events: [
        { id: "a", title: "Daily standup", ...at(4, 15), allDay: false, meetUrl: "https://meet.google.com/x", url: "" },
        { id: "b", title: "1:1 with Louis", ...at(95), allDay: false, meetUrl: null, url: "" },
        { id: "c", title: "Release Coucou 0.2", ...at(60 * 24 * 2), allDay: false, meetUrl: null, url: "" },
        { id: "d", title: "Holiday", start: "2026-10-12", startMs: null, endMs: null, allDay: true, url: "" },
      ],
    });
    State.setFocus("integration_gcal");
  },
  "Calendar · in a meeting": () => {
    State.integrations.integration_gcal = loaded({
      events: [
        { id: "a", title: "Design review — notch island", ...at(-10, 45), allDay: false, meetUrl: "https://meet.google.com/x", url: "" },
        { id: "b", title: "Lunch", ...at(50, 60), allDay: false, meetUrl: null, url: "" },
      ],
    });
    State.setFocus("integration_gcal");
  },
  "Calendar · empty": () => {
    State.integrations.integration_gcal = loaded({ events: [] });
    State.setFocus("integration_gcal");
  },
  "Calendar · not connected": () => {
    State.integrations.integration_gcal = { data: {}, error: null, loaded: true, configured: false };
    State.setFocus("integration_gcal");
  },
  "Calendar · sign-in expired": () => {
    State.integrations.integration_gcal = { data: {}, error: "Google sign-in expired — reconnect in Settings", loaded: false, configured: true };
    State.setFocus("integration_gcal");
  },
  "Reminder · casino, 30 min": () => {
    State.reminder = {
      id: "poker", title: "THE ONE BOUNTY", ...at(30, 240), allDay: false, meetUrl: null, url: "https://calendar.google.com",
      color: "#9fe1e7", calendar: "casino Zaragoza",
      location: "Casino Zaragoza, C/ Marqués de Casa Jiménez, 11, Zaragoza, 50004, Spain",
    };
    show("reminder");
  },
  "Reminder · video call, 2 min": () => {
    State.reminder = {
      id: "standup", title: "Daily standup with a much longer title than fits", ...at(2, 15), allDay: false,
      meetUrl: "https://meet.google.com/x", url: "https://calendar.google.com", color: "#16a765", calendar: "jhoang956@gmail.com",
      location: null,
    };
    show("reminder");
  },
  "Badges: review asked + meeting": () => {
    State.setFocus("integration_vercel");
    State.setPillBadge("integration_github", "approval");
    State.setPillBadge("integration_gcal", "approval");
  },
};

const controls = document.getElementById("controls")!;
const caption = document.getElementById("caption")!;
for (const [name, run] of Object.entries(scenarios)) {
  controls.append(h("button", {
    text: name,
    onclick: () => {
      for (const t of State.tasks) t.pillBadge = null;
      show("overview");
      run();
      caption.textContent = name;
      State.notify();
    },
  }));
}

State.subscribe(() => {
  overview.sync();
  reminderView.sync();
});
scenarios["GitHub · CI failing"]();
caption.textContent = "GitHub · CI failing";
State.notify();

let last = performance.now();
function loop(t: number) {
  tickMiniBots((t - last) / 1000);
  last = t;
  requestAnimationFrame(loop);
}
requestAnimationFrame(loop);
