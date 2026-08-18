import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { execFileSync } from "node:child_process";

const archiveDir = path.resolve(process.argv[2] ?? "PreviousWeeks");
const monthNumbers = new Map([
  ["Jan", 0], ["Feb", 1], ["Mar", 2], ["Apr", 3], ["May", 4], ["Jun", 5],
  ["Jul", 6], ["Aug", 7], ["Sep", 8], ["Oct", 9], ["Nov", 10], ["Dec", 11],
]);
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function archiveWindow(filename) {
  const match = filename.match(/^([A-Z][a-z]{2})(\d{2})_(\d{4})\.qmd$/);
  if (!match || !monthNumbers.has(match[1])) return null;
  const end = new Date(Date.UTC(Number(match[3]), monthNumbers.get(match[1]), Number(match[2])));
  const start = new Date(end.getTime() - 7 * 86_400_000);
  return { start: start.toISOString().slice(0, 10), end: end.toISOString().slice(0, 10) };
}

function normalizedFrontmatter(markdown, window) {
  const start = new Date(`${window.start}T00:00:00Z`);
  const title = `${start.toLocaleString("en-US", { timeZone: "UTC", month: "short" })} ${start.getUTCDate()} ${String(start.getUTCFullYear()).slice(-2)}`;
  let output = markdown.replace(/^title:\s*["']?.*?["']?\s*$/m, `title: "${title}"`);
  if (/^edition_id:/m.test(output)) {
    output = output.replace(/^edition_id:\s*.*$/m, `edition_id: "${window.start}"`);
  } else {
    output = output.replace(/^(title:.*)$/m, `$1\nedition_id: "${window.start}"`);
  }
  if (/^window_end_date:/m.test(output)) {
    output = output.replace(/^window_end_date:\s*.*$/m, `window_end_date: "${window.end}"`);
  } else {
    output = output.replace(/^(edition_id:.*)$/m, `$1\nwindow_end_date: "${window.end}"`);
  }
  return output;
}

function cleanUrl(value) {
  return String(value ?? "").trim().replace(/^</, "").replace(/>$/, "");
}

function stripMarkup(value) {
  return String(value ?? "")
    .replace(/<[^>]+>/g, " ")
    .replace(/\\([*_`[\]])/g, "$1")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

function papersFromMarkdown(markdown) {
  const papers = [];
  const lines = markdown.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index].trim();
    const linked = line.match(/^####\s+\[(.*)\]\((.*)\)\s*$/);
    const split = line.match(/^####\s+\[(.*)\]\s*$/) ?? line.match(/^####\s+\[(.*)\s*$/);
    if (linked) {
      papers.push({ title: stripMarkup(linked[1]), link: cleanUrl(linked[2]) });
    } else if (split) {
      const continuation = String(lines[index + 1] ?? "").trim().match(/^\]?\((.*)\)\s*$/);
      if (continuation) {
        papers.push({ title: stripMarkup(split[1]), link: cleanUrl(continuation[1]) });
        index += 1;
      }
    }
  }
  return papers;
}

async function loadHistoricalDates() {
  const dates = new Map();
  let records = [];
  try {
    records = (await readFile("TrainingData/historical_decisions.jsonl", "utf8"))
      .split(/\r?\n/).filter(Boolean).map(JSON.parse);
  } catch {
    return dates;
  }
  for (const commit of new Set(records.map((record) => record.candidate_commit).filter(Boolean))) {
    try {
      const papers = JSON.parse(execFileSync("git", ["show", `${commit}:papers.json`], { encoding: "utf8" }));
      for (const paper of papers) {
        const date = normalizedDate(paper.date);
        if (!date) continue;
        dates.set(cleanUrl(paper.link), date);
        dates.set(stripMarkup(paper.title), date);
      }
    } catch {
      // Not every historical commit retained a candidate snapshot.
    }
  }
  return dates;
}

function sourceFromUrl(link) {
  try {
    const host = new URL(link).hostname.replace(/^www\./, "");
    if (host === "arxiv.org") return "arXiv";
    if (host === "biorxiv.org") return "bioRxiv";
    if (host === "medrxiv.org") return "medRxiv";
    return host;
  } catch {
    return "";
  }
}

function normalizedDate(value) {
  const raw = String(value ?? "").trim();
  const numeric = raw.match(/\b(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})\b/);
  if (numeric) {
    const candidate = `${numeric[1]}-${numeric[2].padStart(2, "0")}-${numeric[3].padStart(2, "0")}`;
    const timestamp = Date.parse(`${candidate}T00:00:00Z`);
    if (Number.isFinite(timestamp) && new Date(timestamp).toISOString().slice(0, 10) === candidate) return candidate;
  }
  const timestamp = Date.parse(raw);
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString().slice(0, 10) : null;
}

function preferredDate(values, window) {
  const dates = [...new Set(values.map(normalizedDate).filter(Boolean))];
  return dates.find((date) => window.start <= date && date <= window.end)
    ?? dates.filter((date) => date <= window.end).sort().at(-1)
    ?? dates.sort()[0]
    ?? null;
}

function preprintDoiDate(link) {
  if (!/(?:bio|med)rxiv\.org|doi\.org\/10\.(?:1101|64898)\//i.test(link)) return null;
  const match = link.match(/\/(20\d{2})\.(\d{2})\.(\d{2})(?:\.|v|$)/);
  return match ? `${match[1]}-${match[2]}-${match[3]}` : null;
}

function arxivId(link) {
  const match = link.match(/arxiv\.org\/(?:abs|pdf)\/([^/?#]+)/i);
  return match ? match[1].replace(/\.pdf$/i, "").replace(/v\d+$/i, "") : null;
}

function decodeXml(value) {
  return String(value ?? "")
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"');
}

async function fetchWithRetries(url, options = {}) {
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      const response = await fetch(url, {
        redirect: "follow",
        signal: AbortSignal.timeout(20_000),
        headers: { "User-Agent": "BiophysicsWeeklyArchive/1.0 (bezia.lemma@gmail.com)", ...(options.headers ?? {}) },
      });
      if (response.ok) return response;
      lastError = new Error(`HTTP ${response.status}`);
      if (response.status < 500 && response.status !== 429) break;
      if (response.status === 429) {
        const retryAfter = Number(response.headers.get("retry-after"));
        await wait(Number.isFinite(retryAfter) ? retryAfter * 1_000 : 2_000 * attempt);
        continue;
      }
    } catch (error) {
      lastError = error;
    }
    await wait(500 * attempt);
  }
  throw lastError ?? new Error("request failed");
}

async function loadArxivDates(papersByEdition) {
  const ids = [...new Set(papersByEdition.flatMap(({ papers }) => papers
    .filter((paper) => !normalizedDate(paper.existing?.date))
    .map((paper) => arxivId(paper.link)).filter(Boolean)))];
  const dates = new Map();
  for (let index = 0; index < ids.length; index += 25) {
    const batch = ids.slice(index, index + 25);
    const url = `https://export.arxiv.org/api/query?id_list=${encodeURIComponent(batch.join(","))}&max_results=${batch.length}`;
    let xml;
    try {
      xml = await (await fetchWithRetries(url)).text();
    } catch (error) {
      console.warn(`arXiv Atom API unavailable (${error.message}); using Semantic Scholar for remaining IDs.`);
      break;
    }
    for (const entry of xml.matchAll(/<entry>([\s\S]*?)<\/entry>/g)) {
      const id = decodeXml(entry[1].match(/<id>https?:\/\/arxiv\.org\/abs\/([^<]+)<\/id>/)?.[1] ?? "").replace(/v\d+$/i, "");
      if (!id) continue;
      dates.set(id, [
        entry[1].match(/<published>([^<]+)<\/published>/)?.[1],
        entry[1].match(/<updated>([^<]+)<\/updated>/)?.[1],
      ].filter(Boolean));
    }
    if (index + 25 < ids.length) await wait(3_100);
  }
  const unresolved = ids.filter((id) => !dates.has(id));
  for (let index = 0; index < unresolved.length; index += 500) {
    const batch = unresolved.slice(index, index + 500);
    try {
      const response = await fetch("https://api.semanticscholar.org/graph/v1/paper/batch?fields=externalIds,publicationDate", {
        method: "POST",
        signal: AbortSignal.timeout(30_000),
        headers: {
          "Content-Type": "application/json",
          "User-Agent": "BiophysicsWeeklyArchive/1.0 (bezia.lemma@gmail.com)",
        },
        body: JSON.stringify({ ids: batch.map((id) => `ARXIV:${id}`) }),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      for (const paper of await response.json()) {
        const id = paper?.externalIds?.ArXiv;
        if (id && paper.publicationDate) dates.set(id.replace(/v\d+$/i, ""), [paper.publicationDate]);
      }
    } catch (error) {
      console.warn(`Semantic Scholar arXiv lookup unavailable (${error.message}); page metadata will be used.`);
    }
  }
  return dates;
}

function metadataDates(html) {
  const values = [];
  for (const tag of html.match(/<meta\b[^>]*>/gi) ?? []) {
    const attributes = Object.fromEntries([...tag.matchAll(/([\w:-]+)\s*=\s*["']([^"']*)["']/g)]
      .map((match) => [match[1].toLowerCase(), match[2]]));
    const key = String(attributes.name ?? attributes.property ?? attributes.itemprop ?? "").toLowerCase();
    if (/(?:citation_(?:publication_)?date|dc\.date|datepublished|article:published_time|prism\.publicationdate)/.test(key)) {
      values.push(attributes.content ?? "");
    }
  }
  for (const match of html.matchAll(/["'](?:datePublished|dateCreated|dateModified)["']\s*:\s*["']([^"']+)["']/gi)) {
    values.push(match[1]);
  }
  return values;
}

function doiFromLinkOrHtml(link, html) {
  const rscCode = link.match(/\/articlelanding\/\d{4}\/[a-z]+\/([a-z0-9-]+)/i)?.[1];
  const candidates = [
    link.match(/doi\.org\/(10\.\d{4,9}\/[^?#]+)/i)?.[1],
    link.match(/\/doi\/(?:abs\/|full\/)?(10\.\d{4,9}\/[^?#]+)/i)?.[1],
    link.match(/nature\.com\/articles\/([^/?#]+)/i)?.[1] ? `10.1038/${link.match(/nature\.com\/articles\/([^/?#]+)/i)[1]}` : null,
    rscCode ? `10.1039/${rscCode}` : null,
    html.match(/(?:citation_doi|dc\.identifier)[^>]+content=["'](?:doi:)?(10\.\d{4,9}\/[^"']+)/i)?.[1],
    html.match(/(?:doi\.org\/|"doi"\s*:\s*")(10\.\d{4,9}\/[^"'<>\s]+)/i)?.[1],
  ].filter(Boolean);
  return candidates[0]?.replace(/[).,;]+$/, "") ?? null;
}

async function crossrefDates(doi) {
  if (!doi) return [];
  try {
    const response = await fetchWithRetries(`https://api.crossref.org/works/${encodeURIComponent(doi)}?mailto=bezia.lemma@gmail.com`);
    const message = (await response.json()).message ?? {};
    return [message["published-online"], message["published-print"], message.published, message.issued, message.created]
      .map((field) => field?.["date-parts"]?.[0]?.join("-"))
      .filter(Boolean);
  } catch {
    return [];
  }
}

async function crossrefDatesByTitle(title) {
  try {
    const url = new URL("https://api.crossref.org/works");
    url.searchParams.set("query.title", title);
    url.searchParams.set("rows", "1");
    url.searchParams.set("mailto", "bezia.lemma@gmail.com");
    url.searchParams.set("select", "title,published-online,published-print,published,issued,created");
    const response = await fetchWithRetries(url);
    const message = (await response.json()).message?.items?.[0] ?? {};
    const returnedTitle = stripMarkup(message.title?.[0] ?? "").toLowerCase();
    const queryTitle = stripMarkup(title).toLowerCase();
    const significant = queryTitle.split(/\W+/).filter((word) => word.length >= 5);
    if (!significant.length || significant.filter((word) => returnedTitle.includes(word)).length < Math.min(3, significant.length)) {
      return [];
    }
    return [message["published-online"], message["published-print"], message.published, message.issued, message.created]
      .map((field) => field?.["date-parts"]?.[0]?.join("-"))
      .filter(Boolean);
  } catch {
    return [];
  }
}

async function resolveJournalDate(paper, window) {
  try {
    const html = await (await fetchWithRetries(paper.link, { headers: { Accept: "text/html,application/xhtml+xml" } })).text();
    const pageDates = metadataDates(html);
    const pageDate = preferredDate(pageDates, window);
    if (pageDate && window.start <= pageDate && pageDate <= window.end) return pageDate;
    const doi = doiFromLinkOrHtml(paper.link, html);
    const crossref = doi ? await crossrefDates(doi) : await crossrefDatesByTitle(paper.title);
    return preferredDate([...pageDates, ...crossref], window);
  } catch {
    const doi = doiFromLinkOrHtml(paper.link, "");
    const crossref = doi ? await crossrefDates(doi) : await crossrefDatesByTitle(paper.title);
    return preferredDate(crossref, window);
  }
}

async function mapWithConcurrency(items, concurrency, mapper) {
  const results = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await mapper(items[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, worker));
  return results;
}

const filenames = (await readdir(archiveDir))
  .filter((name) => /^[A-Z][a-z]{2}\d{2}_\d{4}\.qmd$/.test(name))
  .sort();
const editions = [];
for (const filename of filenames) {
  const qmdPath = path.join(archiveDir, filename);
  const window = archiveWindow(filename);
  const markdown = await readFile(qmdPath, "utf8");
  const normalizedMarkdown = normalizedFrontmatter(markdown, window);
  if (normalizedMarkdown !== markdown) await writeFile(qmdPath, normalizedMarkdown, "utf8");
  const sidecar = path.join(archiveDir, filename.replace(/\.qmd$/, ".papers.json"));
  let existing = [];
  try {
    existing = JSON.parse(await readFile(sidecar, "utf8"));
    if (existing.length && existing.every((paper) => normalizedDate(paper.date))) continue;
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  const existingByLink = new Map(existing.map((paper) => [cleanUrl(paper.link), paper]));
  const existingByTitle = new Map(existing.map((paper) => [stripMarkup(paper.title), paper]));
  editions.push({
    filename,
    sidecar,
    window,
    papers: papersFromMarkdown(normalizedMarkdown).map((paper) => ({
      ...paper,
      existing: existingByLink.get(paper.link) ?? existingByTitle.get(paper.title) ?? null,
    })),
  });
}

const arxivDates = await loadArxivDates(editions);
const historicalDates = await loadHistoricalDates();
for (const edition of editions) {
  let resolved = 0;
  const papers = await mapWithConcurrency(edition.papers, 2, async (paper) => {
    const savedDate = normalizedDate(paper.existing?.date);
    const historicalDate = historicalDates.get(paper.link) ?? historicalDates.get(paper.title);
    const preprintDate = preprintDoiDate(paper.link);
    const id = arxivId(paper.link);
    let date = savedDate
      ?? historicalDate
      ?? preprintDate
      ?? (id ? preferredDate(arxivDates.get(id) ?? [], edition.window) : null)
      ?? await resolveJournalDate(paper, edition.window);
    if (!date) date = preferredDate(await crossrefDatesByTitle(paper.title), edition.window);
    if (date) resolved += 1;
    return {
      title: paper.title,
      link: paper.link,
      source: paper.existing?.source ?? sourceFromUrl(paper.link),
      date,
    };
  });
  await writeFile(edition.sidecar, `${JSON.stringify(papers, null, 2)}\n`, "utf8");
  console.log(`${edition.filename}: resolved ${resolved}/${papers.length} publication dates`);
}
