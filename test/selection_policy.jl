using Test
include(joinpath(@__DIR__, "..", "selection_policy.jl"))
using .SelectionPolicy

function policy_paper(source, title, abstract="A substantive scientific abstract.")
    Dict(:source => source, :title => title, :abstract => abstract)
end

@testset "recall learning gate" begin
    relevant_optics = policy_paper("Optica", "Microscopy method", "We image living cells and protein membranes.")
    irrelevant_optics = policy_paper("Optica", "Generating quantum entanglement from sunlight")
    biorxiv = policy_paper("bioRxiv", "Membrane dynamics")

    @test recall_approval_supported(relevant_optics, RECALL_MIN_LOCAL_SCORE)
    @test !recall_approval_supported(irrelevant_optics, RECALL_MIN_LOCAL_SCORE)
    @test recall_approval_supported(biorxiv, RECALL_MIN_LOCAL_SCORE)
    @test !recall_approval_supported(biorxiv, RECALL_MIN_LOCAL_SCORE - 0.001)
end
