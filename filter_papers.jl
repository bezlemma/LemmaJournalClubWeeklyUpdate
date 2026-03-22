using JSON3, HTTP, Dates

# ─── Configuration ───────────────────────────────────────────────────────────

const GEMINI_API_KEY = get(ENV, "GEMINI_API_KEY", "")
const INPUT_FILE = "papers.json"
const OUTPUT_FILE = "papers_final.md"
const GEMINI_MODEL = "gemini-3-flash-preview"
const GEMINI_URL_BASE = "https://generativelanguage.googleapis.com/v1beta/models/$GEMINI_MODEL:generateContent"

const FEATURED_SOURCE = "CrossRef/Featured"

# ─── Load Green Authors ──────────────────────────────────────────────────────

const CROSSREF_MAILTO = "lemma@princeton.edu"

function load_green_authors(filename::String)
    entries = Tuple{Union{String,Nothing}, String}[]   # (orcid_or_nothing, name)
    isfile(filename) || return entries
    for line in readlines(filename)
        line = strip(line)
        isempty(line) && continue
        m = match(r"^(\d{4}-\d{4}-\d{4}-[\dX]{4})\s*-\s*(.+)$", line)
        if m !== nothing
            push!(entries, (m.captures[1], lowercase(strip(m.captures[2]))))
        else
            push!(entries, (nothing, lowercase(line)))
        end
    end
    return entries
end

const GREEN_AUTHOR_ENTRIES = load_green_authors("greenauthors.txt")

"""Normalize a name for fuzzy matching: strip accents, periods, hyphens."""
function normalize_name(s::AbstractString)::String
    s = lowercase(s)
    # Strip common accented chars to ASCII equivalents
    for (from, to) in [('á','a'),('à','a'),('â','a'),('ä','a'),('ã','a'),
                        ('é','e'),('è','e'),('ê','e'),('ë','e'),
                        ('í','i'),('ì','i'),('î','i'),('ï','i'),
                        ('ó','o'),('ò','o'),('ô','o'),('ö','o'),('õ','o'),
                        ('ú','u'),('ù','u'),('û','u'),('ü','u'),
                        ('ñ','n'),('ç','c')]
        s = replace(s, from => to)
    end
    s = replace(s, r"[.\-']" => " ")   # periods, hyphens, apostrophes → spaces
    s = replace(s, r"\s+" => " ")
    return strip(s)
end

"""Split an author list string into individual author names."""
function split_authors(authors_str::AbstractString)::Vector{String}
    # Handle both comma-separated (CrossRef/RSS) and semicolon-separated (bioRxiv)
    delim = occursin(";", authors_str) ? ";" : ","
    return filter(!isempty, strip.(split(authors_str, delim)))
end

"""Check if a single author name matches a green author name.
Handles middle initials, name order swaps, and accent differences."""
function name_matches(green_name::AbstractString, paper_author::AbstractString)::Bool
    gn = normalize_name(green_name)
    pa = normalize_name(paper_author)
    g_parts = split(gn)
    p_parts = split(pa)
    length(g_parts) < 2 && return occursin(gn, pa)
    length(p_parts) < 2 && return false
    g_first, g_last = g_parts[1], g_parts[end]
    p_first, p_last = p_parts[1], p_parts[end]
    # Forward match: same first and last name
    if g_first == p_first && g_last == p_last
        return true
    end
    # Swapped: "Last, First" format
    if g_first == p_last && g_last == p_first
        return true
    end
    # First initial match: "D." or "D" matches "David"
    if g_last == p_last
        shorter, longer = length(g_first) <= length(p_first) ? (g_first, p_first) : (p_first, g_first)
        if length(shorter) == 1 && startswith(longer, shorter)
            return true
        end
    end
    return false
end

# Cache CrossRef author data per DOI to avoid redundant API calls
const _crossref_author_cache = Dict{String, Union{Nothing, Vector{String}}}()

"""Fetch ORCID list for a DOI from CrossRef (cached)."""
function _get_crossref_orcids(doi::AbstractString)::Union{Nothing, Vector{String}}
    doi = replace(doi, r"^https?://doi\.org/" => "")
    haskey(_crossref_author_cache, doi) && return _crossref_author_cache[doi]
    try
        sleep(0.1)  # rate-limit CrossRef calls
        resp = HTTP.get("https://api.crossref.org/works/$doi?mailto=$CROSSREF_MAILTO";
                        readtimeout=10, status_exception=false)
        if resp.status != 200
            _crossref_author_cache[doi] = nothing
            return nothing
        end
        data = JSON3.read(String(resp.body))
        authors = get(get(data, :message, Dict()), :author, [])
        orcids = String[]
        for a in authors
            orcid_url = string(get(a, :ORCID, ""))
            !isempty(orcid_url) && push!(orcids, orcid_url)
        end
        _crossref_author_cache[doi] = orcids
        return orcids
    catch
        _crossref_author_cache[doi] = nothing
        return nothing
    end
