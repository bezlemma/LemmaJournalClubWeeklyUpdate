using JSON3, Dates
include(joinpath(@__DIR__, "edition_integrity.jl"))
using .EditionIntegrity

const INPUT_FILE = get(ENV, "EDITION_PAPERS_FILE", "papers.json")
const OUTPUT_FILE = get(ENV, "EDITION_MARKDOWN_FILE", "papers_final.md")
const DECISIONS_DIR = get(ENV, "EDITION_DECISIONS_DIR", "TrainingData")
const EDITION_ID = strip(get(ENV, "EDITION_ID", ""))
const MIN_PAPERS = something(tryparse(Int, get(ENV, "MIN_EDITION_PAPERS", "50")), 50)
const MIN_SELECTION_FRACTION = something(tryparse(Float64, get(ENV, "MIN_SELECTION_FRACTION", "0.50")), 0.50)

function require_edition_date()::Date
    isempty(EDITION_ID) && error("EDITION_ID is required for edition validation.")
    return try
        Date(EDITION_ID)
    catch
        error("EDITION_ID must use YYYY-MM-DD format, received '$EDITION_ID'.")
    end
end

function main()
    edition_date = require_edition_date()
    decision_file = joinpath(DECISIONS_DIR, "filter_decisions_$(EDITION_ID).jsonl")
    isfile(INPUT_FILE) || error("Edition integrity gate: $INPUT_FILE does not exist.")
    isfile(OUTPUT_FILE) || error("Edition integrity gate: $OUTPUT_FILE does not exist.")
    isfile(decision_file) || error("Edition integrity gate: $decision_file does not exist.")

    papers = collect(JSON3.read(read(INPUT_FILE, String)))
    by_link = Dict{String, Any}()
    for paper in papers
        link = strip(string(get(paper, :link, "")))
        isempty(link) || (by_link[link] = paper)
    end

    selected = Any[]
    unmatched = String[]
    for line in eachline(decision_file)
        isempty(strip(line)) && continue
        record = JSON3.read(line)
        lowercase(string(get(record, :label, ""))) in ("featured", "regular") || continue
        link = strip(string(get(record, :link, "")))
        if !haskey(by_link, link)
            push!(unmatched, "$(get(record, :title, "Untitled")) — selected decision has no matching candidate metadata")
            continue
        end
        push!(selected, (paper=by_link[link], summary=string(get(record, :summary, ""))))
    end

    issues = selected_edition_issues(
        selected,
        edition_date;
        min_papers=MIN_PAPERS,
        candidate_count=length(papers),
        min_fraction=MIN_SELECTION_FRACTION,
    )
    append!(issues, unmatched)

    markdown = read(OUTPUT_FILE, String)
    heading_count = count(line -> startswith(strip(line), "#### "), split(markdown, '\n'))
    heading_count == length(selected) || push!(issues,
        "generated markdown contains $heading_count paper headings but decisions select $(length(selected)) papers")

    for item in selected
        title = strip(string(get(item.paper, :title, "")))
        link = strip(string(get(item.paper, :link, "")))
        occursin(link, markdown) || push!(issues, "$title — link is missing from generated markdown")
        occursin(strip(string(item.summary)), markdown) || push!(issues, "$title — validated summary is missing from generated markdown")
    end

    if !isempty(issues)
        println("Edition integrity gate failed with $(length(issues)) issue(s):")
        for issue in issues
            println("  • $issue")
        end
        error("Refusing to publish or email an invalid edition.")
    end

    dates = sort([publication_date(item.paper) for item in selected])
    println("Edition integrity: PASS — $(length(selected)) papers, dates $(first(dates)) through $(last(dates)), " *
            "all required fields and summaries complete.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
