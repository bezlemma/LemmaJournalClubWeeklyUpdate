using Test, Dates
include(joinpath(@__DIR__, "..", "edition_integrity.jl"))
using .EditionIntegrity

function valid_paper(index::Int; date="2026-08-10T00:00:00+00:00", abstract=repeat("A substantive abstract sentence. ", 4))
    return Dict(
        :title => "Valid paper $index",
        :authors => "A. Author, B. Author",
        :abstract => abstract,
        :link => "https://example.org/paper/$index",
        :source => "Example Journal",
        :date => date,
    )
end

valid_item(index::Int; kwargs...) = (
    paper=valid_paper(index; kwargs...),
    summary="A complete summary contains enough words and proper punctuation.",
)

@testset "edition integrity gates" begin
    edition_date = Date(2026, 8, 10)
    valid_items = [valid_item(i) for i in 1:50]
    @test isempty(selected_edition_issues(valid_items, edition_date))

    count_issues = selected_edition_issues(valid_items[1:49], edition_date)
    @test any(contains("minimum is 50"), count_issues)

    ratio_issues = selected_edition_issues(
        valid_items,
        edition_date;
        candidate_count=153,
        min_fraction=0.50,
    )
    @test any(contains("minimum is 77 for 153 valid candidates"), ratio_issues)
    @test required_edition_size(153; min_papers=50, min_fraction=0.50) == 77

    stale_items = copy(valid_items)
    stale_items[1] = valid_item(1; date="2026-08-02T23:59:59+00:00")
    @test any(contains("older than"), selected_edition_issues(stale_items, edition_date))

    boundary_items = copy(valid_items)
    boundary_items[1] = valid_item(1; date="2026-08-03T00:00:00+00:00")
    @test isempty(selected_edition_issues(boundary_items, edition_date))

    future_items = copy(valid_items)
    future_items[1] = valid_item(1; date="2026-08-11T00:00:00+00:00")
    @test any(contains("after edition date"), selected_edition_issues(future_items, edition_date))

    revised_preprint_items = copy(valid_items)
    revised_preprint = valid_paper(1; date="2026-08-10T00:00:00+00:00")
    revised_preprint[:source] = "bioRxiv"
    revised_preprint[:link] = "https://www.biorxiv.org/content/10.1101/2023.08.22.554088v2"
    revised_preprint_items[1] = (paper=revised_preprint, summary=valid_items[1].summary)
    @test any(contains("publication date 2023-08-22 is older"),
              selected_edition_issues(revised_preprint_items, edition_date))

    featured_preprint_items = copy(valid_items)
    featured_preprint = valid_paper(1; date="2026-08-10T00:00:00+00:00")
    featured_preprint[:source] = "CrossRef/Featured"
    featured_preprint[:link] = "https://doi.org/10.64898/2026.07.31.742166"
    featured_preprint_items[1] = (paper=featured_preprint, summary=valid_items[1].summary)
    @test any(contains("publication date 2026-07-31 is older"),
              selected_edition_issues(featured_preprint_items, edition_date))

    placeholder_items = copy(valid_items)
    placeholder_items[1] = (
        paper=valid_paper(1; abstract="Abstract not available via CrossRef API."),
        summary="Abstract not available via CrossRef API.",
    )
    placeholder_issues = selected_edition_issues(placeholder_items, edition_date)
    @test any(contains("placeholder text"), placeholder_issues)

    for field in (:title, :authors, :abstract, :link, :source, :date)
        blank_items = copy(valid_items)
        blank_paper = valid_paper(1)
        blank_paper[field] = ""
        blank_items[1] = (paper=blank_paper, summary=valid_items[1].summary)
        @test any(contains("$field is blank"), selected_edition_issues(blank_items, edition_date))
    end

    fragment_items = copy(valid_items)
    fragment_items[1] = (paper=valid_paper(1), summary="Mid-spindle microtubules maintain invariant")
    @test any(contains("complete sentence"), selected_edition_issues(fragment_items, edition_date))

    duplicate_items = copy(valid_items)
    duplicate_items[2] = (paper=valid_paper(1), summary=valid_items[2].summary)
    @test any(contains("duplicate"), selected_edition_issues(duplicate_items, edition_date))

    substantive_unknown = "Abstract Pyrenoids perform carbon fixation, but one detailed mechanism is currently unknown. " *
                          "Experiments here resolve that mechanism quantitatively."
    @test !is_placeholder_text(substantive_unknown)

    kept, removed = sanitize_candidates([valid_paper(1), valid_paper(2; date="2026-06-17T00:00:00+00:00")], edition_date)
    @test length(kept) == 1
    @test length(removed) == 1
end
