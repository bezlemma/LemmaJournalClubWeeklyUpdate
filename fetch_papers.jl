using HTTP, JSON3, EzXML
using Gumbo: parsehtml, text
using Cascadia: Selector, getattr
using Dates, TimeZones
import Gumbo
import Cascadia

# ─── Configuration ───────────────────────────────────────────────────────────

const DAYS_BACK = 6
const OLDEST_DATE = now(tz"UTC") - Day(DAYS_BACK)

const ARXIV_CATEGORIES = ["physics.bio-ph", "cond-mat.soft"]
const BIORXIV_COLLECTION = "biophysics"

# Journal Feed Configuration
# group: :include_all / :section_filter / :green_filter
const JOURNAL_FEEDS = [
    (url="http://feeds.rsc.org/rss/sm", name="Soft Matter", group=:include_all, section_filter=nothing),
    (url="https://www.cell.com/biophysj/inpress.rss", name="Biophysical Journal", group=:include_all, section_filter=nothing),
    (url="https://feeds.aps.org/rss/tocsec/PRE-Biologicalphysics.xml", name="Physical Review E", group=:include_all, section_filter=nothing),
    (url="https://feeds.aps.org/rss/tocsec/PRL-SoftMatterBiologicalandInterdisciplinaryPhysics.xml", name="PRL", group=:include_all, section_filter=nothing),
    (url="https://feeds.aps.org/rss/recent/prx.xml", name="PRX", group=:include_all, section_filter=nothing),
    (url="https://feeds.aps.org/rss/recent/prxlife.xml", name="PRX Life", group=:include_all, section_filter=nothing),
    (url="https://feeds.aps.org/rss/recent/prresearch.xml", name="PRR", group=:include_all, section_filter=nothing),
    (url="https://www.nature.com/subjects/biophysics.rss", name="Nature", group=:include_all, section_filter=nothing),
    (url="https://www.pnas.org/action/showFeed?type=searchTopic&taxonomyCode=topic&tagCodeOr=biophys-bio&tagCodeOr=biophys-phys", name="PNAS", group=:include_all, section_filter=nothing),
    (url="https://academic.oup.com/rss/site_6448/4114.xml", name="PNAS NEXUS", group=:include_all, section_filter=nothing),
    (url="https://journals.plos.org/plosone/search/feed/atom?sortOrder=DATE_NEWEST_FIRST&filterJournals=PLoSONE&unformattedQuery=subject%3A%22biophysics%22", name="PLOS ONE", group=:include_all, section_filter=nothing),
    (url="https://www.science.org/rss/express.xml", name="Science", group=:section_filter, section_filter="Biophysics"),
    (url="https://www.cell.com/cell/current.rss", name="Cell", group=:green_filter, section_filter=nothing),
    (url="https://elifesciences.org/rss/recent.xml", name="eLife", group=:green_filter, section_filter=nothing),
    (url="https://www.molbiolcell.org/action/showFeed?type=etoc&feed=rss&jc=mboc", name="MBoC", group=:green_filter, section_filter=nothing),
]

const APS_SOURCES = Set(["PRL", "PRX", "PRX Life", "Physical Review E", "PRR"])
const RSC_SOURCES = Set(["Soft Matter"])

const CROSSREF_MAILTO = "lemma@princeton.edu"

# Browser-like headers for web scraping
const BROWSER_HEADERS = [
    "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
    "Accept-Language" => "en-US,en;q=0.9",
    "Accept-Encoding" => "gzip, deflate, br",
    "Connection" => "keep-alive",
    "Upgrade-Insecure-Requests" => "1",
    "Sec-Fetch-Dest" => "document",
    "Sec-Fetch-Mode" => "navigate",
    "Sec-Fetch-Site" => "none",
    "Sec-Fetch-User" => "?1",
    "Cache-Control" => "max-age=0",
]

const RSS_HEADERS = [
    "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
    "Accept-Language" => "en-US,en;q=0.9",
    "Referer" => "https://www.google.com/",
]

# ─── Paper struct ────────────────────────────────────────────────────────────

mutable struct Paper
    source::String
    title::String
    authors::String
    link::String
    abstract::String
    images::Vector{String}
    date::ZonedDateTime
    doi::Union{String,Nothing}
end

Paper(; source="", title="", authors="", link="", abstract_text="",
      images=String[], date=now(tz"UTC"), doi=nothing) =
    Paper(source, title, authors, link, abstract_text, images, date, doi)

# ─── Helper: parse HTML text ────────────────────────────────────────────────

"""Get text content from an HTML string, stripping all tags."""
function html_to_text(html::AbstractString)
    isempty(html) && return ""
    doc = parsehtml(html)
    return text(doc.root)
end



# ─── Load whitelists ────────────────────────────────────────────────────────

function load_list(filename::String)::Vector{String}
    isfile(filename) || (println("Warning: $filename not found."); return String[])
    lines = readlines(filename)
    return filter(!isempty, strip.(lines))
end

const ORCID_PATTERN = r"^(\d{4}-\d{4}-\d{4}-[\dX]{4})\s*-\s*(.+)$"

