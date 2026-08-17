using Test

if !isdefined(Main, :begin_gemini_request!)
    include(joinpath(@__DIR__, "..", "filter_papers.jl"))
end

@testset "structured classifier responses" begin
    approved = parse_scored_classification("""
    ```json
    {"score": 78, "category": "cell mechanics", "explanation": "Measures force transmission in living cells."}
    ```
    """)
    @test approved == (true, "AI Approved", 78, "cell mechanics", "Measures force transmission in living cells.")

    rejected = parse_scored_classification(
        "{\"score\": 31, \"category\": \"clinical genomics\", \"explanation\": \"No physical mechanism is studied.\"}",
        "AI Recall",
    )
    @test rejected == (false, "AI Recall Rejected", 31, "clinical genomics", "No physical mechanism is studied.")

    # Preserve compatibility with a valid response from an older prompt while
    # the new structured format rolls out.
    @test parse_scored_classification("TRUE") ==
          (true, "AI Approved", 75, "unspecified", "Legacy binary classifier response.")
    @test parse_scored_classification("")[2] == "AI Unavailable"
end

@testset "structured classifier audit accepts parsed strings" begin
    empty!(CLASSIFICATION_AUDIT)
    paper = Dict(
        :title => "Cell mechanics audit test",
        :link => "https://example.org/cell-mechanics-audit-test",
    )
    _, _, score, category, explanation = parse_scored_classification(
        "{\"score\": 78, \"category\": \"cell mechanics\", \"explanation\": \"Measures force transmission in living cells.\"}",
    )

    # `strip`/`first` intentionally return SubString values. This is the exact
    # path that the August 17 run exercised before the audit method failed.
    @test category isa SubString{String}
    @test explanation isa SubString{String}
    @test_nowarn record_classification_audit!(paper, "initial", score, category, explanation)

    audit = classification_audit(paper)
    @test audit["initial_score"] == 78
    @test audit["initial_category"] == "cell mechanics"
    @test audit["initial_explanation"] == "Measures force transmission in living cells."
    @test audit["final_category"] isa String
    @test audit["final_explanation"] isa String
end

function reset_gemini_guard_for_test!()
    GEMINI_IN_FLIGHT_COST_USD[] = 0.0
    GEMINI_UNREPORTED_COST_USD[] = 0.0
    GEMINI_REPORTED_COST_USD[] = 0.0
    GEMINI_REQUEST_COUNT[] = 0
    GEMINI_BUDGET_EXHAUSTED[] = false
    GEMINI_BUDGET_REASON[] = ""
    GEMINI_COOLDOWN_UNTIL[] = 0.0
end

@testset "Gemini safety guard accounting" begin
    reset_gemini_guard_for_test!()
    prompt = "Classify this short scientific abstract."

    # Rejected/rate-limited HTTP attempts are released, not accumulated as spend.
    for _ in 1:500
        reservation = begin_gemini_request!(prompt)
        @test reservation !== nothing
        finish_gemini_request!(reservation)
    end
    @test GEMINI_IN_FLIGHT_COST_USD[] ≈ 0.0 atol=1e-12
    @test GEMINI_UNREPORTED_COST_USD[] == 0.0
    @test GEMINI_REPORTED_COST_USD[] == 0.0
    @test !GEMINI_BUDGET_EXHAUSTED[]

    # A successful response replaces its temporary estimate with provider usage.
    reservation = begin_gemini_request!(prompt)
    usage = JSON3.read("""{"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":20,"thoughtsTokenCount":30}}""")
    finish_gemini_request!(reservation; data=usage, charge_unreported=true)
    expected = 100 * GEMINI_INPUT_USD_PER_MILLION / 1_000_000 +
               50 * GEMINI_OUTPUT_USD_PER_MILLION / 1_000_000
    @test GEMINI_REPORTED_COST_USD[] ≈ expected
    @test GEMINI_IN_FLIGHT_COST_USD[] ≈ 0.0 atol=1e-12

    # A timeout or successful response lacking metadata remains conservatively exposed once.
    reservation = begin_gemini_request!(prompt)
    finish_gemini_request!(reservation; charge_unreported=true)
    @test GEMINI_UNREPORTED_COST_USD[] ≈ reservation

    # Both hard stops still work, but only at true runaway/cost conditions.
    reset_gemini_guard_for_test!()
    GEMINI_REPORTED_COST_USD[] = GEMINI_MAX_RUN_COST_USD
    @test begin_gemini_request!(prompt) === nothing
    @test GEMINI_BUDGET_EXHAUSTED[]
    @test occursin("hard ceiling", GEMINI_BUDGET_REASON[])

    reset_gemini_guard_for_test!()
    GEMINI_REQUEST_COUNT[] = GEMINI_MAX_REQUESTS
    @test begin_gemini_request!(prompt) === nothing
    @test GEMINI_BUDGET_EXHAUSTED[]
    @test occursin("runaway request ceiling", GEMINI_BUDGET_REASON[])
end
