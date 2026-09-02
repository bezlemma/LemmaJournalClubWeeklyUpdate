using Test
using JSON3
using Dates, TimeZones

isdefined(@__MODULE__, :Paper) || include(joinpath(@__DIR__, "..", "fetch_papers.jl"))

@testset "Europe PMC journal fallback" begin
    oldest = ZonedDateTime(DateTime(2026, 8, 3), tz"UTC")

    challenge = HTTP.Response(
        200,
        ["Content-Type" => "text/html; charset=utf-8"],
        "<!DOCTYPE html><html><head><title>Client Challenge</title></head><body></body></html>",
    )
    challenge_error = try
        parse_rss_response(challenge, "EMBO Journal")
        nothing
    catch e
        e
    end
    @test challenge_error isa FeedResponseError
    @test challenge_error.permanent
    @test occursin("anti-bot client challenge", sprint(showerror, challenge_error))

    valid_feed = HTTP.Response(
        200,
        ["Content-Type" => "application/rss+xml"],
        """<?xml version="1.0"?><rss version="2.0"><channel><item><title>Test</title><pubDate>Mon, 03 Aug 2026 00:00:00 GMT</pubDate></item></channel></rss>""",
    )
    _, valid_entries = parse_rss_response(valid_feed, "Test Journal")
    @test length(valid_entries) == 1

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

    irrelevant_incomplete = JSON3.read("""
    {
      "id": "42668274",
      "source": "MED",
      "doi": "10.1038/s44318-026-00906-w",
      "title": "From gatekeepers to regenerators: the plasticity of Paneth cells.",
      "authorString": "De Beul S, Libert C, Vanderhaeghen T.",
      "firstPublicationDate": "2026-08-08",
      "pubTypeList": {"pubType": ["Journal Article"]}
    }
    """)
    @test europepmc_item_to_paper(
        irrelevant_incomplete, "EMBO Journal", :green_filter;
        oldest_date=oldest, window_end_date=Date(2026, 8, 10),
    ) === nothing

    incomplete_research = JSON3.read("""
    {
      "id": "missing-abstract",
      "source": "MED",
      "doi": "10.1016/incomplete",
      "title": "Mechanics of an experimental system with unavailable metadata.",
      "authorString": "Researcher A.",
      "firstPublicationDate": "2026-08-08",
      "pubTypeList": {"pubType": ["Journal Article"]}
    }
    """)
    @test_throws ErrorException europepmc_item_to_paper(
        incomplete_research, "Cell", :green_filter;
        oldest_date=oldest, window_end_date=Date(2026, 8, 10),
    )

    enriched = europepmc_item_to_paper(
        incomplete_research, "Cell", :green_filter;
        oldest_date=oldest,
        window_end_date=Date(2026, 8, 10),
        metadata_lookup=doi -> (["Researcher A"], repeat("Mechanics metadata recovered by DOI. ", 4)),
    )
    @test enriched isa Paper
    @test length(enriched.abstract) >= MIN_ABSTRACT_CHARS

    @test europepmc_item_to_paper(
        research, "Biophysical Journal", :include_all;
        oldest_date=oldest, window_end_date=Date(2026, 8, 7),
    ) === nothing

    malformed_relevant = JSON3.read("""
    {
      "id": "missing-date",
      "source": "MED",
      "doi": "10.1016/missing-date",
      "title": "Mechanics of a malformed record.",
      "authorString": "Researcher A.",
      "abstractText": "This sufficiently long abstract describes mechanics in a malformed record without a publication date.",
      "pubTypeList": {"pubType": ["Journal Article"]}
    }
    """)
    record_warnings = String[]
    screened = screen_europepmc_items(
        [malformed_relevant, research], "Biophysical Journal", :include_all;
        warning_sink=record_warnings,
        oldest_date=oldest,
        window_end_date=Date(2026, 8, 10),
    )
    @test length(screened) == 1
    @test length(record_warnings) == 1
    @test occursin("no usable publication date", only(record_warnings))

    @test Set(keys(JOURNAL_EUROPEPMC_BACKUP_ISSNS)) == Set([
        "Biophysical Journal", "Cell", "iScience", "Current Biology",
    ])
    @test JOURNAL_EUROPEPMC_PRIMARY_ISSNS == Dict("EMBO Journal" => "0261-4189")
    @test JOURNAL_CROSSREF_BACKUP_ISSNS == Dict("EMBO Journal" => "1460-2075")

    pnas_copy = Paper(
        source="PNAS",
        title="Initiation of rotational collective migration in Drosophila through tissue geometry and mechanochemical feedback",
        authors="A. Author, B. Author",
        link="https://www.pnas.org/doi/abs/10.1073/pnas.2528342123?af=R",
        abstract_text=repeat("A substantive abstract sentence. ", 4),
        date=ZonedDateTime(DateTime(2026, 8, 8), tz"UTC"),
        doi="10.1073/pnas.2528342123",
    )
    crossref_copy = Paper(
        source="CrossRef/Featured",
        title="Initiation of rotational collective migration in <i>Drosophila</i> through tissue geometry and mechanochemical feedback",
        authors=pnas_copy.authors,
        link="https://doi.org/10.1073/pnas.2528342123",
        abstract_text=pnas_copy.abstract,
        date=pnas_copy.date,
        doi="https://doi.org/10.1073/pnas.2528342123",
    )
    deduplicated = deduplicate_papers([pnas_copy, crossref_copy])
    @test length(deduplicated) == 1
    @test deduplicated[1].source == "CrossRef/Featured"
    @test deduplicated[1].doi == "10.1073/pnas.2528342123"
    @test !isempty(intersect(paper_identity_keys(pnas_copy), paper_identity_keys(crossref_copy)))

    optica_one = Paper(
        source="Optica", title="First distinct optics paper", authors=pnas_copy.authors,
        link="https://opg.optica.org/abstract.cfm?uri=boe-17-8-1234",
        abstract_text=pnas_copy.abstract, date=pnas_copy.date,
    )
    optica_two = Paper(
        source="Optica", title="Second distinct optics paper", authors=pnas_copy.authors,
        link="https://opg.optica.org/abstract.cfm?uri=oe-34-9-5678",
        abstract_text=pnas_copy.abstract, date=pnas_copy.date,
    )
    @test length(deduplicate_papers([optica_one, optica_two])) == 2
end