function load_green_authors_with_orcids(filename::String)
    orcid_list = Tuple{String,String}[]
    name_list = String[]
    isfile(filename) || (println("Warning: $filename not found."); return orcid_list, name_list)
    for line in readlines(filename)
        line = strip(line)
        isempty(line) && continue
        m = match(ORCID_PATTERN, line)
        if m !== nothing
            orcid, name = m.captures[1], strip(m.captures[2])
            push!(orcid_list, (orcid, name))
            push!(name_list, name)
        else
            push!(name_list, line)
        end
    end
    return orcid_list, name_list
end

const GREEN_ORCIDS, GREEN_AUTHORS = load_green_authors_with_orcids("greenauthors.txt")
const GREEN_KEYWORDS = load_list("greenkeywords.txt")

# ─── Filtering ───────────────────────────────────────────────────────────────

const EXCLUDE_TERMS = [
    "review", "perspective", "editorial", "correction", "comment", "highlight",
    "news", "erratum", "author correction", "publisher correction",
    "profile", "q&a", "inner workings", "front matter", "core concepts", "opinion"
]

const NON_RESEARCH_TYPES = [
    "commentary", "perspective", "editorial", "news", "interview", "author summary", "correction"
]

function is_research_article(title::AbstractString, summary::AbstractString="";
                             article_type::AbstractString="")::Bool
    tl = lowercase(title)
    any(t -> occursin(t, tl), EXCLUDE_TERMS) && return false
    if !isempty(article_type)
        atl = lowercase(article_type)
        if any(t -> occursin(t, atl), NON_RESEARCH_TYPES)
            println("    - Filtered out non-research type: $article_type")
            return false
        end
    end
    return true
end

function matches_green_filter(authors_str::AbstractString, title::AbstractString, summary::AbstractString)::Bool
    al = lowercase(authors_str)
    for ga in GREEN_AUTHORS
        occursin(lowercase(ga), al) && return true
    end
    text_to_search = lowercase(title * " " * summary)
    for kw in GREEN_KEYWORDS
        occursin(lowercase(kw), text_to_search) && return true
    end
    return false
end

# ─── Scrape metadata from article page ──────────────────────────────────────

function scrape_metadata(url::AbstractString)
    try
        # Cookie jar needed for Nature.com's idp.nature.com cookie gate
        jar = HTTP.Cookies.CookieJar()
        resp = HTTP.get(url; headers=BROWSER_HEADERS, readtimeout=30, status_exception=false,
                        redirect=true, cookies=jar)
        resp.status != 200 && return nothing, nothing, nothing

        body = String(resp.body)
        doc = parsehtml(body)

        # Authors — try multiple strategies
        authors = String[]

        # Strategy 1: citation_author meta tags (most journals)
        for n in eachmatch(Selector("meta[name=\"citation_author\"]"), doc.root)
            c = getattr(n, "content", "")
            !isempty(c) && push!(authors, c)
        end

        # Strategy 2: DC.creator meta tags
        if isempty(authors)
            for n in eachmatch(Selector("meta[name=\"DC.creator\"]"), doc.root)
                c = getattr(n, "content", "")
                !isempty(c) && push!(authors, strip(c))
            end
        end

        # Strategy 3: JSON-LD structured data (Nature uses this)
        if isempty(authors)
            for script_node in eachmatch(Selector("script[type=\"application/ld+json\"]"), doc.root)
                json_text = text(script_node)
                isempty(json_text) && continue
                try
                    ld = JSON3.read(json_text)
                    # Check mainEntity.author (Nature's format)
                    main_entity = get(ld, :mainEntity, nothing)
                    author_list = main_entity !== nothing ? get(main_entity, :author, nothing) : get(ld, :author, nothing)
                    if author_list !== nothing && isa(author_list, AbstractVector)
                        for a in author_list
                            name = isa(a, AbstractDict) ? get(a, :name, "") : string(a)
                            name = strip(string(name))
                            !isempty(name) && push!(authors, name)
                        end
                    end
                catch
                    # JSON parsing failed, continue
                end
                !isempty(authors) && break
            end
        end

        # Abstract
        abstract_text = ""
        for attr_pair in [("name", "citation_abstract"), ("name", "DC.description"), ("property", "og:description")]
            nodes = eachmatch(Selector("meta[$(attr_pair[1])=\"$(attr_pair[2])\"]"), doc.root)
            for n in nodes
                c = getattr(n, "content", "")
                if !isempty(c)
                    abstract_text = strip(c)
                    break
                end
            end
            !isempty(abstract_text) && break
        end

        # Abstract fallback: JSON-LD description (Nature)
        if isempty(abstract_text)
            for script_node in eachmatch(Selector("script[type=\"application/ld+json\"]"), doc.root)
                json_text = text(script_node)
                isempty(json_text) && continue
                try
                    ld = JSON3.read(json_text)
                    main_entity = get(ld, :mainEntity, nothing)
                    desc = main_entity !== nothing ? get(main_entity, :description, "") : get(ld, :description, "")
                    desc = strip(string(desc))
                    if !isempty(desc) && length(desc) > 50
                        abstract_text = desc
                        break
                    end
                catch
                end
            end
        end

        # Article type
        article_type = ""
        for aname in ["citation_article_type", "dc.Type", "article:section"]
            nodes = eachmatch(Selector("meta[name=\"$aname\"]"), doc.root)
            for n in nodes
                c = getattr(n, "content", "")
                if !isempty(c)
                    article_type = strip(c)
                    break
                end
            end
            !isempty(article_type) && break
        end

        return (isempty(authors) ? nothing : authors),
               (isempty(abstract_text) ? nothing : abstract_text),
               (isempty(article_type) ? nothing : article_type)
    catch e
        println("  Warning: Metadata scraping failed for $url: $e")
        return nothing, nothing, nothing
    end
