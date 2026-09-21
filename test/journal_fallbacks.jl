using Test
using JSON3
using Dates, TimeZones

isdefined(@__MODULE__, :Paper) || include(joinpath(@__DIR__, "..", "fetch_papers.jl"))

@testset "PNAS feed denial and independent recovery" begin
    feed = only(filter(f -> f.name == "PNAS", JOURNAL_FEEDS))
    no_sleep = _ -> nothing
    unexpected = (args...; kwargs...) -> error("Unexpected backup call")
    requests = String[]
    denial_get = function(url; kwargs...)
        push!(requests, url)
        HTTP.Response(403, ["Content-Type" => "text/html; charset=UTF-8"], "<html>Forbidden</html>")
    end
    denied_rss = (args...; kwargs...) -> fetch_rss(
        args...; kwargs..., http_get=denial_get, sleep_fn=no_sleep,
    )

    publication_day = string(WINDOW_END_DATE - Day(1))
    record = Dict(
        "id" => "12345", "source" => "MED", "doi" => "10.1073/pnas.test",
        "title" => "Mechanics of a model membrane", "authorString" => "One A, Two B",
        "firstPublicationDate" => publication_day,
        "abstractText" => repeat("Membrane mechanics and biophysical force measurements. ", 4),
        "pubTypeList" => Dict("pubType" => ["Journal Article"]),
    )
    unrelated = merge(record, Dict("title" => "A historical account of ancient languages",
                                   "abstractText" => repeat("Ancient languages and written records. ", 4)))
    future = merge(record, Dict("firstPublicationDate" => string(WINDOW_END_DATE + Day(1))))
    old = merge(record, Dict("firstPublicationDate" => string(OLDEST_PUBLICATION_DATE - Day(1))))
    epmc_data = Dict("hitCount" => 4, "resultList" => Dict("result" => [record, unrelated, future, old]))
    epmc_get = function(url; kwargs...)
        push!(requests, HTTP.unescapeuri(url))
        HTTP.Response(200, JSON3.write(epmc_data))
    end
    epmc = (args...; kwargs...) -> fetch_europepmc_issn_papers(
        args...; kwargs..., http_get=epmc_get, sleep_fn=no_sleep,
    )
    warnings = String[]
    recovered = fetch_journal_feed(feed; rss_fetcher=denied_rss,
        europepmc_fetcher=epmc, crossref_fetcher=unexpected, warning_sink=warnings)
    @test length(recovered) == 1
    @test only(recovered).source == "PNAS"
    @test only(recovered).doi == record["doi"]
    @test isempty(warnings)
    @test length(requests) == 2 # A 403 goes straight to the independent backup.
    @test occursin("ISSN:0027-8424", requests[2])
    @test occursin("FIRST_PDATE:[$OLDEST_PUBLICATION_DATE TO $WINDOW_END_DATE]", requests[2])

    # A healthy primary still avoids all backup requests.
    primary_papers = fetch_journal_feed(feed;
        rss_fetcher=(args...; kwargs...) -> recovered,
        europepmc_fetcher=unexpected, crossref_fetcher=unexpected, warning_sink=warnings)
    @test primary_papers === recovered

    # Temporary rate limits and server failures still get bounded retries.
    for status in (429, 503)
        calls = Ref(0)
        waits = Int[]
        temporary_get = function(url; kwargs...)
            calls[] += 1
            HTTP.Response(status)
        end
        @test_throws FeedResponseError fetch_rss(feed.url, feed.name, feed.group;
            http_get=temporary_get, sleep_fn=delay -> push!(waits, delay))
        @test calls[] == RSS_MAX_RETRIES
        @test length(waits) == RSS_MAX_RETRIES - 1
    end

    # Europe PMC failures (including empty/truncated successful responses) must
    # reach the third source, which also screens the whole journal by relevance.
    crossref_record = Dict(
        "DOI" => record["doi"], "title" => [record["title"]],
        "abstract" => record["abstractText"], "type" => "journal-article",
        "author" => [Dict("given" => "A", "family" => "One")],
        "published-online" => Dict("date-parts" => [[year(WINDOW_END_DATE), month(WINDOW_END_DATE), day(WINDOW_END_DATE)]]),
    )
    cr_unrelated = merge(crossref_record, Dict("title" => [unrelated["title"]], "abstract" => unrelated["abstractText"]))
    cr_data = Dict("message" => Dict("total-results" => 2, "items" => [crossref_record, cr_unrelated]))
    cr_get = function(url; kwargs...)
        push!(requests, HTTP.unescapeuri(url))
        HTTP.Response(200, JSON3.write(cr_data))
    end
    crossref = (args...; kwargs...) -> fetch_crossref_issn_source(
        args...; kwargs..., http_get=cr_get, sleep_fn=no_sleep,
    )
    for response in (
        () -> HTTP.Response(503),
        () -> HTTP.Response(200, "not json"),
        () -> HTTP.Response(200, "{}"),
        () -> HTTP.Response(200, JSON3.write(Dict("hitCount" => 0, "resultList" => Dict("result" => [])))),
        () -> HTTP.Response(200, JSON3.write(Dict("hitCount" => 2, "resultList" => Dict("result" => [record])))),
    )
        broken_epmc = (args...; kwargs...) -> fetch_europepmc_issn_papers(
            args...; kwargs..., http_get=(url; kw...) -> response(), sleep_fn=no_sleep,
        )
        empty!(requests)
        recovered_cr = fetch_journal_feed(feed; rss_fetcher=denied_rss,
            europepmc_fetcher=broken_epmc, crossref_fetcher=crossref, warning_sink=warnings)
        @test length(recovered_cr) == 1
        @test only(recovered_cr).doi == record["doi"]
        @test isempty(warnings)
        @test occursin("issn:1091-6490", last(requests))
        @test occursin("from-pub-date:$OLDEST_PUBLICATION_DATE,until-pub-date:$WINDOW_END_DATE", last(requests))
    end

    # The exact production failure must stay visible if every route is down.
    all_failed = try
        fetch_journal_feed(feed; rss_fetcher=denied_rss,
            europepmc_fetcher=(args...; kwargs...) -> error("Europe PMC unavailable"),
            crossref_fetcher=(args...; kwargs...) -> error("Crossref unavailable"),
            warning_sink=warnings)
        nothing
    catch e
        e
    end
    @test all_failed isa ErrorException
    for detail in ("HTTP 403", "Europe PMC", "Crossref")
        @test occursin(detail, sprint(showerror, all_failed))
    end

    # Refactoring the route runner must preserve EMBO's structured primary.
    embo = only(filter(f -> f.name == "EMBO Journal", JOURNAL_FEEDS))
    embo_recovered = fetch_journal_feed(embo; rss_fetcher=unexpected,
        europepmc_fetcher=(args...; kwargs...) -> error("temporary outage"),
        crossref_fetcher=crossref, warning_sink=warnings)
    @test only(embo_recovered).source == "EMBO Journal"
