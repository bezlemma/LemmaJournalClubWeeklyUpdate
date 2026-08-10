using Test
using JSON3
using Dates, TimeZones

isdefined(@__MODULE__, :Paper) || include(joinpath(@__DIR__, "..", "fetch_papers.jl"))

@testset "Europe PMC journal fallback" begin
    oldest = ZonedDateTime(DateTime(2026, 8, 3), tz"UTC")

    research = JSON3.read("""
    {
      "id": "42568184",
      "source": "MED",
      "doi": "10.1016/j.bpj.2026.08.002",
      "title": "Effects of force on a model membrane.",
      "authorString": "One A, Two B.",
      "firstPublicationDate": "2026-08-08",
      "abstractText": "This sufficiently long test abstract describes membrane mechanics, force generation, and biophysical measurements in a reproducible experimental system.",
      "pubTypeList": {"pubType": ["Journal Article"]}
    }
    """)
    paper = europepmc_item_to_paper(research, "Biophysical Journal", :include_all;
                                    oldest_date=oldest)
    @test paper isa Paper
    @test paper.doi == "10.1016/j.bpj.2026.08.002"
    @test paper.link == "https://doi.org/10.1016/j.bpj.2026.08.002"
    @test Date(DateTime(paper.date, UTC)) == Date(2026, 8, 8)

    editorial = JSON3.read("""
    {
      "id": "editorial",
      "source": "MED",
      "doi": "10.1016/example",
      "title": "A view from the editors.",
      "authorString": "Editor A.",
      "firstPublicationDate": "2026-08-08",
      "pubTypeList": {"pubType": ["Editorial"]}
    }
    """)
    @test europepmc_item_to_paper(editorial, "Cell", :green_filter;
                                  oldest_date=oldest) === nothing

    incomplete_research = JSON3.read("""
    {
      "id": "missing-abstract",
      "source": "MED",
      "doi": "10.1016/incomplete",
      "title": "A research article with unavailable metadata.",
      "authorString": "Researcher A.",
      "firstPublicationDate": "2026-08-08",
      "pubTypeList": {"pubType": ["Journal Article"]}
    }
    """)
    @test_throws ErrorException europepmc_item_to_paper(
        incomplete_research, "Cell", :green_filter; oldest_date=oldest,
    )

    @test Set(keys(JOURNAL_EUROPEPMC_BACKUP_ISSNS)) == Set([
        "Biophysical Journal", "Cell", "iScience", "Current Biology", "EMBO Journal",
    ])
end
