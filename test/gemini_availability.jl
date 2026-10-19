using Test

if !isdefined(Main, :reset_gemini_guard_for_test!)
    include(joinpath(@__DIR__, "gemini_safety_guard.jl"))
end

const TEST_CLASSIFICATION = """{"score":90,"category":"cell mechanics","explanation":"Measures forces in living cells."}"""

function provider_failure(status; message="Provider rejected the request.")
    HTTP.Response(status, JSON3.write(Dict("error" => Dict(
        "code" => status, "status" => "RESOURCE_EXHAUSTED", "message" => message,
    ))))
end

function provider_success(text=TEST_CLASSIFICATION)
    HTTP.Response(200, JSON3.write(Dict(
        "candidates" => [Dict("finishReason" => "STOP", "content" => Dict(
            "parts" => [Dict("text" => text)],
        ))],
        "usageMetadata" => Dict("promptTokenCount" => 50, "candidatesTokenCount" => 25),
    )))
end

function fake_generate(transport; max_retries=3)
    gemini_generate("Test classification"; api_key="test-key", transport, max_retries,
                    sleep_fn=_->nothing, cooldown_fn=()->nothing)
end

@testset "permanent provider failures stop the entire run" begin
    for status in (400, 401, 402, 403, 404)
        reset_gemini_guard_for_test!()
        calls = Ref(0)
        transport = (args...; kwargs...) -> begin
            calls[] += 1
            @test kwargs[:retry] == false # Retries must pass through the accounting guard.
            provider_failure(status; message=status == 402 ? "Your prepayment credits are depleted." : "Provider rejected the request.")
        end
        @test isempty(fake_generate(transport))
        # Simulate the remaining papers and their repair pass: no more HTTP calls.
        @test all(isempty(fake_generate(transport)) for _ in 1:412)
        @test calls[] == GEMINI_REQUEST_COUNT[] == 1
        @test GEMINI_IN_FLIGHT_COST_USD[] == 0.0
        @test GEMINI_REPORTED_COST_USD[] == GEMINI_UNREPORTED_COST_USD[] == 0.0
        @test !GEMINI_BUDGET_EXHAUSTED[]
        @test_throws ErrorException require_gemini_available!()
        @test GEMINI_ERROR_COUNTS[string(status)] == 1
        if status == 402
            @test GEMINI_FATAL_ERROR[]["kind"] == "billing"
            @test occursin("prepaid balance", gemini_error_reason(GEMINI_FATAL_ERROR[]))
        end
    end
end

@testset "a billing failure drains in-flight workers without launching new requests" begin
    reset_gemini_guard_for_test!()
    calls = Ref(0)
    entered = Channel{Nothing}(4)
    release = Channel{Nothing}(4)
    transport = (args...; kwargs...) -> begin
        calls[] += 1
        put!(entered, nothing)
        take!(release)
        provider_failure(402; message="Your prepayment credits are depleted.")
    end
    semaphore = Base.Semaphore(4)
    @sync begin
        for _ in 1:30
            @async begin
                Base.acquire(semaphore)
                try
                    fake_generate(transport)
                finally
                    Base.release(semaphore)
                end
            end
        end
        @async begin
            for _ in 1:4; take!(entered); end
            for _ in 1:4; put!(release, nothing); end
        end
    end
    @test calls[] == GEMINI_REQUEST_COUNT[] == 4
    @test GEMINI_IN_FLIGHT_COST_USD[] ≈ 0.0 atol=1e-12
    @test GEMINI_ERROR_COUNTS["402"] == 4
end

@testset "temporary failures still recover with bounded retries" begin
    for status in (408, 429, 503)
        reset_gemini_guard_for_test!()
        calls = Ref(0)
        transport = (args...; kwargs...) -> begin
            calls[] += 1
            calls[] == 1 ? provider_failure(status) : provider_success()
        end
        @test fake_generate(transport) == TEST_CLASSIFICATION
        @test calls[] == 2
        @test GEMINI_FATAL_ERROR[] === nothing
        @test GEMINI_IN_FLIGHT_COST_USD[] ≈ 0.0 atol=1e-12
        @test GEMINI_REPORTED_COST_USD[] > 0
        status == 429 && @test GEMINI_COOLDOWN_UNTIL[] > time()
    end
    reset_gemini_guard_for_test!()
    calls = Ref(0)
    unavailable = (args...; kwargs...) -> (calls[] += 1; provider_failure(503))
    @test isempty(fake_generate(unavailable))
    @test calls[] == 3
    @test GEMINI_FATAL_ERROR[] === nothing

    reset_gemini_guard_for_test!()
    depleted = (args...; kwargs...) -> provider_failure(429; message="Your prepayment credits are depleted.")
    @test isempty(fake_generate(depleted))
    @test GEMINI_REQUEST_COUNT[] == 1
    @test GEMINI_FATAL_ERROR[]["kind"] == "billing"
end

@testset "preflight validates actual model output and preserves provider errors" begin
    reset_gemini_guard_for_test!()
    @test preflight_gemini(; generate=_->TEST_CLASSIFICATION) === nothing
    @test_throws ErrorException preflight_gemini(; generate=_->"not valid classification data")

    reset_gemini_guard_for_test!()
    depleted = (args...; kwargs...) -> provider_failure(402; message="Your prepayment credits are depleted.")
    failure = try
        preflight_gemini(; generate=_->fake_generate(depleted))
        nothing
    catch error
        error
    end
    @test failure isa ErrorException
    @test occursin("HTTP 402", sprint(showerror, failure))
    @test occursin("prepayment credits are depleted", sprint(showerror, failure))
    @test GEMINI_REQUEST_COUNT[] == 1
    mktempdir() do directory
        cd(directory) do
            write_pipeline_status("failed", sprint(showerror, failure))
            status = JSON3.read(read(PIPELINE_STATUS_FILE, String))
            diagnostics = JSON3.read(read(GEMINI_DIAGNOSTICS_FILE, String))
            @test status.provider_error.http_status == 402
            @test diagnostics.fatal_error.kind == "billing"
            @test diagnostics.request_count == 1
            @test !isfile(OUTPUT_FILE)
        end
    end
end

@testset "provider diagnostics redact credentials and exclude raw response bodies" begin
    dummy_key = "AIzaFakeCredentialForRegressionTest"
    response = JSON3.write(Dict("error" => Dict(
        "message" => "Denied $dummy_key\nhttps://example.test?key=another-secret&other=value Bearer token-value",
    )))
    detail = gemini_api_error(403, response; api_key=dummy_key)
    @test !occursin(dummy_key, detail["message"])
    @test !occursin("another-secret", detail["message"])
    @test !occursin("token-value", detail["message"])
    @test !occursin('\n', detail["message"])
    @test length(sanitize_gemini_error(repeat("x", 2000))) == 800
    raw = gemini_api_error(502, "<html>private proxy response</html>")
    @test !occursin("private proxy", raw["message"])
end

reset_gemini_guard_for_test!()