end

# ─── Abstract cleaners ──────────────────────────────────────────────────────

function clean_aps_abstract(summary::AbstractString)
    images = String[]
    isempty(summary) && return "", images

    doc = parsehtml(summary)

    # Extract image URLs
    for img in eachmatch(Selector("img"), doc.root)
        src = getattr(img, "src", "")
        if !isempty(src)
            startswith(src, "//") && (src = "https:" * src)
            push!(images, src)
        end
    end

    # Extract from <p> tags
    p_nodes = eachmatch(Selector("p"), doc.root)
    if !isempty(p_nodes)
        abstract_text = join([text(p) for p in p_nodes], " ")
    else
        abstract_text = text(doc.root)
    end

    abstract_text = strip(abstract_text)

    # Remove "Author(s): ..." prefix
    abstract_text = replace(abstract_text, r"^Author\(s\):.*?(?=\S{20,})"s => "")
    # Remove trailing journal citation
    abstract_text = replace(abstract_text, r"\[Phys\.\s*Rev\..*$" => "")
    abstract_text = replace(abstract_text, r"\[PRX\s+Life.*$" => "")

    return strip(abstract_text), images
end

function clean_biorxiv_abstract(abstract_text::AbstractString)
    isempty(abstract_text) && return abstract_text
    markers = ["TOC Graphic", "Graphical Abstract", "O_FIG O_LINKSMALLFIG", "O_FIG\nO_LINKSMALLFIG"]
    for marker in markers
        idx = findfirst(marker, abstract_text)
        if idx !== nothing && first(idx) > 1
            abstract_text = strip(abstract_text[1:first(idx)-1])
        end
    end
    return abstract_text
end

function clean_rsc_abstract(summary::AbstractString)
    images = String[]
    isempty(summary) && return "", "", images

    doc = parsehtml(summary)

    # Extract GA images
    for img in eachmatch(Selector("img"), doc.root)
        src = getattr(img, "src", "")
        if !isempty(src) && occursin("ImageService/image/GA", src)
            startswith(src, "//") && (src = "https:" * src)
            startswith(src, "http://") && (src = replace(src, "http://" => "https://"; count=1))
            push!(images, src)
        end
    end

    # Parse div blocks — find the content div with authors + abstract
    abstract_text = ""
    authors_str = ""

    for div in eachmatch(Selector("div"), doc.root)
        txt = strip(text(div))
        # Skip metadata divs
        (startswith(txt, "Soft Matter") || startswith(txt, "Nanoscale")) && continue
        (occursin("Open Access", txt) && length(txt) < 50) && continue
        (occursin("Creative Commons", txt) || occursin("licensed under", txt)) && continue

        # Split on line breaks — first segment is authors, rest is abstract
        segments = filter(!isempty, strip.(split(txt, "\n")))
        if length(segments) >= 2
            segments = filter(s -> !occursin("The content of this RSS Feed", s) &&
                                   !occursin("To cite this article before page numbers", s), segments)
            if !isempty(segments)
                authors_str = segments[1]
                abstract_text = join(segments[2:end], " ")
            end
        end
    end

    return abstract_text, authors_str, images
end

# ─── CrossRef metadata lookup ────────────────────────────────────────────────

function fetch_crossref_metadata(doi::AbstractString)
    isempty(doi) && return nothing, nothing
    doi = replace(doi, "doi:" => "")
    doi = strip(doi)
    try
        resp = HTTP.get("https://api.crossref.org/works/$doi"; readtimeout=10, status_exception=false)
        resp.status != 200 && return nothing, nothing

        data = JSON3.read(String(resp.body))
        msg = get(data, :message, nothing)
        msg === nothing && return nothing, nothing

        # Authors
        authors = String[]
        for a in get(msg, :author, [])
            given = get(a, :given, "")
            family = get(a, :family, "")
            if !isempty(given) && !isempty(family)
                push!(authors, "$given $family")
            elseif !isempty(family)
                push!(authors, family)
            end
        end

        # Abstract
        abstract_text = string(get(msg, :abstract, ""))
        if !isempty(abstract_text)
            abstract_text = replace(abstract_text, r"<[^>]+>" => "")
            abstract_text = strip(abstract_text)
        end

        return (isempty(authors) ? nothing : authors),
               (isempty(abstract_text) ? nothing : abstract_text)
    catch e
        println("  Warning: CrossRef lookup failed for $doi: $e")
        return nothing, nothing
    end
end

# ─── XML helper: get text content of a child element ────────────────────────

function xml_child_text(node::EzXML.Node, tag::String; ns::Union{String,Nothing}=nothing)
    for child in eachelement(node)
        cname = EzXML.nodename(child)
        # Handle namespaced tags like "dc:creator"
        if cname == tag || endswith(cname, ":$tag") || cname == split(tag, ":")[end]
            return strip(nodecontent(child))
        end
    end
    return ""
