module PaperScorer

using JSON3

export load_training_docs, paper_key, score_map_from_files, score_papers_from_files

const SECTION_WEIGHTS = Dict(
    "featured" => 2.0,
    "some" => 2.0,
    "more" => 1.0,
)

const STOPWORDS = Set([
    "the", "and", "for", "with", "that", "this", "from", "into", "via", "using",
    "use", "uses", "used", "are", "was", "were", "been", "being", "can", "may",
    "has", "have", "had", "not", "but", "its", "their", "our", "your", "you",
    "study", "studies", "paper", "research", "results", "show", "shows", "new",
    "based", "through", "between", "within", "across", "during", "reveals",
    "revealed", "revealing", "suggests", "provides", "demonstrates", "toward",
])

struct TrainingDoc
    title::String
    url::String
    section::String
    text::String
    weight::Float64
    source_file::String
end

function strip_markdown(s::AbstractString)::String
    out = replace(String(s), r"<[^>]+>" => " ")
    out = replace(out, r"\[([^\]]+)\]\([^)]+\)" => s"\1")
    out = replace(out, r"[*_`#>{}\[\]]" => " ")
    out = replace(out, "&amp;" => "&", "&lt;" => "<", "&gt;" => ">")
    out = replace(out, r"\s+" => " ")
    return strip(out)
end

function clean_url(raw::AbstractString)::String
    s = strip(raw)
    s = replace(s, r"^<" => "")
    s = replace(s, r">\s*$" => "")
    return strip(s)
end

function section_from_heading(line::AbstractString)::String
    occursin(r"^#\s+Featured Papers\s*$", line) && return "featured"
    occursin(r"^##\s+Some Papers\s*$", line) && return "some"
    occursin(r"^##\s+More Papers\s*$", line) && return "more"
    return ""
end

function entry_text(title::AbstractString, lines::Vector{String})::String
    parts = String[]
    for line in lines
        s = strip(line)
        isempty(s) && continue
        startswith(s, ":::") && continue

        if occursin(r"(?i)<br\s*/?>", s)
            split_line = split(s, r"(?i)<br\s*/?>"; limit=2)
            s = length(split_line) == 2 ? split_line[2] : ""
        end

        s = strip_markdown(s)
        !isempty(s) && push!(parts, s)
    end
    return strip_markdown(string(title) * " " * join(parts, " "))
end

function parse_qmd_file(path::AbstractString)::Vector{TrainingDoc}
    docs = TrainingDoc[]
    current_section = ""
    current_title = ""
    current_url = ""
    buffer = String[]

    function flush_entry!()
        isempty(current_title) && return
        section = isempty(current_section) ? "more" : current_section
        weight = get(SECTION_WEIGHTS, section, 1.0)
        text = entry_text(current_title, buffer)
        if !isempty(strip(text))
            push!(docs, TrainingDoc(current_title, current_url, section, text, weight, string(path)))
        end
        empty!(buffer)
    end

    for line in readlines(path)
        section = section_from_heading(strip(line))
        if !isempty(section)
            flush_entry!()
            current_title = ""
            current_url = ""
            current_section = section
            continue
        end

        m = match(r"^####\s+\[(.*)\]\((.*)\)\s*$", strip(line))
        if m !== nothing
            flush_entry!()
            current_title = strip(m.captures[1])
            current_url = clean_url(m.captures[2])
            empty!(buffer)
            continue
        end

        !isempty(current_title) && push!(buffer, line)
    end
    flush_entry!()
    return docs
end

function load_training_docs(previous_weeks_dir::AbstractString="PreviousWeeks")::Vector{TrainingDoc}
    !isdir(previous_weeks_dir) && return TrainingDoc[]
    files = sort(filter(f -> endswith(lowercase(f), ".qmd") || endswith(lowercase(f), ".md"),
                        readdir(previous_weeks_dir; join=true)))
    docs = TrainingDoc[]
    for file in files
        append!(docs, parse_qmd_file(file))
    end
    return docs
end

function load_rejected_docs(decisions_dir::AbstractString="TrainingData")::Vector{TrainingDoc}
    !isdir(decisions_dir) && return TrainingDoc[]
    files = sort(filter(f -> endswith(lowercase(f), ".jsonl"),
                        readdir(decisions_dir; join=true)))
    docs = TrainingDoc[]
    for file in files
        for line in eachline(file)
            isempty(strip(line)) && continue
            item = try
                JSON3.read(line)
            catch
                continue
            end
            label = lowercase(string(get(item, :label, "")))
            label == "rejected" || continue
            title = string(get(item, :title, ""))
            abstract = string(get(item, :abstract, ""))
            source = string(get(item, :source, ""))
            text = strip_markdown(join([title, abstract, source], " "))
            isempty(text) && continue
            push!(docs, TrainingDoc(title, string(get(item, :link, "")), "rejected", text, 1.0, file))
        end
    end
    return docs
end

function tokens(text::AbstractString)::Vector{String}
    lowered = lowercase(strip_markdown(text))
    cleaned = replace(lowered, r"[^a-z0-9]+" => " ")
    raw = [t for t in split(cleaned) if length(t) >= 3 && !(t in STOPWORDS)]
    result = copy(raw)
    for i in 1:(length(raw) - 1)
        push!(result, raw[i] * "_" * raw[i + 1])
    end
    return result
end

function count_terms(ts::Vector{String})::Dict{String, Int}
    counts = Dict{String, Int}()
    for t in ts
        counts[t] = get(counts, t, 0) + 1
    end
    return counts
end

function tfidf_vector(counts::Dict{String, Int}, idf::Dict{String, Float64})::Dict{String, Float64}
    vec = Dict{String, Float64}()
    for (term, count) in counts
        vec[term] = (1.0 + log(count)) * get(idf, term, 1.0)
    end
    return vec