end

"""Check if a paper's DOI has a matching ORCID in CrossRef metadata.
Returns :verified, :not_found, or :error."""
function verify_orcid_via_crossref(doi::AbstractString, expected_orcid::String)::Symbol
    isempty(doi) && return :error
    orcids = _get_crossref_orcids(doi)
    orcids === nothing && return :error
    for orcid_url in orcids
        occursin(expected_orcid, orcid_url) && return :verified
    end
    return :not_found
end

"""Check if any green author name matches the paper's author string.
Returns true if a match is found. For names with an ORCID, verifies via CrossRef
when a DOI is available, to avoid false positives from common names."""
function check_green_author(authors_str::AbstractString, doi::AbstractString)::Bool
    paper_authors = split_authors(authors_str)
    for (i, (orcid, name)) in enumerate(GREEN_AUTHOR_ENTRIES)
        matched = any(pa -> name_matches(name, pa), paper_authors)
        matched || continue
        # If this entry has an ORCID and we have a DOI, verify to avoid false positives
        if orcid !== nothing && !isempty(doi)
            result = verify_orcid_via_crossref(doi, orcid)
            if result == :verified
                return true
            elseif result == :not_found
                # ORCID not on this paper — likely a different person with same name
                continue
            else
                # CrossRef lookup failed — trust the name match as fallback
                return true
            end
        end
        # No ORCID to verify against, trust the name match
        return true
    end
    return false
end

# ─── Gemini API calls ───────────────────────────────────────────────────────

"""Call Gemini API with a prompt and return the text response."""
function gemini_generate(prompt::String; max_retries=3)::String
    isempty(GEMINI_API_KEY) && return ""

    body = Dict(
        "contents" => [Dict(
            "parts" => [Dict("text" => prompt)]
        )]
    )
    url = "$GEMINI_URL_BASE?key=$(HTTP.escapeuri(GEMINI_API_KEY))"

    for attempt in 1:max_retries
        try
            resp = HTTP.post(url,
                ["Content-Type" => "application/json"],
                JSON3.write(body);
                readtimeout=30,
                status_exception=false)

            if resp.status == 429
                wait_secs = 5 * attempt
                sleep(wait_secs)
                continue
            end

            if resp.status == 200
                data = JSON3.read(String(resp.body))
                candidates = get(data, :candidates, [])
                if !isempty(candidates)
                    content = get(first(candidates), :content, Dict())
                    parts = get(content, :parts, [])
                    if !isempty(parts)
                        return strip(string(get(first(parts), :text, "")))
                    end
                end
                return ""
            else
                attempt == max_retries && return ""
                sleep(2 * attempt)
            end
        catch e
            attempt == max_retries && (println("  Gemini API error: $e"); return "")
            sleep(2 * attempt)
        end
    end
    return ""
end