end

function xml_child_texts(node::EzXML.Node, tag::String)
    results = String[]
    for child in eachelement(node)
        cname = EzXML.nodename(child)
        if cname == tag || endswith(cname, ":$tag") || cname == split(tag, ":")[end]
            push!(results, strip(nodecontent(child)))
        end
    end
    return results
end

function xml_child_attr(node::EzXML.Node, tag::String, attr::String)
    for child in eachelement(node)
        cname = EzXML.nodename(child)
        if cname == tag || endswith(cname, ":$tag")
            return strip(EzXML.nodecontent(child)), getattr_xml(child, attr, "")
        end
    end
    return "", ""
end

function getattr_xml(node::EzXML.Node, attr::String, default::String="")
    try
        return node[attr]
    catch
        return default
    end
end

# ─── RSS Feed Fetching ───────────────────────────────────────────────────────

"""Parse a date string from an RSS/Atom feed entry."""
function parse_feed_date(node::EzXML.Node)
    for tag in ["published", "pubDate", "updated", "dc:date", "date"]
        d = xml_child_text(node, tag)
        if !isempty(d)
            # Try multiple date formats
            for fmt in [
                dateformat"e, d u y H:M:S Z",     # RSS: Mon, 01 Jan 2026 00:00:00 GMT
                dateformat"y-m-dTH:M:SZ",          # Atom: 2026-01-01T00:00:00Z
                dateformat"y-m-dTH:M:S+00:00",     # Atom with offset
                dateformat"y-m-d",                   # Simple date
            ]
                try
                    dt = DateTime(replace(d, r"\s+[A-Z]{3,4}$" => ""), fmt)
                    return ZonedDateTime(dt, tz"UTC")
                catch
                end
            end
            # Fallback: try Julia's built-in parser
            try
                # Handle "Mon, 01 Jan 2026 00:00:00 GMT" style
                m = match(r"(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})", d)
                if m !== nothing
                    months = Dict("Jan"=>1,"Feb"=>2,"Mar"=>3,"Apr"=>4,"May"=>5,"Jun"=>6,
                                  "Jul"=>7,"Aug"=>8,"Sep"=>9,"Oct"=>10,"Nov"=>11,"Dec"=>12)
                    day = parse(Int, m.captures[1])
                    mon = get(months, m.captures[2], 1)
                    yr = parse(Int, m.captures[3])
                    hr = parse(Int, m.captures[4])
                    mn = parse(Int, m.captures[5])
                    sc = parse(Int, m.captures[6])
                    return ZonedDateTime(DateTime(yr, mon, day, hr, mn, sc), tz"UTC")
                end
                # Handle ISO 8601 with timezone offset
                m2 = match(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})", d)
                if m2 !== nothing
                    yr = parse(Int, m2.captures[1])
                    mo = parse(Int, m2.captures[2])
                    dy = parse(Int, m2.captures[3])
                    hr = parse(Int, m2.captures[4])
                    mn = parse(Int, m2.captures[5])
                    sc = parse(Int, m2.captures[6])
                    return ZonedDateTime(DateTime(yr, mo, dy, hr, mn, sc), tz"UTC")
                end
            catch
            end
        end
    end
    return nothing
end

"""Extract all RSS/Atom entries from parsed XML, handling both RSS and Atom formats."""
function extract_feed_entries(xmldoc::EzXML.Document)
    root_el = EzXML.root(xmldoc)
    entries = EzXML.Node[]

    # Atom format: <feed><entry>...</entry></feed>
    # RSS format: <rss><channel><item>...</item></channel></rss>
    for node in EzXML.eachelement(root_el)
        nname = EzXML.nodename(node)
        if nname == "entry"
            push!(entries, node)
        elseif nname == "channel"
            for child in EzXML.eachelement(node)
                EzXML.nodename(child) == "item" && push!(entries, child)
            end
        end
    end

    # Also check root directly for items (some RSS feeds)
    if isempty(entries)
        for node in EzXML.eachelement(root_el)
            EzXML.nodename(node) == "item" && push!(entries, node)
        end
    end

    return entries
end

"""Get link from an RSS/Atom entry."""
function get_entry_link(entry::EzXML.Node)
    # Atom: <link href="..."/>
    for child in eachelement(entry)
        if EzXML.nodename(child) == "link"
            href = getattr_xml(child, "href", "")
            !isempty(href) && return href
            # RSS: <link>text</link>
            t = strip(nodecontent(child))
            !isempty(t) && return t
        end
    end
    # Fallback: guid
    guid = xml_child_text(entry, "guid")
    return guid
end

"""Get tags/categories from an entry."""
function get_entry_tags(entry::EzXML.Node)
    tags = String[]
    for child in eachelement(entry)
        cname = EzXML.nodename(child)
        if cname == "category"
            term = getattr_xml(child, "term", "")
            label = getattr_xml(child, "label", "")
            !isempty(term) && push!(tags, lowercase(term))
            !isempty(label) && push!(tags, lowercase(label))
            t = strip(nodecontent(child))
            !isempty(t) && push!(tags, lowercase(t))
        end
    end
    return tags
