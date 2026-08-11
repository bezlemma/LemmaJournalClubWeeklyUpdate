module EditionIntegrity

using Dates

export MIN_EDITION_PAPERS,
       candidate_issues,
       is_placeholder_text,
       publication_date,
       required_edition_size,
       sanitize_candidates,
       selected_edition_issues,
       summary_issues

const MIN_EDITION_PAPERS = 50
const MIN_ABSTRACT_CHARS = 80
const MIN_SUMMARY_WORDS = 6

field_text(record, field::Symbol)::String = strip(string(get(record, field, "")))

function is_placeholder_text(value::AbstractString)::Bool
    clean = lowercase(replace(strip(value), r"\s+" => " "))
    isempty(clean) && return true
    clean in ("n/a", "na", "none", "null", "unknown", "tbd", "-") && return true

    unavailable = r"^(?:abstract|summary|authors?|title|source|content|information|data)?\s*(?:is|are|was|were)?\s*(?:not\s+available|unavailable|missing|unknown|not\s+provided)(?:\s+via\b.*)?[.!]?$"
    no_value = r"^no\s+(?:abstract|summary|authors?|title|source|content|information|data)(?:\s+(?:is|was))?\s*(?:available|provided|found)?(?:\s+via\b.*)?[.!]?$"
    return occursin(unavailable, clean) || occursin(no_value, clean)
end

function publication_date(record)::Union{Date, Nothing}
    raw = field_text(record, :date)
    date_match = match(r"^\d{4}-\d{2}-\d{2}", raw)
    date_match === nothing && return nothing
    reported = try
        Date(date_match.match)
    catch
        return nothing
    end

    # bioRxiv and medRxiv APIs report the latest revision date. Their DOI keeps
    # the first-posted date, which is the publication date readers expect and
    # prevents an old revised manuscript from masquerading as a new paper.
    source = lowercase(field_text(record, :source))
    link = lowercase(field_text(record, :link))
    if occursin("biorxiv", source) || occursin("medrxiv", source) ||
       occursin("biorxiv.org", link) || occursin("medrxiv.org", link) ||
       occursin("doi.org/10.64898/", link) || occursin("doi.org/10.1101/", link)
        original_match = match(r"/(20\d{2})\.(\d{2})\.(\d{2})(?:\.|v|$)", link)
        if original_match !== nothing
            original = try
                Date(parse(Int, original_match.captures[1]),
                     parse(Int, original_match.captures[2]),
                     parse(Int, original_match.captures[3]))
            catch
                nothing
            end
            original !== nothing && return min(original, reported)
        end
    end
    return reported
end

function candidate_issues(record, edition_date::Date)::Vector{String}
    issues = String[]
    title = field_text(record, :title)

    for field in (:title, :authors, :abstract, :link, :source, :date)
        value = field_text(record, field)
        if isempty(value)
            push!(issues, "$field is blank")
        elseif is_placeholder_text(value)
            push!(issues, "$field contains placeholder text: '$value'")
        end
    end

    abstract_text = field_text(record, :abstract)
    if !isempty(abstract_text) && !is_placeholder_text(abstract_text) && length(abstract_text) < MIN_ABSTRACT_CHARS
        push!(issues, "abstract is too short to be substantive ($(length(abstract_text)) characters)")
    end

    link = field_text(record, :link)
    if !isempty(link) && !startswith(lowercase(link), "http://") && !startswith(lowercase(link), "https://")
        push!(issues, "link is not an HTTP(S) URL: '$link'")
    end

    published = publication_date(record)
    if published === nothing
        isempty(field_text(record, :date)) || push!(issues, "date is not parseable: '$(field_text(record, :date))'")
    else
        oldest = edition_date - Day(7)
        published < oldest && push!(issues, "publication date $published is older than the allowed $oldest cutoff")
        published > edition_date && push!(issues, "publication date $published is after edition date $edition_date")
    end

    return [isempty(title) ? issue : "$title — $issue" for issue in issues]
end

function summary_issues(summary::AbstractString)::Vector{String}
    clean = strip(summary)
    issues = String[]
    if isempty(clean)
        push!(issues, "summary is blank")
        return issues
    end
    is_placeholder_text(clean) && push!(issues, "summary contains placeholder text: '$clean'")
    length(split(clean)) < MIN_SUMMARY_WORDS && push!(issues, "summary has fewer than $MIN_SUMMARY_WORDS words")
    occursin(r"[.!?][\"'”’\)\]]*$", clean) || push!(issues, "summary does not end as a complete sentence")
    return issues
end

function sanitize_candidates(papers, edition_date::Date)
    kept = Any[]
    removed = NamedTuple[]
    for (index, paper) in enumerate(papers)
        issues = candidate_issues(paper, edition_date)
        if isempty(issues)
            normalized = Dict{Symbol, Any}(Symbol(key) => value for (key, value) in pairs(paper))
            published = publication_date(paper)
            published !== nothing && (normalized[:date] = "$(published)T00:00:00+00:00")
            push!(kept, normalized)
        else
            push!(removed, (index=index, title=field_text(paper, :title), issues=issues))
        end
    end
    return kept, removed
end

function required_edition_size(candidate_count::Int; min_papers::Int=MIN_EDITION_PAPERS,
                               min_fraction::Float64=0.0)::Int
    0.0 <= min_fraction <= 1.0 || error("min_fraction must be between 0 and 1")
    return max(min_papers, ceil(Int, candidate_count * min_fraction))
end

function selected_edition_issues(items, edition_date::Date; min_papers::Int=MIN_EDITION_PAPERS,
                                 candidate_count::Union{Nothing, Int}=nothing,
                                 min_fraction::Float64=0.0)::Vector{String}
    issues = String[]
    required = candidate_count === nothing ? min_papers :
               required_edition_size(candidate_count; min_papers=min_papers, min_fraction=min_fraction)
    length(items) < required && push!(issues,
        "edition contains $(length(items)) papers; minimum is $required" *
        (candidate_count === nothing ? "" : " for $candidate_count valid candidates"))

    seen_links = Set{String}()
    seen_titles = Set{String}()
    for item in items
        paper = item.paper
        title = field_text(paper, :title)
        link = lowercase(field_text(paper, :link))
        normalized_title = lowercase(replace(title, r"\s+" => " "))

        append!(issues, candidate_issues(paper, edition_date))
        append!(issues, ["$title — $issue" for issue in summary_issues(string(item.summary))])

        !isempty(link) && link in seen_links && push!(issues, "$title — duplicate link '$link'")
        !isempty(normalized_title) && normalized_title in seen_titles && push!(issues, "$title — duplicate title")
        push!(seen_links, link)
        push!(seen_titles, normalized_title)
    end
    return issues
end

end
