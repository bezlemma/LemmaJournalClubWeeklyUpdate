#!/usr/bin/env julia
# filter_papers.jl — Julia port of filter_papers.py
# AI-powered paper filtering and summarization using Gemini REST API.
# Input:  papers.json
# Output: papers_final.md

using JSON3
using HTTP
using Dates

# ─── Configuration ───────────────────────────────────────────────────────────

const GEMINI_API_KEY = get(ENV, "GEMINI_API_KEY", "")
const INPUT_FILE = "papers.json"
const OUTPUT_FILE = "papers_final.md"
const GREEN_AUTHORS_FILE = "greenauthors.txt"
const GEMINI_MODEL = "gemini-3-flash-preview"
const GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/$GEMINI_MODEL:generateContent?key=$GEMINI_API_KEY"

if isempty(GEMINI_API_KEY)
    println("Error: GEMINI_API_KEY environment variable not set.")
    exit(1)
end

# ─── Author matching ────────────────────────────────────────────────────────

"""
Normalize author name to (last_name, first_initial) for matching.
Handles: "First Last", "Last, First", "Last, F.", "F. Last".
"""
function normalize_author_identifier(name_str::AbstractString)
    name_str = strip(name_str)
    isempty(name_str) && return nothing

    clean_name = replace(name_str, "." => " ")
    parts = split(replace(clean_name, "," => " "))
    parts = filter(!isempty, parts)
    isempty(parts) && return nothing

    if occursin(",", name_str)
        # "Last, First" format
        before_comma = strip(split(name_str, ",")[1])
        last = split(before_comma)[end]
        after_comma = strip(split(name_str, ",")[2])
        first_initial = isempty(after_comma) ? "" : string(after_comma[1])
    else
        # "First Last" or "F Last"
        last = parts[end]
        first_initial = string(parts[1][1])
    end

    return (lowercase(last), lowercase(first_initial))
end

const ORCID_LINE_PATTERN = r"^\d{4}-\d{4}-\d{4}-[\dX]{4}\s*-\s*(.+)$"

"""
Load green authors as a set of (last_name, first_initial) tuples.
"""
function load_green_authors_identifiers(filename::String)
    identifiers = Set{Tuple{String,String}}()
    isfile(filename) || (println("Warning: $filename not found."); return identifiers)

    for line in readlines(filename)
        line = strip(line)
        isempty(line) && continue
        m = match(ORCID_LINE_PATTERN, line)
        name = m !== nothing ? strip(m.captures[1]) : line
        ident = normalize_author_identifier(name)
        ident !== nothing && push!(identifiers, ident)
    end
    return identifiers
end

const GREEN_AUTHORS_IDENTIFIERS = load_green_authors_identifiers(GREEN_AUTHORS_FILE)

"""Check if any author in the paper matches a green author."""
function matches_green_author(authors_str::String)::Bool
    isempty(authors_str) && return false

    # Strategy 1: Full string as single author
    full_ident = normalize_author_identifier(authors_str)
    full_ident !== nothing && full_ident in GREEN_AUTHORS_IDENTIFIERS && return true

    # Strategy 2: Split and check
    if occursin(";", authors_str)
        raw_list = split(authors_str, ";")
    else
        raw_list = split(authors_str, r",|\s+and\s+")
    end

    for raw_auth in raw_list
        paper_ident = normalize_author_identifier(String(strip(raw_auth)))
        paper_ident !== nothing && paper_ident in GREEN_AUTHORS_IDENTIFIERS && return true
    end

    return false
end

# ─── Gemini API calls ───────────────────────────────────────────────────────

"""Call Gemini API with a prompt and return the text response."""
function gemini_generate(prompt::String; max_retries=3)::String
    body = Dict(
        "contents" => [Dict(
            "parts" => [Dict("text" => prompt)]
        )]
    )

    for attempt in 1:max_retries
        try
            resp = HTTP.post(GEMINI_URL,
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
- NON-RESEARCH CONTENT: Reviews, Commentaries, Perspectives, Editorials, News, Withdrawn, Retracted, Author Summaries

If unsure, default to TRUE.
Reply with a single word: TRUE or FALSE.
"""

    try
        result = uppercase(gemini_generate(prompt))
        if occursin("TRUE", result)
            return true, "AI Approved"
        else
            return false, "AI Rejected"
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

# ─── Paper processing ───────────────────────────────────────────────────────

"""
Process one paper: check green authors, then AI classify.
Returns: (paper_dict, category) where category is :featured, :regular, or nothing.
"""
function process_one_paper(paper)
    try
        authors = string(get(paper, :authors, ""))
        title = string(get(paper, :title, ""))
        abstract_text = string(get(paper, :abstract, ""))

        # 1. Check Green Authors
        if matches_green_author(authors)
            summary = summarize_paper(title, abstract_text)
            return (paper, summary, :featured)
        end

        # 2. AI Classification
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
                    results[i] = process_one_paper(paper)

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
        paper, summary, category = result
        if category == :featured
            push!(featured_papers, (paper=paper, summary=summary))
        elseif category == :regular
            push!(regular_papers, (paper=paper, summary=summary))
        end
    end

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

    date_str = Dates.format(now(), "udd 'yy")

    println("\nGenerating $OUTPUT_FILE with $total_kept papers...")

    open(OUTPUT_FILE, "w") do f
        # YAML frontmatter
        println(f, "---")
        println(f, "title: \"Weekly Update $date_str\"")
        println(f, "format:")
        println(f, "  html:")
        println(f, "    toc: false")
        println(f, "---\n")

        # Featured Papers
        if !isempty(featured_papers)
            println(f, "# Featured Papers\n")
            println(f, "::: {.grid}\n")
            for item in featured_papers
                println(f, "::: {.g-col-12 .g-col-md-6}")
                println(f, "#### [$(get(item.paper, :title, ""))]($(get(item.paper, :link, "")))")
                println(f, "*$(get(item.paper, :authors, ""))* <br>")
                println(f, item.summary)
                println(f, ":::\n")
            end
            println(f, ":::\n")
        end

        # Regular Papers
        if !isempty(regular_papers)
            println(f, "## More Papers\n")
            for item in regular_papers
                println(f, "#### [$(get(item.paper, :title, ""))]($(get(item.paper, :link, "")))")
                println(f, "*$(get(item.paper, :authors, ""))* <br>")
                println(f, "$(item.summary)\n")
            end
        end
    end

    println("Done!")
end

# ─── Entry point ─────────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