end

"""Get authors from an RSS/Atom entry."""
function get_entry_authors(entry::EzXML.Node)
    authors = String[]
    for child in eachelement(entry)
        cname = EzXML.nodename(child)
        if cname == "author"
            # Atom: <author><name>...</name></author>
            name_text = xml_child_text(child, "name")
            if !isempty(name_text)
                push!(authors, name_text)
            else
                t = strip(nodecontent(child))
                !isempty(t) && push!(authors, t)
            end
        elseif endswith(cname, "creator")  # dc:creator
            t = strip(nodecontent(child))
            !isempty(t) && push!(authors, t)
        end
    end
    return authors
end

function fetch_rss(url::AbstractString, source_name::AbstractString, group_type::Symbol;
                   section_filter::Union{AbstractString,Nothing}=nothing)
    println("Fetching $source_name...")
    papers = Paper[]

    try
        # Cookie jar needed for Nature.com's idp.nature.com cookie gate (303→302→302 redirect chain)
        jar = HTTP.Cookies.CookieJar()
        resp = HTTP.get(url; headers=RSS_HEADERS, readtimeout=30, status_exception=false, redirect=true, cookies=jar)
        if resp.status != 200
            println("  Error: $source_name returned status $(resp.status)")
            return papers
        end

        body = String(resp.body)
        xmldoc = try
            EzXML.parsexml(body)
        catch
            # Some feeds are not valid XML — try cleaning
            body_clean = replace(body, r"&(?!amp;|lt;|gt;|quot;|apos;|#)" => "&amp;")
            try
                EzXML.parsexml(body_clean)
            catch e
                println("  Warning: Issue parsing $source_name feed: $e")
                return papers
            end
        end

        entries = extract_feed_entries(xmldoc)

        for entry in entries
            # Date
            published = parse_feed_date(entry)
            published === nothing && continue
            published < OLDEST_DATE && continue

            # Authors
            authors = get_entry_authors(entry)

            title = xml_child_text(entry, "title")
            isempty(title) && continue

            # Research article check
            summary_raw = xml_child_text(entry, "summary")
            isempty(summary_raw) && (summary_raw = xml_child_text(entry, "description"))
            isempty(summary_raw) && (summary_raw = xml_child_text(entry, "content"))

            !is_research_article(title, summary_raw) && continue

            # Section filter
            if group_type == :section_filter && section_filter !== nothing
                tags = get_entry_tags(entry)
                sf = lowercase(section_filter)
                category_match = any(t -> occursin(sf, t), tags)
                text_match = occursin(sf, lowercase(title)) || occursin(sf, lowercase(summary_raw))
                !(category_match || text_match) && continue
            end

            # Green filter
            if group_type == :green_filter
                authors_str_check = join(authors, " ")
                !matches_green_filter(authors_str_check, title, summary_raw) && continue
            end

            # Build paper
            abstract_text = replace(summary_raw, "\n" => " ")
            images = String[]
            link = get_entry_link(entry)

            # APS cleaning
            if source_name in APS_SOURCES
                abstract_text, images = clean_aps_abstract(abstract_text)
            end

            # RSC cleaning
            if source_name in RSC_SOURCES
                rsc_abstract, rsc_authors, rsc_images = clean_rsc_abstract(summary_raw)
                !isempty(rsc_abstract) && (abstract_text = rsc_abstract)
                !isempty(rsc_authors) && (authors = [rsc_authors])
                images = rsc_images
            end

            # Data quality checks & fallback scraping
            needs_scrape = false
            if source_name == "PNAS"
                needs_scrape = true
            elseif isempty(authors)
                needs_scrape = true
            end
            if isempty(abstract_text) || length(abstract_text) < 20
                needs_scrape = true
            end

            if needs_scrape && !isempty(link)
                println("    - Scraping metadata for: $(first(title, 30))...")
                scraped_authors, scraped_abstract, scraped_type = scrape_metadata(link)

                scraped_authors !== nothing && (authors = scraped_authors)
                scraped_abstract !== nothing && (abstract_text = scraped_abstract)

                if scraped_type !== nothing && !is_research_article(title; article_type=string(scraped_type))
                    continue
                end

                # CrossRef fallback for PNAS
                if source_name == "PNAS" && (scraped_authors === nothing || scraped_abstract === nothing)
                    # Try to extract DOI from link
                    doi_match = match(r"10\.\d{4,}/[^\s?&#]+", link)
                    if doi_match !== nothing
                        doi = doi_match.match
                        println("    - CrossRef fallback for: $(first(title, 30))...")
                        cr_authors, cr_abstract = fetch_crossref_metadata(doi)
                        scraped_authors === nothing && cr_authors !== nothing && (authors = cr_authors)
                        scraped_abstract === nothing && cr_abstract !== nothing && (abstract_text = cr_abstract)
                    end
                end
            end

            push!(papers, Paper(
                source=source_name,
                title=replace(title, "\n" => " "),
                authors=join(authors, ", "),
                link=link,
                abstract_text=abstract_text,
                images=images,
                date=published,
            ))
        end
    catch e
        println("  Error fetching $source_name: $e")
    end

    println("  Found $(length(papers)) papers.")
    return papers
end

