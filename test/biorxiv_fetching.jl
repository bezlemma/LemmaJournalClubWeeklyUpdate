using Test
using Dates, TimeZones

include(joinpath(@__DIR__, "..", "fetch_papers.jl"))

@testset "bioRxiv category API and backup merge" begin
    url = biorxiv_api_url("2026-07-27", "2026-08-03", 30)
    @test url == "https://api.biorxiv.org/details/biorxiv/2026-07-27/2026-08-03/30/json?category=biophysics"

    newer = Paper(
        source="bioRxiv",
        title="A physical model",
        authors="A. One, B. Two",
        link="https://www.biorxiv.org/content/10.1101/examplev2",
        abstract_text="A sufficiently long abstract for a deterministic unit-test fixture.",
        images=String[],
        date=ZonedDateTime(DateTime(2026, 8, 2), tz"UTC"),
        doi="10.1101/example",
    )
    older = Paper(
        source="bioRxiv",
        title="A physical model",
        authors="A. One, B. Two",
        link="https://www.biorxiv.org/content/10.1101/examplev1",
        abstract_text="The original version should win when API and RSS results overlap.",
        images=String[],
        date=ZonedDateTime(DateTime(2026, 8, 1), tz"UTC"),
        doi="10.1101/example",
    )

    merged = deduplicate_biorxiv_papers([newer, older])
    @test length(merged) == 1
    @test merged[1].link == older.link
end
