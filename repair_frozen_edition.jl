using JSON3, Dates
include(joinpath(@__DIR__, "edition_integrity.jl"))
include(joinpath(@__DIR__, "selection_policy.jl"))
using .EditionIntegrity
using .SelectionPolicy

const INPUT_FILE = get(ENV, "EDITION_PAPERS_FILE", "papers.json")
const OUTPUT_FILE = get(ENV, "EDITION_MARKDOWN_FILE", "papers_final.md")
const DECISIONS_DIR = get(ENV, "EDITION_DECISIONS_DIR", "TrainingData")
const EDITION_ID = strip(get(ENV, "EDITION_ID", ""))
const WINDOW_END_DATE = strip(get(ENV, "WINDOW_END_DATE", EDITION_ID))
const DECISION_FILE = strip(get(ENV, "DECISION_FILE", ""))
const MIN_SELECTION_FRACTION = something(tryparse(Float64, get(ENV, "MIN_SELECTION_FRACTION", "0.50")), 0.50)

field_text(record, field::Symbol)::String = strip(string(get(record, field, "")))

function escape_markdown_text(value::AbstractString)::String
    out = replace(value, "\\" => "\\\\")
    out = replace(out, "*" => "\\*", "_" => "\\_", "`" => "\\`")
    out = replace(out, "[" => "\\[", "]" => "\\]")
    return strip(replace(out, "\n" => " "))
end

markdown_link_target(value::AbstractString)::String = "<$(strip(value))>"

function write_markdown(featured, regular, edition_date::Date, window_end_date::Date)
    date_str = Dates.format(edition_date, "u d yy")
    open(OUTPUT_FILE, "w") do output
        println(output, "---")
        println(output, "title: \"$date_str\"")
        println(output, "edition_id: \"$(Dates.format(edition_date, "yyyy-mm-dd"))\"")
        println(output, "window_end_date: \"$(Dates.format(window_end_date, "yyyy-mm-dd"))\"")
        println(output, "format:")
        println(output, "  html:")
        println(output, "    toc: false")
        println(output, "---\n")

        if !isempty(featured)
            println(output, "# Featured Papers\n")
            println(output, "::: {.grid}\n")
            for item in featured
                println(output, "::: {.g-col-12 .g-col-md-6}")
                println(output, "#### [$(escape_markdown_text(field_text(item.paper, :title)))]" *
                                "($(markdown_link_target(field_text(item.paper, :link))))")
                println(output, "*$(escape_markdown_text(field_text(item.paper, :authors)))* <br>")
                println(output, item.summary)
                println(output, ":::\n")
            end
            println(output, ":::\n")
        end

        if !isempty(regular)
            println(output, "## More Papers\n")
            for item in regular
                println(output, "#### [$(escape_markdown_text(field_text(item.paper, :title)))]" *
                                "($(markdown_link_target(field_text(item.paper, :link))))")
                println(output, "*$(escape_markdown_text(field_text(item.paper, :authors)))* <br>")
                println(output, "$(item.summary)\n")
            end
        end
    end
end

function main()
    isempty(EDITION_ID) && error("EDITION_ID is required to repair a frozen edition.")
    edition_date = try
        Date(EDITION_ID)
    catch
        error("EDITION_ID must use YYYY-MM-DD format, received '$EDITION_ID'.")
    end
    window_end_date = try
        Date(WINDOW_END_DATE)
    catch
        error("WINDOW_END_DATE must use YYYY-MM-DD format, received '$WINDOW_END_DATE'.")
    end
    decision_file = isempty(DECISION_FILE) ?
        joinpath(DECISIONS_DIR, "filter_decisions_$(WINDOW_END_DATE).jsonl") : DECISION_FILE
    isfile(INPUT_FILE) || error("Frozen candidate file $INPUT_FILE does not exist.")
    isfile(decision_file) || error("Frozen decision file $decision_file does not exist.")

    raw_papers = collect(JSON3.read(read(INPUT_FILE, String)))
    papers, removed = sanitize_candidates(raw_papers, window_end_date)
    println("Frozen-edition repair retained $(length(papers))/$(length(raw_papers)) valid candidates.")
    for item in removed
        println("  • Removed $(isempty(item.title) ? "candidate #$(item.index)" : item.title)")
        for issue in item.issues
            println("      - $issue")
        end
    end
    length(papers) >= MIN_EDITION_PAPERS || error(
        "Frozen-edition repair left only $(length(papers)) valid candidates; minimum is $MIN_EDITION_PAPERS."
    )

    by_link = Dict(field_text(paper, :link) => paper for paper in papers)
    kept_records = Dict{String, Any}[]
    selected_links = Set{String}()
    decided_links = Set{String}()
    featured = Any[]
    regular = Any[]
    recall_downgrades = 0

    for line in eachline(decision_file)
        isempty(strip(line)) && continue
        record = JSON3.read(line)
        link = field_text(record, :link)
        haskey(by_link, link) || continue
        link in decided_links && error("Frozen decision file contains duplicate link '$link'.")
        push!(decided_links, link)

        mutable_record = Dict{String, Any}(string(key) => value for (key, value) in pairs(record))
        mutable_record["date"] = string(publication_date(by_link[link]))

        label = lowercase(field_text(record, :label))
        label in ("featured", "regular", "rejected") || error(
            "Frozen decision for '$link' has invalid label '$label'."
        )
        score = try Float64(get(record, :local_score, 0.0)) catch; 0.0 end
        if label == "regular" && field_text(record, :classifier_reason) == "AI Recall Approved" &&
           field_text(record, :score_policy) == SCORE_POLICY_VERSION &&
           !recall_approval_supported(by_link[link], score)
            label = "rejected"
            mutable_record["label"] = "rejected"
            mutable_record["classifier_reason"] = "AI Recall Rejected by Learning Gate"
            mutable_record["summary"] = ""
            recall_downgrades += 1
        end
        push!(kept_records, mutable_record)

        label == "rejected" && continue
        link in selected_links && error("Frozen selected decisions contain duplicate link '$link'.")
        push!(selected_links, link)
        summary = field_text(record, :summary)
        item = (paper=by_link[link], summary=summary, score=score)
        label == "featured" ? push!(featured, item) : push!(regular, item)
    end

    missing_decisions = setdiff(Set(keys(by_link)), decided_links)
    isempty(missing_decisions) || error(
        "Frozen decision file is missing $(length(missing_decisions)) valid candidate(s); refusing a partial repair."
    )

    preprint_sources = Set(["arXiv", "bioRxiv", "medRxiv"])
    sort!(regular; by=item -> (-item.score,
                              field_text(item.paper, :source) in preprint_sources ? 1 : 0,
                              lowercase(field_text(item.paper, :title))))
    selected = vcat(featured, regular)
    issues = selected_edition_issues(
        selected,
        window_end_date;
        candidate_count=length(papers),
        min_fraction=MIN_SELECTION_FRACTION,
    )
    isempty(issues) || error("Frozen-edition repair failed integrity validation:\n" *
                             join(["  • $issue" for issue in issues], "\n"))

    open(INPUT_FILE, "w") do output
        JSON3.pretty(output, papers)
    end
    open(decision_file, "w") do output
        for record in kept_records
            println(output, JSON3.write(record))
        end
    end
    write_markdown(featured, regular, edition_date, window_end_date)

    dates = sort([publication_date(item.paper) for item in selected])
    println("Frozen-edition repair: PASS — $(length(selected)) papers, dates $(first(dates)) through $(last(dates)); " *
            "$recall_downgrades unsupported recall approvals removed; no AI calls made.")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