# ─── arXiv Fetching (direct API) ────────────────────────────────────────────

function fetch_arxiv_papers()
    println("Fetching arXiv papers...")
    query_string = join(["cat:$c" for c in ARXIV_CATEGORIES], " OR ")

    papers = Paper[]
    seen_ids = Set{String}()
    start = 0
    page_size = 50
    max_results = 200
    max_retries = 4

    while start < max_results
        params = Dict(
            "search_query" => query_string,
            "sortBy" => "submittedDate",
            "sortOrder" => "descending",
            "start" => string(start),
            "max_results" => string(page_size),
        )

        query_str = join(["$k=$(HTTP.escapeuri(v))" for (k,v) in params], "&")
        url = "https://export.arxiv.org/api/query?$query_str"

        # Retry with backoff
        data = nothing
        for attempt in 1:max_retries
            try
                resp = HTTP.get(url; headers=["User-Agent" => "LemmaJournalClub/1.0 (weekly paper fetch)"], readtimeout=30, status_exception=false)
                if resp.status == 429
                    wait_secs = 15 * attempt
                    if attempt < max_retries
                        println("  arXiv rate limit (429). Waiting $(wait_secs)s (attempt $attempt/$max_retries)...")
                        sleep(wait_secs)
                        continue
                    else
                        println("  ❌ arXiv rate limit persisted after $max_retries attempts.")
                        println("  Continuing with $(length(papers)) arXiv papers found so far.")
                        return papers
                    end
                end
                resp.status >= 400 && error("HTTP $(resp.status)")
                data = String(resp.body)
                break
            catch e
                wait_secs = 10 * attempt
                if attempt < max_retries
                    println("  arXiv error: $e. Waiting $(wait_secs)s (attempt $attempt/$max_retries)...")
                    sleep(wait_secs)
                else
                    println("  ❌ arXiv failed after $max_retries attempts: $e")
                    println("  Continuing with $(length(papers)) arXiv papers found so far.")
                    return papers
                end
            end
        end

        data === nothing && break

        xmldoc = try
            EzXML.parsexml(data)
        catch e
            println("  Warning: Could not parse arXiv XML: $e")
            break
        end

        root_el = EzXML.root(xmldoc)
        atom_entries = [n for n in eachelement(root_el) if EzXML.nodename(n) == "entry"]
        isempty(atom_entries) && break

        done = false
        for entry in atom_entries
            # Published date
            pub_str = xml_child_text(entry, "published")
            published = try
                m = match(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})", pub_str)
                if m !== nothing
                    ZonedDateTime(DateTime(
                        parse(Int, m.captures[1]), parse(Int, m.captures[2]),
                        parse(Int, m.captures[3]), parse(Int, m.captures[4]),
                        parse(Int, m.captures[5]), parse(Int, m.captures[6])), tz"UTC")
                else
                    now(tz"UTC")
                end
            catch
                now(tz"UTC")
            end

            if published < OLDEST_DATE
                done = true
                break
            end

            # ID dedup
            id_str = xml_child_text(entry, "id")
            paper_id = replace(split(split(id_str, "/")[end], "v")[1], r"\s+" => "")
            paper_id in seen_ids && continue
            push!(seen_ids, paper_id)

            title = replace(xml_child_text(entry, "title"), "\n" => " ")
            summary = replace(xml_child_text(entry, "summary"), "\n" => " ")

            !is_research_article(title, summary) && continue

            # Authors
            author_names = String[]
            for child in eachelement(entry)
                if EzXML.nodename(child) == "author"
                    name = xml_child_text(child, "name")
                    !isempty(name) && push!(author_names, name)
                end
            end

            push!(papers, Paper(
                source="arXiv",
                title=title,
                authors=join(author_names, ", "),
                link=id_str,
                abstract_text=summary,
                images=String[],
                date=published,
            ))
        end

        done && break
        start += page_size
        sleep(5)  # Polite delay between pages
    end

    println("  Found $(length(papers)) arXiv papers.")
    return papers
end

# ─── bioRxiv Fetching ────────────────────────────────────────────────────────

