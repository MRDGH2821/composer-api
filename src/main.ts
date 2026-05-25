import { hydrateIcons, icon, wireCopyButtons } from "./ui";
import { renderMarkdown } from "./markdown";

const origin = window.location.origin;
const baseUrl = `${origin}/v1`;

/* ---------------------------------------------------------------- routing */

const isChatRoute = (): boolean => window.location.pathname.replace(/\/+$/, "") === "/chat";

async function route(): Promise<void> {
  const landing = document.getElementById("landing");
  const chatRoot = document.getElementById("chat-root");
  if (!landing || !chatRoot) return;
  mountEarlyAccessBar();

  if (isChatRoute()) {
    landing.hidden = true;
    chatRoot.hidden = false;
    document.title = "Cursor Chat — API for Cursor";
    const { mountChat } = await import("./chat");
    mountChat(chatRoot);
  } else {
    chatRoot.hidden = true;
    landing.hidden = false;
    document.title = "API for Cursor";
    mountLanding();
  }
}

// Intercept same-origin links so navigation between `/` and `/chat` is instant.
document.addEventListener("click", (event) => {
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey) return;
  const anchor = (event.target as HTMLElement | null)?.closest("a");
  if (!anchor) return;
  const href = anchor.getAttribute("href") || "";
  if (href !== "/" && href !== "/chat") return;
  if (anchor.target === "_blank") return;
  event.preventDefault();
  if (window.location.pathname !== href) {
    window.history.pushState({}, "", href);
    void route();
  }
});

window.addEventListener("popstate", () => void route());

/* ----------------------------------------------------------- landing page */

let landingReady = false;
let docsReady = false;

function mountLanding(): void {
  hydrateIcons(document.getElementById("landing") ?? document);
  if (landingReady) return;
  landingReady = true;

  void renderDocs();
  void loadStars();
}

async function renderDocs(): Promise<void> {
  if (docsReady) return;
  const content = document.getElementById("docs-content");
  const nav = document.getElementById("docs-nav");
  if (!content || !nav) return;
  docsReady = true;

  try {
    const response = await fetch("/setup.md");
    if (!response.ok) throw new Error(`setup.md returned ${response.status}`);
    const markdown = (await response.text()).replaceAll("{{BASE_URL}}", baseUrl);
    const rendered = renderMarkdown(markdown, { copyButtons: true });
    content.innerHTML = rendered.html;
    trimDocsPreamble(content);
    wrapDocsSections(content);
    nav.innerHTML = rendered.headings
      .filter((heading) => heading.level === 2)
      .map((heading) => `<a href="#${heading.id}">${heading.text}</a>`)
      .join("");
    wireCopyButtons(content);
    wireCodeTabs(content);
  } catch {
    content.innerHTML = "<p>Setup docs could not be loaded. Open the Markdown version directly.</p>";
    nav.innerHTML = "";
  }
}

function trimDocsPreamble(content: HTMLElement): void {
  for (const node of Array.from(content.childNodes)) {
    if (node instanceof HTMLHeadingElement && node.tagName === "H2") return;
    node.remove();
  }
}

function wireCodeTabs(root: HTMLElement): void {
  for (const group of root.querySelectorAll<HTMLElement>("[data-code-tabs]")) {
    const tabs = [...group.querySelectorAll<HTMLButtonElement>("[data-code-tab]")];
    const panels = [...group.querySelectorAll<HTMLElement>("[data-code-panel]")];
    for (const tab of tabs) {
      tab.addEventListener("click", () => {
        const index = tab.dataset.codeTab || "0";
        for (const item of tabs) {
          const active = item === tab;
          item.classList.toggle("is-active", active);
          item.setAttribute("aria-selected", active ? "true" : "false");
        }
        for (const panel of panels) {
          const active = panel.dataset.codePanel === index;
          panel.hidden = !active;
          panel.classList.toggle("is-active", active);
        }
      });
    }
  }
}

function wrapDocsSections(content: HTMLElement): void {
  const nodes = Array.from(content.childNodes);
  let section: HTMLElement | null = null;
  for (const node of nodes) {
    if (node instanceof HTMLHeadingElement && node.tagName === "H2") {
      section = document.createElement("section");
      section.className = "doc-section";
      content.insertBefore(section, node);
      const logo = docsLogoForHeading(node.textContent?.trim() || "");
      if (logo) {
        section.dataset.brand = logo.key;
        const lockup = document.createElement("span");
        lockup.className = `doc-brand-lockup doc-brand-${logo.key}`;
        lockup.innerHTML = `<img src="${logo.src}" alt="${logo.alt}" loading="lazy" />`;
        section.appendChild(lockup);
      }
      section.appendChild(node);
      continue;
    }
    if (section) section.appendChild(node);
  }
}

