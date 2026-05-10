include(joinpath(@__DIR__, "score_papers.jl"))

using Dates
using JSON3

const INPUT_FILE = "papers.json"
const FINAL_FILE = "papers_final.md"
const DECISIONS_DIR = "TrainingData"
const PREVIOUS_WEEKS_DIR = "PreviousWeeks"

function normalize_doi(raw::AbstractString)::String
    s = lowercase(strip(raw))
    s = replace(s, r"^https?://(dx\.)?doi\.org/" => "")
    s = replace(s, r"^doi:\s*" => "")
    m = match(r"10\.\d{4,9}/[-._;()/:a-z0-9]+", s)
    m === nothing && return ""
    return strip(replace(m.match, r"[\]\).,;]+$" => ""))
end

function normalize_link(raw::AbstractString)::String
    s = lowercase(strip(raw))
    s = replace(s, r"^<" => "")
    s = replace(s, r">\s*$" => "")
    s = replace(s, r"\?rss=yes$" => "")
    s = replace(s, r"#.*$" => "")
    s = replace(s, r"/+$" => "")
    return s
end

function normalize_title(raw::AbstractString)::String
    s = lowercase(PaperScorer.strip_markdown(raw))
    return replace(s, r"[^a-z0-9]+" => "")
end

function candidate_keys(; title::AbstractString="", link::AbstractString="", doi::AbstractString="")::Set{String}
    keys = Set{String}()
    nd = normalize_doi(doi)
    !isempty(nd) && push!(keys, "doi:$nd")
    nd_link = normalize_doi(link)
    !isempty(nd_link) && push!(keys, "doi:$nd_link")
    nl = normalize_link(link)
    !isempty(nl) && push!(keys, "link:$nl")
    nt = normalize_title(title)
    !isempty(nt) && push!(keys, "title:$nt")
    return keys
end

function selected_lookup(final_file::AbstractString)
    lookup = Dict{String, String}()
    for doc in PaperScorer.parse_qmd_file(final_file)
        for key in candidate_keys(title=doc.title, link=doc.url)
            lookup[key] = doc.section
        end
    end
    return lookup
end

function item_string(item, key::Symbol)::String
    value = get(item, key, "")
    value === nothing && return ""
    return string(value)
end

function item_keys(item)::Set{String}
    return candidate_keys(
        title=item_string(item, :title),
        link=item_string(item, :link),
        doi=item_string(item, :doi),
    )
end

function selected_section(item, lookup::Dict{String, String})::Union{String, Nothing}
    for key in item_keys(item)
        haskey(lookup, key) && return lookup[key]
    end
    return nothing
end

function date_from_final(final_file::AbstractString)::Date
    title_line = ""
    for line in eachline(final_file)
        if startswith(strip(line), "title:")
            title_line = strip(line)
            break
        end
    end
    m = match(r"\"([A-Za-z]{3})\s+(\d{1,2})\s+(\d{2,4})\"", title_line)
    if m !== nothing
        mon, day, year = m.captures
        yr = length(year) == 2 ? parse(Int, "20" * year) : parse(Int, year)
        return Date("$(mon) $(day) $(yr)", dateformat"u d yyyy")
    end

    today = Dates.today()
    return today - Day(dayofweek(today) - 1)
end

function archive_name(week::Date)::String
    return Dates.format(week, "uuu") * Dates.format(week, "dd") * "_" * Dates.format(week, "yyyy") * ".qmd"
end

function training_weight(section::Union{String, Nothing})::Float64
    section == "featured" && return 2.0
    section == "some" && return 2.0
    section == "more" && return 1.0
    return 0.0
end

function record_final_decisions(; input_file::AbstractString=INPUT_FILE,
                                  final_file::AbstractString=FINAL_FILE,
                                  decisions_dir::AbstractString=DECISIONS_DIR,
                                  previous_weeks_dir::AbstractString=PREVIOUS_WEEKS_DIR)
    isfile(input_file) || error("$input_file not found")
    isfile(final_file) || error("$final_file not found")

    week = date_from_final(final_file)
    lookup = selected_lookup(final_file)
    papers = JSON3.read(read(input_file, String))
    mkpath(decisions_dir)
    decision_file = joinpath(decisions_dir, "final_decisions_$(Dates.format(week, "yyyy-mm-dd")).jsonl")

    selected = 0
    total = 0
    open(decision_file, "w") do io
        for paper in papers
            section = selected_section(paper, lookup)
            label = section === nothing ? "rejected" : "selected"
            selected += section === nothing ? 0 : 1
            total += 1
            JSON3.write(io, Dict(
                "run_date" => Dates.format(Dates.today(), "yyyy-mm-dd"),
                "week" => Dates.format(week, "yyyy-mm-dd"),
                "label" => label,
                "selected_section" => section === nothing ? "" : section,
                "training_weight" => training_weight(section),
                "source" => item_string(paper, :source),
                "title" => item_string(paper, :title),
                "authors" => item_string(paper, :authors),
                "link" => item_string(paper, :link),
                "doi" => item_string(paper, :doi),
                "abstract" => item_string(paper, :abstract),
            ))
            write(io, "\n")
        end
    end

    mkpath(previous_weeks_dir)
    archive_file = joinpath(previous_weeks_dir, archive_name(week))
    cp(final_file, archive_file; force=true)

    return decision_file, archive_file, selected, total
end

if abspath(PROGRAM_FILE) == @__FILE__
    decision_file, archive_file, selected, total = record_final_decisions()
    println("Saved final decisions to $decision_file")
    println("Archived final paper list to $archive_file")
    println("Final labels: selected=$selected rejected=$(total - selected) total=$total")
end
