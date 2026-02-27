using JSON3, HTTP, Dates

# ─── Configuration ───────────────────────────────────────────────────────────

const GEMINI_API_KEY = get(ENV, "GEMINI_API_KEY", "")
const INPUT_FILE = "papers.json"
const OUTPUT_FILE = "papers_final.md"
const GEMINI_MODEL = "gemini-3-flash-preview"
const GEMINI_URL_BASE = "https://generativelanguage.googleapis.com/v1beta/models/$GEMINI_MODEL:generateContent"

const FEATURED_SOURCE = "CrossRef/Featured"

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
- Not about biology or soft matter (quantum mechanics, astronomy, particle physics)
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

        # 1. Featured papers are identified by source tag from ORCID-based fetch
        if source == FEATURED_SOURCE
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

    date_str = Dates.format(now(), "u d 'yy")

    println("\nGenerating $OUTPUT_FILE with $total_kept papers...")
    println("Source breakdown: $breakdown")

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
                title = escape_markdown_text(string(get(item.paper, :title, "")))
                authors = escape_markdown_text(string(get(item.paper, :authors, "")))
                link = markdown_link_target(string(get(item.paper, :link, "")))
                println(f, "::: {.g-col-12 .g-col-md-6}")
                println(f, "#### [$title]\n($link)")
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
                println(f, "#### [$title]\n($link)")
                println(f, "*$authors* <br>")
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