end

@testset "Incomplete journal stages are retried, not cached" begin
    feed = only(filter(f -> f.name == "PNAS", JOURNAL_FEEDS))
    checkpoint = Dict{String,Vector{Paper}}()
    saves = Ref(0)
    calls = Ref(0)
    save_fn = _ -> saves[] += 1
    warnings = String[]
    fetcher = function(feed; warning_sink)
        calls[] += 1
        calls[] == 1 && error("PNAS returned HTTP 403; both backups unavailable")
        return [Paper(source="PNAS")]
    end
    fetch_journal_papers!(checkpoint; feeds=[feed], fetcher=fetcher,
                          warning_sink=warnings, save_fn=save_fn)
    @test length(warnings) == 1
    @test occursin("PNAS returned HTTP 403", only(warnings))
    @test !haskey(checkpoint, "rss")
    @test saves[] == 0

    empty!(warnings) # Next run begins with a fresh warning sink.
    recovered = fetch_journal_papers!(checkpoint; feeds=[feed], fetcher=fetcher,
                                     warning_sink=warnings, save_fn=save_fn)
    @test isempty(warnings)
    @test length(recovered) == 1
    @test calls[] == 2
    @test saves[] == 1
    @test fetch_journal_papers!(checkpoint; feeds=[feed], fetcher=fetcher,
                               warning_sink=warnings, save_fn=save_fn) === recovered
    @test calls[] == 2

    # A successful HTTP request with incomplete records is still incomplete.
    empty!(checkpoint)
    incomplete_fetcher = function(feed; warning_sink)
        push!(warning_sink, "PNAS research record is missing abstract")
        return [Paper(source="PNAS")]
    end
    fetch_journal_papers!(checkpoint; feeds=[feed], fetcher=incomplete_fetcher,
                          warning_sink=warnings, save_fn=save_fn)
    @test !haskey(checkpoint, "rss")
    @test saves[] == 1
    @test only(warnings) == "PNAS research record is missing abstract"

    mktempdir() do dir
        cd(dir) do
            legacy = Dict("from_date" => string(OLDEST_PUBLICATION_DATE), "stages" => Dict("rss" => []))
            write(CHECKPOINT_FILE, JSON3.write(legacy))
            @test isempty(load_checkpoint())
            save_checkpoint(Dict("rss" => Paper[]))
            if !FETCH_CLEAN
                @test haskey(load_checkpoint(), "rss")
            end
        end
    end