end

function normalize!(vec::Dict{String, Float64})
    norm = sqrt(sum(v * v for v in values(vec)))
    norm == 0 && return vec
    for k in keys(vec)
        vec[k] /= norm
    end
    return vec
end

function dot_sparse(a::Dict{String, Float64}, b::Dict{String, Float64})::Float64
    if length(a) > length(b)
        a, b = b, a
    end
    total = 0.0
    for (k, v) in a
        total += v * get(b, k, 0.0)
    end
    return total
end

function get_string(item, key::Symbol)::String
    value = get(item, key, "")
    value === nothing && return ""
    return string(value)
end

function paper_key(item)::String
    doi = lowercase(strip(get_string(item, :doi)))
    if !isempty(doi) && doi != "null"
        doi = replace(doi, r"^https?://(dx\.)?doi\.org/" => "")
        return "doi:" * doi
    end
    link = lowercase(strip(get_string(item, :link)))
    !isempty(link) && return "link:" * link
    title = lowercase(strip(get_string(item, :title)))
    title = replace(title, r"[^a-z0-9]+" => "")
    return "title:" * title
end

function paper_text(item)::String
    title = get_string(item, :title)
    abstract = get_string(item, :abstract)
    source = get_string(item, :source)
    return join([title, abstract, source], " ")
end

function weighted_centroid(docs::Vector{TrainingDoc}, counts_list::Vector{Dict{String, Int}},
                           idf::Dict{String, Float64})::Dict{String, Float64}
    centroid = Dict{String, Float64}()
    total_weight = 0.0
    for (doc, counts) in zip(docs, counts_list)
        vec = normalize!(tfidf_vector(counts, idf))
        for (term, value) in vec
            centroid[term] = get(centroid, term, 0.0) + doc.weight * value
        end
        total_weight += doc.weight
    end
    if total_weight > 0
        for term in keys(centroid)
            centroid[term] /= total_weight
        end
    end
    normalize!(centroid)
    return centroid
end

function score_papers(training_docs::Vector{TrainingDoc}, paper_items;
                      negative_docs::Vector{TrainingDoc}=TrainingDoc[])::Vector{Float64}
    isempty(training_docs) && return fill(0.0, length(paper_items))

    train_counts = [count_terms(tokens(doc.text)) for doc in training_docs]
    negative_counts = [count_terms(tokens(doc.text)) for doc in negative_docs]
    paper_counts = [count_terms(tokens(paper_text(p))) for p in paper_items]
    all_counts = vcat(train_counts, negative_counts, paper_counts)

    df = Dict{String, Int}()
    for counts in all_counts
        for term in keys(counts)
            df[term] = get(df, term, 0) + 1
        end
    end

    n_docs = length(all_counts)
    idf = Dict(term => log((1.0 + n_docs) / (1.0 + freq)) + 1.0 for (term, freq) in df)

    positive_centroid = weighted_centroid(training_docs, train_counts, idf)
    negative_centroid = weighted_centroid(negative_docs, negative_counts, idf)

    scores = Float64[]
    for counts in paper_counts
        vec = normalize!(tfidf_vector(counts, idf))
        positive_score = dot_sparse(vec, positive_centroid)
        negative_score = isempty(negative_docs) ? 0.0 : dot_sparse(vec, negative_centroid)
        push!(scores, positive_score - negative_score)
    end
    return scores
end

function score_map_from_files(input_file::AbstractString="papers.json",
                              previous_weeks_dir::AbstractString="PreviousWeeks";
                              decisions_dir::AbstractString="TrainingData",
                              output_file::Union{AbstractString, Nothing}="paper_scores.json")
    papers = JSON3.read(read(input_file, String))
    training_docs = load_training_docs(previous_weeks_dir)
    negative_docs = load_rejected_docs(decisions_dir)
    scores = score_papers(training_docs, papers; negative_docs=negative_docs)
    score_map = Dict{String, Float64}()
    rows = Dict{String, Any}[]

    for (paper, score) in zip(papers, scores)
        key = paper_key(paper)
        score_map[key] = score
        push!(rows, Dict(
            "score" => score,
            "title" => get_string(paper, :title),
            "source" => get_string(paper, :source),
            "link" => get_string(paper, :link),
            "doi" => get_string(paper, :doi),
        ))
    end

    if output_file !== nothing
        sort!(rows; by=row -> row["score"], rev=true)
        open(output_file, "w") do io
            JSON3.pretty(io, rows)
        end
    end

    return score_map
end

function score_papers_from_files(input_file::AbstractString="papers.json",
                                 previous_weeks_dir::AbstractString="PreviousWeeks";
                                 decisions_dir::AbstractString="TrainingData",
                                 output_file::Union{AbstractString, Nothing}="paper_scores.json")
    score_map_from_files(input_file, previous_weeks_dir; decisions_dir=decisions_dir, output_file=output_file)
end

end # module

if abspath(PROGRAM_FILE) == @__FILE__
    using .PaperScorer
    input_file = length(ARGS) >= 1 ? ARGS[1] : "papers.json"
    previous_weeks_dir = length(ARGS) >= 2 ? ARGS[2] : "PreviousWeeks"
    output_file = length(ARGS) >= 3 ? ARGS[3] : "paper_scores.json"
    scores = PaperScorer.score_map_from_files(input_file, previous_weeks_dir; output_file=output_file)
    println("Scored $(length(scores)) papers using $(length(PaperScorer.load_training_docs(previous_weeks_dir))) previous selections and $(length(PaperScorer.load_rejected_docs())) rejected examples.")
    println("Wrote $output_file")
end