function fetch_biorxiv_papers()
    println("Fetching bioRxiv papers...")
    start_date = Dates.format(DateTime(OLDEST_DATE, UTC), "yyyy-mm-dd")
    end_date = Dates.format(now(UTC), "yyyy-mm-dd")

    papers = Paper[]
    cursor = 0

    while true
        url = "https://api.biorxiv.org/details/biorxiv/$start_date/$end_date/$cursor/json"

        max_retries = 4
        data = nothing
        for attempt in 1:max_retries
            try
                resp = HTTP.get(url; readtimeout=30, status_exception=false)
                if resp.status == 429
                    wait_secs = 10 * attempt
                    println("  bioRxiv rate limit (429) at cursor $cursor. Waiting $(wait_secs)s (attempt $attempt/$max_retries)...")
                    sleep(wait_secs)
                    continue
                end
                resp.status >= 400 && error("HTTP $(resp.status)")
                data = JSON3.read(String(resp.body))
                break
            catch e
                wait_secs = 5 * attempt
                println("  bioRxiv error at cursor $cursor: $e. Waiting $(wait_secs)s (attempt $attempt/$max_retries)...")
                sleep(wait_secs)
            end
        end

        (data === nothing || !haskey(data, :collection)) && break

        for item in data.collection
            cat = get(item, :category, "")
            lowercase(cat) != lowercase(BIORXIV_COLLECTION) && continue

            paper_date = try
                ZonedDateTime(DateTime(string(item.date), "yyyy-mm-dd"), tz"UTC")
            catch
                now(tz"UTC")
            end

            authors = string(get(item, :authors, ""))
            raw_abstract = replace(string(item.abstract), "\n" => " ")
            clean_abs = clean_biorxiv_abstract(raw_abstract)
            doi = string(item.doi)
            version = string(item.version)

            push!(papers, Paper(
                source="bioRxiv",
                title=replace(string(item.title), "\n" => " "),
                authors=authors,
                link="https://www.biorxiv.org/content/$(doi)v$(version)",
                abstract_text=clean_abs,
                images=String[],
                date=paper_date,
                doi=doi,
            ))
        end

        messages = get(data, :messages, [Dict()])
        msg = isempty(messages) ? Dict() : first(messages)
        count = parse(Int, string(get(msg, :count, "0")))
        total = parse(Int, string(get(msg, :total, "0")))
        new_cursor = parse(Int, string(get(msg, :cursor, "0"))) + count

        (new_cursor >= total || count == 0) && break
        cursor = new_cursor
        sleep(0.5)
    end

    # Deduplicate by DOI (keep earliest date)
    unique_papers = Dict{String, Paper}()
    for p in papers
        doi = something(p.doi, p.title)
        if !haskey(unique_papers, doi) || p.date < unique_papers[doi].date
            unique_papers[doi] = p
        end
    end

    final = collect(values(unique_papers))
    println("  Found $(length(final)) bioRxiv papers (biophysics).")
    return final
end

# ─── CrossRef ORCID Fetching ────────────────────────────────────────────────

function _query_crossref_orcid(orcid::String, author_name::String, from_date::String)
    papers = Paper[]
    max_retries = 4
    url = "https://api.crossref.org/works"
    params = Dict(
        "filter" => "orcid:$orcid,from-pub-date:$from_date",
        "rows" => "10",
        "sort" => "published",
        "order" => "desc",
        "mailto" => CROSSREF_MAILTO,
    )

    query_str = join(["$k=$(HTTP.escapeuri(v))" for (k,v) in params], "&")
    full_url = "$url?$query_str"

    for attempt in 1:max_retries
        try
            resp = HTTP.get(full_url; readtimeout=15, status_exception=false)
            if resp.status == 200
                data = JSON3.read(String(resp.body))
                items = get(get(data, :message, Dict()), :items, [])
                for item in items
                    title_parts = get(item, :title, ["No Title"])
                    title = isempty(title_parts) ? "No Title" : string(first(title_parts))

                    # Authors
                    authors_raw = get(item, :author, [])
                    authors_list = String[]
                    for a in authors_raw
                        given = string(get(a, :given, ""))
                        family = string(get(a, :family, ""))
                        if !isempty(given) && !isempty(family)
                            push!(authors_list, "$given $family")
                        elseif !isempty(family)
                            push!(authors_list, family)
                        end
                    end
                    authors_str = isempty(authors_list) ? "Unknown" : join(authors_list, ", ")

                    # DOI + link
                    doi = string(get(item, :DOI, ""))
                    link = !isempty(doi) ? "https://doi.org/$doi" : string(get(item, :URL, ""))

                    # Abstract
                    abstract_text = string(get(item, :abstract, ""))
                    if !isempty(abstract_text)
                        abstract_text = replace(abstract_text, r"<[^>]+>" => "")
                        abstract_text = strip(abstract_text)
                    end
                    isempty(abstract_text) && (abstract_text = "Abstract not available via CrossRef API.")

                    # Publication date
                    pub_date = try
                        published = get(item, :published, Dict())
                        date_parts = get(published, Symbol("date-parts"), [[]])
                        parts = isempty(date_parts) ? [] : first(date_parts)
                        yr = length(parts) >= 1 ? Int(parts[1]) : year(now())
                        mo = length(parts) >= 2 ? Int(parts[2]) : 1
                        dy = length(parts) >= 3 ? Int(parts[3]) : 1
                        ZonedDateTime(DateTime(yr, mo, dy), tz"UTC")
                    catch
                        now(tz"UTC")
                    end

                    push!(papers, Paper(
                        source="CrossRef/Featured",
                        title=replace(title, "\n" => " "),
                        authors=authors_str,
                        link=link,
                        abstract_text=abstract_text,
                        images=String[],
                        date=pub_date,
                        doi=!isempty(doi) ? "https://doi.org/$doi" : nothing,
                    ))
                end
                return papers
            elseif resp.status == 429
                wait_secs = 5 * attempt
                sleep(wait_secs)
                continue
            else
                println("  ❌ CrossRef failed for $author_name: HTTP $(resp.status)")
                return papers
            end
        catch e
            if e isa HTTP.TimeoutError && attempt < max_retries
                sleep(3 * attempt)
            else
                println("  ❌ CrossRef failed for $author_name: $e")
                return papers
            end
        end
    end
    return papers
end

