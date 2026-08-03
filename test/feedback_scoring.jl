using Test
using JSON3

Meta.parseall(read(joinpath(@__DIR__, "..", "filter_papers.jl"), String))
include(joinpath(@__DIR__, "..", "score_papers.jl"))

fixture = Dict(
    "papers" => [
        Dict(
            "title" => "Mechanical force transmission by molecular motors",
            "summary" => "Force generation and dynamics in living cells.",
            "source" => "Preprint",
            "link" => "https://example.com/up",
            "upvotes" => 3,
            "downvotes" => 0,
        ),
        Dict(
            "title" => "Virtual drug docking database",
            "summary" => "High-throughput screening of compound libraries.",
            "source" => "Journal",
            "link" => "https://example.com/down",
            "upvotes" => 0,
            "downvotes" => 2,
        ),
    ],
)

mktemp() do path, io
    JSON3.write(io, fixture)
    close(io)

    positive, negative = PaperScorer.load_reader_feedback_docs(path)
    @test length(positive) == 1
    @test length(negative) == 1

    candidates = [
        Dict(
            :title => "Molecular motors transmit mechanical force",
            :abstract => "Cell dynamics and force generation by active matter.",
            :source => "bioRxiv",
        ),
        Dict(
            :title => "Database for virtual compound docking",
            :abstract => "High-throughput drug screening and compound ranking.",
            :source => "Journal",
        ),
    ]
    scores = PaperScorer.score_papers(positive, candidates; negative_docs=negative)
    @test scores[1] > scores[2]
end
