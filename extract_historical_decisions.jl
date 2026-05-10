include(joinpath(@__DIR__, "score_papers.jl"))

using Dates
using JSON3

const DEFAULT_OUTPUT = joinpath("TrainingData", "historical_decisions.jsonl")

function git_output(args::Vector{String})::String
    return read(`git $args`, String)
end

function normalize_doi(raw::AbstractString)::String
    s = lowercase(strip(raw))
    s = replace(s, r"^https?://(dx\.)?doi\.org/" => "")
    s = replace(s, r"^doi:\s*" => "")
    m = match(r"10\.\d{4,9}/[-._;()/:a-z0-9]+", s)
    m === nothing && return ""
    doi = replace(m.match, r"[\]\).,;]+$" => "")
    return strip(doi)
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

function week_from_commit(commit::AbstractString)::Date
    raw = strip(git_output(["show", "-s", "--date=short", "--format=%cd", string(commit)]))
    d = Date(raw, dateformat"yyyy-mm-dd")
    return d - Day(dayofweek(d) - 1)
end

function week_file(week::Date, previous_weeks_dir::AbstractString)::String
    stem = Dates.format(week, "uuu") * Dates.format(week, "dd") * "_" * Dates.format(week, "yyyy")
    return joinpath(previous_weeks_dir, stem * ".qmd")
end

function commits_with_papers_json()::Vector{String}
    raw = git_output(["log", "--all", "--reverse", "--pretty=format:%H", "--", "papers.json"])
    commits = filter(!isempty, split(raw, "\n"))
    return String[string(c) for c in commits]
end

function latest_candidate_commits_by_week(previous_weeks_dir::AbstractString)::Dict{Date, String}
    by_week = Dict{Date, String}()
    for commit in commits_with_papers_json()
        has_papers = success(pipeline(`git cat-file -e $(commit):papers.json`, stdout=devnull, stderr=devnull))
        has_papers || continue
        week = week_from_commit(commit)
        isfile(week_file(week, previous_weeks_dir)) || continue
        by_week[week] = commit
    end
    return by_week
end

function selected_lookup(qmd_file::AbstractString)
    lookup = Dict{String, String}()
    for doc in PaperScorer.parse_qmd_file(qmd_file)
        keys = candidate_keys(title=doc.title, link=doc.url)
        for key in keys
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

function extract_historical_decisions(previous_weeks_dir::AbstractString="PreviousWeeks";
                                      output_file::AbstractString=DEFAULT_OUTPUT)
    by_week = latest_candidate_commits_by_week(previous_weeks_dir)
    mkpath(dirname(output_file))

    total = 0
    accepted = 0
    summaries = []

    open(output_file, "w") do io
        for week in sort(collect(keys(by_week)))
            commit = by_week[week]
            qmd = week_file(week, previous_weeks_dir)
            lookup = selected_lookup(qmd)
            candidates = JSON3.read(git_output(["show", "$(commit):papers.json"]))
            week_total = 0
            week_accepted = 0

            for paper in candidates
                section = selected_section(paper, lookup)
                label = section === nothing ? "rejected" : "selected"
                weight = section == "featured" || section == "some" ? 2.0 :
                         section == "more" ? 1.0 : 0.0
                week_total += 1
                total += 1
                if section !== nothing
                    week_accepted += 1
                    accepted += 1
                end
                JSON3.write(io, Dict(
                    "week" => Dates.format(week, "yyyy-mm-dd"),
                    "candidate_commit" => commit,
                    "label" => label,
                    "selected_section" => section === nothing ? "" : section,
                    "training_weight" => weight,
                    "source" => item_string(paper, :source),
                    "title" => item_string(paper, :title),
                    "authors" => item_string(paper, :authors),
                    "link" => item_string(paper, :link),
                    "doi" => item_string(paper, :doi),
                    "abstract" => item_string(paper, :abstract),
                ))
                write(io, "\n")
            end

            push!(summaries, (week=week, commit=commit, selected=week_accepted, total=week_total))
        end
    end

    return summaries, accepted, total
end

if abspath(PROGRAM_FILE) == @__FILE__
    previous_weeks_dir = length(ARGS) >= 1 ? ARGS[1] : "PreviousWeeks"
    output_file = length(ARGS) >= 2 ? ARGS[2] : DEFAULT_OUTPUT
    summaries, accepted, total = extract_historical_decisions(previous_weeks_dir; output_file=output_file)
    for s in summaries
        println("$(Dates.format(s.week, "yyyy-mm-dd")) $(s.commit[1:7]) selected=$(s.selected) rejected=$(s.total - s.selected) total=$(s.total)")
    end
    println("Wrote $output_file")
    println("Historical labels: selected=$accepted rejected=$(total - accepted) total=$total")
end