function fetch_crossref_papers()
    println("Fetching CrossRef papers for Green Authors ($(length(GREEN_ORCIDS)) with ORCIDs)...")

    isempty(GREEN_ORCIDS) && (println("  No Green Authors with ORCIDs found to search."); return Paper[])

    from_date = Dates.format(DateTime(OLDEST_DATE, UTC), "yyyy-mm-dd")

    # Parallel fetch using @async tasks
    results = Vector{Vector{Paper}}(undef, length(GREEN_ORCIDS))
    @sync begin
        for (i, (orcid, name)) in enumerate(GREEN_ORCIDS)
            @async begin
                results[i] = _query_crossref_orcid(orcid, name, from_date)
            end
        end
    end

    papers = Paper[]
    for r in results
        append!(papers, r)
    end

    # Deduplicate
    unique = Dict{String, Paper}()
    for p in papers
        key = something(p.doi, lowercase(p.title))
        haskey(unique, key) || (unique[key] = p)
    end

    println("  Found $(length(unique)) unique papers from CrossRef.")
    return collect(values(unique))
end

# ─── Main orchestrator ───────────────────────────────────────────────────────

function fetch_and_display_papers()
    println("Fetching papers from $(Dates.format(DateTime(OLDEST_DATE, UTC), "yyyy-mm-dd")) to Now...")

    all_papers = Paper[]

    # 0. CrossRef (Featured)
    append!(all_papers, fetch_crossref_papers())

    # 1. arXiv
    append!(all_papers, fetch_arxiv_papers())

    # 2. bioRxiv
    append!(all_papers, fetch_biorxiv_papers())

    # 3. Journal RSS feeds — parallel
    rss_results = Vector{Vector{Paper}}(undef, length(JOURNAL_FEEDS))
    @sync begin
        for (i, feed) in enumerate(JOURNAL_FEEDS)
            @async begin
                rss_results[i] = fetch_rss(feed.url, feed.name, feed.group;
                                           section_filter=feed.section_filter)
            end
        end
    end
    for r in rss_results
        append!(all_papers, r)
    end

    # ─── Deduplication ───
    # Pass 1: by DOI
    unique_by_doi = Dict{String, Paper}()
    no_doi_papers = Paper[]
    for p in all_papers
        if p.doi !== nothing
            if !haskey(unique_by_doi, p.doi) || p.date < unique_by_doi[p.doi].date
                unique_by_doi[p.doi] = p
            end
        else
            push!(no_doi_papers, p)
        end
    end

    # Pass 2: by normalized title
    unique_map = Dict{String, Paper}()
    for p in vcat(collect(values(unique_by_doi)), no_doi_papers)
        title_clean = filter(isascii, lowercase(replace(p.title, r"[^a-zA-Z0-9]" => "")))
        if !haskey(unique_map, title_clean) || p.date < unique_map[title_clean].date
            unique_map[title_clean] = p
        end
    end

    final_list = collect(values(unique_map))
    sort!(final_list; by=p -> p.date, rev=true)

    total_count = length(final_list)

    # Build markdown output
    output_lines = String[]
    for paper in final_list
        push!(output_lines, "### $(paper.title)")
        push!(output_lines, "**Source:** $(paper.source)")
        push!(output_lines, "**Date:** $(Dates.format(DateTime(paper.date, UTC), "yyyy-mm-dd"))")
        push!(output_lines, "**Authors:** $(paper.authors)")
        push!(output_lines, "**Link:** $(paper.link)")
        push!(output_lines, "<details>")
        push!(output_lines, "<summary><strong>Abstract</strong></summary>")
        push!(output_lines, paper.abstract)
        if !isempty(paper.images)
            push!(output_lines, "")
            push!(output_lines, "**Key Images:**")
            for img_url in paper.images
                push!(output_lines, "- ![key image]($img_url)")
            end
        end
        push!(output_lines, "</details>")
        push!(output_lines, "")
        push!(output_lines, "---")
        push!(output_lines, "")
    end

    # Write JSON
    json_list = [Dict(
        "source" => p.source,
        "title" => p.title,
        "authors" => p.authors,
        "link" => p.link,
        "abstract" => p.abstract,
        "images" => p.images,
        "date" => Dates.format(DateTime(p.date, UTC), "yyyy-mm-ddTHH:MM:SS+00:00"),
        "doi" => p.doi,
    ) for p in final_list]

    open("papers.json", "w") do f
        JSON3.pretty(f, json_list)
    end
    println("Saved structured data to papers.json")

    # Write raw markdown
    source_counts = Dict{String, Int}()
    for p in final_list
        source_counts[p.source] = get(source_counts, p.source, 0) + 1
    end
    sorted_sources = sort(collect(source_counts); by=x -> x[2], rev=true)
    breakdown = join(["$(src): $(cnt)" for (src, cnt) in sorted_sources], ", ")

    oldest_str = Dates.format(DateTime(OLDEST_DATE, UTC), "yyyy-mm-dd")
    now_str = Dates.format(now(), "yyyy-mm-dd")

    println("\nDone. Found $total_count total unique papers.")
end

# ─── Entry point ─────────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    fetch_and_display_papers()
    # Clean up HTTP.jl's idle connection pool to suppress "Unhandled Task ERROR" on exit
    HTTP.Connections.closeall()
end
