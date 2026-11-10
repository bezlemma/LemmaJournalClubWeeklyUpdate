module GreenAuthors
using Unicode

export read_green_authors, author_index, matching_authors

struct Author
    names::Vector{String}
    ids::Vector{String}
    institutions::Vector{String}
end

function read_green_authors(path)
    entries = Author[]
    for raw in eachline(path)
        line = strip(first(split(raw, '#'; limit=2)))
        isempty(line) && continue
        parts = split(line, " - "; limit=2)
        ids = length(parts) == 2 ? strip.(split(first(parts), ',')) : String[]
        all(id -> occursin(r"^\d{4}-\d{4}-\d{4}-\d{3}[\dX]$", id), ids) || error("Invalid ORCID: $line")
        fields = split(last(parts), " @ "; limit=2)
        institutions = length(fields) == 2 ? strip.(split(last(fields), '|')) : String[]
        push!(entries, Author(strip.(split(first(fields), '|')), ids, institutions))
    end
    return entries
end

# Preserve compound surnames; only punctuation, accents, and middle initials are optional.
function name_key(name)
    key = Unicode.normalize(name; casefold=true, stripmark=true)
    strip(replace(replace(key, r"[\p{Pd}'’\.]" => ""), r"\s+" => " "))
end

function without_initials(key)
    parts = split(key)
    length(parts) < 3 && return key
    join([first(parts); filter(p -> length(p) > 1, parts[2:end-1]); last(parts)], " ")
end

function author_index(entries)
    exact = Dict{String, Vector{Author}}()
    initials = Dict{String, Vector{Author}}()
    for a in entries, name in a.names
        key = name_key(name)
        for k in unique([key, without_initials(key)])
            push!(get!(exact, k, Author[]), a)
        end
        parts = split(without_initials(key))
        if !isempty(a.ids) && length(parts) >= 2
            initial_key = join([string(first(parts[1])); parts[2:end]], " ")
            push!(get!(initials, initial_key, Author[]), a)
        end
    end
    return (; exact, initials)
end

function byline_names(byline)
    # bioRxiv: "Surname, A.; Other, Beth". Journal feeds may flatten the
    # same format to "Surname, Alex, Other, Beth"; Crossref uses "Alex Surname, Beth Other".
    if occursin(';', byline)
        return [join(reverse(strip.(split(s, ','))), " ") for s in split(byline, ';')]
    end
    parts = strip.(split(byline, ','))
    names = String.(parts)
    if iseven(length(parts))
        append!(names, [parts[i+1] * " " * parts[i] for i in 1:2:length(parts)])
    end
    return names
end

function matching_authors(index, byline; allow_initials=false)
    matches = Author[]
    for raw in byline_names(byline)
        key = name_key(raw)
        for k in unique([key, without_initials(key)])
            haskey(index.exact, k) && append!(matches, index.exact[k])
            if allow_initials && haskey(index.initials, k)
                append!(matches, index.initials[k])
            end
        end
    end
    return unique!(matches)
end

end