end

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
        "Biophysical Journal", "Cell", "iScience", "Current Biology", "PNAS",
    ])
    @test JOURNAL_EUROPEPMC_PRIMARY_ISSNS == Dict("EMBO Journal" => "0261-4189")
    @test JOURNAL_CROSSREF_BACKUP_ISSNS == Dict("EMBO Journal" => "1460-2075", "PNAS" => "1091-6490")
    @test CROSSREF_JOURNAL_EUROPEPMC_BACKUP_ISSNS == Dict("Cytoskeleton" => "1949-3592")

    empty_response = JSON3.read("""{"hitCount":0,"resultList":{"result":[]}}""")
    empty_count, empty_items = europepmc_response_items(
        empty_response, "Cytoskeleton"; allow_empty=true,
    )
    @test empty_count == 0
    @test isempty(empty_items)
    @test_throws ErrorException europepmc_response_items(empty_response, "Cytoskeleton")

    crossref_calls = Ref(0)
    europepmc_calls = Ref(0)
    function zero_crossref(issn, source_name, group_type; warning_sink=nothing)
        crossref_calls[] += 1
        error("Crossref returned 0 records for $source_name; completeness cannot be confirmed")
    end
    function confirmed_empty_europepmc(issn, source_name, group_type;
                                       warning_sink=nothing, allow_empty=false)
        europepmc_calls[] += 1
        @test allow_empty
        return Paper[]
    end

    confirmed_empty_warnings = String[]
    confirmed_empty = fetch_crossref_issn_papers(
        sources=[(issn="1949-3592", name="Cytoskeleton")],
        crossref_fetcher=zero_crossref,
        europepmc_fetcher=confirmed_empty_europepmc,
        warning_sink=confirmed_empty_warnings,
        sleep_fn=_ -> nothing,
    )
    @test isempty(confirmed_empty)
    @test isempty(confirmed_empty_warnings)
    @test crossref_calls[] == 1
    @test europepmc_calls[] == 1

    function unavailable_europepmc(issn, source_name, group_type;
                                   warning_sink=nothing, allow_empty=false)
        error("Europe PMC unavailable")
    end
    unavailable_warnings = String[]
    unavailable = fetch_crossref_issn_papers(
        sources=[(issn="1949-3592", name="Cytoskeleton")],
        crossref_fetcher=zero_crossref,
        europepmc_fetcher=unavailable_europepmc,
        warning_sink=unavailable_warnings,
        sleep_fn=_ -> nothing,
    )
    @test isempty(unavailable)
    @test length(unavailable_warnings) == 1
    @test occursin("Crossref primary failed", only(unavailable_warnings))
    @test occursin("Europe PMC backup failed", only(unavailable_warnings))

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