function docsLogoForHeading(text: string): { key: string; src: string; alt: string } | null {
  if (text === "Vercel AI SDK") return { key: "vercel", src: "/vercel-logotype.svg", alt: "Vercel" };
  if (text === "OpenAI SDK") return { key: "openai", src: "/openai-logo.svg", alt: "OpenAI" };
  return null;
}

/* ----------------------------------------------------- GitHub star count */

function formatStars(count: number): string {
  if (count >= 1000) {
    const thousands = count / 1000;
    return `${thousands.toFixed(thousands >= 10 ? 0 : 1).replace(/\.0$/, "")}k`;
  }
  return String(count);
}

async function loadStars(): Promise<void> {
  const starValue = document.getElementById("star-value");
  if (!starValue) return;
  try {
    const response = await fetch("https://api.github.com/repos/standardagents/composer-api", {
      headers: { Accept: "application/vnd.github+json" }
    });
    if (!response.ok) throw new Error(`GitHub responded ${response.status}`);
    const data = (await response.json()) as { stargazers_count?: number };
    if (typeof data.stargazers_count !== "number") throw new Error("Missing star count");
    starValue.textContent = formatStars(data.stargazers_count);
  } catch {
    starValue.textContent = "Star";
  }
}

/* --------------------------------------------- Standard Agents CTA bar */

let earlyAccessReady = false;

function mountEarlyAccessBar(): void {
  if (earlyAccessReady) return;
  earlyAccessReady = true;

  const bar = document.createElement("aside");
  bar.id = "sa-bar";
  bar.className = "sa-bar";
  bar.setAttribute("aria-label", "Standard Agents early access");
  bar.innerHTML = `
    <div class="sa-bar-inner">
      <div class="sa-bar-pitch">
        <img class="sa-bar-mark" src="/standard-agents-logo.svg" alt="Standard Agents" />
        <p>We're building better agent infrastructure. Get early access</p>
      </div>
      <form id="sa-bar-form" class="sa-bar-form" novalidate>
        <input id="sa-bar-name" name="name" type="text" placeholder="Name" autocomplete="name" required />
        <input id="sa-bar-email" name="email" type="email" placeholder="Email" autocomplete="email" required />
        <button id="sa-bar-submit" class="sa-bar-submit" type="submit">
          <span class="sa-bar-submit-label">Request access</span>
          ${icon("ArrowRight", { width: 16, height: 16, class: "sa-bar-arrow" })}
          ${icon("Loader2", { width: 16, height: 16, class: "sa-bar-spinner spin" })}
        </button>
      </form>
      <p id="sa-bar-status" class="sa-bar-status" role="status"></p>
    </div>`;
  document.body.appendChild(bar);
  bindEarlyAccessForm(bar);
}

function bindEarlyAccessForm(bar: HTMLElement): void {
  const form = bar.querySelector<HTMLFormElement>("#sa-bar-form");
  const submit = bar.querySelector<HTMLButtonElement>("#sa-bar-submit");
  const status = bar.querySelector<HTMLElement>("#sa-bar-status");
  const nameInput = bar.querySelector<HTMLInputElement>("#sa-bar-name");
  const emailInput = bar.querySelector<HTMLInputElement>("#sa-bar-email");
  const label = submit?.querySelector<HTMLElement>(".sa-bar-submit-label");
  const arrow = submit?.querySelector<SVGElement>(".sa-bar-arrow");
  const spinner = submit?.querySelector<SVGElement>(".sa-bar-spinner");
  if (!form) return;

  const setStatus = (text: string, tone?: "ok" | "err"): void => {
    if (!status) return;
    status.textContent = text;
    if (tone) status.dataset.tone = tone;
    else delete status.dataset.tone;
  };

  const setBusy = (busy: boolean): void => {
    if (submit) submit.disabled = busy;
    if (label) label.style.display = busy ? "none" : "";
    if (arrow) arrow.style.display = busy ? "none" : "";
    if (spinner) spinner.style.display = busy ? "" : "none";
  };
  setBusy(false);

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const name = nameInput?.value.trim() || "";
    const email = emailInput?.value.trim() || "";
    if (!name || !email) {
      setStatus("Add your name and email first.", "err");
      return;
    }
    setBusy(true);
    setStatus("");
    try {
      const response = await fetch("/api/early-access", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, email })
      });
      const data = (await response.json().catch(() => ({}))) as { ok?: boolean; error?: { message?: string } | string };
      if (!response.ok || !data.ok) {
        const message = typeof data.error === "string" ? data.error : data.error?.message;
        throw new Error(message || "Could not submit right now.");
      }
      bar.classList.add("sa-bar--done");
      setStatus("You're on the list — we'll be in touch.", "ok");
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Something went wrong.", "err");
      setBusy(false);
    }
  });
}

void route();