"""Classify paper as biophysics (true/false) using Gemini."""
function classify_paper(title::String, abstract_text::String)
    prompt = """
Classify if the provided paper is "Biophysics".

Title: $title
Abstract: $abstract_text

INCLUSION CRITERIA:
- Investigates physical mechanisms (forces, dynamics, thermodynamics, entropy).
- Covers soft/active matter, condensates, or polymer physics in biology.
- Uses quantitative modeling/simulations of biological phenomena.
- Novel physical imaging/instrumentation (Lattice light sheet, etc).
- Novel use of physics to understand biological systems.

EXCLUSION CRITERIA:
- Not about biology or soft matter (quantum mechanics, astronomy, particle physics).
- SOLID-STATE & HARD CONDENSED MATTER: Polarons, superconductivity, topological insulators, magnetism, purely electronic/magnetic properties of inorganic materials or low-dimensional systems.
- Static structural biology (routine crystallography).
- Purely clinical, medical, or descriptive genetics/omics.
- Pure materials science with no biological application.
- Papers with "Simulation" in the name
- SOFTWARE: Papers focused on introducing or improving a software package, python framework, etc.
- NETWORK ECOLOGY: Food webs, trophic levels, ecosystem robustness, predator-prey population graphs.
- POPULATION DYNAMICS: Lotka-Volterra models, species abundance distributions, biodiversity statistics.
- HIGH-THROUGHPUT SCREENING: "Virtual screening," "Molecular docking studies," or "In silico characterization" of large lists of proteins without deep mechanistic insight.
- ROUTINE MD or CryoEM: The main method is CryoEM, or MD, as stated in the abstract, and there is no deeper physics
- DATABASES: Papers that just present a list of predicted structures (e.g., "Genome-wide analysis of...").
- Contains the word CryoEM, Structural, or MD in the title.
- NON-RESEARCH CONTENT: Reviews, Commentaries, Perspectives, Editorials, News, Withdrawn, Retracted, Author Summaries.
- PHILOSOPHY & HISTORY: Philosophical essays, epistemological discussions, or historical reviews about biophysics (e.g., "the relation between biology and physics", "dialectical materialism"), rather than presenting new quantitative biological models or physical experiments.

If unsure, default to TRUE.
Reply with a single word: TRUE or FALSE.
"""

    try
        result_raw = gemini_generate(prompt)
        result = uppercase(strip(result_raw))
        if result == "TRUE"
            return true, "AI Approved"
        elseif result == "FALSE"
            return false, "AI Rejected"
        elseif isempty(result)
            return true, "AI Unavailable Fallback"
        else
            return true, "AI Ambiguous Fallback"
        end
    catch e
        println("  Error classifying '$(first(title, 30))...': $e")
        return true, "Error Fallback: $e"
    end
end

"""Summarize paper using Gemini."""
function summarize_paper(title::String, abstract_text::String)::String
    prompt = """
Provide a one sentence summary of the following paper.
Do not start with a preamble "This study suggests", "The paper describes", "Researchers find", or similar phrases.
Start directly with the subject of the summary. Assume the reader has already read the title and does not need information provided in the title.

Title: $title
Abstract: $abstract_text
"""

    try
        result = gemini_generate(prompt)
        return isempty(result) ? "Summary unavailable." : result
    catch e
        println("  Error summarizing '$(first(title, 30))...': $e")
        return "Summary unavailable."
    end
end

function escape_markdown_text(s::AbstractString)::String
    out = replace(s, "\\" => "\\\\")
    out = replace(out, "*" => "\\*", "_" => "\\_", "`" => "\\`")
    out = replace(out, "[" => "\\[", "]" => "\\]")
    out = replace(out, "\n" => " ")
    return strip(out)
end

function markdown_link_target(url::AbstractString)::String
    u = strip(url)
    isempty(u) && return "#"
    return "<$u>"
end

# ─── Paper processing ───────────────────────────────────────────────────────

"""
Process one paper: check green authors, then AI classify.
Returns: (paper_dict, category) where category is :featured, :regular, or nothing.
"""
function process_one_paper(paper)
    try
        title = string(get(paper, :title, ""))
        abstract_text = string(get(paper, :abstract, ""))
        source = string(get(paper, :source, ""))

        # 1. Featured papers are identified by source tag OR by having a green author
        authors_str = string(get(paper, :authors, ""))
        doi_raw = get(paper, :doi, nothing)
        doi = doi_raw === nothing ? "" : string(doi_raw)
        is_green_author = check_green_author(authors_str, doi)

        if source == FEATURED_SOURCE || is_green_author
            summary = summarize_paper(title, abstract_text)
            return (paper, summary, :featured)
        end

        # 2. AI Classification for all other papers
        is_biophysics, reason = classify_paper(title, abstract_text)
        if is_biophysics
            summary = summarize_paper(title, abstract_text)
            return (paper, summary, :regular)
        else
            return (paper, "", nothing)
        end
    catch e
        println("Error processing $(first(string(get(paper, :title, "")), 30))...: $e")
        return (paper, "", nothing)
    end
end

# ─── Main ────────────────────────────────────────────────────────────────────

