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

@testset "AI decisions are audit-only" begin
    mktempdir() do root
        previous = joinpath(root, "PreviousWeeks")
        decisions = joinpath(root, "TrainingData")
        mkpath(previous)
        mkpath(decisions)
        write(joinpath(previous, "week.qmd"), """
## More Papers

#### [Membrane force dynamics](https://example.com/selected)
*A. Author* <br>
Mechanical forces reorganize a living-cell membrane.
""")
        write(joinpath(decisions, "filter_decisions_2026-08-10.jsonl"), JSON3.write(Dict(
            "label" => "rejected",
            "title" => "Membrane force dynamics",
            "abstract" => "Mechanical forces reorganize a living-cell membrane.",
            "source" => "Journal",
            "link" => "https://example.com/rejected",
        )) * "\n")
        input = joinpath(root, "papers.json")
        open(input, "w") do io
            JSON3.write(io, [Dict(
                "title" => "Membrane mechanics",
                "abstract" => "Forces and dynamics reorganize cell membranes.",
                "source" => "Journal",
                "link" => "https://example.com/candidate",
                "doi" => nothing,
            )])
        end

        # The presence of an AI-rejected audit record does not lower the score.
        with_audit = PaperScorer.score_map_from_files(
            input,
            previous;
            feedback_file=joinpath(root, "missing-feedback.json"),
            output_file=nothing,
        )
        rm(joinpath(decisions, "filter_decisions_2026-08-10.jsonl"))
        without_audit = PaperScorer.score_map_from_files(
            input,
            previous;
            feedback_file=joinpath(root, "missing-feedback.json"),
            output_file=nothing,
        )
        @test with_audit == without_audit
    end
end

@testset "missing DOI values use stable links" begin
    link = "https://arxiv.org/abs/2608.00001"
    @test PaperScorer.paper_key(Dict(:doi => nothing, :link => link)) == "link:$link"
    @test PaperScorer.paper_key(Dict(:doi => "nothing", :link => link)) == "link:$link"
    @test PaperScorer.paper_key(Dict(:doi => "null", :link => link)) == "link:$link"
end