function main()
    if isempty(GEMINI_API_KEY)
        println("Error: GEMINI_API_KEY environment variable not set.")
        return
    end

    println("Loading papers from $INPUT_FILE...")
    if !isfile(INPUT_FILE)
        println("Error: $INPUT_FILE not found. Run fetch_papers.jl first.")
        return
    end

    papers = JSON3.read(read(INPUT_FILE, String))

    featured_papers = []
    regular_papers = []
    total = length(papers)

    println("Processing $total papers with parallel execution (10 workers)...")

    # Process papers with async tasks (batched for rate limiting)
    results = Vector{Any}(undef, total)
    completed = Threads.Atomic{Int}(0)
    print_lock = ReentrantLock()

    # Use asyncmap with limited concurrency
    sem = Base.Semaphore(10)
    @sync begin
        for (i, paper) in enumerate(papers)
            @async begin
                Base.acquire(sem)
                try
                    try
                        results[i] = process_one_paper(paper)
                    catch e
                        println("Error in worker for paper $i: $e")
                        results[i] = (paper, "", nothing)
                    end

                    # Print progress as each paper completes
                    Threads.atomic_add!(completed, 1)
                    n = completed[]
                    _, summary, category = results[i]
                    title_str = first(string(get(paper, :title, "")), 40)

                    lock(print_lock) do
                        if category == :featured
                            println("[$n/$total] ✅ FEATURED: $(title_str)...")
                        elseif category == :regular
                            println("[$n/$total] 🟢 KEPT: $(title_str)...")
                        else
                            println("[$n/$total] ❌ SKIPPED: $(title_str)...")
                        end
                        n % 10 == 0 && println("   ... $n/$total done.")
                        flush(stdout)
                    end
                finally
                    Base.release(sem)
                end
            end
        end
    end

    # Collect results
    for (i, result) in enumerate(results)
        if !isassigned(results, i)
            continue
        end
        paper, summary, category = result
        if category == :featured
            push!(featured_papers, (paper=paper, summary=summary))
        elseif category == :regular
            push!(regular_papers, (paper=paper, summary=summary))
        end
    end

    # Deduplicate: remove regular papers that also appear in featured list
    featured_titles = Set(lowercase(string(get(item.paper, :title, ""))) for item in featured_papers)
    filter!(item -> lowercase(string(get(item.paper, :title, ""))) ∉ featured_titles, regular_papers)

    # Sort regular papers: journal papers first, then arXiv/bioRxiv
    preprint_sources = Set(["arXiv", "bioRxiv"])
    sort!(regular_papers; by=item -> string(get(item.paper, :source, "")) in preprint_sources ? 1 : 0)

    # Generate output
    all_final = vcat(featured_papers, regular_papers)
    total_kept = length(all_final)

    source_counts = Dict{String, Int}()
    for item in all_final
        src = string(get(item.paper, :source, ""))
        source_counts[src] = get(source_counts, src, 0) + 1
    end
    sorted_sources = sort(collect(source_counts); by=x -> x[2], rev=true)
    breakdown = join(["$(src): $(cnt)" for (src, cnt) in sorted_sources], ", ")

    # date_str should reflect the most recent Monday rather than today
    # (so running on Fri 6 Mar -> use Mon 2 Mar).
    today = Dates.today()
    dow = Dates.dayofweek(today)      # 1=Monday, 7=Sunday
    prev_monday = today - Dates.Day(dow - 1)
    date_str = Dates.format(prev_monday, "u d 'yy")

    println("\nGenerating $OUTPUT_FILE with $total_kept papers...")
    println("Source breakdown: $breakdown")

    open(OUTPUT_FILE, "w") do f
        # YAML frontmatter
        println(f, "---")
        println(f, "title: \"$date_str\"")
        println(f, "format:")
        println(f, "  html:")
        println(f, "    toc: false")
        println(f, "---\n")

        # Featured Papers
        if !isempty(featured_papers)
            println(f, "# Featured Papers\n")
            println(f, "::: {.grid}\n")
            for item in featured_papers
                title = escape_markdown_text(string(get(item.paper, :title, "")))
                authors = escape_markdown_text(string(get(item.paper, :authors, "")))
                link = markdown_link_target(string(get(item.paper, :link, "")))
                println(f, "::: {.g-col-12 .g-col-md-6}")
                println(f, "#### [$title]($link)")
                println(f, "*$authors* <br>")
                println(f, item.summary)
                println(f, ":::\n")
            end
            println(f, ":::\n")
        end

        # Regular Papers
        if !isempty(regular_papers)
            println(f, "## More Papers\n")
            for item in regular_papers
                title = escape_markdown_text(string(get(item.paper, :title, "")))
                authors = escape_markdown_text(string(get(item.paper, :authors, "")))
                link = markdown_link_target(string(get(item.paper, :link, "")))
                println(f, "#### [$title]($link)")
                println(f, "*$authors* <br>")
                println(f, "$(item.summary)\n")
            end
        end
    end

    println("Done!")
end

# ─── Entry point ─────────────────────────────────────────────────────────────
main()